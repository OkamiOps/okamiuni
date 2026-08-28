import Foundation
import GRDB
import UNICore

/// `MailSource` lendo do banco. **A fonte de verdade da UI quando há conta.**
///
/// Nada aqui espera rede: o pior caso é uma leitura de SQLite local. É o que
/// faz o app abrir offline mostrando os 90 dias, e é por isso que a rede
/// escreve no banco em vez de falar com a tela.
public struct DatabaseMailSource: MailSource, Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    public func accounts() async throws -> [Account] {
        try await database.pool.read { db in
            try AccountRecord.order(Column("createdAt")).fetchAll(db).map(\.account)
        }
    }

    public func messages() async throws -> [Message] {
        try await database.pool.read { try Self.messages(in: $0) }
    }

    public func agenda() async throws -> [AgendaItem] {
        try await database.pool.read { db in
            try AgendaItemRecord.fetchAll(db).map(\.item)
        }
    }

    /// Sem tabela: `PendingItem` é a seção "Vindo do email" do Marco 1, que
    /// nasce da detecção no dispositivo e não do servidor. Lista vazia é a
    /// resposta honesta — inventar uma tabela vazia seria pior.
    public func pendingItems() async throws -> [PendingItem] { [] }

    /// O retrato inteiro numa leitura só, e não quatro.
    ///
    /// Quatro `read` seriam quatro instantâneos diferentes do banco: a carga
    /// inicial grava mensagem e corpo em lotes, e um retrato montado de quatro
    /// leituras pode ter a mensagem de um lote sem o corpo dele. Uma
    /// transação de leitura vê um estado consistente e pronto.
    public func snapshot() async throws -> MailSnapshot {
        try await database.pool.read { db in try Self.snapshot(in: db) }
    }

    /// A observação: um retrato agora, e outro a cada escrita que mexa no que
    /// a UI mostra.
    ///
    /// `ValueObservation` observa as tabelas que a consulta toca, então uma
    /// escrita em `sync_state` não acorda a lista à toa, e um lote da carga
    /// inicial acorda.
    public func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        let pool = database.pool
        return AsyncThrowingStream { continuation in
            let tarefa = Task {
                do {
                    let observacao = ValueObservation.tracking { db in
                        try Self.snapshot(in: db)
                    }
                    for try await snapshot in observacao.values(in: pool) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Quem para de consumir (a janela fechou, o `for` deu `break`)
            // desliga a observação junto — senão ela continua acordando a cada
            // escrita, para ninguém, enquanto o app viver.
            continuation.onTermination = { _ in tarefa.cancel() }
        }
    }

    public func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? {
        try await database.pool.read { db in
            try MessageSearch.matchingBodyIDs(db, term: term, accountID: accountID)
        }
    }

    // MARK: A leitura, num lugar só

    private static func snapshot(in db: Database) throws -> MailSnapshot {
        MailSnapshot(
            accounts: try AccountRecord.order(Column("createdAt")).fetchAll(db).map(\.account),
            messages: try messages(in: db),
            agenda: try AgendaItemRecord.fetchAll(db).map(\.item),
            pendingItems: []
        )
    }

    private static func messages(in db: Database) throws -> [Message] {
        // `ORDER BY receivedAt DESC` desce pelo índice `message_on_received`,
        // cujo plano a Task 5 provou por `EXPLAIN QUERY PLAN` — nenhuma
        // consulta nova entra aqui.
        let registros = try MessageRecord
            .order(Column("receivedAt").desc)
            .fetchAll(db)
        // Os corpos numa consulta só: um `fetchOne` por mensagem seria uma
        // consulta por linha da lista, e a lista tem milhares.
        let corpos = try MessageBodyRecord.fetchAll(db)
        // `uniquingKeysWith` e não `uniqueKeysWithValues`: `messageID` é UNIQUE
        // no esquema, mas um `init(uniqueKeysWithValues:)` responde a uma
        // violação disso com `fatalError` — o app inteiro caindo por causa de
        // uma linha duplicada num banco de disco. Ficar com uma delas é pior
        // do que nada e melhor do que morrer.
        let porID = Dictionary(corpos.map { ($0.messageID, $0.body) }, uniquingKeysWith: { primeiro, _ in primeiro })
        return registros.map { $0.message(body: porID[$0.id] ?? []) }
    }
}
