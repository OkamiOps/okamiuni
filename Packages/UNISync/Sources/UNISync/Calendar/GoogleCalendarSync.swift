import Foundation
import UNICore

/// A agenda do Google da conta que o OkamiUNI acabou de autorizar.
///
/// O EventKit só vê o Google que a pessoa adicionou no Calendário do macOS.
/// Entrar com o Google aqui grava o e-mail e o token, e a agenda ficava de
/// fora: `calendar.events` já permite ler e gravar a agenda principal, e a
/// lista inteira entra quando o token tem `calendar.calendarlist.readonly`.
/// Sem a lista, a agenda principal (`primary`) ainda sincroniza — quem já
/// autorizou não precisa entrar de novo para ver o calendário dela.
struct GoogleCalendarSync: Sendable {
    let session: URLSession
    let token: @Sendable (String) async throws -> String
    let baseURL: URL

    init(
        session: URLSession,
        token: @Sendable @escaping (String) async throws -> String,
        baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3/")!
    ) {
        self.session = session
        self.token = token
        self.baseURL = baseURL
    }

    struct Pull: Sendable {
        var calendars: [ConnectedCalendar]
        var items: [AgendaItem]
        var index: [String: GoogleEventRef]
    }

    /// O Mac já mostra esta conta quando a origem ou o título do EventKit é o
    /// endereço. Puxar de novo a API duplicaria a mesma agenda.
    static func macAlreadyShows(_ account: Account, among calendars: [ConnectedCalendar]) -> Bool {
        let address = account.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return false }
        return calendars.contains { calendar in
            calendar.source.localizedCaseInsensitiveCompare(address) == .orderedSame
                || calendar.source.localizedCaseInsensitiveContains(address)
                || calendar.title.localizedCaseInsensitiveCompare(address) == .orderedSame
        }
    }

    func pull(account: Account, referenceDay: Date, calendar: Calendar = .current) async throws -> Pull {
        let listed: [RemoteCalendar]
        do {
            listed = try await listCalendars(account: account)
        } catch GoogleCalendarFailure.listUnavailable {
            listed = []
        }
        let remotes = listed.isEmpty ? [RemoteCalendar.primary(account)] : listed
        let start = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: referenceDay))!
        let end = calendar.date(byAdding: .day, value: 366, to: calendar.startOfDay(for: referenceDay))!
        var calendars: [ConnectedCalendar] = []
        var items: [AgendaItem] = []
        var index: [String: GoogleEventRef] = [:]
        for remote in remotes {
            let connected = ConnectedCalendar(
                id: ConnectedCalendar.googleID(accountID: account.id, calendarID: remote.id),
                title: remote.title,
                source: account.address,
                colorHex: remote.colorHex,
                allowsModifications: remote.canWrite
            )
            calendars.append(connected)
            let events = (try? await listEvents(accountID: account.id, calendarID: remote.id, from: start, through: end)) ?? []
            for event in events {
                let built = agendaItems(
                    from: event, account: account, calendar: connected,
                    remoteCalendarID: remote.id, referenceDay: referenceDay, wall: calendar
                )
                for item in built.items {
                    items.append(item)
                    index[item.id] = built.ref
                }
                if let okami = event.okamiID {
                    index[okami] = built.ref
                }
            }
        }
        return Pull(calendars: calendars, items: items, index: index)
    }

    func write(
        _ item: AgendaItem, accountID: String, remoteCalendarID: String,
        existingEventID: String?, referenceDay: Date, calendar: Calendar = .current
    ) async throws -> String {
        let updatePath = existingEventID.map { eventID in
            "calendars/\(Self.pathComponent(remoteCalendarID))/events/\(Self.pathComponent(eventID))"
        }
        let body = try JSONSerialization.data(withJSONObject: bodyObject(
            item, referenceDay: referenceDay, calendar: calendar
        ))
        let data = try await send(
            accountID: accountID,
            method: updatePath == nil ? "POST" : "PATCH",
            path: updatePath ?? "calendars/\(Self.pathComponent(remoteCalendarID))/events",
            query: [],
            body: body,
            ok: 200..<300
        )
        struct Wire: Decodable { let id: String? }
        let created = (try? JSONDecoder().decode(Wire.self, from: data))?.id
        return created ?? existingEventID ?? item.id
    }

    func delete(accountID: String, remoteCalendarID: String, eventID: String) async throws {
        _ = try await send(
            accountID: accountID,
            method: "DELETE",
            path: "calendars/\(Self.pathComponent(remoteCalendarID))/events/\(Self.pathComponent(eventID))",
            query: [],
            body: nil,
            ok: 200..<300
        )
    }

    // MARK: Lista e eventos

    private func listCalendars(account: Account) async throws -> [RemoteCalendar] {
        var page: String?
        var collected: [RemoteCalendar] = []
        for _ in 0..<5 {
            var query = [
                URLQueryItem(name: "minAccessRole", value: "reader"),
                URLQueryItem(name: "maxResults", value: "250"),
            ]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            let result = try await fetch(
                accountID: account.id, method: "GET",
                path: "users/me/calendarList", query: query, body: nil
            )
            if result.status == 401 { throw SyncError.autenticacao }
            if result.status == 403 { throw GoogleCalendarFailure.listUnavailable }
            guard (200..<300).contains(result.status) else {
                throw SyncError.resposta("O Google Agenda respondeu \(result.status).")
            }
            let wire = try JSONDecoder().decode(CalendarListWire.self, from: result.data)
            collected.append(contentsOf: (wire.items ?? []).compactMap { RemoteCalendar(wire: $0, account: account) })
            guard let next = wire.nextPageToken, !next.isEmpty else { break }
            page = next
        }
        return collected.sorted { lhs, rhs in
            if lhs.primary != rhs.primary { return lhs.primary }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func listEvents(
        accountID: String, calendarID: String, from start: Date, through end: Date
    ) async throws -> [RemoteEvent] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var page: String?
        var collected: [RemoteEvent] = []
        for _ in 0..<8 {
            var query = [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "timeMin", value: formatter.string(from: start)),
                URLQueryItem(name: "timeMax", value: formatter.string(from: end)),
            ]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            let result = try await fetch(
                accountID: accountID, method: "GET",
                path: "calendars/\(Self.pathComponent(calendarID))/events",
                query: query, body: nil
            )
            if result.status == 401 { throw SyncError.autenticacao }
            // Sem permissão neste calendário a agenda continua na lista,
            // vazia, em vez de sumir a conta inteira.
            if result.status == 403 { return collected }
            guard (200..<300).contains(result.status) else {
                throw SyncError.resposta("O Google Agenda respondeu \(result.status).")
            }
            let wire = try JSONDecoder().decode(EventsWire.self, from: result.data)
            collected.append(contentsOf: (wire.items ?? []).compactMap(RemoteEvent.init(wire:)))
            guard let next = wire.nextPageToken, !next.isEmpty else { break }
            page = next
        }
        return collected
    }

    // MARK: HTTP

    private struct HTTPResult {
        var status: Int
        var data: Data
    }

    private func send(
        accountID: String, method: String, path: String,
        query: [URLQueryItem], body: Data?, ok: Range<Int>
    ) async throws -> Data {
        let result = try await fetch(
            accountID: accountID, method: method, path: path, query: query, body: body
        )
        guard ok.contains(result.status) else {
            if result.status == 401 { throw SyncError.autenticacao }
            throw SyncError.resposta("O Google Agenda respondeu \(result.status).")
        }
        return result.data
    }

    private func fetch(
        accountID: String, method: String, path: String,
        query: [URLQueryItem], body: Data?
    ) async throws -> HTTPResult {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SyncError.resposta("URL do Google Agenda inválida.")
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw SyncError.resposta("URL do Google Agenda inválida.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(try await token(accountID))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.resposta("O Google Agenda respondeu sem HTTP.")
        }
        return HTTPResult(status: http.statusCode, data: data)
    }

    static func pathComponent(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    private func bodyObject(
        _ item: AgendaItem, referenceDay: Date, calendar: Calendar
    ) -> [String: Any] {
        let start = Self.date(for: item.dayOffset, minute: item.startMinute, referenceDay: referenceDay, calendar: calendar)
        let end = Self.date(
            for: item.dayOffset,
            minute: max(item.endMinute, item.startMinute + 1),
            referenceDay: referenceDay, calendar: calendar
        )
        var object: [String: Any] = [
            "summary": item.title,
            "extendedProperties": ["private": ["okamiID": item.id]],
        ]
        if item.startMinute == 0, item.endMinute >= 1_440 {
            let day = Self.dayString(start, calendar: calendar)
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
            object["start"] = ["date": day]
            object["end"] = ["date": Self.dayString(next, calendar: calendar)]
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let zone = TimeZone.current.identifier
            object["start"] = ["dateTime": formatter.string(from: start), "timeZone": zone]
            object["end"] = ["dateTime": formatter.string(from: end), "timeZone": zone]
        }
        if let place = item.detail?.place.trimmingCharacters(in: .whitespacesAndNewlines),
           !place.isEmpty, place != L10n.tr("Sem local definido") {
            object["location"] = place
        }
        if let notes = item.detail?.descricao?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            object["description"] = notes
        }
        return object
    }

    private static func date(for offset: Int, minute: Int, referenceDay: Date, calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: referenceDay))!
        return calendar.date(byAdding: .minute, value: minute, to: day)!
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct GoogleEventRef: Sendable, Hashable {
    var accountID: String
    var remoteCalendarID: String
    var eventID: String
}

