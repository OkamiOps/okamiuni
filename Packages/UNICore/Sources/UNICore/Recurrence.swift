import Foundation

/// Como um compromisso se repete. A tela escolhe em português; o EventKit e o
/// CalDAV recebem a forma RFC 5545. O que vai para o disco é `storage`, para
/// a agenda antiga ("Não se repete", "Evento único") continuar legível.
public struct RecurrenceRule: Sendable, Hashable, Codable {
    public enum Frequency: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        case none
        case daily
        case weekdays
        case weekly
        case monthly
        case yearly

        public var id: String { rawValue }

        public var shortLabel: String {
            switch self {
            case .none: "Não"
            case .daily: "Diário"
            case .weekdays: "Úteis"
            case .weekly: "Semanal"
            case .monthly: "Mensal"
            case .yearly: "Anual"
            }
        }
    }

    public var frequency: Frequency
    /// A cada N unidades da frequência. Sempre ≥ 1.
    public var interval: Int
    /// `Calendar.weekday`: 1 = domingo … 7 = sábado. Só a semanal usa.
    public var weekdays: [Int]
    public var count: Int?
    public var untilDay: CivilDay?

    public static let none = RecurrenceRule(frequency: .none)

    public init(
        frequency: Frequency,
        interval: Int = 1,
        weekdays: [Int] = [],
        count: Int? = nil,
        untilDay: CivilDay? = nil
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays.sorted()
        self.count = count.flatMap { $0 > 0 ? $0 : nil }
        self.untilDay = untilDay
    }

    public var repeats: Bool { frequency != .none }

    public var label: String {
        guard frequency != .none else { return "Não se repete" }
        var parts: [String] = [frequencyLabel]
        if let count {
            parts.append(count == 1 ? "1 vez" : "\(count) vezes")
        } else if let untilDay {
            parts.append("até \(untilDay.iso)")
        }
        return parts.joined(separator: " · ")
    }

    private var frequencyLabel: String {
        switch frequency {
        case .none:
            "Não se repete"
        case .daily:
            interval == 1 ? "Todos os dias" : "A cada \(interval) dias"
        case .weekdays:
            "Somente dias úteis"
        case .weekly:
            weeklyLabel
        case .monthly:
            interval == 1 ? "Todo mês" : "A cada \(interval) meses"
        case .yearly:
            interval == 1 ? "Todo ano" : "A cada \(interval) anos"
        }
    }

    private var weeklyLabel: String {
        let days = weekdayNames
        let prefix = interval == 1 ? "Toda semana" : "A cada \(interval) semanas"
        guard !days.isEmpty else { return prefix }
        return "\(prefix), \(days.joined(separator: ", "))"
    }

    private var weekdayNames: [String] {
        let names = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
        return weekdays.compactMap { weekday in
            guard (1...7).contains(weekday) else { return nil }
            return names[weekday - 1]
        }
    }

    /// Forma compacta para `EventDetail.recurrence`. Quem não reconhece o
    /// prefixo mostra o texto cru — os compromissos antigos continuam iguais.
    public var storage: String {
        guard frequency != .none else { return "none" }
        var body = "\(frequency.rawValue):\(interval)"
        if frequency == .weekly, !weekdays.isEmpty {
            body += ":" + weekdays.map(String.init).joined(separator: ",")
        }
        if let count { body += ";count=\(count)" }
        if let untilDay { body += ";until=\(untilDay.iso)" }
        return "rrule:" + body
    }

    public static func parse(_ text: String?) -> RecurrenceRule? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return RecurrenceRule.none }
        if trimmed == "none" || trimmed == "Não se repete" {
            return RecurrenceRule.none
        }
        guard trimmed.hasPrefix("rrule:") else { return nil }
        let raw = String(trimmed.dropFirst("rrule:".count))
        let pieces = raw.split(separator: ";", omittingEmptySubsequences: true)
        guard let head = pieces.first else { return nil }
        var count: Int?
        var until: CivilDay?
        for piece in pieces.dropFirst() {
            if piece.hasPrefix("count="), let value = Int(piece.dropFirst("count=".count)) {
                count = value
            } else if piece.hasPrefix("until=") {
                until = CivilDay(iso: String(piece.dropFirst("until=".count)))
            }
        }
        let headParts = head.split(separator: ":", omittingEmptySubsequences: false)
        guard let freqRaw = headParts.first,
              let frequency = Frequency(rawValue: String(freqRaw))
        else { return nil }
        let interval = headParts.count > 1 ? Int(headParts[1]) ?? 1 : 1
        var weekdays: [Int] = []
        if frequency == .weekly, headParts.count > 2 {
            weekdays = headParts[2].split(separator: ",").compactMap { Int($0) }
        }
        return RecurrenceRule(
            frequency: frequency, interval: interval, weekdays: weekdays,
            count: count, untilDay: until
        )
    }

    /// O rótulo que a janela mostra: regra nova vira português, texto antigo
    /// (EventKit "Recorrente", fixtures) permanece.
    public static func display(_ stored: String) -> String {
        parse(stored)?.label ?? stored
    }

    /// `RRULE` do iCalendar, sem a chave. Nulo quando não se repete.
    public var rfc5545: String? {
        guard frequency != .none else { return nil }
        var parts: [String] = []
        switch frequency {
        case .none:
            return nil
        case .daily:
            parts.append("FREQ=DAILY")
            if interval > 1 { parts.append("INTERVAL=\(interval)") }
        case .weekdays:
            parts.append("FREQ=WEEKLY")
            parts.append("BYDAY=MO,TU,WE,TH,FR")
        case .weekly:
            parts.append("FREQ=WEEKLY")
            if interval > 1 { parts.append("INTERVAL=\(interval)") }
            let byDay = rfcWeekdays
            if !byDay.isEmpty { parts.append("BYDAY=\(byDay.joined(separator: ","))") }
        case .monthly:
            parts.append("FREQ=MONTHLY")
            if interval > 1 { parts.append("INTERVAL=\(interval)") }
        case .yearly:
            parts.append("FREQ=YEARLY")
            if interval > 1 { parts.append("INTERVAL=\(interval)") }
        }
        if let count { parts.append("COUNT=\(count)") }
        if let untilDay {
            parts.append("UNTIL=\(String(format: "%04d%02d%02d", untilDay.year, untilDay.month, untilDay.day))T235959Z")
        }
        return parts.joined(separator: ";")
    }

    private var rfcWeekdays: [String] {
        let map = [1: "SU", 2: "MO", 3: "TU", 4: "WE", 5: "TH", 6: "FR", 7: "SA"]
        return weekdays.compactMap { map[$0] }
    }

    public func withWeekdayOf(_ date: Date, calendar: Calendar = .current) -> RecurrenceRule {
        guard frequency == .weekly, weekdays.isEmpty else { return self }
        return RecurrenceRule(
            frequency: frequency, interval: interval,
            weekdays: [calendar.component(.weekday, from: date)],
            count: count, untilDay: untilDay
        )
    }
}

