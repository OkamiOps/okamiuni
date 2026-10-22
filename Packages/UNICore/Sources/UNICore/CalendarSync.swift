import Foundation

/// Um calendário visível na lateral da Agenda: os do macOS (iCloud, Gmail,
/// Todoist), os CalDAV das caixas IMAP, as agendas do Google lidas com o
/// token da conta, e um calendário OkamiUNI por conta que o sistema não cobre.
public struct ConnectedCalendar: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let source: String
    public let colorHex: String
    public let allowsModifications: Bool

    /// Compromissos criados a partir de um email, sem calendário do sistema.
    public static var email: ConnectedCalendar {
        ConnectedCalendar(
        id: "okamiuni.email",
        title: L10n.tr("Do email"),
        source: "OkamiUNI",
        colorHex: "#3E6FA8",
        allowsModifications: true
        )
    }

    /// Prefixo dos calendários virtuais de uma caixa IMAP (Zoho, Hostinger,
    /// Yahoo…): o EventKit não os vê, então a lateral da Agenda precisa de um
    /// lugar para o que aquela caixa cria ou importa.
    public static let mailboxPrefix = "okamiuni.mailbox."

    /// Prefixo dos calendários CalDAV sincronizados por conta.
    public static let calDAVPrefix = "caldav."

    /// Prefixo da agenda do Google lida com o token da conta. O id da conta
    /// é um e-mail e tem ponto; os dois lados vão percent-encoded para o
    /// primeiro ponto cru continuar sendo o separador.
    public static let googlePrefix = "gcal."

    public static func mailboxID(forAccountID accountID: String) -> String {
        mailboxPrefix + accountID
    }

    public static func mailbox(for account: Account) -> ConnectedCalendar {
        ConnectedCalendar(
            id: mailboxID(forAccountID: account.id),
            title: account.address,
            source: "OkamiUNI",
            colorHex: account.tintLightHex,
            allowsModifications: true
        )
    }

    public static func calDAVID(accountID: String, calendarURL: String) -> String {
        calDAVPrefix + accountID + "." + calendarURL
    }

    public static func calDAVAccountID(from calendarID: String) -> String? {
        guard calendarID.hasPrefix(calDAVPrefix) else { return nil }
        let rest = calendarID.dropFirst(calDAVPrefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        return String(rest[..<dot])
    }

    public static func googleID(accountID: String, calendarID: String) -> String {
        googlePrefix + encodeGooglePart(accountID) + "." + encodeGooglePart(calendarID)
    }

    public static func googleAccountID(from calendarID: String) -> String? {
        googleParts(from: calendarID)?.accountID
    }

    public static func googleRemoteID(from calendarID: String) -> String? {
        googleParts(from: calendarID)?.remoteID
    }

    public static func googleParts(from calendarID: String) -> (accountID: String, remoteID: String)? {
        guard calendarID.hasPrefix(googlePrefix) else { return nil }
        let rest = calendarID.dropFirst(googlePrefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        guard let accountID = String(rest[..<dot]).removingPercentEncoding,
              let remoteID = String(rest[rest.index(after: dot)...]).removingPercentEncoding,
              !accountID.isEmpty, !remoteID.isEmpty
        else { return nil }
        return (accountID, remoteID)
    }

    private static func encodeGooglePart(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// Gmail fica de fora deste calendário local: a agenda entra pela API do
    /// Google, com o token da conta, ou pelo EventKit quando o macOS já tem
    /// essa conta. iCloud também fica no EventKit. Qualquer outra caixa ganha
    /// o calendário local; se ela tiver CalDAV, a lateral usa o servidor.
    public static func needsMailboxCalendar(_ account: Account?) -> Bool {
        guard let account else { return false }
        if account.provider == .gmail { return false }
        if account.host == "icloud" { return false }
        return true
    }

    public init(
        id: String, title: String, source: String, colorHex: String,
        allowsModifications: Bool
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.colorHex = colorHex
        self.allowsModifications = allowsModifications
    }
}

/// O estado da agenda que a interface consegue explicar sem conhecer EventKit
/// nem detalhes de rede. `MailStore` o publica para todas as superfícies que
/// desenham compromissos.
public enum CalendarAvailability: Sendable, Hashable {
    case loading
    case available
    case authorizationRequired
    case unavailable(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// A fronteira entre a agenda da interface e um calendário de verdade.
///
/// O modelo continua sendo `AgendaItem`: a grade não sabe (nem precisa saber)
/// se um compromisso veio do Calendário do macOS ou de um servidor CalDAV. A
/// referência de dia é explícita porque a UI usa `dayOffset`, enquanto os
/// adaptadores trabalham com datas reais.
public protocol CalendarSyncing: AnyObject, Sendable {
    func availability() async -> CalendarAvailability
    func calendars() async -> [ConnectedCalendar]
    func synchronize(referenceDay: Date, requestAuthorization: Bool) async throws -> [AgendaItem]
    func save(_ item: AgendaItem, referenceDay: Date) async throws
    func remove(id: String, referenceDay: Date) async throws
}
