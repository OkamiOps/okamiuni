import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("A re-decodificação dos corpos já gravados")
struct BodyRedecodingTests {
    private let conta = Account(
        id: "conta-a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )

    /// O que o banco do dono tem de verdade: o `BODY[TEXT]` de um
    /// `multipart/alternative` gravado como se fosse leitura, já partido em
    /// parágrafos por linha em branco — que é o que a carga fazia.
    private static let cruDoDono = GmailMessageParser.paragraphs(from: """
        --=_Part_9182_1755
        Content-Type: text/plain; charset="ISO-8859-1"
        Content-Transfer-Encoding: quoted-printable

        Ol=E1 Marina, a revis=E3o do or=E7amento saiu.

        Podemos fechar quinta?
        --=_Part_9182_1755
        Content-Type: text/html; charset="ISO-8859-1"
        Content-Transfer-Encoding: quoted-printable

        <p>Ol=E1 Marina</p>
        --=_Part_9182_1755--
        """)

    private func semeia(
        _ db: SyncDatabase, corpo: [String], snippet: String? = nil
    ) async throws {
        let primeiro = snippet ?? corpo.first ?? "Assunto"
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
                subject: "Assunto", snippet: primeiro, body: corpo,
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil, serverID: "9001", uidValidity: 42
            )
            try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(conexao)
            var registro = MessageBodyRecord(messageID: "m1", paragraphs: corpo)
            try registro.insert(conexao)
        }
    }

    private func corpo(_ db: SyncDatabase) async throws -> [String] {
        try await db.pool.read { conexao in
            try MessageBodyRecord.filter(Column("messageID") == "m1").fetchOne(conexao)?.body ?? []
        }
    }

    // MARK: A varredura

    @Test("Um corpo gravado cru vira texto, na abertura, sem rede")
    func consertaOCru() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db, corpo: Self.cruDoDono)
        // Antes: é isto que o dono vê hoje no leitor.
        #expect(try await corpo(db).first?.hasPrefix("--=_Part_") == true)

        let quantos = try await BodyRedecoding.run(db)

        #expect(quantos == 1)
        #expect(try await corpo(db) == [
            "Olá Marina, a revisão do orçamento saiu.",
            "Podemos fechar quinta?",
        ])
    }

    @Test("A busca acha o conteúdo novo — o FTS foi reindexado pelo gatilho que já existia")
    func aBuscaAchaODepois() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db, corpo: Self.cruDoDono)
        let fonte = DatabaseMailSource(database: db)

        // Antes, a palavra não estava no índice: o que estava indexado era
        // `=E7amento`, que não casa com nada que alguém digite.
        #expect(try await fonte.bodyMatches("orcamento", accountID: nil) == [])

        _ = try await BodyRedecoding.run(db)

        // Depois, casa — e casa **sem acento**, porque o índice dobra
        // diacrítico desde a v1. Nada nesta tarefa mexeu no FTS: o gatilho
        // `message_body_au` faz o trabalho porque a linha foi atualizada.
        #expect(try await fonte.bodyMatches("orcamento", accountID: nil) == ["m1"])
        #expect(try await fonte.bodyMatches("revisao", accountID: nil) == ["m1"])
    }

    @Test("A prévia da lista, que era a primeira linha crua, vira a primeira linha de verdade")
    func aPreviaTambemConserta() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db, corpo: Self.cruDoDono)
        _ = try await BodyRedecoding.run(db)

        let snippet = try await db.pool.read { conexao in
            try String.fetchOne(conexao, sql: "SELECT snippet FROM message WHERE id = 'm1'")
        }
        #expect(snippet == "Olá Marina, a revisão do orçamento saiu.")
    }

    @Test("A prévia que NÃO veio do corpo — a do Gmail — fica onde está")
    func previaDoServidorNaoEMexida() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db, corpo: Self.cruDoDono, snippet: "Resumo que o servidor deu")
        _ = try await BodyRedecoding.run(db)

        let snippet = try await db.pool.read { conexao in
            try String.fetchOne(conexao, sql: "SELECT snippet FROM message WHERE id = 'm1'")
        }
        #expect(snippet == "Resumo que o servidor deu")
    }

    @Test("Um corpo que já é texto não é tocado, e a segunda passada não reescreve nada")
    func convergencia() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db, corpo: ["Bom dia.", "Segue o combinado — até quinta."])
        #expect(try await BodyRedecoding.run(db) == 0)

        let outro = try SyncDatabase.temporary()
        try await semeia(outro, corpo: Self.cruDoDono)
        #expect(try await BodyRedecoding.run(outro) == 1)
        // A convergência é o que autoriza rodar isto a cada abertura sem
        // marcador nenhum no esquema: a segunda passada não acha o que fazer.
        #expect(try await BodyRedecoding.run(outro) == 0)
    }

    @Test("Vários corpos, mais que um lote: a paginação por rowid não pula nem repete")
    func maisQueUmLote() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db, corpo: Self.cruDoDono)
        let quantas = BodyRedecoding.loteDeLeitura + 7
        try await db.pool.write { conexao in
            for indice in 0..<quantas {
                let id = "extra-\(indice)"
                let mensagem = Message(
                    id: id, accountID: "conta-a",
                    from: Contact(name: "Marina", address: "marina@x.com"),
                    receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    subject: "A", snippet: "T", body: Self.cruDoDono,
                    tags: [], bucket: .today, isRead: false,
                    summary: nil, detectedEvent: nil
                )
                try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(conexao)
                var registro = MessageBodyRecord(messageID: id, paragraphs: Self.cruDoDono)
                try registro.insert(conexao)
            }
        }
        #expect(try await BodyRedecoding.run(db) == quantas + 1)
        #expect(try await BodyRedecoding.run(db) == 0)
    }

    // MARK: A heurística

    @Test("O que parece cru, e o que não parece")
    func heuristica() {
        #expect(MimeBody.looksRaw(Self.cruDoDono))
        // Quoted-printable sem cabeçalho nenhum: o `BODY[TEXT]` de uma
        // mensagem de parte única, onde a codificação ficou no cabeçalho.
        #expect(MimeBody.looksRaw(["Ol=E1, a revis=E3o saiu."]))
        // Prosa. Nenhuma destas pode ser reescrita.
        #expect(!MimeBody.looksRaw(["Bom dia.", "Segue o combinado — até quinta."]))
        #expect(!MimeBody.looksRaw(["--", "Marina Duarte"]))
        #expect(!MimeBody.looksRaw(["----------------------------------------"]))
        #expect(!MimeBody.looksRaw(["O total é 100 = 40 + 60, conforme a planilha."]))
        #expect(!MimeBody.looksRaw([]))
    }

    @Test("Base64 solto é reconhecido; uma palavra que por acaso é base64 não")
    func base64Solto() {
        let carga = Data("Segue em anexo o contrato revisado da semana passada.".utf8)
            .base64EncodedString()
        #expect(MimeBody.redecoded([carga])
                == ["Segue em anexo o contrato revisado da semana passada."])
        // "Confirmado" é base64 sintaticamente válido. O tamanho e a
        // legibilidade do que sai é o que o separa de um corpo de verdade.
        #expect(MimeBody.redecoded(["Confirmado"]) == nil)
    }

    @Test("Decodificação que daria vazio não apaga o que estava lá")
    func vazioNaoSubstitui() {
        // Fronteira e sub-cabeçalho, mas nenhuma parte de texto: só um anexo.
        // Reescrever isto em `[]` trocaria um corpo feio por nenhum corpo.
        let so_anexo = GmailMessageParser.paragraphs(from: """
            --x1x1
            Content-Type: application/pdf; name="contrato.pdf"
            Content-Transfer-Encoding: base64

            JVBERi0xLjQK
            --x1x1--
            """)
        #expect(MimeBody.redecoded(so_anexo) == nil)
    }
}
