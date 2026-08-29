import Foundation
import GRDB
import UNICore

/// A porta de confiança **do disco**: onde o "sempre carregar deste remetente"
/// passa a noite.
///
/// Ver `UNICore.SenderTrusting` para a queixa que ela atende ("toda hora tenho
/// que clicar em Carregar") e para as duas decisões que a moldam: por endereço
/// exato, e sem dono — a confiança é da pessoa, não da conta.
///
/// Síncrona, como o protocolo pede: quem pergunta é o leitor, no meio do
/// desenho, e a resposta já está em memória no `MailStore` — o que chega aqui é
/// a leitura única da montagem e as duas escritas do clique.
public struct DatabaseTrustedSenderStore: SenderTrusting {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    public func trustSender(_ address: String) throws {
        let normalizado = SenderTrust.normalize(address)
        guard !normalizado.isEmpty else { return }
        try database.pool.write { db in
            // `save` é upsert pela chave primária: confiar de novo no mesmo
            // remetente não é erro nem linha nova — é a mesma decisão.
            try TrustedSenderRecord(address: normalizado, createdAt: Date()).save(db)
        }
    }

    public func revokeSenderTrust(_ address: String) throws {
        let normalizado = SenderTrust.normalize(address)
        _ = try database.pool.write { db in
            try TrustedSenderRecord.deleteOne(db, key: normalizado)
        }
    }

    public func trustedSenders() throws -> Set<String> {
        try database.pool.read { db in
            Set(try TrustedSenderRecord.fetchAll(db).map(\.address))
        }
    }
}

/// A linha de `trusted_sender`.
struct TrustedSenderRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "trusted_sender"

    /// Já normalizado — a normalização é uma regra só, e mora em
    /// `SenderTrust.normalize`. Gravar cru aqui faria `Noreply@` e `noreply@`
    /// virarem dois remetentes, e a faixa voltar para quem já tinha confiado.
    var address: String
    var createdAt: Date
}
