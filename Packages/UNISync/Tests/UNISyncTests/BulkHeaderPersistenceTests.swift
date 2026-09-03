import Foundation
import Testing
import UNICore
@testable import UNISync

/// Os cabeçalhos de disparo em massa atravessam a sincronização e o banco.
///
/// Sem isto a barreira determinística fica sem dado: o `List-Unsubscribe`
/// chega com a mensagem e é jogado fora ao gravar, e o dashboard, semanas
/// depois, só tem o texto — que é justamente o que o modelo lê errado.
@Suite("Cabeçalhos de disparo, do servidor ao banco")
struct BulkHeaderPersistenceTests {

    @Test("o parser do Gmail lê os cabeçalhos de lista")
    func gmailLeOsCabecalhos() throws {
        let json = """
            {
              "id": "g1", "threadId": "t1", "labelIds": ["INBOX"],
              "internalDate": "1800000000000",
              "snippet": "Welcome to Resend!",
              "payload": {
                "mimeType": "text/plain",
                "headers": [
                  {"name": "From", "value": "Resend <onboarding@resend.dev>"},
                  {"name": "Subject", "value": "Welcome to Resend!"},
                  {"name": "List-Unsubscribe", "value": "<mailto:u@resend.dev>"},
                  {"name": "Precedence", "value": "bulk"}
                ],
                "body": {"size": 0}
              }
            }
            """
        let mensagem = try GmailMessageParser.parse(Data(json.utf8))
        #expect(mensagem.bulkMarks.contains(.listUnsubscribe))
        #expect(mensagem.bulkMarks.contains(.precedence))
    }

    @Test("uma mensagem de gente não ganha marca nenhuma")
    func genteNaoGanhaMarca() throws {
        let json = """
            {
              "id": "g2", "threadId": "t2", "labelIds": ["INBOX"],
              "internalDate": "1800000000000", "snippet": "oi",
              "payload": {
                "mimeType": "text/plain",
                "headers": [
                  {"name": "From", "value": "Jack Whitmore <jack@whitmore.co>"},
                  {"name": "Subject", "value": "Pode confirmar sexta?"}
                ],
                "body": {"size": 0}
              }
            }
            """
        let mensagem = try GmailMessageParser.parse(Data(json.utf8))
        #expect(mensagem.bulkMarks.isEmpty)
    }

    @Test("o FETCH de envelopes pede os cabeçalhos de lista")
    func fetchPedeOsCabecalhos() {
        let comando = ImapWire.uidFetchEnvelopes(tag: "A1", uids: [1, 2])
        #expect(comando.contains("BODY.PEEK[HEADER.FIELDS ("))
        for nome in BulkMailMarks.headerNames {
            #expect(comando.contains(nome.uppercased()), "faltou \(nome)")
        }
    }

    @Test("o envelope do IMAP traz as marcas, com o remetente pelado")
    func envelopeTrazAsMarcas() {
        let linha = ImapWire.FetchLine(
            uid: 9_001, flags: [], internalDate: Date(timeIntervalSince1970: 1_800_000_000),
            from: "\"Upwork\" <do-not-reply@upwork.com>", to: nil, cc: nil,
            subject: "Invitation to Interview", text: nil,
            listHeader: "Precedence: bulk\r\n"
        )
        let envelopes = ImapWire.envelopes(from: [.fetch(linha)])
        #expect(envelopes.first?.bulkMarks.contains(.noReplySender) == true)
        #expect(envelopes.first?.bulkMarks.contains(.precedence) == true)
    }

    @Test("a marca sobrevive à ida e à volta do banco")
    func bancoGuardaAMarca() async throws {
        let database = try SyncDatabase.temporary()
        let conta = Account(
            id: "a", address: "marcos@okamiops.com", displayName: "Marcos",
            provider: .imap, host: "okamiops",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", state: .ativa
        )
        let mensagem = Message(
            id: "m1", accountID: "a",
            from: Contact(name: "Upwork", address: "do-not-reply@upwork.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Invitation to Interview", snippet: "", body: [],
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil,
            bulkMarks: [.listUnsubscribe, .autoSubmitted]
        )
        let folderID = FolderRecord.gmail(accountID: "a").id
        try await database.pool.write { db in
            try AccountRecord(conta, createdAt: Date()).insert(db)
            try FolderRecord(
                id: folderID, accountID: "a", serverName: FolderRecord.gmailServerName,
                role: .other, displayName: "Entrada"
            ).insert(db)
            try MessageRecord(mensagem, folderID: folderID).insert(db)
        }
        let devolta = try await database.pool.read { db in
            try MessageRecord.fetchOne(db, key: "m1")?.message(body: [])
        }
        #expect(devolta?.bulkMarks == [.listUnsubscribe, .autoSubmitted])
    }
}
