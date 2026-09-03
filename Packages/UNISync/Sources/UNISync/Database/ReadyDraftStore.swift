import Foundation
import GRDB
import UNICore

/// A linha de `ready_draft`. As colunas usam `snake_case` porque a spec as
/// nomeia assim; as propriedades seguem o Swift — o mesmo contrato de
/// `MessageIntelligenceRecord`.
struct ReadyDraftRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "ready_draft"

    var messageID: String
    var text: String
    var contentHash: String
    var modelVersion: String
    var usedAgenda: Bool
    var createdAt: Date
    /// A versão da mensagem cujo rascunho a pessoa descartou. `nil` enquanto
    /// ninguém descartou nada.
    var discardedHash: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case text
        case contentHash = "content_hash"
        case modelVersion = "model_version"
        case usedAgenda = "used_agenda"
        case createdAt = "created_at"
        case discardedHash = "discarded_hash"
    }

    /// A coluna é `DOUBLE`, como em toda data deste banco.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    /// O rascunho que a tela pode oferecer. `nil` quando a linha existe só
    /// para lembrar de um descarte.
    var draft: ReadyDraft? {
        guard discardedHash != contentHash, !text.isEmpty else { return nil }
        return ReadyDraft(
            messageID: messageID, text: text, contentHash: contentHash,
            modelVersion: modelVersion, usedAgenda: usedAgenda
        )
    }
}

/// A fronteira de persistência do rascunho antecipado.
///
/// Ela não conhece motor nem tela: decide o que ainda precisa de rascunho e
/// grava a resposta pronta. É a irmã de `MessageIntelligenceStore`, com uma
/// diferença de contrato que vale escrever: aqui **não existe** estado
/// intermediário. A análise precisa de `processing` porque uma queda no meio
/// dela deixaria a mensagem sem resumo para sempre; um rascunho perdido no
/// meio simplesmente não existe, e a volta seguinte da fila o escreve de novo.
public struct ReadyDraftStore: Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    /// Os rascunhos que a tela pode mostrar para estas mensagens.
    ///
    /// **Não confere o hash aqui**: quem sabe qual é a versão corrente da
    /// mensagem é quem tem a `Message` na mão, e `ReadyDraft.matches(_:)` é a
    /// pergunta dele. Devolver só o que casa exigiria reler todos os corpos.
    public func drafts(for messageIDs: [String]) throws -> [String: ReadyDraft] {
        guard !messageIDs.isEmpty else { return [:] }
        return try database.pool.read { db in
            let registros = try ReadyDraftRecord
                .filter(keys: messageIDs)
                .fetchAll(db)
            return Dictionary(
                registros.compactMap { registro in registro.draft.map { (registro.messageID, $0) } },
                uniquingKeysWith: { primeiro, _ in primeiro }
            )
        }
    }

    /// Grava (ou regrava) o rascunho desta versão da mensagem.
    ///
    /// Um rascunho novo apaga o descarte: ele foi escrito para **outra**
    /// versão do texto — a fila nunca chega aqui com o hash recusado, porque
    /// `isDiscarded` a barra antes.
    public func save(_ draft: ReadyDraft, at date: Date = Date()) throws {
        try database.pool.write { db in
            try ReadyDraftRecord(
                messageID: draft.messageID, text: draft.text,
                contentHash: draft.contentHash, modelVersion: draft.modelVersion,
                usedAgenda: draft.usedAgenda, createdAt: date, discardedHash: nil
            ).save(db)
        }
    }

    /// "Descartar" da linha: o texto sai e o hash fica.
    ///
    /// A linha **não** é apagada, e é essa a decisão inteira: apagá-la faria a
    /// fila reescrever o mesmo rascunho na volta seguinte da observação, e o
    /// botão de descartar não descartaria nada.
    public func discard(messageID: String) throws {
        try database.pool.write { db in
            guard let registro = try ReadyDraftRecord.fetchOne(db, key: messageID) else { return }
            var descartado = registro
            descartado.text = ""
            descartado.discardedHash = registro.contentHash
            try descartado.update(db)
        }
    }

    /// A pessoa já recusou o rascunho **desta** versão da mensagem?
    public func isDiscarded(messageID: String, contentHash: String) throws -> Bool {
        try database.pool.read { db in
            try ReadyDraftRecord.fetchOne(db, key: messageID)?.discardedHash == contentHash
        }
    }
}

/// A porta de regras **do disco**: onde "este remetente nunca é prioridade"
/// passa a noite. Ver `UNICore.SenderRuling`.
public struct DatabaseSenderRuleStore: SenderRuling {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    public func learnSender(_ address: String, neverPriority: Bool, at date: Date) throws {
        let normalizado = SenderRule.normalize(address)
        guard !normalizado.isEmpty else { return }
        _ = try database.pool.write { db in
            guard neverPriority else {
                return try SenderRuleRecord.deleteOne(db, key: normalizado)
            }
            // `save` é upsert pela chave primária: ensinar duas vezes o mesmo
            // remetente é a mesma decisão, não uma linha nova.
            try SenderRuleRecord(
                address: normalizado, neverPriority: true, createdAt: date
            ).save(db)
            return true
        }
    }

    public func senderRules() throws -> [SenderRule] {
        try database.pool.read { db in
            try SenderRuleRecord
                .order(Column("address"))
                .fetchAll(db)
                .map(\.rule)
        }
    }
}

/// A linha de `sender_rule`.
struct SenderRuleRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "sender_rule"

    /// Já normalizado — a regra da normalização é uma só e mora em
    /// `SenderRule.normalize`. Gravar cru faria `News@` e `news@` virarem dois
    /// remetentes, e a lista da pessoa ficaria com o mesmo endereço duas vezes.
    var address: String
    var neverPriority: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case address
        case neverPriority = "never_priority"
        case createdAt = "created_at"
    }

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    var rule: SenderRule {
        SenderRule(address: address, neverPriority: neverPriority, createdAt: createdAt)
    }
}
