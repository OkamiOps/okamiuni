import Foundation
import GRDB
import UNICore

/// Contas que a agenda composta consulta para CalDAV. O `MailStore` ainda
/// não tem a lista no primeiro `refreshCalendar` (ele corre antes do retrato);
/// ler do banco é o que faz Zoho sincronizar na abertura.
public protocol CalendarAccountListing: Sendable {
    func calendarAccounts() async -> [Account]
}

/// EventKit do macOS **mais** CalDAV das caixas IMAP que têm servidor de
/// agenda. Uma conta que falha não apaga a agenda das outras.
public actor CompositeCalendarSync: CalendarSyncing {
    private let eventKit: EventKitCalendarAdapter
    private let accounts: any CalendarAccountListing
    private let secrets: any SecretStore
    private let session: URLSession
    private var lastCalDAVCalendars: [ConnectedCalendar] = []
    private var lastCalDAVEvents: [String: (account: Account, calendar: CalDAVCalendar, event: CalDAVEvent)] = [:]

    public init(
        eventKit: EventKitCalendarAdapter = EventKitCalendarAdapter(),
        accounts: any CalendarAccountListing,
        secrets: any SecretStore,
        session: URLSession = .shared
    ) {
        self.eventKit = eventKit
        self.accounts = accounts
        self.secrets = secrets
        self.session = session
    }

    public func availability() async -> CalendarAvailability {
        await eventKit.availability()
    }

    public func calendars() async -> [ConnectedCalendar] {
        await eventKit.calendars() + lastCalDAVCalendars
    }

    public func synchronize(
        referenceDay: Date, requestAuthorization: Bool
    ) async throws -> [AgendaItem] {
        var items: [AgendaItem] = []
        let ekState = await eventKit.availability()
        if ekState.isAvailable || requestAuthorization {
            do {
                items.append(contentsOf: try await eventKit.synchronize(
                    referenceDay: referenceDay, requestAuthorization: requestAuthorization
                ))
            } catch {
                // CalDAV das outras caixas não pode morrer porque o macOS
                // recusou o EventKit.
            }
        }

        var calDAVCalendars: [ConnectedCalendar] = []
        var calDAVEvents: [String: (account: Account, calendar: CalDAVCalendar, event: CalDAVEvent)] = [:]
        for account in await accounts.calendarAccounts() {
            guard let preset = CalDAVPresets.preset(for: account) else { continue }
            guard case .password(let senha)? = try? secrets.secret(for: account.id) else { continue }
            do {
                let result = try await pull(
                    account: account, password: senha, preset: preset, referenceDay: referenceDay
                )
                calDAVCalendars.append(contentsOf: result.calendars)
                items.append(contentsOf: result.items)
                for entry in result.index { calDAVEvents[entry.key] = entry.value }
            } catch {
                continue
            }
        }
        lastCalDAVCalendars = calDAVCalendars
        lastCalDAVEvents = calDAVEvents
        return items
    }

    public func save(_ item: AgendaItem, referenceDay: Date) async throws {
        if let id = item.calendarID, id.hasPrefix(ConnectedCalendar.calDAVPrefix) {
            try await put(item, referenceDay: referenceDay)
            return
        }
        try await eventKit.save(item, referenceDay: referenceDay)
    }

    public func remove(id: String, referenceDay: Date) async throws {
        if let cached = lastCalDAVEvents[id] {
            guard case .password(let senha)? = try? secrets.secret(for: cached.account.id),
                  let preset = CalDAVPresets.preset(for: cached.account)
            else { return }
            let transport = URLSessionCalDAVTransport(
                session: session, user: cached.account.address, password: senha
            )
            let client = try CalDAVClient(
                baseURL: preset.baseURL, transport: transport, allowedHosts: preset.allowedHosts
            )
            try await client.delete(cached.event)
            lastCalDAVEvents[id] = nil
            return
        }
        try await eventKit.remove(id: id, referenceDay: referenceDay)
    }

    private struct Pull {
        var calendars: [ConnectedCalendar]
        var items: [AgendaItem]
        var index: [String: (account: Account, calendar: CalDAVCalendar, event: CalDAVEvent)]
    }

    private func pull(
        account: Account, password: String, preset: CalDAVPreset, referenceDay: Date
    ) async throws -> Pull {
        let transport = URLSessionCalDAVTransport(
            session: session, user: account.address, password: password
        )
        let client = try CalDAVClient(
            baseURL: preset.baseURL, transport: transport, allowedHosts: preset.allowedHosts
        )
        let remote = try await client.discoverCalendars()
        let start = Calendar.current.date(byAdding: .day, value: -90, to: Calendar.current.startOfDay(for: referenceDay))!
        let end = Calendar.current.date(byAdding: .day, value: 366, to: Calendar.current.startOfDay(for: referenceDay))!
        var calendars: [ConnectedCalendar] = []
        var items: [AgendaItem] = []
        var index: [String: (account: Account, calendar: CalDAVCalendar, event: CalDAVEvent)] = [:]
        for calendar in remote {
            let connected = ConnectedCalendar(
                id: ConnectedCalendar.calDAVID(accountID: account.id, calendarURL: calendar.url.absoluteString),
                title: calendar.title,
                source: account.host,
                colorHex: account.tintLightHex,
                allowsModifications: true
            )
            calendars.append(connected)
            for event in try await client.events(in: calendar, from: start, through: end) {
                let item = agendaItem(
                    from: event, account: account, calendar: connected, referenceDay: referenceDay
                )
                items.append(item)
                index[item.id] = (account, calendar, event)
            }
        }
        return Pull(calendars: calendars, items: items, index: index)
    }

    private func put(_ item: AgendaItem, referenceDay: Date) async throws {
        guard let accountID = ConnectedCalendar.calDAVAccountID(from: item.calendarID ?? ""),
              let account = await accounts.calendarAccounts().first(where: { $0.id == accountID }),
              let preset = CalDAVPresets.preset(for: account),
              case .password(let senha)? = try? secrets.secret(for: account.id)
        else { return }
        let transport = URLSessionCalDAVTransport(
            session: session, user: account.address, password: senha
        )
        let client = try CalDAVClient(
            baseURL: preset.baseURL, transport: transport, allowedHosts: preset.allowedHosts
        )
        let remote = try await client.discoverCalendars()
        let target = remote.first { ConnectedCalendar.calDAVID(accountID: account.id, calendarURL: $0.url.absoluteString) == item.calendarID }
            ?? remote.first
        guard let target else { return }
        let start = date(for: item.dayOffset, minute: item.startMinute, referenceDay: referenceDay)
        let end = date(for: item.dayOffset, minute: max(item.endMinute, item.startMinute + 1), referenceDay: referenceDay)
        let href = lastCalDAVEvents[item.id]?.event.href
            ?? target.url.appendingPathComponent("\(item.id).ics")
        let event = CalDAVEvent(
            href: href, uid: item.calendarUID ?? item.id, okamiID: item.id,
            title: item.title, start: start, end: end,
            location: item.detail?.place, notes: item.detail?.descricao,
            rrule: RecurrenceRule.parse(item.detail?.recurrence)?.rfc5545
        )
        try await client.put(event, in: target)
    }

    private func agendaItem(
        from event: CalDAVEvent, account: Account,
        calendar: ConnectedCalendar, referenceDay: Date
    ) -> AgendaItem {
        let cal = Calendar.current
        let startMinute: Int
        let endMinute: Int
        if event.isAllDay {
            startMinute = 0
            endMinute = 1_440
        } else {
            let startParts = cal.dateComponents([.hour, .minute], from: event.start)
            let endParts = cal.dateComponents([.hour, .minute], from: event.end)
            startMinute = (startParts.hour ?? 0) * 60 + (startParts.minute ?? 0)
            let sameDay = cal.isDate(event.end, inSameDayAs: event.start)
            endMinute = sameDay
                ? max(startMinute + 1, (endParts.hour ?? 0) * 60 + (endParts.minute ?? 0))
                : 1_440
        }
        let dayOffset = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: referenceDay),
            to: cal.startOfDay(for: event.start)
        ).day ?? 0
        return AgendaItem(
            id: event.okamiID ?? "caldav:\(account.id):\(event.uid):\(Int(event.start.timeIntervalSince1970))",
            title: event.title,
            startMinute: startMinute, endMinute: endMinute,
            accountID: account.id, dayOffset: dayOffset,
            calendarUID: event.uid,
            calendarID: calendar.id, calendarTitle: calendar.title,
            calendarColorHex: calendar.colorHex, calendarSource: calendar.source
        )
    }

    private func date(for offset: Int, minute: Int, referenceDay: Date) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: referenceDay))!
        return Calendar.current.date(byAdding: .minute, value: minute, to: day)!
    }
}

/// Basic auth no transporte. A senha nunca entra na URL nem no log do cliente.
struct URLSessionCalDAVTransport: CalDAVTransport {
    let session: URLSession
    let user: String
    let password: String

    func send(_ request: CalDAVRequest) async throws -> CalDAVResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 30
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        urlRequest.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return CalDAVResponse(status: http.statusCode, body: data, finalURL: http.url)
    }
}

public struct DatabaseCalendarAccounts: CalendarAccountListing {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    public func calendarAccounts() async -> [Account] {
        (try? await database.pool.read { db in
            try AccountRecord.order(Column("createdAt")).fetchAll(db).map(\.account)
        }) ?? []
    }
}
