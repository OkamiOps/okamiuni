import Foundation
import Testing
@testable import UNICore

@MainActor
private final class CalendarSyncDouble: CalendarSyncing {
    var state: CalendarAvailability = .available
    var synchronized: [AgendaItem] = []
    var failure: Error?

    func availability() async -> CalendarAvailability { state }

    func synchronize(referenceDay _: Date, requestAuthorization _: Bool) async throws -> [AgendaItem] {
        if let failure { throw failure }
        return synchronized
    }

    func save(_: AgendaItem, referenceDay _: Date) async throws {}
    func remove(id _: String, referenceDay _: Date) async throws {}
}

@Suite("Agenda conectada no MailStore")
@MainActor
struct CalendarSyncTests {
    @Test("O retrato do calendário conectado soma à agenda existente")
    func mergeConnectedCalendar() async {
        let remote = AgendaItem(
            id: "system-1", title: "Reunião real", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar"
        )
        let sync = CalendarSyncDouble()
        sync.synchronized = [remote]
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []), calendarSync: sync
        )

        await store.load()

        #expect(store.calendarAvailability == .available)
        #expect(store.agenda == [remote])
    }

    @Test("Falha da agenda conectada é estado visível, não uma agenda silenciosamente vazia")
    func failureIsVisible() async {
        let sync = CalendarSyncDouble()
        sync.failure = NSError(domain: "calendar", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "O servidor de agenda não respondeu."
        ])
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []), calendarSync: sync
        )

        await store.refreshCalendar()

        #expect(store.calendarAvailability == .unavailable("O servidor de agenda não respondeu."))
    }
}
