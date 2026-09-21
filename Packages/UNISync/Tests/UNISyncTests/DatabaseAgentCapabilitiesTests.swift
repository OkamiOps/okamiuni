import Foundation
import GRDB
import NIOPosix
import Testing
import UNICore
@testable import UNISync

@Suite("Capacidades persistentes do agente")
struct DatabaseAgentCapabilitiesTests {
    private let imapAccount = Account(
        id: "imap-a", address: "eu@example.com", displayName: "Eu", provider: .imap,
        host: "example.com", tintLightHex: "#123456", tintDarkHex: "#abcdef"
    )

    @Test("leitor de anexos lê bytes cacheados no SQLite sem caminho local")
    func attachmentReaderUsesSQLiteIdentity() async throws {
        let database = try SyncDatabase.temporary()
        let data = Data("fatura 42\n".utf8)
        try await seedIMAP(database, attachmentData: data)
        let reader = DatabaseAgentAttachmentReader(
            fetcher: DatabaseAttachmentFetcher(database: database, auth: nil, session: .shared)
        )

        let content = try await reader.readAttachment(
            accountID: imapAccount.id, messageID: "imap-message", attachmentID: "imap-attachment"
        )
        #expect(content.kind == .text)
        #expect(content.text == "fatura 42\n")
        #expect(content.truncated == false)
        await #expect(throws: AttachmentError.unavailable) {
            _ = try await reader.readAttachment(
                accountID: imapAccount.id, messageID: "imap-message", attachmentID: "other"
            )
        }
    }

    @Test("rascunho com bytes encaminhados sobrevive à reabertura do SQLite")
    func draftAttachmentPayloadSurvivesDatabaseRoundTrip() async throws {
        let database = try SyncDatabase.temporary()
        try await database.pool.write { db in
            try AccountRecord(imapAccount, createdAt: .now).save(db)
        }
        let attachment = try OutgoingAttachment(
            id: "forwarded-1", filename: "contrato.txt", mimeType: "text/plain", data: Data("bytes reais".utf8)
        )
        let draft = Message(
            id: "local-draft-agent-forward", accountID: imapAccount.id,
            from: Contact(name: "Eu", address: imapAccount.address), receivedAt: .now,
            subject: "Fwd: contrato", snippet: "segue", body: ["segue"], tags: [], bucket: .drafts,
            isRead: true, summary: nil, detectedEvent: nil, bodyHTML: "<p>segue</p>",
            attachments: [attachment.metadata]
        )
        try DatabaseCommandPort(database: database).saveDraft(draft, attachments: [attachment])

        let reopened = try #require(try await DatabaseMailSource(database: database).messages().first { $0.id == draft.id })
        #expect(reopened.bodyHTML == "<p>segue</p>")
        #expect(reopened.attachments == [attachment.metadata])
        let bytes = try await DatabaseAttachmentFetcher(database: database, auth: nil, session: .shared)
            .fetchAttachment(accountID: imapAccount.id, messageID: draft.id, attachmentID: attachment.id)
        #expect(bytes.data == attachment.data)
    }

    @Test("busca Gmail percorre cursor HTTP e grava na pseudo-pasta neutra")
    func gmailSearchPaginatesAndPreservesLabelDrivenBucket() async throws {
        let database = try SyncDatabase.temporary()
        let account = Account(
            id: "gmail-a", address: "eu@gmail.example", displayName: "Eu", provider: .gmail,
            host: "gmail", tintLightHex: "#123456", tintDarkHex: "#abcdef"
        )
        try await database.pool.write { db in try AccountRecord(account, createdAt: .now).save(db) }
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/messages": [
                .json("{\"messages\":[{\"id\":\"m1\"}],\"nextPageToken\":\"p2\",\"resultSizeEstimate\":2}"),
                .json("{\"messages\":[{\"id\":\"m2\"}],\"resultSizeEstimate\":2}"),
            ],
            "/gmail/v1/users/me/messages/m1": [.json(gmailMessage(id: "m1", subject: "Invoice one", labels: ["INBOX"]))],
            "/gmail/v1/users/me/messages/m2": [.json(gmailMessage(id: "m2", subject: "Invoice two", labels: []))],
        ])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let search = DatabaseAgentMailSearch(
            database: database, secrets: InMemorySecretStore(), auth: nil, session: session,
            gmailBaseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!, eventLoopGroup: group,
            gmailAccessToken: { _ in "fixture-token" }
        )

        let lowerBound = Date(timeIntervalSince1970: 1_729_999_999.4)
        let upperBound = Date(timeIntervalSince1970: 1_730_000_000.6)
        let result = try await search.search(.init(
            query: "Invoice", accountIDs: [account.id],
            receivedAfter: lowerBound, receivedBefore: upperBound
        ))
        #expect(result.scope == .localAndRemote)
        #expect(result.messages.map(\.id).count == 2)
        #expect(result.messages.first(where: { $0.id == "gmail-a:g:m1" })?.bucket == .today)
        #expect(result.messages.first(where: { $0.id == "gmail-a:g:m2" })?.bucket == .archived)
        let lists = StubURLProtocol.requests(for: session).filter { $0.path == "/gmail/v1/users/me/messages" }
        #expect(lists.count == 2)
        let firstQuery = lists.first?.query.removingPercentEncoding ?? lists.first?.query ?? ""
        let secondQuery = lists.last?.query.removingPercentEncoding ?? lists.last?.query ?? ""
        #expect(firstQuery.contains("q=Invoice"))
        #expect(firstQuery.contains("after:1729999998"))
        #expect(firstQuery.contains("before:1730000001"))
        #expect(secondQuery.contains("pageToken=p2"))
        let folder = try await database.pool.read { db in try FolderRecord.fetchOne(db, key: FolderRecord.gmail(accountID: account.id).id) }
        #expect(folder?.role == FolderRole.other.rawValue)
    }

    @Test("calendário do agente persiste, sincroniza e mantém create idempotente")
    func calendarManagerPersistsAndSynchronizesWithoutInvitationTransport() async throws {
        let database = try SyncDatabase.temporary()
        let account = Account(
            id: "calendar-a", address: "eu@gmail.example", displayName: "Eu", provider: .gmail,
            host: "gmail", tintLightHex: "#123456", tintDarkHex: "#abcdef"
        )
        try await database.pool.write { db in try AccountRecord(account, createdAt: .now).save(db) }
        let sync = RecordingCalendarSync()
        let manager = DatabaseAgentCalendarManager(
            database: database, agenda: DatabaseAgendaStore(database: database), calendarSync: sync,
            referenceDay: { Date(timeIntervalSince1970: 1_730_000_000) }
        )
        let draft = AgentCalendarDraft(
            id: "agent-event", accountID: account.id, title: "Reunião",
            startsAt: Date(timeIntervalSince1970: 1_730_000_400), endsAt: Date(timeIntervalSince1970: 1_730_004_000),
            place: "Sala", note: "Sem convidados"
        )
        let created = try await manager.create(draft)
        let retried = try await manager.create(draft)
        #expect(created.didChange)
        #expect(!retried.didChange)
        #expect(try DatabaseAgendaStore(database: database).savedAgendaItems().map(\.id) == [draft.id])
        #expect(await sync.savedIDs == [draft.id])
        #expect(await sync.invitationAttempts == 0)
    }

    @Test("atualização de agenda remota conserva identidade e bloqueia convidados")
    func calendarRemoteUpdatePreservesMetadataAndRefusesParticipants() async throws {
        let database = try SyncDatabase.temporary()
        let account = Account(
            id: "remote-calendar-a", address: "eu@gmail.example", displayName: "Eu", provider: .gmail,
            host: "gmail", tintLightHex: "#123456", tintDarkHex: "#abcdef"
        )
        try await database.pool.write { db in try AccountRecord(account, createdAt: .now).save(db) }
        let reference = Date(timeIntervalSince1970: 1_730_000_000)
        let agenda = DatabaseAgendaStore(database: database)
        let organizer = EventPerson(name: "Ana", address: "ana@example.com", role: "organizadora", status: .yes)
        let original = AgendaItem(
            id: "remote-event", title: "Planejamento", startMinute: 60, endMinute: 120,
            accountID: account.id, dayOffset: 0, calendarUID: "provider-uid", calendarSequence: 7,
            detail: EventDetail(
                place: "Sala antiga", link: "https://meet.example/abc", organizer: organizer, people: [],
                note: "Google", recurrence: "Semanal", notice: "10 min", agenda: ["pauta"], thread: [],
                descricao: "Descrição anterior"
            ),
            calendarID: "eventkit:work", calendarTitle: "Trabalho", calendarColorHex: "#00aa00",
            calendarSource: "Google"
        )
        try agenda.saveAgendaItem(StoredAgendaItem(original, referenceDay: reference))
        let sync = RecordingCalendarSync()
        let manager = DatabaseAgentCalendarManager(
            database: database, agenda: agenda, calendarSync: sync, referenceDay: { reference }
        )
        let changed = try await manager.update(AgentCalendarDraft(
            id: original.id, accountID: account.id, title: "Planejamento atualizado",
            startsAt: reference.addingTimeInterval(3_600), endsAt: reference.addingTimeInterval(10_800),
            place: "Sala nova", note: "Nova descrição"
        ))
        let saved = try #require(changed.item)
        #expect(saved.calendarUID == "provider-uid")
        #expect(saved.calendarSequence == 7)
        #expect(saved.calendarID == "eventkit:work")
        #expect(saved.calendarTitle == "Trabalho")
        #expect(saved.detail?.link == "https://meet.example/abc")
        #expect(saved.detail?.organizer == organizer)
        #expect(saved.detail?.recurrence == "Semanal")
        #expect(await sync.savedIDs == [original.id])

        let invited = AgendaItem(
            id: "invited-event", title: "Convite", startMinute: 60, endMinute: 120, accountID: account.id,
            detail: EventDetail(
                place: "Sala", link: nil, organizer: organizer,
                people: [EventPerson(name: "Bia", address: "bia@example.com", role: "convidada", status: .pending)],
                note: "Google", recurrence: "Evento único", notice: "", agenda: [], thread: []
            ), calendarID: "eventkit:work"
        )
        try agenda.saveAgendaItem(StoredAgendaItem(invited, referenceDay: reference))
        await #expect(throws: AgentToolError.self) {
            _ = try await manager.update(AgentCalendarDraft(
                id: invited.id, accountID: account.id, title: "Convite alterado",
                startsAt: reference.addingTimeInterval(3_600), endsAt: reference.addingTimeInterval(7_200)
            ))
        }
        #expect(await sync.savedIDs == [original.id])
    }

    @Test("HTML do agente recarrega do SQLite com CID e metadado de assinatura")
    @MainActor
    func htmlDraftRoundTripsThroughSQLite() async throws {
        let database = try SyncDatabase.temporary()
        let account = Account(
            id: "html-a", address: "eu@example.com", displayName: "Eu", provider: .imap,
            host: "example.com", tintLightHex: "#123456", tintDarkHex: "#abcdef"
        )
        try await database.pool.write { db in try AccountRecord(account, createdAt: .now).save(db) }
        let store = MailStore(
            source: DatabaseMailSource(database: database), draftPort: DatabaseCommandPort(database: database)
        )
        await store.load()
        let tools = AgentApplicationServices().tools(store: store)
        let result = try await tools.execute(name: "drafts_create_html", arguments: .object([
            "accountID": .string(account.id), "subject": .string("Proposta"), "body": .string("Proposta em texto"),
            "html": .string("<table><tr><td><img src=\"cid:logo\"></td><td>Proposta</td></tr></table><!--okamiuni-signature:work--><a href=\"&#106;avascript:alert(1)\">x</a>"),
            "to": .array([.string("ana@example.com")]), "requestID": .string("sqlite-html"),
        ]))
        let id = try #require(result["draftID"]?.stringValue)
        let reopened = try #require(try await DatabaseMailSource(database: database).messages().first { $0.id == id })
        let html = try #require(reopened.bodyHTML)
        #expect(html.contains("<table>"))
        #expect(html.contains("cid:logo"))
        #expect(html.contains("okamiuni-signature:work"))
        #expect(!html.lowercased().contains("javascript:"))
    }

    @Test("falha de calendário externo restaura a versão persistida")
    func calendarUpdateRollsBackPersistenceOnSyncFailure() async throws {
        let database = try SyncDatabase.temporary()
        let account = Account(
            id: "rollback-a", address: "eu@gmail.example", displayName: "Eu", provider: .gmail,
            host: "gmail", tintLightHex: "#123456", tintDarkHex: "#abcdef"
        )
        try await database.pool.write { db in try AccountRecord(account, createdAt: .now).save(db) }
        let sync = FailingCalendarSync()
        let reference = Date(timeIntervalSince1970: 1_730_000_000)
        let manager = DatabaseAgentCalendarManager(
            database: database, agenda: DatabaseAgendaStore(database: database), calendarSync: sync,
            referenceDay: { reference }
        )
        let first = AgentCalendarDraft(
            id: "rollback-event", accountID: account.id, title: "Original",
            startsAt: reference.addingTimeInterval(3_600), endsAt: reference.addingTimeInterval(7_200)
        )
        _ = try await manager.create(first)
        await sync.failNextSave()
        let changed = AgentCalendarDraft(
            id: first.id, accountID: account.id, title: "Não pode persistir",
            startsAt: reference.addingTimeInterval(10_800), endsAt: reference.addingTimeInterval(14_400)
        )
        await #expect(throws: FailingCalendarSyncError.self) { _ = try await manager.update(changed) }
        #expect(try await manager.event(id: first.id)?.title == "Original")
        #expect(try DatabaseAgendaStore(database: database).savedAgendaItems().first?.title == "Original")
    }

    private func seedIMAP(_ database: SyncDatabase, attachmentData: Data) async throws {
        try await database.pool.write { db in
            try AccountRecord(imapAccount, createdAt: .now).save(db)
            let folder = FolderRecord(id: "imap-a/INBOX", accountID: imapAccount.id, serverName: "INBOX", role: .inbox, displayName: "Entrada")
            try folder.save(db)
            let message = Message(
                id: "imap-message", accountID: imapAccount.id,
                from: Contact(name: "Ana", address: "ana@example.com"), receivedAt: .now,
                subject: "Fatura", snippet: "fatura", body: ["fatura"], tags: [], bucket: .today,
                isRead: false, summary: nil, detectedEvent: nil
            )
            try MessageRecord(message, folderID: folder.id).save(db)
            try MessageAttachmentRecord(
                id: "imap-attachment", messageID: message.id, filename: "fatura.txt",
                mimeType: "text/plain", byteCount: attachmentData.count, data: attachmentData
            ).insert(db)
        }
    }

    private func gmailMessage(id: String, subject: String, labels: [String]) -> String {
        let encoded = Data("body \(id)".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let labelsJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(id)","threadId":"t-\(id)","labelIds":[\(labelsJSON)],"snippet":"body \(id)","internalDate":"1730000000000","payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"Ana <ana@example.com>"},{"name":"To","value":"eu@gmail.example"},{"name":"Subject","value":"\(subject)"}],"body":{"data":"\(encoded)"}}}
        """
    }
}

private actor RecordingCalendarSync: CalendarSyncing {
    private(set) var savedIDs: [String] = []
    private(set) var invitationAttempts = 0

    func availability() async -> CalendarAvailability { .available }
    func calendars() async -> [ConnectedCalendar] { [] }
    func synchronize(referenceDay: Date, requestAuthorization: Bool) async throws -> [AgendaItem] { [] }
    func save(_ item: AgendaItem, referenceDay: Date) async throws { savedIDs.append(item.id) }
    func remove(id: String, referenceDay: Date) async throws { }
}

private enum FailingCalendarSyncError: Error { case transport }

private actor FailingCalendarSync: CalendarSyncing {
    private var shouldFail = false

    func failNextSave() { shouldFail = true }
    func availability() async -> CalendarAvailability { .available }
    func calendars() async -> [ConnectedCalendar] { [] }
    func synchronize(referenceDay: Date, requestAuthorization: Bool) async throws -> [AgendaItem] { [] }
    func save(_ item: AgendaItem, referenceDay: Date) async throws {
        if shouldFail {
            shouldFail = false
            throw FailingCalendarSyncError.transport
        }
    }
    func remove(id: String, referenceDay: Date) async throws { }
}
