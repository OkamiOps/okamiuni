import Foundation
import Testing
@testable import UNICore

@MainActor
private final class CalendarSyncDouble: CalendarSyncing {
    var state: CalendarAvailability = .available
    var synchronized: [AgendaItem] = []
    var listed: [ConnectedCalendar] = []
    var failure: Error?
    var removalFailure: Error?
    var removedIDs: [String] = []
    var savedIDs: [String] = []
    var pauseRemovals = false
    var completedRemovals = 0
    private var pendingRemovals: [CheckedContinuation<Void, any Error>] = []

    var pendingRemovalCount: Int { pendingRemovals.count }

    func availability() async -> CalendarAvailability { state }
    func calendars() async -> [ConnectedCalendar] { listed }

    func synchronize(referenceDay _: Date, requestAuthorization _: Bool) async throws -> [AgendaItem] {
        if let failure { throw failure }
        return synchronized
    }

    func save(_ item: AgendaItem, referenceDay _: Date) async throws { savedIDs.append(item.id) }

    func remove(id: String, referenceDay _: Date) async throws {
        removedIDs.append(id)
        defer { completedRemovals += 1 }
        if pauseRemovals {
            try await withCheckedThrowingContinuation { pendingRemovals.append($0) }
        }
        if let removalFailure { throw removalFailure }
    }

    func completeRemoval(throwing error: Error? = nil) {
        guard !pendingRemovals.isEmpty else {
            Issue.record("Não há remoção de calendário aguardando resposta.")
            return
        }
        let pending = pendingRemovals.removeFirst()
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}

@Suite("Agenda conectada no MailStore")
@MainActor
struct CalendarSyncTests {
    @Test("Remover uma ocorrência cancelada não deixa os retratos trazê-la de volta nem esconde a próxima semana")
    func removedCancelledOccurrenceStaysAbsentAcrossSnapshots() async {
        let removed = occurrence(dayOffset: 0)
        let nextWeek = occurrence(dayOffset: 7)
        let active = occurrence(dayOffset: 1, isCancelled: false)
        let sync = CalendarSyncDouble()
        sync.synchronized = [removed, nextWeek, active]
        let source = InMemoryMailSource(accounts: [], messages: [], agenda: [removed])
        let store = MailStore(source: source, calendarSync: sync)
        await store.load()

        store.removeFromAgenda(removed.id)
        await store.refreshCalendar()
        store.apply(.init(accounts: [], messages: [], agenda: [removed], pendingItems: []))
        await waitUntil { sync.completedRemovals == 1 }

        #expect(sync.removedIDs == [removed.id])
        #expect(Set(store.agenda.map(\.id)) == [nextWeek.id, active.id])
        #expect(!store.calendarAgenda.contains { $0.id == removed.id })
    }

    @Test("A exclusão explícita de ocorrência cancelada sobrevive a uma nova instância do MailStore")
    func removedCancelledOccurrenceSurvivesRestart() async throws {
        let suite = "okamiuni.removed-calendar-occurrence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let removed = occurrence(dayOffset: 0)
        let nextWeek = occurrence(dayOffset: 7)
        let sync = CalendarSyncDouble()
        sync.synchronized = [removed, nextWeek]
        let source = InMemoryMailSource(accounts: [], messages: [], agenda: [removed])
        let first = MailStore(source: source, calendarSync: sync, calendarDefaults: defaults)
        await first.load()

        first.removeFromAgenda(removed.id)
        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        let second = MailStore(source: source, calendarSync: sync, calendarDefaults: reopenedDefaults)
        await second.load()
        await waitUntil { sync.completedRemovals == 1 }

        #expect(Set(second.agenda.map(\.id)) == [nextWeek.id])
        #expect(sync.removedIDs == [removed.id])
    }

    @Test("Desfazer limpa a exclusão da ocorrência e a mantém visível após atualizar e reabrir")
    func restoringCancelledOccurrenceClearsDurableExclusion() async throws {
        let suite = "okamiuni.restored-calendar-occurrence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = occurrence(dayOffset: 0)
        let sync = CalendarSyncDouble()
        sync.synchronized = [item]
        let source = InMemoryMailSource(accounts: [], messages: [], agenda: [])
        let first = MailStore(source: source, calendarSync: sync, calendarDefaults: defaults)
        await first.load()
        first.removeFromAgenda(item.id)
        await waitUntil { sync.completedRemovals == 1 }

        first.restoreToAgenda(item.id)
        await first.refreshCalendar()
        let second = MailStore(source: source, calendarSync: sync, calendarDefaults: defaults)
        await second.load()

        #expect(first.agenda.contains { $0.id == item.id })
        #expect(second.agenda.contains { $0.id == item.id })
    }

