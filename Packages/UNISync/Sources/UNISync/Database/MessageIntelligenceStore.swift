import CryptoKit
import Foundation
import GRDB
import UNICore

/// O ciclo de vida do resultado local de inteligência de uma mensagem.
///
/// A linha só é criada quando um trabalhador assume uma mensagem. Até lá, a
/// ausência de estado significa `pending`, o que inclui naturalmente todas as
/// mensagens anteriores à migração.
public enum MessageIntelligenceState: String, Sendable, Codable, CaseIterable {
    case pending
    case processing
    case completed
    case failed
    case unsupported
}

/// A entrada autocontida que o motor consome da fila local.
///
/// `contentHash` é calculado do corpo exato que sai de `plain`; ele deve voltar
/// em toda transição para impedir que um resultado atrasado sobrescreva uma
/// mensagem que mudou enquanto era analisada.
public struct MessageIntelligenceWork: Sendable, Equatable {
    public let messageID: String
    public let accountID: String
    public let fromName: String
    public let fromAddress: String
    public let subject: String
    public let receivedAt: Date
    public let plainBody: String
    public let contentHash: String
    /// Quando a mensagem apareceu neste Mac — a coluna `firstSeenAt` da v16.
    public let firstSeenAt: Date?

    public static func contentHash(for plainBody: String) -> String {
        SHA256.hash(data: Data(plainBody.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A fronteira de persistência da fila de inteligência. Ela não conhece motor,
/// UI ou modelos Foundation: só decide qual corpo pode ser trabalhado e grava
/// transições consistentes no SQLite.
public struct MessageIntelligenceStore: Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    /// Devolve no máximo `limit` corpos utilizáveis que ainda precisam de
    /// trabalho. Uma linha terminal com o mesmo hash fica fora; um hash novo
    /// entra uma vez de novo, inclusive se a tentativa anterior falhou. Um
    /// `processing` é retomável: após um crash, o único runner serial o assume
    /// de novo na próxima abertura em vez de deixá-lo preso para sempre.
    /// `acceptedModelVersions` vazio significa "só `modelVersion` serve" — o
    /// comportamento de sempre. Um roteador que grava resultados sob mais de
    /// uma versão legítima passa as duas, e nenhuma delas volta para a fila.
    /// `excludingMessageIDs` é o que o ciclo já tentou e não pôde andar — a
    /// mensagem cujo motor não responde agora. Sem isto o mesmo item volta ao
    /// topo a cada volta do laço e o histórico atrás dele nunca é analisado.
    public func pendingWork(
        limit: Int = 20,
        modelVersion: String? = nil,
        acceptedModelVersions: Set<String> = [],
        priorityMessageID: String? = nil,
        excludingMessageIDs: Set<String> = []
    ) throws -> [MessageIntelligenceWork] {
        guard limit > 0 else { return [] }
        return try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                      m.id AS messageID,
                      m.accountID,
                      m.fromName,
                      m.fromAddress,
                      m.subject,
                      m.receivedAt,
                      m.firstSeenAt,
                      b.plain,
                      i.contentHash,
                      i.state,
                      i.modelVersion
                    FROM message m
                    JOIN message_body b ON b.messageID = m.id
                    LEFT JOIN message_intelligence i ON i.messageID = m.id
                    WHERE b.plain != ''
                    ORDER BY
                      CASE WHEN m.id = ? THEN 0 ELSE 1 END,
                      m.receivedAt DESC,
                      m.id ASC
                    """,
                arguments: [priorityMessageID]
            )
            return rows.compactMap { row -> MessageIntelligenceWork? in
                let id: String = row["messageID"]
                guard !excludingMessageIDs.contains(id) else { return nil }
                return Self.workIfPending(
                    row,
                    modelVersion: modelVersion,
                    acceptedModelVersions: acceptedModelVersions
                )
            }.prefix(limit).map { $0 }
        }
    }

    /// Assume uma entrada pendente. `false` quer dizer que outro trabalhador
    /// já a assumiu, que ela deixou de ter corpo utilizável, ou que o corpo
    /// mudou desde a leitura da fila.
    @discardableResult
    public func markProcessing(
        _ work: MessageIntelligenceWork,
        modelVersion: String,
        acceptedModelVersions: Set<String> = [],
        at: Date = Date()
    ) throws -> Bool {
        try database.pool.write { db in
            guard try Self.currentContentMatches(work, in: db) else { return false }

            let existing = try MessageIntelligenceRecord.fetchOne(db, key: work.messageID)
            let modelChanged = !Self.accepted(modelVersion, acceptedModelVersions)
                .contains(existing?.modelVersion ?? "")
            if let existing,
               existing.contentHash == work.contentHash,
               existing.state != MessageIntelligenceState.pending.rawValue,
               existing.state != MessageIntelligenceState.processing.rawValue,
               !modelChanged {
                return false
            }

            // Um resultado de um corpo antigo não pode continuar visível
            // enquanto a nova versão espera processamento.
            if let existing,
               existing.contentHash != work.contentHash || modelChanged {
                try db.execute(
                    sql: "UPDATE message SET summary = NULL, detectedEventJSON = NULL, category = NULL WHERE id = ?",
                    arguments: [work.messageID]
                )
            }

            try Self.upsert(
                db, work: work, state: .processing, modelVersion: modelVersion,
                lastError: nil, at: at
            )
            return true
        }
    }

    /// Persiste o resultado e fecha o trabalho em **uma** transação. O hash e
    /// o estado `processing` são conferidos antes das duas escritas, portanto
    /// uma conclusão atrasada não deixa resumo sem a transição correspondente.
    @discardableResult
    public func markCompleted(
        _ work: MessageIntelligenceWork,
        modelVersion: String,
        summary: String?,
        detectedEventJSON: String?,
        category: MailCategory? = nil,
        at: Date = Date()
    ) throws -> Bool {
        try database.pool.write { db in
            guard try Self.canFinish(work, in: db) else { return false }
            try db.execute(
                sql: """
                    UPDATE message
                    SET summary = ?, detectedEventJSON = ?, category = ?
                    WHERE id = ?
                    """,
                arguments: [summary, detectedEventJSON, category?.rawValue, work.messageID]
            )
            try Self.updateClaimed(
                db, work: work, state: .completed, modelVersion: modelVersion,
                lastError: nil, at: at
            )
            return true
        }
    }

    /// Fecha uma tentativa que falhou. Ela não volta sozinha para a fila com o
    /// mesmo hash; só uma alteração real do corpo a reabre, evitando loop.
    @discardableResult
    public func markFailed(
        _ work: MessageIntelligenceWork,
        modelVersion: String? = nil,
        error: String,
        at: Date = Date()
    ) throws -> Bool {
        try markTerminal(
            work, state: .failed, modelVersion: modelVersion, lastError: error, at: at
        )
    }

    /// Fecha mensagens que o motor deliberadamente não suporta. Como `failed`,
    /// este estado é terminal para o mesmo conteúdo e reabre só com hash novo.
    @discardableResult
    public func markUnsupported(
        _ work: MessageIntelligenceWork,
        modelVersion: String? = nil,
        error: String? = nil,
        at: Date = Date()
    ) throws -> Bool {
        try markTerminal(
            work, state: .unsupported, modelVersion: modelVersion, lastError: error, at: at
        )
    }

    /// Devolve à fila uma entrada que foi assumida mas **não** chegou a ser
    /// tentada — o motor dela recusou antes da primeira palavra. Deixá-la em
    /// `processing` faria a linha parecer trabalho em andamento para sempre;
    /// marcá-la como falha culparia a mensagem por um defeito de configuração.
    @discardableResult
    public func markPending(
        _ work: MessageIntelligenceWork,
        modelVersion: String? = nil,
        at: Date = Date()
    ) throws -> Bool {
        try markState(work, state: .pending, modelVersion: modelVersion, lastError: nil, at: at)
    }

    private func markTerminal(
        _ work: MessageIntelligenceWork,
        state: MessageIntelligenceState,
        modelVersion: String?,
        lastError: String?,
        at: Date
    ) throws -> Bool {
        try markState(work, state: state, modelVersion: modelVersion, lastError: lastError, at: at)
    }

    private func markState(
        _ work: MessageIntelligenceWork,
        state: MessageIntelligenceState,
        modelVersion: String?,
        lastError: String?,
        at: Date
    ) throws -> Bool {
        try database.pool.write { db in
            guard try Self.canFinish(work, in: db) else { return false }
            try Self.updateClaimed(
                db, work: work, state: state, modelVersion: modelVersion,
                lastError: lastError, at: at
            )
            return true
        }
    }

    private static func workIfPending(
        _ row: Row,
        modelVersion: String?,
        acceptedModelVersions: Set<String>
    ) -> MessageIntelligenceWork? {
        let plainBody: String = row["plain"]
        guard hasUsableBody(plainBody) else { return nil }
        let contentHash = MessageIntelligenceWork.contentHash(for: plainBody)
        let storedHash: String? = row["contentHash"]
        let storedModelVersion: String? = row["modelVersion"]
        let state = (row["state"] as String?).flatMap(MessageIntelligenceState.init(rawValue:))
        let modelChanged = modelVersion.map {
            !Self.accepted($0, acceptedModelVersions).contains(storedModelVersion ?? "")
        } ?? false
        guard storedHash == nil || storedHash != contentHash || state == .pending
            || state == .processing || modelChanged
        else { return nil }
        return MessageIntelligenceWork(
            messageID: row["messageID"], accountID: row["accountID"],
            fromName: row["fromName"], fromAddress: row["fromAddress"],
            subject: row["subject"], receivedAt: Date(timeIntervalSince1970: row["receivedAt"]),
            plainBody: plainBody, contentHash: contentHash,
            firstSeenAt: (row["firstSeenAt"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }

    /// O conjunto vazio é o caso comum, e nele a única versão aceita é a que
    /// o motor está usando agora.
    private static func accepted(
        _ modelVersion: String,
        _ acceptedModelVersions: Set<String>
    ) -> Set<String> {
        acceptedModelVersions.isEmpty ? [modelVersion] : acceptedModelVersions
    }

    private static func hasUsableBody(_ plainBody: String) -> Bool {
        !plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func currentContentMatches(_ work: MessageIntelligenceWork, in db: Database) throws -> Bool {
        guard let plainBody = try String.fetchOne(
            db,
            sql: "SELECT plain FROM message_body WHERE messageID = ?",
            arguments: [work.messageID]
        ), hasUsableBody(plainBody) else { return false }
        return MessageIntelligenceWork.contentHash(for: plainBody) == work.contentHash
    }

    private static func canFinish(_ work: MessageIntelligenceWork, in db: Database) throws -> Bool {
        guard try currentContentMatches(work, in: db),
              let record = try MessageIntelligenceRecord.fetchOne(db, key: work.messageID)
        else { return false }
        return record.contentHash == work.contentHash
            && record.state == MessageIntelligenceState.processing.rawValue
    }

    private static func upsert(
        _ db: Database,
        work: MessageIntelligenceWork,
        state: MessageIntelligenceState,
        modelVersion: String?,
        lastError: String?,
        at: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO message_intelligence
                  (messageID, contentHash, state, modelVersion, lastError, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(messageID) DO UPDATE SET
                  contentHash = excluded.contentHash,
                  state = excluded.state,
                  modelVersion = excluded.modelVersion,
                  lastError = excluded.lastError,
                  updatedAt = excluded.updatedAt
                """,
            arguments: [
                work.messageID, work.contentHash, state.rawValue,
                modelVersion, lastError, at.timeIntervalSince1970,
            ]
        )
    }

    private static func updateClaimed(
        _ db: Database,
        work: MessageIntelligenceWork,
        state: MessageIntelligenceState,
        modelVersion: String?,
        lastError: String?,
        at: Date
    ) throws {
        try db.execute(
            sql: """
                UPDATE message_intelligence
                SET state = ?,
                    modelVersion = COALESCE(?, modelVersion),
                    lastError = ?,
                    updatedAt = ?
                WHERE messageID = ? AND contentHash = ? AND state = ?
                """,
            arguments: [
                state.rawValue, modelVersion, lastError, at.timeIntervalSince1970,
                work.messageID, work.contentHash, MessageIntelligenceState.processing.rawValue,
            ]
        )
    }
}

/// A forma crua da tabela. O formato fica aqui, perto da fila, em vez de
/// contaminar `Message` com detalhes de tentativa/modelo.
struct MessageIntelligenceRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "message_intelligence"

    var messageID: String
    var contentHash: String
    var state: String
    var modelVersion: String?
    var lastError: String?
    var updatedAt: Date

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension MessageRecord {
    /// Regravar metadados vindos do servidor não pode apagar a projeção local
    /// de inteligência. Os quatro caminhos de sync montam `Message` com
    /// `summary` e `detectedEvent` nulos; preservamos o que já foi calculado
    /// quando o servidor não trouxe um novo valor para esses campos.
    func savePreservingIntelligenceProjection(_ db: Database) throws {
        var record = self
        if let current = try MessageRecord.fetchOne(db, key: id) {
            if record.summary == nil { record.summary = current.summary }
            if record.detectedEventJSON == nil {
                record.detectedEventJSON = current.detectedEventJSON
            }
            if record.category == nil { record.category = current.category }
            // "Primeira vez que vi" não anda para a frente: um re-sync da
            // mesma mensagem não pode fazê-la parecer recém-chegada e cair
            // no consentimento que a pessoa deu para mensagens novas.
            if let visto = current.firstSeenAt {
                record.firstSeenAt = min(visto, record.firstSeenAt ?? visto)
            }
        }
        try record.save(db)
    }
}