enum GoogleCalendarItemID {
    static func make(
        accountID: String, remoteCalendarID: String, eventID: String, start: Date, dayIndex: Int
    ) -> String {
        func enc(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        }
        var id = "gcalitem.\(enc(accountID)).\(enc(remoteCalendarID)).\(enc(eventID)).\(Int(start.timeIntervalSince1970))"
        if dayIndex > 0 { id += ".\(dayIndex)" }
        return id
    }

    static func parse(_ id: String) -> GoogleEventRef? {
        guard id.hasPrefix("gcalitem.") else { return nil }
        let parts = id.dropFirst("gcalitem.".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 4,
              let accountID = String(parts[0]).removingPercentEncoding,
              let remote = String(parts[1]).removingPercentEncoding,
              let eventID = String(parts[2]).removingPercentEncoding,
              !accountID.isEmpty, !remote.isEmpty, !eventID.isEmpty
        else { return nil }
        return GoogleEventRef(accountID: accountID, remoteCalendarID: remote, eventID: eventID)
    }
}

private enum GoogleCalendarFailure: Error {
    /// `calendarList` recusou. A agenda principal ainda pode ser lida com
    /// `calendar.events`, que é o escopo que a conta já tem.
    case listUnavailable
}

private struct RemoteCalendar: Sendable {
    var id: String
    var title: String
    var colorHex: String
    var canWrite: Bool
    var primary: Bool

