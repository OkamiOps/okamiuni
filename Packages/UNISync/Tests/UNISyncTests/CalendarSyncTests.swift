import Foundation
import Testing
import UNICore
@testable import UNISync

@MainActor
private final class EventKitGatewayDouble: SystemCalendarGateway {
    var state: CalendarAvailability = .authorizationRequired
    var requests = 0
    var items: [AgendaItem] = []
    var saved: [String] = []
    var removed: [String] = []

    func availability() -> CalendarAvailability { state }
    func requestAccess() async throws -> CalendarAvailability {
        requests += 1
        state = .available
        return state
    }
    func events(referenceDay _: Date) throws -> [AgendaItem] { items }
    func save(_ item: AgendaItem, referenceDay _: Date) throws { saved.append(item.id) }
    func remove(id: String, referenceDay _: Date) throws { removed.append(id) }
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
    @Test("A autorização só é pedida pela ação explícita e então a leitura chega")
    func explicitAuthorization() async throws {
        let gateway = EventKitGatewayDouble()
        gateway.items = [AgendaItem(id: "ek-1", title: "Call", startMinute: 540, endMinute: 570, accountID: "system")]
        let adapter = EventKitCalendarAdapter(gateway: gateway)

        await #expect(throws: (any Error).self) {
            _ = try await adapter.synchronize(referenceDay: Fixtures.today, requestAuthorization: false)
        }
        #expect(gateway.requests == 0)

        let items = try await adapter.synchronize(referenceDay: Fixtures.today, requestAuthorization: true)
        #expect(gateway.requests == 1)
        #expect(items.map(\.id) == ["ek-1"])
    }

    @Test("Escrita e remoção alcançam o adapter, não só a lista local")
    func writesThroughGateway() async throws {
        let gateway = EventKitGatewayDouble()
        gateway.state = .available
        let adapter = EventKitCalendarAdapter(gateway: gateway)
        let item = AgendaItem(id: "email-1", title: "Contrato", startMinute: 600, endMinute: 660, accountID: "zoho")

        try await adapter.save(item, referenceDay: Fixtures.today)
        try await adapter.remove(id: item.id, referenceDay: Fixtures.today)

        #expect(gateway.saved == ["email-1"])
        #expect(gateway.removed == ["email-1"])
    }
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
