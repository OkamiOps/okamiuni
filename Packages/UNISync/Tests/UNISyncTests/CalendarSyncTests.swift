import Foundation
import EventKit
import Testing
import UNICore
@testable import UNISync

private actor EventKitGatewayDouble: SystemCalendarGateway {
    var state: CalendarAvailability = .authorizationRequired
    var requests = 0
    var items: [AgendaItem] = []
    var saved: [String] = []
    var removed: [String] = []
    var listedCalendars: [ConnectedCalendar] = []

    init(
        state: CalendarAvailability = .authorizationRequired,
        items: [AgendaItem] = [],
        calendars: [ConnectedCalendar] = []
    ) {
        self.state = state
        self.items = items
        self.listedCalendars = calendars
    }

    func availability() -> CalendarAvailability { state }
    func requestAccess() async throws -> CalendarAvailability {
        requests += 1
        state = .available
        return state
    }
    func calendars() -> [ConnectedCalendar] { listedCalendars }
    func events(referenceDay _: Date) throws -> [AgendaItem] { items }
    func save(_ item: AgendaItem, referenceDay _: Date) throws { saved.append(item.id) }
    func remove(id: String, referenceDay _: Date) throws { removed.append(id) }

    func snapshot() -> (requests: Int, saved: [String], removed: [String]) {
        (requests, saved, removed)
    }
}

private actor CalDAVScript: CalDAVTransport {
    private var replies: [CalDAVResponse]
    private var recorded: [CalDAVRequest] = []

    init(_ replies: [CalDAVResponse]) { self.replies = replies }

    func send(_ request: CalDAVRequest) async throws -> CalDAVResponse {
        recorded.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return replies.removeFirst()
    }

    func requests() -> [CalDAVRequest] { recorded }
}

@Suite("Agenda real")
@MainActor
struct EventKitCalendarAdapterTests {
    private var organizer: EventPerson {
        EventPerson(
            name: "Marcos", address: "marcos@okamiops.com",
            role: "organizador · você", status: .yes
        )
    }

    @Test("A autorização só é pedida pela ação explícita e então a leitura chega")
    func explicitAuthorization() async throws {
        let gateway = EventKitGatewayDouble(items: [
            AgendaItem(
                id: "ek-1", title: "Call", startMinute: 540, endMinute: 570,
                accountID: "system"
            )
        ])
        let adapter = EventKitCalendarAdapter(gateway: gateway)

        await #expect(throws: (any Error).self) {
            _ = try await adapter.synchronize(referenceDay: Fixtures.today, requestAuthorization: false)
        }
        let before = await gateway.snapshot()
        #expect(before.requests == 0)

