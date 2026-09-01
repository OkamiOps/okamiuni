import Foundation
import Testing
@testable import UNICore

@Suite("Recorrência de compromisso")
struct RecurrenceTests {
    @Test("Diário, úteis, semanal e a cada N dias sobrevivem ao disco")
    func roundTripStorage() {
        let daily = RecurrenceRule(frequency: .daily, interval: 3)
        #expect(daily.label == "A cada 3 dias")
        #expect(RecurrenceRule.parse(daily.storage) == daily)
        #expect(daily.rfc5545 == "FREQ=DAILY;INTERVAL=3")

        let weekdays = RecurrenceRule(frequency: .weekdays)
        #expect(weekdays.label == "Somente dias úteis")
        #expect(weekdays.rfc5545 == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        #expect(RecurrenceRule.parse(weekdays.storage) == weekdays)

        let weekly = RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [2, 4])
        #expect(weekly.label.contains("semanas"))
        #expect(RecurrenceRule.parse(weekly.storage) == weekly)
        #expect(weekly.rfc5545?.contains("BYDAY=MO,WE") == true)

        let monthly = RecurrenceRule(frequency: .monthly, interval: 1, count: 6)
        #expect(monthly.label.contains("vezes"))
        #expect(RecurrenceRule.parse(monthly.storage)?.count == 6)
        #expect(monthly.rfc5545 == "FREQ=MONTHLY;COUNT=6")
    }

    @Test("Texto antigo continua sendo o rótulo")
    func legacyDisplay() {
        #expect(RecurrenceRule.parse("Não se repete") == RecurrenceRule.none)
        #expect(RecurrenceRule.display("Evento único") == "Evento único")
        #expect(RecurrenceRule.display("none") == "Não se repete")
    }

    @Test("Semanal vazia herda o dia do compromisso")
    func weeklyInheritsWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = Date(timeIntervalSince1970: 1_788_163_200) // 2026-08-31 segunda UTC
        let filled = RecurrenceRule(frequency: .weekly).withWeekdayOf(monday, calendar: calendar)
        #expect(filled.weekdays == [calendar.component(.weekday, from: monday)])
    }
}
