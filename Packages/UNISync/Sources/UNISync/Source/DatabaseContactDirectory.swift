import Foundation
import GRDB
import UNICore

/// `ContactDirectoryPort` lendo do banco: os destinatários e cópias das
/// mensagens em Enviadas, agregados por `ContactDirectory.build`. Remetentes
/// recebidos não entram automaticamente no catálogo.
///
/// **Sem consulta nova de verdade.** A leitura é a mesma que
/// `DatabaseMailSource.messages(in:)` já faz para a lista "Tudo" —
/// `MessageRecord.order(receivedAt DESC)`, filtrada por `accountID` quando
/// pedido — e já desce pelos índices `message_on_received` e
/// `message_on_account_received` que a Task 5 provou por `EXPLAIN QUERY
/// PLAN`. O teste desta tarefa reprova o mesmo plano para o filtro de conta;
/// nenhum índice novo entra. `ContactDirectory.build` faz a agregação (quem
/// recebeu mensagem do usuário, quantas vezes e quando pela última vez) em memória — pura e
/// testável sem banco.
///
/// **Não é FTS.** Casar prefixo/substring no nome e no endereço, com dobra de
/// acento, é `ContactDirectory.matches`/`fold`, em memória — um índice de
/// texto para um catálogo de algumas centenas de contatos seria a fatia maior
/// que o problema pede.
public struct DatabaseContactDirectory: ContactDirectoryPort, Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    public func contacts(accountID: String?) async throws -> [DirectoryContact]? {
        try await database.pool.read { db -> [DirectoryContact]? in
            // A mesma decisão de `DatabaseMailSource.bodyMatches`: banco sem
            // conta nenhuma é o estado "ainda não sincronizou nada", e quem
            // substitui por `Fixtures.contacts` é o `MailStore` — `nil` é
            // como esta porta pede isso, para não duplicar a regra dos dois
            // lados.
            let accounts = try AccountRecord.fetchAll(db)
            guard !accounts.isEmpty else { return nil }

            var query = MessageRecord.order(Column("receivedAt").desc)
            if let accountID {
                query = query.filter(Column("accountID") == accountID)
            }
            let mensagens = try query.fetchAll(db).map { $0.message(body: []) }
            let ownAddresses = Set(accounts.map { $0.address.lowercased() })
            return ContactDirectory.build(
                fromMessages: mensagens, excluding: ownAddresses
            )
        }
    }
}
