import Foundation
import UNICore
import UNISync

/// Uma **fonte** de agendas na aba Agendas: o Calendário do Mac, uma caixa que
/// sincroniza por CalDAV, ou o próprio app.
///
/// O desenho agrupa por quem entrega o calendário, e não por conta de e-mail:
/// o Calendário do Mac entrega iCloud, Google e Feriados de uma vez só, e
/// quebrar esse bloco em três cartões diria que são três ligações diferentes
/// quando é uma só — a permissão do macOS.
struct AgendaSource: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Tudo o que vem do EventKit.
        case eventKit
        /// Uma caixa com servidor de agenda (Zoho, Yahoo, Fastmail).
        case calDAV(accountID: String)
        /// O que fica só neste Mac: o calendário "Do email" e os calendários
        /// de caixa sem servidor de agenda.
        case local
    }

    enum Tone: Hashable { case green, orange, quiet }

    let id: String
    let kind: Kind
    let monogram: String
    let title: String
    let subtitle: String
    let state: String
    let tone: Tone
    let calendars: [ConnectedCalendar]
}

enum AgendaSources {
    /// Separa os calendários conectados nas fontes que a aba desenha.
    ///
    /// A classificação é por **identidade do id**, nunca por nome: o prefixo
    /// `caldav.` diz a conta, o prefixo `okamiuni.mailbox.` e o id do
    /// calendário "Do email" dizem que é local, e o que sobra veio do EventKit
    /// (os ids de lá são os `calendarIdentifier` do macOS).
    static func build(
        calendars: [ConnectedCalendar],
        accounts: [AccountStatus],
        availability: CalendarAvailability?,
        now: Date,
        calendar: Calendar = .current
    ) -> [AgendaSource] {
        var eventKit: [ConnectedCalendar] = []
        var local: [ConnectedCalendar] = []
        var calDAV: [String: [ConnectedCalendar]] = [:]
        var calDAVOrder: [String] = []

        for connected in calendars {
            if let accountID = ConnectedCalendar.calDAVAccountID(from: connected.id) {
                if calDAV[accountID] == nil { calDAVOrder.append(accountID) }
                calDAV[accountID, default: []].append(connected)
            } else if connected.id == ConnectedCalendar.email.id
                || connected.id.hasPrefix(ConnectedCalendar.mailboxPrefix)
            {
                local.append(connected)
            } else {
                eventKit.append(connected)
            }
        }

        var sources: [AgendaSource] = []

        // O Mac entra mesmo sem calendário nenhum **quando o macOS negou**:
        // é o aviso que ocupa esse lugar na coluna, e sumir com ele deixaria a
        // pessoa sem saber por que as agendas do Mac não estão ali.
        let macState = macState(availability)
        if !eventKit.isEmpty || macState != nil {
            sources.append(AgendaSource(
                id: "eventkit",
                kind: .eventKit,
                monogram: "M",
                title: L10n.tr("Calendário do Mac"),
                subtitle: eventKit.count == 1
                    ? L10n.tr("EventKit · 1 agenda neste Mac")
                    : L10n.tr("EventKit · \(eventKit.count) agendas neste Mac"),
                state: macState ?? L10n.tr("Autorizado"),
                tone: macState == nil ? .green : .orange,
                calendars: eventKit
            ))
        }

        for accountID in calDAVOrder {
            let list = calDAV[accountID] ?? []
            let status = accounts.first { $0.accountID == accountID }
            let address = status?.address ?? accountID
            sources.append(AgendaSource(
                id: "caldav.\(accountID)",
                kind: .calDAV(accountID: accountID),
                monogram: String(address.prefix(1)).uppercased(),
                title: address,
                subtitle: list.count == 1
                    ? L10n.tr("CalDAV · senha de app · 1 agenda")
                    : L10n.tr("CalDAV · senha de app · \(list.count) agendas"),
                state: calDAVState(status, now: now, calendar: calendar),
                tone: status.map { AccountsCopy.isFailing($0) ? .orange : .green } ?? .quiet,
                calendars: list
            ))
        }

        if !local.isEmpty {
            sources.append(AgendaSource(
                id: "local",
                kind: .local,
                monogram: "O",
                title: L10n.tr("Neste app"),
                subtitle: L10n.tr("contas sem servidor de agenda · fica só neste Mac"),
                state: L10n.tr("Só neste Mac"),
                tone: .quiet,
                calendars: local
            ))
        }

        return sources
    }

    /// "oito, em quatro fontes" — a nota ao lado do título da coluna.
    static func countNote(_ sources: [AgendaSource]) -> String {
        let calendars = sources.reduce(0) { $0 + $1.calendars.count }
        let withCalendars = sources.filter { !$0.calendars.isEmpty }.count
        if calendars == 0 { return L10n.tr("nenhuma agenda conectada ainda") }
        let left = calendars == 1 ? L10n.tr("uma agenda") : L10n.tr("\(calendars) agendas")
        let right = withCalendars == 1 ? L10n.tr("em uma fonte") : L10n.tr("em \(withCalendars) fontes")
        return "\(left), \(right)"
    }

    /// `nil` quando o macOS autorizou. Senão, a frase curta do estado.
    private static func macState(_ availability: CalendarAvailability?) -> String? {
        switch availability {
        case .available, .none: nil
        case .loading: L10n.tr("Lendo…")
        case .authorizationRequired: L10n.tr("Sem permissão")
        case .unavailable: L10n.tr("Indisponível")
        }
    }

    /// `true` quando o bloco de aviso substitui a lista do Mac.
    static func needsCalendarPermission(_ availability: CalendarAvailability?) -> Bool {
        switch availability {
        case .authorizationRequired, .unavailable: true
        default: false
        }
    }

    private static func calDAVState(
        _ status: AccountStatus?, now: Date, calendar: Calendar
    ) -> String {
        guard let status else { return L10n.tr("Conectada") }
        if AccountsCopy.isFailing(status) { return L10n.tr("Pedindo senha") }
        guard let when = status.lastSyncedAt else { return L10n.tr("Ainda não sincronizada") }
        return L10n.tr("Sincronizada \(AccountsCopy.horario(when, calendar: calendar))")
    }
}
