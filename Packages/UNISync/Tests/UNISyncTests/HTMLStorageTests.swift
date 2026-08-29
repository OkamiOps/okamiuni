import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// A v3 e o caminho que ela abre: o HTML da mensagem entra no banco, sai no
/// retrato, e o FTS continua indexando texto.
@Suite("A v3: o banco guarda o HTML e o convite")
struct HTMLStorageTests {
    private func banco() throws -> SyncDatabase { try SyncDatabase.temporary() }

    private func semeia(_ db: SyncDatabase) throws {
        try db.pool.write { conexao in
            let conta = Account(
                id: "a", address: "eu@x.com", displayName: "Eu",
                provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
            )
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 0)).save(conexao)
            let pasta = FolderRecord(
                id: "a/INBOX", accountID: "a", serverName: "INBOX",
                role: .inbox, displayName: "Entrada"
            )
            try pasta.save(conexao)
            let mensagem = Message(
                id: "m1", accountID: "a",
                from: Contact(name: "Quem", address: "quem@x.com"),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                subject: "Assunto", snippet: "Trecho", body: [], tags: [],
                bucket: .today, isRead: false, summary: nil, detectedEvent: nil
            )
            try MessageRecord(mensagem, folderID: "a/INBOX").save(conexao)
        }
    }

    @Test("A v3 acrescenta as duas colunas sem tocar no que a v1 criou")
    func colunasDaV3() throws {
        let db = try banco()
        let colunas = try db.pool.read { conexao -> Set<String> in
            try Set(conexao.columns(in: "message_body").map(\.name))
        }
        #expect(colunas.contains("html"))
        #expect(colunas.contains("calendarICS"))
        // O que a v1 criou continua exatamente onde estava: a v3 acrescenta, e
        // uma migração registrada não é reescrita nem para melhorar.
        for velha in ["rowid", "messageID", "paragraphs", "plain"] {
            #expect(colunas.contains(velha), "a v3 comeu a coluna \(velha)")
        }
    }

    @Test("O HTML e o convite vão e voltam pela linha do corpo")
    func vaiEVolta() throws {
        let db = try banco()
        try semeia(db)
        try db.pool.write { conexao in
            try InitialLoader.gravaCorpo(
                conexao, id: "m1", paragrafos: ["O texto."],
                html: "<p>O <b>texto</b>.</p>", calendarICS: "BEGIN:VCALENDAR\nEND:VCALENDAR"
            )
        }
        let lido = try db.pool.read { conexao in
            try MessageBodyRecord.filter(Column("messageID") == "m1").fetchOne(conexao)
        }
        #expect(lido?.html == "<p>O <b>texto</b>.</p>")
        #expect(lido?.calendarICS?.contains("VCALENDAR") == true)
    }

    @Test("Regravar troca o HTML velho — a segunda carga não deixa o de antes para trás")
    func regravarAtualiza() throws {
        let db = try banco()
        try semeia(db)
        try db.pool.write { conexao in
            try InitialLoader.gravaCorpo(
                conexao, id: "m1", paragrafos: ["Antes."], html: "", calendarICS: nil
            )
            try InitialLoader.gravaCorpo(
                conexao, id: "m1", paragrafos: ["Depois."],
                html: "<p>Depois.</p>", calendarICS: nil
            )
        }
        let lido = try db.pool.read { conexao in
            try MessageBodyRecord.filter(Column("messageID") == "m1").fetchOne(conexao)
        }
        #expect(lido?.html == "<p>Depois.</p>")
        #expect(lido?.body == ["Depois."])
    }

    @Test("O índice de busca continua sendo do TEXTO: o `<td>` do HTML não entra nele")
    func ftsIndexaOTexto() throws {
        let db = try banco()
        try semeia(db)
        try db.pool.write { conexao in
            try InitialLoader.gravaCorpo(
                conexao, id: "m1", paragrafos: ["O orçamento saiu."],
                html: "<table><td style=\"background-color:crimson\">O orçamento saiu.</td></table>",
                calendarICS: nil
            )
        }
        func achou(_ termo: String) throws -> Int {
            try db.pool.read { conexao in
                try Int.fetchOne(
                    conexao,
                    sql: "SELECT count(*) FROM message_fts WHERE message_fts MATCH ?",
                    arguments: [termo]
                ) ?? 0
            }
        }
        #expect(try achou("orcamento") == 1)
        // Indexar o HTML poria a marcação e o base64 de um logotipo no índice —
        // e uma busca por "table" acharia metade da caixa.
        #expect(try achou("background") == 0)
        #expect(try achou("crimson") == 0)
    }

    @Test("O retrato leva o HTML à tela — e a mensagem sem linha de corpo continua sem resposta")
    func oRetratoLevaOHtml() async throws {
        let db = try banco()
        try semeia(db)
        let fonte = DatabaseMailSource(database: db)

        let antes = try await fonte.snapshot()
        let mudaAinda = try #require(antes.messages.first)
        // Sem linha em `message_body`, `bodyHTML` é `nil` — "ninguém perguntou
        // ainda", que é o que faz o leitor buscar uma vez ao abrir.
        #expect(mudaAinda.htmlResolved == false)

        try await db.pool.write { conexao in
            try InitialLoader.gravaCorpo(
                conexao, id: "m1", paragrafos: ["O texto."],
                html: "<p>O texto.</p>", calendarICS: "BEGIN:VCALENDAR"
            )
        }
        let depois = try await fonte.snapshot()
        let mensagem = try #require(depois.messages.first)
        #expect(mensagem.hasHTML)
        #expect(mensagem.bodyHTML == "<p>O texto.</p>")
        #expect(mensagem.calendarICS == "BEGIN:VCALENDAR")
    }

    @Test("Decodificada e sem HTML é `\"\"`, não ausência — só-texto fica só-texto")
    func soTextoFicaResolvido() async throws {
        let db = try banco()
        try semeia(db)
        try await db.pool.write { conexao in
            try InitialLoader.gravaCorpo(
                conexao, id: "m1", paragrafos: ["Bom dia."], html: "", calendarICS: nil
            )
        }
        let mensagem = try #require(try await DatabaseMailSource(database: db).snapshot().messages.first)
        #expect(mensagem.htmlResolved)
        #expect(!mensagem.hasHTML)
    }
}