    static func primary(_ account: Account) -> RemoteCalendar {
        RemoteCalendar(
            id: "primary", title: account.address, colorHex: account.tintLightHex,
            canWrite: true, primary: true
        )
    }

    init(id: String, title: String, colorHex: String, canWrite: Bool, primary: Bool) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.canWrite = canWrite
        self.primary = primary
    }

    init?(wire: CalendarListWire.Item, account: Account) {
        if wire.selected == false { return nil }
        if wire.accessRole == "freeBusyReader" { return nil }
        let rawTitle = wire.summaryOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = wire.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false ? rawTitle : nil)
            ?? (summary?.isEmpty == false ? summary : nil)
            ?? account.address
        let color = wire.backgroundColor.flatMap(Self.hex) ?? account.tintLightHex
        let role = wire.accessRole ?? ""
        self.init(
            id: wire.id,
            title: title,
            colorHex: color,
            canWrite: role == "owner" || role == "writer",
            primary: wire.primary == true
        )
    }

    private static func hex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.hasPrefix("#"),
              trimmed.dropFirst().allSatisfy({ $0.isHexDigit })
        else { return nil }
        return trimmed.uppercased()
    }
}

private struct RemoteEvent: Sendable {
    var id: String
    var iCalUID: String?
    var okamiID: String?
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var notes: String?
    var link: String?
    var organizerName: String?
    var organizerEmail: String?
    var attendees: [RemoteAttendee]
    var recurring: Bool
    var cancelled: Bool
}

