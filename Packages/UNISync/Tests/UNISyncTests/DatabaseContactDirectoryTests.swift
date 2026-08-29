import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// `DatabaseContactDirectory`: o catálogo real de contatos, lido do banco.
///
/// A agregação em si (quem conta, como desempata) já está provada em
/// `ContactDirectoryBuildTests`, no `UNICore` — sem banco. O que esta suíte
/// prova é o que só existe aqui: o banco sem conta devolve `nil` (não uma
/// lista vazia), o filtro de conta funciona, e a consulta continua descendo
/// pelos índices que já existem — nenhum novo.
@Suite("O catálogo real de contatos, lido do banco")
struct DatabaseContactDirectoryTests {
    private func banco() throws -> SyncDatabase { try SyncDatabase.temporary() }

    private func conta(_ id: String, criadaEm: TimeInterval = 1) -> Account {
        Account(
            id: id, address: "\(id)@x.com", displayName: id,
            provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
        )
    }

    private func mensagem(
        _ id: String, accountID: String,
        de: Contact, para: [Contact] = [], copia: [Contact] = [],
        recebidaEm: TimeInterval
    ) -> Message {
        Message(
            id: id, accountID: accountID, from: de,
            receivedAt: Date(timeIntervalSince1970: recebidaEm),
            subject: "Assunto \(id)", snippet: "", body: [],
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil, to: para, cc: copia
        )
    }

    /// Insere a conta, a pasta (chave estrangeira obrigatória de `message`)
    /// e a mensagem, na ordem que o esquema exige.
    private func grava(_ mensagens: [Message], in db: SyncDatabase, contas: [Account]) throws {
        try db.pool.write { conexao in
            for c in contas {
                try AccountRecord(c, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
                try FolderRecord(
                    id: "\(c.id)/INBOX", accountID: c.id,
                    serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
                ).insert(conexao)
            }
            for m in mensagens {
                try MessageRecord(m, folderID: "\(m.accountID)/INBOX").insert(conexao)
            }
        }
    }

    @Test("Banco sem conta nenhuma devolve nil — não uma lista vazia")
    func semContaDevolveNil() async throws {
        let db = try banco()
        let porta = DatabaseContactDirectory(database: db)
        let resultado = try await porta.contacts(accountID: nil)
        #expect(resultado == nil)
    }

    @Test("Com conta mas sem mensagem nenhuma, o catálogo é uma lista vazia — não nil")
    func comContaSemMensagemDevolveListaVazia() async throws {
        let db = try banco()
        try grava([], in: db, contas: [conta("conta-a")])
        let porta = DatabaseContactDirectory(database: db)
        let resultado = try await porta.contacts(accountID: nil)
        #expect(resultado != nil)
        #expect(resultado?.isEmpty == true)
    }

    @Test("Remetente, destinatário e cópia entram todos no catálogo")
    func colheDosTresLugares() async throws {
        let db = try banco()
        try grava(
            [mensagem(
                "m1", accountID: "conta-a",
                de: Contact(name: "Marina Duarte", address: "marina@x.com"),
                para: [Contact(name: "Bruno", address: "bruno@x.com")],
                copia: [Contact(name: "Cláudia", address: "claudia@x.com")],
                recebidaEm: 1_000
            )],
            in: db, contas: [conta("conta-a")]
        )
        let porta = DatabaseContactDirectory(database: db)
        let resultado = try #require(try await porta.contacts(accountID: nil))
        #expect(Set(resultado.map(\.address)) == ["marina@x.com", "bruno@x.com", "claudia@x.com"])
    }

    @Test("accountID filtra: só as mensagens daquela conta entram no catálogo")
    func filtraPorConta() async throws {
        let db = try banco()
        try grava(
            [
                mensagem(
                    "m1", accountID: "conta-a",
                    de: Contact(name: "Da Conta A", address: "a@x.com"), recebidaEm: 1_000
                ),
                mensagem(
                    "m2", accountID: "conta-b",
                    de: Contact(name: "Da Conta B", address: "b@x.com"), recebidaEm: 2_000
                ),
            ],
            in: db, contas: [conta("conta-a"), conta("conta-b")]
        )
        let porta = DatabaseContactDirectory(database: db)

        let deTodas = try #require(try await porta.contacts(accountID: nil))
        #expect(Set(deTodas.map(\.address)) == ["a@x.com", "b@x.com"])

        let soDaA = try #require(try await porta.contacts(accountID: "conta-a"))
        #expect(soDaA.map(\.address) == ["a@x.com"])
    }

    /// A prova que a tarefa pede: nenhuma consulta nova entra no banco. A
    /// leitura sem filtro de conta é literalmente a mesma de
    /// `DatabaseMailSource.messages(in:)` (`ORDER BY receivedAt DESC`), e o
    /// filtro por conta é coberto pelo mesmo índice composto que a Task 5 já
    /// provou para a lista "Tudo" por conta.
    @Test("A leitura por trás do catálogo usa os índices que já existem — nenhum novo")
    func usaIndicesExistentes() throws {
        let db = try banco()
        try db.pool.read { conexao in
            let semFiltro = try Row.fetchAll(
                conexao, sql: "EXPLAIN QUERY PLAN SELECT * FROM message ORDER BY receivedAt DESC"
            ).map { $0["detail"] as String }.joined(separator: " | ")
            let comFiltro = try Row.fetchAll(
                conexao,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM message WHERE accountID = 'conta-a' ORDER BY receivedAt DESC
                """
            ).map { $0["detail"] as String }.joined(separator: " | ")
            #expect(semFiltro.contains("message_on_received"), "plano: \(semFiltro)")
            #expect(comFiltro.contains("message_on_account_received"), "plano: \(comFiltro)")
            // Nenhum dos dois pode recorrer a um `TEMP B-TREE` para ordenar —
            // isso seria o sinal de que o índice não está cobrindo o
            // `ORDER BY`, e a consulta teria virado scan + sort em memória.
            #expect(!semFiltro.contains("TEMP B-TREE"), "plano: \(semFiltro)")
            #expect(!comFiltro.contains("TEMP B-TREE"), "plano: \(comFiltro)")
        }
    }

    @Test("Mais frequente vem primeiro, com o mesmo desempate por recência de ContactDirectory.build")
    func ordenaPorFrequenciaERecencia() async throws {
        let db = try banco()
        try grava(
            [
                mensagem(
                    "m1", accountID: "conta-a",
                    de: Contact(name: "Raro", address: "raro@x.com"), recebidaEm: 1_000
                ),
                mensagem(
                    "m2", accountID: "conta-a",
                    de: Contact(name: "Frequente", address: "frequente@x.com"), recebidaEm: 1_500
                ),
                mensagem(
                    "m3", accountID: "conta-a",
                    de: Contact(name: "Frequente", address: "frequente@x.com"), recebidaEm: 2_000
                ),
            ],
            in: db, contas: [conta("conta-a")]
        )
        let porta = DatabaseContactDirectory(database: db)
        let resultado = try #require(try await porta.contacts(accountID: nil))
        #expect(resultado.map(\.address) == ["frequente@x.com", "raro@x.com"])
    }
}