        let items = try await adapter.synchronize(referenceDay: Fixtures.today, requestAuthorization: true)
        let after = await gateway.snapshot()
        #expect(after.requests == 1)
        #expect(items.map(\.id) == ["ek-1"])
    }

    @Test("Escrita e remoção alcançam o adapter, não só a lista local")
    func writesThroughGateway() async throws {
        let gateway = EventKitGatewayDouble(state: .available)
        let adapter = EventKitCalendarAdapter(gateway: gateway)
        let item = AgendaItem(id: "email-1", title: "Contrato", startMinute: 600, endMinute: 660, accountID: "zoho")

        try await adapter.save(item, referenceDay: Fixtures.today)
        try await adapter.remove(id: item.id, referenceDay: Fixtures.today)

        let result = await gateway.snapshot()
        #expect(result.saved == ["email-1"])
        #expect(result.removed == ["email-1"])
    }

    @Test("Cada ocorrência de um evento recorrente ganha id próprio")
    func occurrenceIdentityKeepsEachDay() {
        let identifier = "recurring-standup"
        let monday = Date(timeIntervalSince1970: 1_788_163_200) // 2026-08-31
        let thursday = Date(timeIntervalSince1970: 1_788_422_400) // 2026-09-03
        let a = EventKitItemID.make(
            marker: nil, calendarItemIdentifier: identifier, start: monday
        )
        let b = EventKitItemID.make(
            marker: nil, calendarItemIdentifier: identifier, start: thursday
        )
        #expect(a != b)
        #expect(a.hasPrefix("eventkit:\(identifier):"))
        #expect(b.hasPrefix("eventkit:\(identifier):"))
    }

    @Test("Remove a ocorrência Google importada sem depender de marker do app")
    func resolvesImportedOccurrenceWithoutMarker() throws {
        let start = Date(timeIntervalSince1970: 1_788_163_200)
        let cancelledGoogle = EventKitLookupFixture(key: "google-cancelled", marker: nil, identifier: "Google:opaque:identifier", start: start)
        let id = EventKitItemID.make(marker: nil, calendarItemIdentifier: cancelledGoogle.identifier, start: start)

        let selected = try #require(EventKitEventLookup.find(id: id, in: [cancelledGoogle], identity: \.identity))
        #expect(selected.key == "google-cancelled")
    }

    @Test("O id da recorrência não seleciona outro dia, outro horário ou outra série")
    func resolvesOnlyRequestedOccurrence() throws {
        let start = Date(timeIntervalSince1970: 1_788_163_200)
        let otherDay = EventKitLookupFixture(key: "next-week", marker: nil, identifier: "recurring-series", start: start.addingTimeInterval(7 * 86_400))
        let otherTime = EventKitLookupFixture(key: "same-day-later", marker: nil, identifier: "recurring-series", start: start.addingTimeInterval(3_600))
        let otherSeries = EventKitLookupFixture(key: "other-series", marker: nil, identifier: "other-series", start: start)
        let target = EventKitLookupFixture(key: "requested", marker: nil, identifier: "recurring-series", start: start)
        let id = EventKitItemID.make(marker: nil, calendarItemIdentifier: target.identifier, start: start)

        let selected = try #require(EventKitEventLookup.find(id: id, in: [otherDay, otherTime, otherSeries, target], identity: \.identity))
        #expect(selected.key == "requested")
        #expect(EventKitEventLookup.find(id: id, in: [otherDay, otherTime, otherSeries], identity: \.identity) == nil)
    }

    @Test("Marker de um evento criado no app continua sendo a identidade preferencial")
    func preservesCreatedEventMarkerLookup() throws {
        let start = Date(timeIntervalSince1970: 1_788_163_200)
        let id = EventKitItemID.make(marker: nil, calendarItemIdentifier: "imported-original", start: start)
        let imported = EventKitLookupFixture(key: "unmarked", marker: nil, identifier: "imported-original", start: start)
        let movedAppEvent = EventKitLookupFixture(key: "marked", marker: id, identifier: "new-system-identifier", start: start.addingTimeInterval(86_400))
        let selected = try #require(EventKitEventLookup.find(id: id, in: [imported, movedAppEvent], identity: \.identity))
        #expect(selected.key == "marked")

        let manual = EventKitLookupFixture(key: "manual", marker: "email-created-event", identifier: "system-manual", start: start)
        #expect(EventKitEventLookup.find(id: "email-created-event", in: [manual], identity: \.identity)?.key == "manual")
    }

    @Test("Ocorrência inexistente e segunda remoção não atingem os outros eventos")
    func absentOccurrenceIsIdempotent() throws {
        let start = Date(timeIntervalSince1970: 1_788_163_200)
        let target = EventKitLookupFixture(key: "target", marker: nil, identifier: "series", start: start)
        let next = EventKitLookupFixture(key: "next", marker: nil, identifier: "series", start: start.addingTimeInterval(86_400))
        let id = EventKitItemID.make(marker: nil, calendarItemIdentifier: "series", start: start)
        var events = [target, next]
        let firstRemoval = try #require(EventKitEventLookup.find(id: id, in: events, identity: \.identity))
        events.removeAll { $0.key == firstRemoval.key }
        #expect(EventKitEventLookup.find(id: id, in: events, identity: \.identity) == nil)
        #expect(events.map(\.key) == ["next"])
        #expect(EventKitEventLookup.find(id: "missing", in: events, identity: \.identity) == nil)
    }

    @Test("A busca importada usa o dia codificado mesmo fora da referência atual")
    func importedLookupUsesEncodedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_788_163_200)
        let id = EventKitItemID.make(marker: nil, calendarItemIdentifier: "Google:opaque:identifier", start: start)
        let interval = try #require(EventKitItemID.importedOccurrenceDay(id: id, calendar: calendar))
        #expect(interval.start == calendar.startOfDay(for: start))
        #expect(interval.end == calendar.date(byAdding: .day, value: 1, to: interval.start))
        #expect(interval.contains(start))
        #expect(EventKitItemID.importedOccurrenceDay(id: "email-created-event", calendar: calendar) == nil)
        #expect(EventKitItemID.importedOccurrenceDay(id: "eventkit:series:not-a-time", calendar: calendar) == nil)
    }

    @Test("Marker diferente e evento sem início nunca são removidos por um id importado")
    func refusesMismatchedIdentity() {
        let start = Date(timeIntervalSince1970: 1_788_163_200)
        let id = EventKitItemID.make(marker: nil, calendarItemIdentifier: "series", start: start)
        let markedOtherEvent = EventKitLookupFixture(key: "marked-other", marker: "other-app-event", identifier: "series", start: start)
        let missingStart = EventKitLookupFixture(key: "missing-start", marker: nil, identifier: "series", start: nil)
        #expect(EventKitEventLookup.find(id: id, in: [markedOtherEvent, missingStart], identity: \.identity) == nil)
    }

    @Test("A ponte exporta a sala sem perder as notas")
    func exportsMeetingInNotes() {
        let detail = EventDetail(
            place: "", link: "https://empresa.webex.com/meet/revisao",
            organizer: organizer, people: [], note: "Criado manualmente",
            recurrence: "Não se repete", notice: "Sem lembrete",
            agenda: [], thread: [], descricao: "Levar os números do trimestre."
        )

        #expect(
            EventKitEventNotes.text(for: detail)
                == "Levar os números do trimestre.\n\nLink da reunião: https://empresa.webex.com/meet/revisao"
        )
        #expect(EventKitEventNotes.text(for: nil) == nil)
    }

    @Test("Participantes do EventKit preservam email e sinalizam entradas sem endereço")
    func projectsAttendeesForMutationGuard() {
        let identified = EventKitParticipantProjection.person(
            name: "Ana", url: URL(string: "mailto:ana%40example.com"),
            role: .required, status: .accepted, index: 0
        )
        let opaque = EventKitParticipantProjection.person(
            name: nil, url: URL(string: "urn:uuid:7E5A"),
            role: .optional, status: .tentative, index: 1
        )

        #expect(identified == EventPerson(
            name: "Ana", address: "ana@example.com", role: "obrigatório", status: .yes
        ))
        #expect(opaque == EventPerson(
            name: "Participante sem endereço 2", address: "",
            role: "opcional", status: .maybe
        ))
    }
}

