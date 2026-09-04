import CoreGraphics
import EventKit
import Foundation
import UNICore

/// A única dependência de EventKit que o adaptador enxerga. O protocolo deixa
/// autorização, leitura e escrita verificáveis sem abrir a agenda da máquina
/// durante a suíte.
protocol SystemCalendarGateway: Actor {
    func availability() -> CalendarAvailability
    func requestAccess() async throws -> CalendarAvailability
    func calendars() -> [ConnectedCalendar]
    func events(referenceDay: Date) throws -> [AgendaItem]
    func save(_ item: AgendaItem, referenceDay: Date) throws
    func remove(id: String, referenceDay: Date) throws
}

/// Porta de calendário do macOS. Nenhuma chamada de autorização acontece na
/// abertura: o app só a pede depois da ação explícita da pessoa na aba Agenda.
public actor EventKitCalendarAdapter: CalendarSyncing {
    private let gateway: any SystemCalendarGateway

    public init() {
        gateway = EventKitCalendarGateway()
    }

    init(gateway: any SystemCalendarGateway) {
        self.gateway = gateway
    }

    public func availability() async -> CalendarAvailability { await gateway.availability() }

    public func calendars() async -> [ConnectedCalendar] { await gateway.calendars() }

    public func synchronize(
        referenceDay: Date, requestAuthorization: Bool
    ) async throws -> [AgendaItem] {
        var state = await gateway.availability()
        if case .authorizationRequired = state, requestAuthorization {
            state = try await gateway.requestAccess()
        }
        guard state.isAvailable else { throw CalendarAdapterError(state) }
        return try await gateway.events(referenceDay: referenceDay)
    }

    public func save(_ item: AgendaItem, referenceDay: Date) async throws {
        let state = await gateway.availability()
        guard state.isAvailable else {
            throw CalendarAdapterError(state)
        }
        try await gateway.save(item, referenceDay: referenceDay)
    }

    public func remove(id: String, referenceDay: Date) async throws {
        let state = await gateway.availability()
        guard state.isAvailable else {
            throw CalendarAdapterError(state)
        }
        try await gateway.remove(id: id, referenceDay: referenceDay)
    }
}

private struct CalendarAdapterError: LocalizedError {
    let state: CalendarAvailability

    init(_ state: CalendarAvailability) { self.state = state }

    var errorDescription: String? {
        switch state {
        case .authorizationRequired:
            L10n.tr("Permita o acesso aos Calendários para sincronizar a agenda.")
        case .unavailable(let message): message
        case .loading:
            L10n.tr("A agenda ainda está sendo preparada. Tente novamente em instantes.")
        case .available:
            L10n.tr("Não foi possível atualizar a agenda do sistema.")
        }
    }
}

