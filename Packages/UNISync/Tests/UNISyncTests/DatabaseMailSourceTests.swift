import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("A fonte que lê do banco")
struct DatabaseMailSourceTests {
    private let conta = Account(
        id: "conta-a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )

    private func semeia(_ db: SyncDatabase, corpo: [String] = ["A revisão saiu."]) async throws {
        try await db.pool.write { conexao in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "INBOX"
            ).insert(conexao)
            let mensagem = Message(
                id: "m1", accountID: "conta-a",
                from: Contact(name: "Marina", address: "marina@x.com"),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                subject: "Assunto", snippet: "Trecho", body: corpo,
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil, serverID: "9001", uidValidity: 42
            )
            try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(conexao)
            var registroDeCorpo = MessageBodyRecord(messageID: "m1", paragraphs: corpo)
            try registroDeCorpo.insert(conexao)
            try AgendaItemRecord(AgendaItem(
                id: "a1", title: "Reunião", startMinute: 570, endMinute: 600, accountID: "conta-a"
            )).insert(conexao)
        }
    }

    @Test("O snapshot traz contas, mensagens e agenda do banco")
    func snapshot() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let snapshot = try await DatabaseMailSource(database: db).snapshot()

        #expect(snapshot.accounts.map(\.id) == ["conta-a"])
        #expect(snapshot.messages.map(\.id) == ["m1"])
        #expect(snapshot.messages.first?.serverID == "9001")
        #expect(snapshot.agenda.map(\.id) == ["a1"])
        // `pendingItems` é do Marco 1 e não tem tabela: lista vazia, não erro.
        #expect(snapshot.pendingItems.isEmpty)
    }

    @Test("O corpo vem junto para quem já o tem no banco")
    func corpoNoSnapshot() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let snapshot = try await DatabaseMailSource(database: db).snapshot()
        #expect(snapshot.messages.first?.body == ["A revisão saiu."])
    }

    @Test("A busca de corpo desce para o índice e dobra acento")
    func buscaDeCorpo() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let fonte = DatabaseMailSource(database: db)
        #expect(try await fonte.bodyMatches("revisao", accountID: nil) == ["m1"])
        #expect(try await fonte.bodyMatches("orcamento", accountID: nil) == [])
        #expect(try await fonte.bodyMatches("revisao", accountID: "outra") == [])
    }

    @Test("A observação entrega o estado atual e acorda a cada escrita")
    func observacao() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let fonte = DatabaseMailSource(database: db)

        var vistos: [Int] = []
        for try await snapshot in fonte.snapshots() {
            vistos.append(snapshot.messages.count)
            if vistos.count == 1 {
                try await db.pool.write { conexao in
                    let outra = Message(
                        id: "m2", accountID: "conta-a",
                        from: Contact(name: "Outro", address: "o@x.com"),
                        receivedAt: Date(timeIntervalSince1970: 1_800_000_100),
                        subject: "Novo", snippet: "Novo", body: [],
                        tags: [], bucket: .today, isRead: false,
                        summary: nil, detectedEvent: nil
                    )
                    try MessageRecord(outra, folderID: "conta-a/INBOX").insert(conexao)
                }
            }
            if vistos.count == 2 { break }
        }
        #expect(vistos == [1, 2])
    }

    @Test("Banco vazio devolve snapshot vazio, e não erro")
    func bancoVazio() async throws {
        // É o estado do app antes da primeira conta: sem conta, a composição
        // fica nas fixtures, e esta fonte tem de saber dizer "não tenho nada"
        // sem lançar.
        let snapshot = try await DatabaseMailSource(database: try SyncDatabase.temporary()).snapshot()
        #expect(snapshot.accounts.isEmpty)
        #expect(snapshot.messages.isEmpty)
    }

    @Test("As mensagens vêm da mais recente para a mais antiga")
    func ordemPorData() async throws {
        // A mesma ordem que `visibleMessages` do Marco 1 aplica em memória —
        // ela vem do índice `message_on_received`, cujo plano a Task 5 já
        // provou por `EXPLAIN QUERY PLAN`.
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        try await db.pool.write { conexao in
            let antiga = Message(
                id: "m0", accountID: "conta-a",
                from: Contact(name: "Antigo", address: "a@x.com"),
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                subject: "Velho", snippet: "Velho", body: [],
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil
            )
            try MessageRecord(antiga, folderID: "conta-a/INBOX").insert(conexao)
        }
        let snapshot = try await DatabaseMailSource(database: db).snapshot()
        #expect(snapshot.messages.map(\.id) == ["m1", "m0"])
    }
}