/// Pedido para criar uma sala nova — uma por compromisso, nunca uma sala
/// permanente reaproveitada.
/// O que a fábrica devolve ao criar a sala: o link e, no Meet, o id do
/// evento no Google Calendar — é com ele que o cancelamento apaga a sala.
public struct MeetingMint: Sendable, Hashable {
    public let link: String
    public let googleEventID: String?

    public init(link: String, googleEventID: String? = nil) {
        self.link = link
        self.googleEventID = googleEventID
    }
}

public struct MeetingRoomRequest: Sendable, Hashable {
    public let service: MeetingService
    public let account: Account
    /// A caixa cujo OAuth cria a sala. Meet usa uma conta Google mesmo quando
    /// o compromisso cai noutra caixa.
    public let oauthAccountID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [Contact]
    public let rrule: String?

    public init(
        service: MeetingService, account: Account, title: String, start: Date, end: Date,
        oauthAccountID: String? = nil,
        attendees: [Contact] = [],
        rrule: String? = nil
    ) {
        self.service = service
        self.account = account
        self.oauthAccountID = oauthAccountID ?? account.id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.rrule = rrule
    }

    public var durationMinutes: Int {
        max(1, Int(end.timeIntervalSince(start) / 60))
    }
}

public enum MeetingRoomError: Error, Sendable, Hashable, LocalizedError {
    case notConnected(MeetingService)
    case needsGoogle
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let service):
            "Conecte o \(service.label) em Ajustes → Agenda, ou cole um link existente."
        case .needsGoogle:
            "O Google Meet precisa autorizar esta sessão. Use Reconectar o Google, ou cole um link existente."
        case .failed(let detalhe):
            detalhe
        }
    }
}