private struct RemoteAttendee: Sendable {
    var name: String
    var email: String
    var optional: Bool
    var status: EventPerson.Status
}

private struct CalendarListWire: Decodable {
    struct Item: Decodable {
        let id: String
        let summary: String?
        let summaryOverride: String?
        let backgroundColor: String?
        let accessRole: String?
        let selected: Bool?
        let primary: Bool?
    }

    let items: [Item]?
    let nextPageToken: String?
}

private struct EventsWire: Decodable {
    struct Item: Decodable {
        struct When: Decodable {
            let date: String?
            let dateTime: String?
        }

        struct Person: Decodable {
            let email: String?
            let displayName: String?
            let responseStatus: String?
            let optional: Bool?
        }

        struct Conference: Decodable {
            struct Entry: Decodable { let uri: String? }
            let entryPoints: [Entry]?
        }

        struct Extended: Decodable {
            struct Priv: Decodable { let okamiID: String? }
            let priv: Priv?
            enum CodingKeys: String, CodingKey { case priv = "private" }
        }

        let id: String
        let status: String?
        let summary: String?
        let description: String?
        let location: String?
        let hangoutLink: String?
        let iCalUID: String?
        let recurringEventId: String?
        let start: When?
        let end: When?
        let organizer: Person?
        let attendees: [Person]?
        let conferenceData: Conference?
        let extendedProperties: Extended?
    }

    let items: [Item]?
    let nextPageToken: String?
}

extension RemoteEvent {
    init?(wire: EventsWire.Item) {
        guard let start = wire.start else { return nil }
        let allDay = start.dateTime == nil && start.date != nil
        guard let begins = Self.parse(start, allDay: allDay) else { return nil }
        let ends = wire.end.flatMap { Self.parse($0, allDay: allDay) } ?? begins.addingTimeInterval(allDay ? 86_400 : 1_800)
        let meet = wire.hangoutLink
            ?? wire.conferenceData?.entryPoints?.compactMap(\.uri).first { $0.contains("meet.google.com") }
        let people = (wire.attendees ?? []).compactMap { person -> RemoteAttendee? in
            let email = person.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !email.isEmpty else { return nil }
            if email.caseInsensitiveCompare(wire.organizer?.email ?? "") == .orderedSame { return nil }
            let name = person.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RemoteAttendee(
                name: (name?.isEmpty == false ? name! : email),
                email: email,
                optional: person.optional == true,
                status: Self.rsvp(person.responseStatus)
            )
        }
        let title = wire.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: wire.id,
            iCalUID: wire.iCalUID,
            okamiID: wire.extendedProperties?.priv?.okamiID,
            title: (title?.isEmpty == false ? title! : "Sem título"),
            start: begins,
            end: ends,
            allDay: allDay,
            location: wire.location,
            notes: wire.description,
            link: meet,
            organizerName: wire.organizer?.displayName,
            organizerEmail: wire.organizer?.email,
            attendees: people,
            recurring: wire.recurringEventId != nil,
            cancelled: wire.status == "cancelled"
        )
    }

    private static func parse(_ when: EventsWire.Item.When, allDay: Bool) -> Date? {
        if allDay, let day = when.date {
            return parseDay(day)
        }
        if let raw = when.dateTime {
            return parseDateTime(raw)
        }
        return nil
    }

    private static func parseDateTime(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func parseDay(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }

    private static func rsvp(_ raw: String?) -> EventPerson.Status {
        switch raw {
        case "accepted": .yes
        case "tentative": .maybe
        default: .pending
        }
    }
}

private struct BuiltEvents {
    var items: [AgendaItem]
    var ref: GoogleEventRef
}

