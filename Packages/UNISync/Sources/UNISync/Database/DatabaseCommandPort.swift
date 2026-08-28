import Foundation
import GRDB
import UNICore

/// A porta de escrita real: `MailCommandPort` sobre o `SyncDatabase`.
///
/// **O conserto do defeito do dono.** Cada método faz duas coisas na
/// **mesma transação** (`database.pool.write`, que já é uma transação
/// SQLite): grava a projeção na tabela `message` — o estado local, que é o
/// que o próximo retrato lido do banco vai devolver — e enfileira a operação
/// no `outbox`, para o executor (fora do escopo desta tarefa) mandar ao
/// servidor. Sem a primeira metade, uma mutação otimista no `MailStore` era
/// desfeita pelo próximo retrato que a `ValueObservation` entregasse, porque
/// o banco nunca soubera da mudança — exatamente o que o dono viu com conta
/// real. Com as duas na mesma transação, ou as duas acontecem, ou nenhuma:
/// não há um mundo em que a fila tem a operação e a tela ainda mostra o
/// estado velho, nem o contrário.
///
/// Síncrona e não `async`: é uma escrita de SQLite local, nunca rede, e
/// `MailStore.setRead`, `.move`, `.deleteForever` e `.emptyTrash` já são
/// síncronos em toda a superfície pública deles. Uma porta assíncrona
/// obrigaria a disparar um `Task` a partir de um método síncrono — e então
/// o teste teria de esperar por ele para poder afirmar qualquer coisa,
/// correndo atrás de uma corrida que não precisa existir.
public struct DatabaseCommandPort: MailCommandPort, Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    public func setRead(_ isRead: Bool, accountID: String, messageIDs: [String]) throws {
        try run(accountID: accountID, operation: .setRead(isRead: isRead, messageIDs: messageIDs)) { db in
            try Self.scoped(accountID: accountID, ids: messageIDs)
                .updateAll(db, Column("isRead").set(to: isRead))
        }
    }

    public func setFlagged(_ isFlagged: Bool, accountID: String, messageIDs: [String]) throws {
        try run(accountID: accountID, operation: .setFlagged(isFlagged: isFlagged, messageIDs: messageIDs)) { db in
            try Self.scoped(accountID: accountID, ids: messageIDs)
                .updateAll(db, Column("isFlagged").set(to: isFlagged))
        }
    }

    public func move(to bucket: TriageBucket, accountID: String, messageIDs: [String]) throws {
        try run(accountID: accountID, operation: .move(bucket: bucket.rawValue, messageIDs: messageIDs)) { db in
            try Self.scoped(accountID: accountID, ids: messageIDs)
                .updateAll(db, Column("bucket").set(to: bucket.rawValue))
        }
    }

    /// Move para a Lixeira. É `bucket = trash`, e não uma linha apagada — a
    /// mensagem continua existindo, visível na caixa Lixeira, até
    /// `deletePermanently` ou `emptyTrash`.
    public func delete(accountID: String, messageIDs: [String]) throws {
        try run(accountID: accountID, operation: .delete(messageIDs: messageIDs)) { db in
            try Self.scoped(accountID: accountID, ids: messageIDs)
                .updateAll(db, Column("bucket").set(to: TriageBucket.trash.rawValue))
        }
    }

    public func deletePermanently(accountID: String, messageIDs: [String]) throws {
        try run(accountID: accountID, operation: .deletePermanently(messageIDs: messageIDs)) { db in
            try Self.scoped(accountID: accountID, ids: messageIDs).deleteAll(db)
        }
    }

    public func emptyTrash(accountID: String) throws {
        try run(accountID: accountID, operation: .emptyTrash) { db in
            try MessageRecord
                .filter(Column("accountID") == accountID)
                .filter(Column("bucket") == TriageBucket.trash.rawValue)
                .deleteAll(db)
        }
    }

    private static func scoped(accountID: String, ids: [String]) -> QueryInterfaceRequest<MessageRecord> {
        MessageRecord
            .filter(keys: ids)
            .filter(Column("accountID") == accountID)
    }

    /// A transação comum aos seis métodos: a projeção primeiro, o
    /// enfileiramento depois, as duas ou nenhuma.
    private func run(
        accountID: String, operation: MailOperation, projection: @escaping (Database) throws -> Void
    ) throws {
        try database.pool.write { db in
            try projection(db)
            let record = try OutboxRecord(accountID: accountID, operation: operation)
            // `ON CONFLICT(idempotencyKey) DO NOTHING`: a mesma intenção
            // (mesma conta, mesmo tipo, mesmos ids) chamada de novo não
            // duplica a fila — a idempotência da chave.
            try db.execute(
                sql: """
                    INSERT INTO outbox
                      (id, accountID, operationJSON, idempotencyKey, attempts, nextAttemptAt, state, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(idempotencyKey) DO NOTHING
                    """,
                arguments: [
                    record.id, record.accountID, record.operationJSON, record.idempotencyKey,
                    record.attempts, record.nextAttemptAt.timeIntervalSince1970,
                    record.state, record.createdAt.timeIntervalSince1970,
                ]
            )
        }
    }
}