private struct EventKitLookupFixture {
    let key: String
    let marker: String?
    let identifier: String
    let start: Date?
    var identity: EventKitEventIdentity { .init(marker: marker, calendarItemIdentifier: identifier, start: start) }
}

@Suite("CalDAV sem rede externa")
struct CalDAVClientTests {
    private func response(_ text: String) -> CalDAVResponse { .init(status: 207, body: Data(text.utf8)) }

    @Test("Descobre, sincroniza e grava VEVENT com transporte injetado")
    func discoverySyncAndWrite() async throws {
        let discovery = """
        <d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop><d:current-user-principal><d:href>/principals/marcos/</d:href></d:current-user-principal></d:prop></d:propstat></d:response></d:multistatus>
        """
        let home = """
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:propstat><d:prop><c:calendar-home-set><d:href>/calendars/marcos/</d:href></c:calendar-home-set></d:prop></d:propstat></d:response></d:multistatus>
        """
        let collection = """
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/calendars/marcos/trabalho/</d:href><d:propstat><d:prop><d:displayname>Trabalho</d:displayname><d:resourcetype><d:collection/><c:calendar/></d:resourcetype></d:prop></d:propstat></d:response></d:multistatus>
        """
        let events = """
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/calendars/marcos/trabalho/contrato.ics</d:href><d:propstat><d:prop><c:calendar-data>BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:uid-1
        DTSTART:20260830T100000Z
        DTEND:20260830T110000Z
        SUMMARY:Contrato
        X-OKAMIUNI-ID:email-1
        END:VEVENT
        END:VCALENDAR</c:calendar-data></d:prop></d:propstat></d:response></d:multistatus>
        """
        let script = CalDAVScript([response(discovery), response(home), response(collection), response(events), .init(status: 201)])
        let client = try CalDAVClient(baseURL: URL(string: "https://caldav.example")!, transport: script)

        let calendars = try await client.discoverCalendars()
        let calendar = try #require(calendars.first)
        let synchronized = try await client.events(
            in: calendar, from: Fixtures.today, through: Fixtures.today.addingTimeInterval(86_400)
        )
        let event = try #require(synchronized.first)
        try await client.put(event, in: calendar)

        let requests = await script.requests()
        #expect(requests.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT", "PUT"])
        #expect(event.okamiID == "email-1")
        #expect(String(data: try #require(requests.last?.body), encoding: .utf8)?.contains("X-OKAMIUNI-ID:email-1") == true)
    }

