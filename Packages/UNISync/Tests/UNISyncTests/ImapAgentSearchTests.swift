import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

@Suite("Busca IMAP do agente")
struct ImapAgentSearchTests {
    @Test("escapa dados de busca sem transformá-los em comandos")
    func escapedQuery() throws {
        #expect(try ImapWire.uidSearchText(tag: "A001", text: "proposal \"Q4\" \\ docs") == "A001 UID SEARCH TEXT \"proposal \\\"Q4\\\" \\\\ docs\"")
        #expect(try ImapWire.uidSearchText(tag: "A002", text: "revisão") == "A002 UID SEARCH CHARSET UTF-8 TEXT \"revisão\"")
        #expect(try ImapWire.uidSearchText(tag: "A003", text: "  ") == "A003 UID SEARCH ALL")
    }
    @Test("recusa injeção CRLF, NUL e argumentos enormes", arguments: ["x\r\nA999 LOGOUT", "x\0y", String(repeating: "x", count: 4_097)])
    func rejectsCommands(_ text: String) {
        #expect(throws: (any Error).self) { try ImapWire.uidSearchText(tag: "A001", text: text) }
    }

    @Test("adapter pesquisa UID no servidor fixture e persiste corpo para leitura posterior")
    func remoteSearchPersistsFixtureMessage() async throws {
        let fullBody = "Full proposal body"
        let server = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "SELECT": [
                "* 1 EXISTS", "* OK [UIDVALIDITY 42] UIDs valid", "* OK [UIDNEXT 8] Predicted next UID",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            "UID SEARCH": ["* SEARCH 7", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                "* 1 FETCH (UID 7 FLAGS () INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"Proposal Q4\" ((\"Ana\" NIL \"ana\" \"example.com\")) NIL NIL ((\"Eu\" NIL \"eu\" \"example.com\")) NIL NIL NIL NIL))",
                "TAG OK UID FETCH completed",
            ],
            FakeImapServer.chaveDeCorpo: [
                "* 1 FETCH (UID 7 BODY[TEXT] {\(fullBody.utf8.count)}\r\n\(fullBody))", "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let port = try server.start()
        defer { server.stop() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let account = Account(
            id: "imap-search", address: "eu@example.com", displayName: "Eu", provider: .imap,
            host: "fixture", tintLightHex: "#123456", tintDarkHex: "#abcdef",
            imap: ImapEndpoint(host: "127.0.0.1", port: port, security: .startTLS)
        )
        let database = try SyncDatabase.temporary()
        try await database.pool.write { db in
            try AccountRecord(account, createdAt: .now).save(db)
            try FolderRecord(
                id: FolderRecord.id(accountID: account.id, serverName: "INBOX"), accountID: account.id,
                serverName: "INBOX", role: .inbox, displayName: "Entrada"
            ).save(db)
        }
        let secrets = InMemorySecretStore()
        try secrets.store(.password("fixture-password"), for: account.id)
        let adapter = DatabaseAgentMailSearch(
            database: database, secrets: secrets, auth: nil, eventLoopGroup: group,
            imapConnect: { endpoint, eventLoopGroup in
                try await ImapSession.connect(endpoint: endpoint, group: eventLoopGroup, allowInsecure: true, teto: .seconds(5))
            }
        )

        let result = try await adapter.search(.init(query: "Proposal", accountIDs: [account.id]))
        let expectedID = MessageIdentity.imap(
            accountID: account.id, folderID: FolderRecord.id(accountID: account.id, serverName: "INBOX"), uidValidity: 42, uid: 7
        )
        #expect(result.messages.map(\.id) == [expectedID])
        #expect(result.messages.first?.body == ["Full proposal body"])
        #expect(try await DatabaseMailSource(database: database).messages().first?.id == expectedID)
        let commands = server.commands.joined(separator: "\n")
        #expect(commands.contains("UID SEARCH TEXT \"Proposal\""))
    }
}