private actor EventKitCalendarGateway: SystemCalendarGateway {
    private let store = EKEventStore()
    private let calendar = Calendar.current
    private static let systemAccountID = "okamiuni.system-calendar"

    func availability() -> CalendarAvailability {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            .available
        case .notDetermined:
            .authorizationRequired
        case .denied:
            .unavailable("O acesso aos Calendários foi negado. Autorize o OkamiUNI em Ajustes do Sistema > Privacidade e Segurança > Calendários.")
        case .restricted, .writeOnly:
            .unavailable("Este Mac não permite que o OkamiUNI leia os Calendários.")
        @unknown default:
            .unavailable("O macOS devolveu um estado de Calendários que o OkamiUNI ainda não reconhece.")
        }
    }

    func requestAccess() async throws -> CalendarAvailability {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            return .unavailable("O acesso aos Calendários não foi concedido. Autorize o OkamiUNI em Ajustes do Sistema > Privacidade e Segurança > Calendários.")
        }
        return availability()
    }

    func calendars() -> [ConnectedCalendar] {
        guard availability().isAvailable else { return [] }
        return store.calendars(for: .event).map(Self.connected(from:))
    }

    func events(referenceDay: Date) throws -> [AgendaItem] {
        guard availability().isAvailable else { return [] }
        let start = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: referenceDay))!
        let end = calendar.date(byAdding: .day, value: 366, to: calendar.startOfDay(for: referenceDay))!
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .compactMap { item(from: $0, referenceDay: referenceDay) }
            .sorted {
                if $0.dayOffset != $1.dayOffset { return $0.dayOffset < $1.dayOffset }
                return $0.startMinute < $1.startMinute
            }
    }

    func save(_ item: AgendaItem, referenceDay: Date) throws {
        let event = existingEvent(id: item.id, referenceDay: referenceDay) ?? EKEvent(eventStore: store)
        event.calendar = event.calendar ?? store.defaultCalendarForNewEvents
        guard event.calendar != nil else {
            throw CalendarAdapterError(.unavailable("Nenhum calendário editável está configurado neste Mac."))
        }
        event.title = item.title
        event.startDate = date(for: item.dayOffset, minute: item.startMinute, referenceDay: referenceDay)
        event.endDate = date(for: item.dayOffset, minute: max(item.endMinute, item.startMinute + 1), referenceDay: referenceDay)
        event.location = item.detail?.place
        event.notes = EventKitEventNotes.text(for: item.detail)
        event.url = markerURL(for: item.id)
        if let rule = RecurrenceRule.parse(item.detail?.recurrence),
           let ekRule = EventKitRecurrence.make(rule)
        {
            event.recurrenceRules = [ekRule]
        } else {
            event.recurrenceRules = []
        }
        let span: EKSpan = event.hasRecurrenceRules ? .futureEvents : .thisEvent
        try store.save(event, span: span, commit: true)
    }

    func remove(id: String, referenceDay: Date) throws {
        guard let event = existingEvent(id: id, referenceDay: referenceDay) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    private func existingEvent(id: String, referenceDay: Date) -> EKEvent? {
        let start = calendar.date(byAdding: .day, value: -366, to: calendar.startOfDay(for: referenceDay))!
        let end = calendar.date(byAdding: .day, value: 731, to: calendar.startOfDay(for: referenceDay))!
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .first { markerID(for: $0) == id }
    }

    private func item(from event: EKEvent, referenceDay: Date) -> AgendaItem? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let startMinute: Int
        let endMinute: Int
        if event.isAllDay {
            startMinute = 0
            endMinute = 1_440
        } else {
            let startParts = calendar.dateComponents([.hour, .minute], from: start)
            let endParts = calendar.dateComponents([.hour, .minute], from: end)
            startMinute = (startParts.hour ?? 0) * 60 + (startParts.minute ?? 0)
            let endDay = calendar.isDate(end, inSameDayAs: start)
            endMinute = endDay
                ? max(startMinute + 1, (endParts.hour ?? 0) * 60 + (endParts.minute ?? 0))
                : 1_440
        }
        let organizer = event.organizer
        let ekCalendar = event.calendar
        let connected = ekCalendar.map(Self.connected(from:))
        let sourceName = connected?.source ?? "Calendário do macOS"
        let detail = EventDetail(
            place: event.location ?? "Sem local definido",
            link: externalLink(from: event.url),
            organizer: EventPerson(
                name: organizer?.name ?? sourceName,
                address: organizer?.url.absoluteString ?? "",
                role: "organizador", status: .yes
            ),
            people: [], note: sourceName,
            recurrence: EventKitRecurrence.storage(from: event) ?? (event.hasRecurrenceRules ? "Recorrente" : "Evento único"),
            notice: "Consulte o Calendário para alertas", agenda: [], thread: [], descricao: event.notes
        )
        return AgendaItem(
            id: EventKitItemID.make(
                marker: markerID(for: event),
                calendarItemIdentifier: event.calendarItemIdentifier,
                start: start
            ),
            title: event.title?.isEmpty == false ? event.title! : "Sem título",
            startMinute: startMinute, endMinute: endMinute,
            accountID: Self.systemAccountID,
            dayOffset: calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: referenceDay), to: calendar.startOfDay(for: start)
            ).day ?? 0,
            calendarUID: event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier,
            detail: detail,
            calendarID: connected?.id,
            calendarTitle: connected?.title,
            calendarColorHex: connected?.colorHex,
            calendarSource: connected?.source,
            isCancelled: event.status == .canceled
        )
    }

    private static func connected(from calendar: EKCalendar) -> ConnectedCalendar {
        ConnectedCalendar(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            source: calendar.source.title,
            colorHex: hex(from: calendar.cgColor),
            allowsModifications: calendar.allowsContentModifications
        )
    }

    private static func hex(from color: CGColor) -> String {
        guard let rgb = color.converted(
            to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil
        ), let c = rgb.components, c.count >= 3 else {
            return "#5B8DEF"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((c[0] * 255).rounded()),
            Int((c[1] * 255).rounded()),
            Int((c[2] * 255).rounded())
        )
    }

    private func date(for offset: Int, minute: Int, referenceDay: Date) -> Date {
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: referenceDay))!
        return calendar.date(byAdding: .minute, value: minute, to: day)!
    }

    private func markerURL(for id: String) -> URL? {
        URL(string: "okamiuni://agenda/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
    }

    private func markerID(for event: EKEvent) -> String? {
        guard event.url?.scheme == "okamiuni", event.url?.host == "agenda" else { return nil }
        return event.url?.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func externalLink(from url: URL?) -> String? {
        guard let url, url.scheme == "https" || url.scheme == "http" else { return nil }
        return url.absoluteString
    }
}

/// O EventKit usa `event.url` para a identidade privada do item criado pelo
/// OkamiUNI. A sala, portanto, acompanha as notas para sobreviver também no
/// Calendar do macOS. Ao voltar, `EventDetail` a promove para cartão e remove
/// esta linha da descrição visível.
/// Identidade de um compromisso do EventKit.
///
/// A ocorrência entra no id. Sem a data, uma reunião semanal colapsava numa
/// linha só — o `calendarItemIdentifier` é o mesmo em todas as sessões — e a
/// grade perdia o dia 31 e o dia 03.
enum EventKitItemID {
    static func make(marker: String?, calendarItemIdentifier: String, start: Date) -> String {
        if let marker, !marker.isEmpty { return marker }
        return "eventkit:\(calendarItemIdentifier):\(Int(start.timeIntervalSince1970))"
    }
}

enum EventKitRecurrence {
    static func make(_ rule: RecurrenceRule) -> EKRecurrenceRule? {
        guard rule.frequency != .none else { return nil }
        let end = ekEnd(rule)
        switch rule.frequency {
        case .none:
            return nil
        case .daily:
            return EKRecurrenceRule(recurrenceWith: .daily, interval: rule.interval, end: end)
        case .weekdays:
            let days = [EKWeekday.monday, .tuesday, .wednesday, .thursday, .friday]
                .map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(
                recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days,
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: end
            )
        case .weekly:
            let days = rule.weekdays.compactMap { EKWeekday(rawValue: $0) }
                .map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(
                recurrenceWith: .weekly, interval: rule.interval,
                daysOfTheWeek: days.isEmpty ? nil : days,
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: end
            )
        case .monthly:
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: rule.interval, end: end)
        case .yearly:
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: rule.interval, end: end)
        }
    }

    static func storage(from event: EKEvent) -> String? {
        guard let rule = event.recurrenceRules?.first else { return nil }
        let frequency: RecurrenceRule.Frequency
        var weekdays: [Int] = []
        switch rule.frequency {
        case .daily:
            frequency = .daily
        case .weekly:
            let days = (rule.daysOfTheWeek ?? []).map(\.dayOfTheWeek.rawValue).sorted()
            if days == [2, 3, 4, 5, 6] {
                frequency = .weekdays
            } else {
                frequency = .weekly
                weekdays = days
            }
        case .monthly:
            frequency = .monthly
        case .yearly:
            frequency = .yearly
        default:
            return "Recorrente"
        }
        var until: CivilDay?
        var count: Int?
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                count = end.occurrenceCount
            } else if let date = end.endDate {
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
                until = CivilDay(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
            }
        }
        return RecurrenceRule(
            frequency: frequency, interval: max(1, rule.interval),
            weekdays: weekdays, count: count, untilDay: until
        ).storage
    }

    private static func ekEnd(_ rule: RecurrenceRule) -> EKRecurrenceEnd? {
        if let count = rule.count {
            return EKRecurrenceEnd(occurrenceCount: count)
        }
        if let until = rule.untilDay {
            var parts = DateComponents()
            parts.year = until.year
            parts.month = until.month
            parts.day = until.day
            parts.hour = 23
            parts.minute = 59
            if let date = Calendar.current.date(from: parts) {
                return EKRecurrenceEnd(end: date)
            }
        }
        return nil
    }
}

enum EventKitEventNotes {
    static func text(for detail: EventDetail?) -> String? {
        guard let detail else { return nil }
        let description = detail.descricao?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingLink = detail.meetingLink

        var parts: [String] = []
        if let description, !description.isEmpty { parts.append(description) }
        if let meetingLink,
           description?.contains(meetingLink) != true {
            parts.append("Link da reunião: \(meetingLink)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
