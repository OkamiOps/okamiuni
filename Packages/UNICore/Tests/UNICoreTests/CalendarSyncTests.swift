import Foundation
import Testing
@testable import UNICore

@MainActor
private final class CalendarSyncDouble: CalendarSyncing {
    var state: CalendarAvailability = .available
    var synchronized: [AgendaItem] = []
    var listed: [ConnectedCalendar] = []
    var failure: Error?

    func availability() async -> CalendarAvailability { state }
    func calendars() async -> [ConnectedCalendar] { listed }

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

    @Test("A grade da Agenda não some os compromissos do macOS ao filtrar uma caixa de email")
    func calendarAgendaIgnoresMailAccountFilter() async {
        let remote = AgendaItem(
            id: "ek-todoist", title: "Reunião Todoist", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar",
            calendarID: "todoist-1", calendarTitle: "Todoist", calendarSource: "Todoist"
        )
        let sync = CalendarSyncDouble()
        sync.synchronized = [remote]
        let store = MailStore(
            source: InMemoryMailSource.fixtures, calendarSync: sync
        )
        await store.load()
        let conta = try! #require(store.accounts.first?.id)
        store.select(account: conta)

        #expect(store.visibleAgenda.contains { $0.id == "ek-todoist" } == false)
        #expect(store.calendarAgenda.contains { $0.id == "ek-todoist" })
    }

    @Test("Desligar um calendário na lateral tira só os compromissos dele")
    func hidingACalendarFiltersTheGrid() async {
        let remote = AgendaItem(
            id: "ek-1", title: "Call", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar",
            calendarID: "todoist-1", calendarTitle: "Todoist", calendarSource: "Todoist"
        )
        let sync = CalendarSyncDouble()
        sync.synchronized = [remote]
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []), calendarSync: sync
        )
        await store.load()
        #expect(store.calendarAgenda.contains { $0.id == "ek-1" })
        store.toggleCalendar("todoist-1")
        #expect(store.calendarAgenda.contains { $0.id == "ek-1" } == false)
        store.toggleCalendar("todoist-1")
        #expect(store.calendarAgenda.contains { $0.id == "ek-1" })
    }

    @Test("Recolher uma origem na lateral não desliga os calendários dela")
    func collapsingASourceKeepsCalendarsEnabled() async {
        let remote = AgendaItem(
            id: "ek-1", title: "Call", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar",
            calendarID: "todoist-1", calendarTitle: "Todoist", calendarSource: "Todoist"
        )
        let sync = CalendarSyncDouble()
        sync.synchronized = [remote]
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []), calendarSync: sync
        )
        await store.load()
        #expect(store.calendarSourceExpanded("Todoist"))
        store.toggleCalendarSource("Todoist")
        #expect(store.calendarSourceExpanded("Todoist") == false)
        #expect(store.calendarAgenda.contains { $0.id == "ek-1" })
        store.toggleCalendarSource("Todoist")
        #expect(store.calendarSourceExpanded("Todoist"))
    }

    @Test("Caixas IMAP ganham calendário OkamiUNI; Gmail e iCloud não")
    func imapAccountsAppearAsMailboxCalendars() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let ids = Set(store.calendarsForSidebar.map(\.id))
        #expect(ids.contains(ConnectedCalendar.mailboxID(forAccountID: "zoho")))
        #expect(ids.contains(ConnectedCalendar.mailboxID(forAccountID: "host")))
        #expect(!ids.contains(ConnectedCalendar.mailboxID(forAccountID: "gmail")))
        #expect(!ids.contains(ConnectedCalendar.mailboxID(forAccountID: "icloud")))
        #expect(store.calendarsForSidebar.contains { $0.source == "OkamiUNI" && $0.title == "ricardo@empresa.com" })
    }

    @Test("Desligar o calendário OkamiUNI da caixa tira só os compromissos dela")
    func hidingMailboxCalendarFiltersImapEvents() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let zohoID = ConnectedCalendar.mailboxID(forAccountID: "zoho")
        #expect(store.calendarAgenda.contains { $0.accountID == "zoho" })
        store.toggleCalendar(zohoID)
        #expect(store.calendarAgenda.contains { $0.accountID == "zoho" } == false)
        #expect(store.calendarAgenda.contains { $0.accountID == "host" })
        store.toggleCalendar(zohoID)
        #expect(store.calendarAgenda.contains { $0.accountID == "zoho" })
    }

    @Test("Ocultar tira da lista visível, da trilha e da grade")
    func concealingHidesFromListAndGrid() async {
        let remote = AgendaItem(
            id: "ek-family", title: "Aniversário", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar",
            calendarID: "family-1", calendarTitle: "Family", calendarSource: "Google"
        )
        let family = ConnectedCalendar(
            id: "family-1", title: "Family", source: "Google",
            colorHex: "#9C27B0", allowsModifications: false
        )
        let sync = CalendarSyncDouble()
        sync.synchronized = [remote]
        sync.listed = [family]
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []), calendarSync: sync
        )
        await store.load()

        #expect(store.visibleCalendarsForSidebar.contains { $0.id == "family-1" })
        #expect(store.calendarAgenda.contains { $0.id == "ek-family" })
        store.concealCalendar("family-1")
        #expect(store.isCalendarConcealed("family-1"))
        #expect(store.visibleCalendarsForSidebar.contains { $0.id == "family-1" } == false)
        #expect(store.concealedCalendarsForSidebar.contains { $0.id == "family-1" })
        #expect(store.calendarAgenda.contains { $0.id == "ek-family" } == false)
        store.revealCalendar("family-1")
        #expect(!store.isCalendarConcealed("family-1"))
        #expect(store.visibleCalendarsForSidebar.contains { $0.id == "family-1" })
        #expect(store.calendarAgenda.contains { $0.id == "ek-family" })
    }

    @Test("Compromisso vindo do Gmail pinta a cor de Do email, não o acento")
    func emailEventUsesEmailCalendarColor() async {
        let gmail = Account(
            id: "gmail", address: "msant262@gmail.com", displayName: "Marcos",
            provider: .gmail, host: "gmail",
            tintLightHex: "#2C7D5E", tintDarkHex: "#7CBAAA"
        )
        let item = AgendaItem(
            id: "email-vet", title: "Termin de Odette",
            startMinute: 570, endMinute: 600, accountID: gmail.id, dayOffset: 3
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [gmail], messages: [], agenda: [item])
        )
        await store.load()
        #expect(store.calendarFilterID(for: item) == ConnectedCalendar.email.id)
        #expect(store.calendarSwatchHex(for: item) == ConnectedCalendar.email.colorHex)
        #expect(store.calendarSwatchHex(for: item) != gmail.tintLightHex)
    }

    @Test("Compromisso do EventKit pinta a cor da própria agenda")
    func eventKitEventKeepsCalendarColor() async throws {
        let remote = AgendaItem(
            id: "ek-1", title: "Reunião", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar",
            calendarID: "todoist-1", calendarTitle: "Todoist",
            calendarColorHex: "#E44332", calendarSource: "Todoist"
        )
        let sync = CalendarSyncDouble()
        sync.synchronized = [remote]
        sync.listed = [
            ConnectedCalendar(
                id: "todoist-1", title: "Todoist", source: "Todoist",
                colorHex: "#E44332", allowsModifications: false
            )
        ]
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []), calendarSync: sync
        )
        await store.load()
        let item = try #require(store.agenda.first { $0.id == "ek-1" })
        #expect(store.calendarSwatchHex(for: item) == "#E44332")
    }
}