    @Test("Recusa HTTP e href que saem do host HTTPS configurado")
    func secureDestination() async throws {
        let script = CalDAVScript([])
        #expect(throws: SyncError.tls("CalDAV exige uma URL HTTPS com host")) {
            _ = try CalDAVClient(baseURL: URL(string: "http://calendar.example")!, transport: script)
        }

        let client = try CalDAVClient(baseURL: URL(string: "https://calendar.example")!, transport: script)
        let remote = CalDAVEvent(
            href: URL(string: "https://other.example/event.ics")!, uid: "x", okamiID: nil,
            title: "x", start: Fixtures.today, end: Fixtures.today.addingTimeInterval(60),
            location: nil, notes: nil
        )
        let calendar = CalDAVCalendar(url: URL(string: "https://calendar.example/work/")!, title: "Trabalho")
        await #expect(throws: SyncError.tls("O servidor CalDAV apontou para outro host ou para uma URL insegura")) {
            try await client.put(remote, in: calendar)
        }

        let redirected = CalDAVScript([
            .init(status: 207, finalURL: URL(string: "https://other.example/.well-known/caldav"))
        ])
        let redirectClient = try CalDAVClient(
            baseURL: URL(string: "https://calendar.example")!, transport: redirected
        )
        await #expect(throws: SyncError.tls("CalDAV recusou redirect para outro host ou para uma URL insegura")) {
            _ = try await redirectClient.discoverCalendars()
        }
    }
}

private struct StaticCalendarAccounts: CalendarAccountListing {
    let accounts: [Account]
    init(_ accounts: [Account]) { self.accounts = accounts }
    func calendarAccounts() async -> [Account] { accounts }
}

@Suite("Agenda composta: EventKit e CalDAV")
struct CompositeCalendarSyncTests {
    @Test("Zoho e Yahoo têm CalDAV; Hostinger não")
    func presetsFollowImapHost() {
        let zoho = Account(
            id: "z", address: "a@empresa.com", displayName: "A",
            provider: .imap, host: "zoho",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7",
            imap: ImapEndpoint(host: "imap.zoho.com", port: 993, security: .tls)
        )
        let hostinger = Account(
            id: "h", address: "b@site.com", displayName: "B",
            provider: .imap, host: "hostinger",
            tintLightHex: "#397852", tintDarkHex: "#88D1A2",
            imap: ImapEndpoint(host: "imap.hostinger.com", port: 993, security: .tls)
        )
        let yahoo = Account(
            id: "y", address: "c@yahoo.com", displayName: "C",
            provider: .imap, host: "yahoo",
            tintLightHex: "#6A1B9A", tintDarkHex: "#CE93D8",
            imap: ImapEndpoint(host: "imap.mail.yahoo.com", port: 993, security: .tls)
        )
        #expect(CalDAVPresets.preset(for: zoho)?.name == "Zoho")
        #expect(CalDAVPresets.preset(for: yahoo)?.name == "Yahoo")
        #expect(CalDAVPresets.preset(for: hostinger) == nil)
    }