extension GoogleCalendarSync {
    fileprivate func agendaItems(
        from event: RemoteEvent, account: Account, calendar connected: ConnectedCalendar,
        remoteCalendarID: String, referenceDay: Date, wall: Calendar
    ) -> BuiltEvents {
        let ref = GoogleEventRef(
            accountID: account.id, remoteCalendarID: remoteCalendarID, eventID: event.id
        )
        let organizerEmail = event.organizerEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let organizerName = event.organizerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = EventDetail(
            place: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? L10n.tr("Sem local definido"),
            link: event.link,
            organizer: EventPerson(
                name: (organizerName?.isEmpty == false ? organizerName! : account.displayName),
                address: (organizerEmail?.isEmpty == false ? organizerEmail! : account.address),
                role: "organizador",
                status: .yes
            ),
            people: event.attendees.map { person in
                EventPerson(
                    name: person.name, address: person.email,
                    role: person.optional ? "opcional" : "obrigatório",
                    status: person.status
                )
            },
            note: account.address,
            recurrence: event.recurring ? "Recorrente" : "Evento único",
            notice: "",
            agenda: [],
            thread: [],
            descricao: event.notes
        )
        if event.allDay {
            var items: [AgendaItem] = []
            var cursor = wall.startOfDay(for: event.start)
            let exclusive = wall.startOfDay(for: event.end)
            let cap = wall.date(byAdding: .day, value: 21, to: cursor)!
            var index = 0
            while cursor < exclusive, cursor < cap {
                items.append(item(
                    event: event, account: account, calendar: connected, detail: detail,
                    start: cursor, end: cursor, allDay: true,
                    referenceDay: referenceDay, wall: wall, dayIndex: index
                ))
                cursor = wall.date(byAdding: .day, value: 1, to: cursor)!
                index += 1
            }
            if items.isEmpty {
                items.append(item(
                    event: event, account: account, calendar: connected, detail: detail,
                    start: event.start, end: event.end, allDay: true,
                    referenceDay: referenceDay, wall: wall, dayIndex: 0
                ))
            }
            return BuiltEvents(items: items, ref: ref)
        }
        return BuiltEvents(
            items: [item(
                event: event, account: account, calendar: connected, detail: detail,
                start: event.start, end: event.end, allDay: false,
                referenceDay: referenceDay, wall: wall, dayIndex: 0
            )],
            ref: ref
        )
    }

    private func item(
        event: RemoteEvent, account: Account, calendar connected: ConnectedCalendar,
        detail: EventDetail, start: Date, end: Date, allDay: Bool,
        referenceDay: Date, wall: Calendar, dayIndex: Int
    ) -> AgendaItem {
        let startMinute: Int
        let endMinute: Int
        if allDay {
            startMinute = 0
            endMinute = 1_440
        } else {
            let startParts = wall.dateComponents([.hour, .minute], from: start)
            let endParts = wall.dateComponents([.hour, .minute], from: end)
            startMinute = (startParts.hour ?? 0) * 60 + (startParts.minute ?? 0)
            endMinute = wall.isDate(end, inSameDayAs: start)
                ? max(startMinute + 1, (endParts.hour ?? 0) * 60 + (endParts.minute ?? 0))
                : 1_440
        }
        let dayOffset = wall.dateComponents(
            [.day], from: wall.startOfDay(for: referenceDay), to: wall.startOfDay(for: start)
        ).day ?? 0
        // O id estável que o app gravou ao criar o compromisso. Sem ele, o
        // evento voltava da API com outro id e aparecia duas vezes.
        let id = (dayIndex == 0 ? event.okamiID : nil) ?? GoogleCalendarItemID.make(
            accountID: account.id,
            remoteCalendarID: remoteID(of: connected),
            eventID: event.id,
            start: start,
            dayIndex: dayIndex
        )
        return AgendaItem(
            id: id,
            title: event.title,
            startMinute: startMinute,
            endMinute: endMinute,
            accountID: account.id,
            dayOffset: dayOffset,
            calendarUID: event.iCalUID,
            detail: detail,
            calendarID: connected.id,
            calendarTitle: connected.title,
            calendarColorHex: connected.colorHex,
            calendarSource: connected.source,
            isCancelled: event.cancelled
        )
    }

    private func remoteID(of calendar: ConnectedCalendar) -> String {
        ConnectedCalendar.googleRemoteID(from: calendar.id) ?? "primary"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
