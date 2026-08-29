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
public struct DatabaseCommandPort: MailCommandPort, MailSendPort, Sendable {
    private let database: SyncDatabase
    /// Quem avisa o executor da conta que há coisa nova. Opcional porque a
    /// porta é útil sem ele — todos os testes da tarefa 1 a exercitam assim, e
    /// o que eles afirmam (projeção + enfileiramento na mesma transação) não
    /// muda por haver ou não quem consuma a fila depois.
    private let signal: OutboxSignal?

    public init(database: SyncDatabase, signal: OutboxSignal? = nil) {
        self.database = database
        self.signal = signal
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

    /// O "Enviar" da janela: a mensagem entra na fila e mais nada acontece
    /// agora.
    ///
    /// **Sem projeção**, ao contrário das seis mutações acima, e é uma
    /// diferença de fato e não de gosto: aquelas mudam uma linha que já existe
    /// na tela, e a tela tem de refletir a mudança na hora. Esta não tem linha
    /// nenhuma para mudar — a mensagem enviada não entra na triagem (ver
    /// `TriageProjection.bucket(role:)`: `.sent` devolve `nil`, de propósito,
    /// porque o que a pessoa escreveu não é caixa de entrada dela). Gravar uma
    /// linha que nenhuma visão desenha seria escrever no banco para ninguém
    /// ler.
    ///
    /// O que a pessoa vê é a janela fechando e, se algo der errado, a mesma
    /// falha de fila que as outras operações já mostram, com "tentar de novo"
    /// ao lado.
    public func send(_ message: OutgoingMessage) throws {
        try database.pool.write { db in
            try Self.enfileira(db, accountID: message.accountID, operation: .send(message: message))
        }
        signal?.notify(accountID: message.accountID)
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
            try Self.enfileira(db, accountID: accountID, operation: operation)
        }
        // **Depois** da transação, nunca dentro: o executor acordado lê o
        // banco, e um aviso disparado antes do commit o mandaria procurar uma
        // linha que ainda não existe.
        signal?.notify(accountID: accountID)
    }

    /// O `INSERT` no `outbox`, e só ele. Extraído porque o envio o chama
    /// **sem** projeção nenhuma — e uma segunda cópia deste SQL divergiria da
    /// primeira no dia em que uma coluna mudasse.
    private static func enfileira(
        _ db: Database, accountID: String, operation: MailOperation
    ) throws {
            let record = try OutboxRecord(accountID: accountID, operation: operation)
            // **Toda ação entra na fila.** A versão anterior deduplicava aqui,
            // por uma chave derivada do conteúdo, e com isso engolia o terceiro
            // passo de um ciclo ler→não-ler→ler e todo `emptyTrash` depois do
            // primeiro (ver `OutboxRecord.idempotencyKey`). Descartar no
            // enfileirar é a única forma de perda que nenhum retry conserta: a
            // operação nunca existiu. Quem tira redundância é a coalescência do
            // executor, que junta o que dá para juntar — depois, e sabendo o
            // que está junto de quê.
            try db.execute(
                sql: """
                    INSERT INTO outbox
                      (id, accountID, operationJSON, idempotencyKey, attempts, nextAttemptAt, state, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id, record.accountID, record.operationJSON, record.idempotencyKey,
                    record.attempts, record.nextAttemptAt.timeIntervalSince1970,
                    record.state, record.createdAt.timeIntervalSince1970,
                ]
            )
    }
}