    @Test("Sem contas IMAP, a composta devolve só o EventKit")
    func fallsBackToEventKit() async throws {
        let gateway = EventKitGatewayDouble(state: .available, items: [
            AgendaItem(id: "ek-1", title: "Call", startMinute: 540, endMinute: 570, accountID: "system")
        ])
        let composite = CompositeCalendarSync(
            eventKit: EventKitCalendarAdapter(gateway: gateway),
            accounts: StaticCalendarAccounts([]),
            secrets: InMemorySecretStore()
        )
        let items = try await composite.synchronize(
            referenceDay: Fixtures.today, requestAuthorization: false
        )
        #expect(items.map(\.id) == ["ek-1"])
    }

    @Test("EventKit recusado não derruba a composta")
    func eventKitDeniedDoesNotThrow() async throws {
        let gateway = EventKitGatewayDouble(state: .authorizationRequired)
        let composite = CompositeCalendarSync(
            eventKit: EventKitCalendarAdapter(gateway: gateway),
            accounts: StaticCalendarAccounts([]),
            secrets: InMemorySecretStore()
        )
        let items = try await composite.synchronize(
            referenceDay: Fixtures.today, requestAuthorization: false
        )
        #expect(items.isEmpty)
    }

    @Test("Conta Google traz a agenda e os compromissos, e ignora a lista oculta")
    func gmailAccountPullsGoogleCalendar() async throws {
        let account = googleAccount("marco@okamiops.com")
        let session = StubURLProtocol.session(routes: [
            "/calendar/v3/users/me/calendarList": [.json(
                """
                {"items":[
                  {"id":"marco@okamiops.com","summary":"Marco","backgroundColor":"#4285f4","accessRole":"owner","selected":true,"primary":true},
                  {"id":"oculta","summary":"Oculta","accessRole":"reader","selected":false}
                ]}
                """
            )],
            "/calendar/v3/calendars/marco@okamiops.com/events": [.json(
                """
                {"items":[
                  {"id":"evt-all","status":"confirmed","summary":"Folga","iCalUID":"evt-all@google.com",
                   "start":{"date":"2026-08-25"},"end":{"date":"2026-08-26"}},
                  {"id":"evt-meet","status":"confirmed","summary":"Revisão","iCalUID":"evt-meet@google.com",
                   "hangoutLink":"https://meet.google.com/abc-defg-hij","location":"Sala 2",
                   "start":{"dateTime":"2026-08-25T15:00:00-03:00"},
                   "end":{"dateTime":"2026-08-25T16:00:00-03:00"},
                   "organizer":{"email":"marco@okamiops.com","displayName":"Marco"},
                   "attendees":[{"email":"ana@okamiops.com","displayName":"Ana","responseStatus":"accepted"}]}
                ]}
                """
            )],
        ])
        let composite = googleComposite(accounts: [account], session: session)
        let items = try await composite.synchronize(referenceDay: Fixtures.today, requestAuthorization: false)
        let calendars = await composite.calendars()
        let agenda = try #require(calendars.first { $0.title == "Marco" })
        #expect(ConnectedCalendar.googleAccountID(from: agenda.id) == account.id)
        #expect(ConnectedCalendar.googleRemoteID(from: agenda.id) == "marco@okamiops.com")
        #expect(agenda.colorHex == "#4285F4")
        #expect(calendars.contains { $0.title == "Oculta" } == false)
        let folga = try #require(items.first { $0.title == "Folga" })
        #expect(folga.dayOffset == 0)
        #expect(folga.startMinute == 0)
        #expect(folga.endMinute == 1_440)
        #expect(folga.accountID == account.id)
        #expect(folga.calendarID == agenda.id)
        let revisao = try #require(items.first { $0.title == "Revisão" })
        #expect(revisao.detail?.place == "Sala 2")
        #expect(revisao.detail?.link == "https://meet.google.com/abc-defg-hij")
        #expect(revisao.detail?.people.map(\.address) == ["ana@okamiops.com"])
        let pedidos = StubURLProtocol.requests(for: session)
        #expect(pedidos.allSatisfy { $0.authorization == "Bearer ya29.test" })
        #expect(pedidos.contains { $0.path.contains("oculta") } == false)

        let round = ConnectedCalendar.googleID(accountID: "marco@okamiops.com", calendarID: "en.brazilian#holiday@group.v.calendar.google.com")
        #expect(ConnectedCalendar.googleAccountID(from: round) == "marco@okamiops.com")
        #expect(ConnectedCalendar.googleRemoteID(from: round) == "en.brazilian#holiday@group.v.calendar.google.com")
    }

