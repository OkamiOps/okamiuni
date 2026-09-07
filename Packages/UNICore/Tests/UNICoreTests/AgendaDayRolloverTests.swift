import Foundation
import Synchronization
import Testing
@testable import UNICore

private final class AgendaTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}

@MainActor
private final class RolloverCalendarSync: CalendarSyncing {
    let item: AgendaItem
    var duringSync: (() -> Void)?
    init(_ item: AgendaItem) { self.item = item }
    func availability() async -> CalendarAvailability { .available }
    func calendars() async -> [ConnectedCalendar] { [] }
    func synchronize(referenceDay: Date, requestAuthorization: Bool) async throws -> [AgendaItem] {
        duringSync?()
        return [item]
    }
    func save(_ item: AgendaItem, referenceDay: Date) async throws {}
    func remove(id: String, referenceDay: Date) async throws {}
}

@Suite("Datas da agenda ao atravessar a meia-noite")
@MainActor
struct AgendaDayRolloverTests {
    private func date(_ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    @Test("Um aniversário no dia 9 não muda para o dia 10 quando o relógio avança")
    func birthdayKeepsCivilDate() async throws {
        let clock = AgendaTestClock(date(6, hour: 23))
        let birthday = AgendaItem(
            id: "birthday", title: "Meu aniversário", startMinute: 0, endMinute: 1440,
            accountID: "calendar", dayOffset: 3
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: [birthday]),
            agendaReferenceDay: { clock.now }
        )
        await store.load()
        clock.set(date(7, hour: 3))
        let item = try #require(store.calendarAgenda.first)
        #expect(Calendar.current.isDate(store.agendaDate(for: item), inSameDayAs: date(9)))
        store.updateAgendaDay()
        let updated = try #require(store.calendarAgenda.first)
        #expect(updated.dayOffset == 2)
        #expect(Calendar.current.isDate(store.agendaReferenceDate, inSameDayAs: date(7)))
        #expect(Calendar.current.isDate(store.agendaDate(for: updated), inSameDayAs: date(9)))
        let days = WeekAgenda.days(from: store.calendarAgenda, anchor: store.agendaReferenceDate)
        #expect(days.first(where: { !$0.events.isEmpty })?.dayNumber == 9)
        // Um novo retrato do correio não pode desfazer a correção.
        await store.load()
        #expect(store.calendarAgenda.first?.dayOffset == 2)
    }

    @Test("Vários dias em suspensão e relógio voltando preservam o dia salvo")
    func persistedDatesAndClockReversal() async throws {
        let clock = AgendaTestClock(date(6))
        let persisted = StoredAgendaItem(
            AgendaItem(id: "meeting", title: "Reunião", startMinute: 600, endMinute: 660,
                       accountID: "calendar", dayOffset: 3),
            referenceDay: clock.now
        )
        let port = AgendaEmMemoria([persisted])
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []),
            agendaPort: port, agendaReferenceDay: { clock.now }
        )
        await store.load()
        for day in [10, 10, 7] {
            clock.set(date(day))
            store.updateAgendaDay()
            let item = try #require(store.calendarAgenda.first)
            #expect(item.dayOffset == 9 - day)
            #expect(item.startMinute == 600)
            #expect(Calendar.current.isDate(store.agendaDate(for: item), inSameDayAs: date(9)))
            #expect(try port.savedAgendaItems() == [persisted])
        }
    }

    @Test("Sincronização que atravessa a meia-noite mantém as datas e os metadados")
    func synchronizationCrossingMidnight() async throws {
        let clock = AgendaTestClock(date(6, hour: 23))
        let birthday = AgendaItem(
            id: "system-birthday", title: "Meu aniversário", startMinute: 0, endMinute: 1440,
            accountID: "calendar", dayOffset: 3, calendarUID: "uid-birthday", calendarSequence: 4,
            calendarID: "personal", calendarTitle: "Pessoal", calendarColorHex: "#123456",
            calendarSource: "Google"
        )
        let sync = RolloverCalendarSync(birthday)
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []),
            calendarSync: sync, agendaReferenceDay: { clock.now }
        )
        sync.duringSync = { clock.set(self.date(7)); store.updateAgendaDay() }
        await store.refreshCalendar()
        #expect(store.calendarAgenda == [birthday.rebased(from: date(6), to: date(7))])
        #expect(Calendar.current.isDate(store.agendaDate(for: store.calendarAgenda[0]), inSameDayAs: date(9)))
    }

    @Test("A virada usa dias civis, inclusive no fim do horário de verão")
    func daylightSavingRollover() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let before = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let item = AgendaItem(id: "dst", title: "Reunião", startMinute: 600, endMinute: 660,
                             accountID: "calendar", dayOffset: 1)
        #expect(item.rebased(from: before, to: after, calendar: calendar).dayOffset == 0)
    }
}
