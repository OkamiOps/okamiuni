import Foundation

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
    func synchronize(referenceDay: Date, requestAuthorization: Bool) async throws -> [AgendaItem]
    func save(_ item: AgendaItem, referenceDay: Date) async throws
    func remove(id: String, referenceDay: Date) async throws
}