    @Test("Sem a lista, a agenda principal do Google ainda entra")
    func listDeniedFallsBackToPrimary() async throws {
        let account = googleAccount("marco@okamiops.com")
        let session = StubURLProtocol.session(routes: [
            "/calendar/v3/users/me/calendarList": [.json(
                #"{"error":{"code":403,"status":"PERMISSION_DENIED","errors":[{"reason":"insufficientPermissions"}]}}"#,
                status: 403
            )],
            "/calendar/v3/calendars/primary/events": [.json(
                """
                {"items":[{"id":"p1","status":"confirmed","summary":"Primária",
                  "start":{"date":"2026-08-25"},"end":{"date":"2026-08-26"}}]}
                """
            )],
        ])
        let composite = googleComposite(accounts: [account], session: session)
        let items = try await composite.synchronize(referenceDay: Fixtures.today, requestAuthorization: false)
        let calendars = await composite.calendars()
        #expect(calendars.map(\.title) == [account.address])
        #expect(ConnectedCalendar.googleRemoteID(from: calendars[0].id) == "primary")
        #expect(items.map(\.title) == ["Primária"])
    }

    @Test("Agenda que o Mac já tem com o mesmo endereço não é puxada de novo")
    func skipsGoogleWhenEventKitAlreadyHasTheAddress() async throws {
        let account = googleAccount("marco@okamiops.com")
        let session = StubURLProtocol.session(routes: [:])
        let gateway = EventKitGatewayDouble(
            state: .available,
            calendars: [
                ConnectedCalendar(
                    id: "ek-google", title: account.address, source: "Google",
                    colorHex: "#4285F4", allowsModifications: true
                )
            ]
        )
        let composite = CompositeCalendarSync(
            eventKit: EventKitCalendarAdapter(gateway: gateway),
            accounts: StaticCalendarAccounts([account]),
            secrets: InMemorySecretStore(),
            session: session,
            googleToken: { _ in "ya29.test" }
        )
        _ = try await composite.synchronize(referenceDay: Fixtures.today, requestAuthorization: false)
        #expect(StubURLProtocol.requests(for: session).isEmpty)
    }

    @Test("Gravar na agenda Google fala com o Calendar")
    func savePostsToGoogleCalendar() async throws {
        let account = googleAccount("marco@okamiops.com")
        let session = StubURLProtocol.session(routes: [
            "/calendar/v3/calendars/primary/events": [.json(#"{"id":"novo"}"#)],
        ])
        let gateway = EventKitGatewayDouble(state: .available)
        let composite = CompositeCalendarSync(
            eventKit: EventKitCalendarAdapter(gateway: gateway),
            accounts: StaticCalendarAccounts([account]),
            secrets: InMemorySecretStore(),
            session: session,
            googleToken: { _ in "ya29.test" }
        )
        let item = AgendaItem(
            id: "manual-1", title: "Revisão", startMinute: 600, endMinute: 660,
            accountID: account.id,
            calendarID: ConnectedCalendar.googleID(accountID: account.id, calendarID: "primary")
        )
        try await composite.save(item, referenceDay: Fixtures.today)
        let body = try #require(StubURLProtocol.requests(for: session).first?.body)
        #expect(body.contains("Revisão"))
        #expect(body.contains("manual-1"))
        let shot = await gateway.snapshot()
        #expect(shot.saved.isEmpty)
    }

    private func googleAccount(_ address: String) -> Account {
        Account(
            id: address, address: address, displayName: "Marco",
            provider: .gmail, host: "gmail",
            tintLightHex: "#4285F4", tintDarkHex: "#8AB4F8"
        )
    }

    private func googleComposite(accounts: [Account], session: URLSession) -> CompositeCalendarSync {
        CompositeCalendarSync(
            eventKit: EventKitCalendarAdapter(gateway: EventKitGatewayDouble(state: .authorizationRequired)),
            accounts: StaticCalendarAccounts(accounts),
            secrets: InMemorySecretStore(),
            session: session,
            googleToken: { _ in "ya29.test" }
        )
    }
}