    @Test("Falha real da remoção devolve a ocorrência, limpa a exclusão persistida e não salva nem envia outro convite")
    func failedRemovalRestoresCancelledOccurrenceWithoutSaving() async throws {
        let suite = "okamiuni.failed-calendar-removal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = occurrence(dayOffset: 0)
        let sync = CalendarSyncDouble()
        sync.synchronized = [item]
        sync.removalFailure = removalError
        let source = InMemoryMailSource(accounts: [], messages: [], agenda: [])
        let store = MailStore(source: source, calendarSync: sync, calendarDefaults: defaults)
        await store.load()

        store.removeFromAgenda(item.id)
        await waitUntil { store.calendarAvailability == .unavailable("A remoção foi recusada.") }

        #expect(store.agenda == [item])
        #expect(sync.savedIDs.isEmpty)
        #expect(store.calendarAvailability == .unavailable("A remoção foi recusada."))
        let reopened = MailStore(source: source, calendarSync: sync, calendarDefaults: defaults)
        await reopened.load()
        #expect(reopened.agenda == [item])
    }

    @Test("A exclusão durável é limitada a cancelados importados do EventKit")
    func activeAndManualRemovalsDoNotCreateExclusions() async throws {
        let suite = "okamiuni.calendar-removal-scope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let active = occurrence(dayOffset: 0, isCancelled: false)
        let manual = AgendaItem(
            id: "manual-cancelled", title: "Cancelado manual", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar", isCancelled: true
        )
        let sync = CalendarSyncDouble()
        sync.synchronized = [active, manual]
        let source = InMemoryMailSource(accounts: [], messages: [], agenda: [])
        let store = MailStore(source: source, calendarSync: sync, calendarDefaults: defaults)
        await store.load()

        store.removeFromAgenda(active.id)
        store.removeFromAgenda(manual.id)
        await waitUntil { sync.completedRemovals == 2 }
        let reopened = MailStore(source: source, calendarSync: sync, calendarDefaults: defaults)
        await reopened.load()

        #expect(Set(reopened.agenda.map(\.id)) == [active.id, manual.id])
    }

    @Test("Uma falha antiga não desfaz uma restauração mais recente")
    func staleRemovalFailureDoesNotOverrideRestore() async {
        let item = occurrence(dayOffset: 0)
        let sync = CalendarSyncDouble()
        sync.synchronized = [item]
        sync.pauseRemovals = true
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []), calendarSync: sync
        )
        await store.load()
        store.removeFromAgenda(item.id)
        await waitUntil { sync.pendingRemovalCount == 1 }
        store.restoreToAgenda(item.id)
        await waitUntil { !sync.savedIDs.isEmpty && store.calendarAvailability == .available }

        sync.completeRemoval(throwing: removalError)
        await waitUntil { sync.completedRemovals == 1 }

        #expect(store.agenda.contains { $0.id == item.id })
        #expect(store.calendarAvailability == .available)
    }

    @Test("Uma falha antiga não desfaz uma segunda remoção da mesma ocorrência")
    func staleRemovalFailureDoesNotOverrideNewRemoval() async {
        let item = occurrence(dayOffset: 0)
        let sync = CalendarSyncDouble()
        sync.synchronized = [item]
        sync.pauseRemovals = true
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []), calendarSync: sync
        )
        await store.load()
        store.removeFromAgenda(item.id)
        await waitUntil { sync.pendingRemovalCount == 1 }
        store.restoreToAgenda(item.id)
        store.removeFromAgenda(item.id)
        await waitUntil { sync.pendingRemovalCount == 2 }

        sync.completeRemoval(throwing: removalError)
        await waitUntil { sync.completedRemovals == 1 }
        await store.refreshCalendar()

        #expect(!store.agenda.contains { $0.id == item.id })
        sync.completeRemoval()
        await waitUntil { sync.completedRemovals == 2 }
    }

    private func occurrence(dayOffset: Int, isCancelled: Bool = true) -> AgendaItem {
        AgendaItem(
            id: "eventkit:recurring-meeting:\(1_788_163_200 + dayOffset * 86_400)",
            title: "Reunião recorrente", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar", dayOffset: dayOffset,
            calendarUID: "recurring-meeting", calendarID: "google-calendar",
            calendarTitle: "Trabalho", calendarSource: "Google", isCancelled: isCancelled
        )
    }

    private var removalError: NSError {
        NSError(domain: "calendar", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "A remoção foi recusada."
        ])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
        #expect(condition())
    }

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
