import Foundation
import SwiftUI
import Testing
@testable import UNIShell

@Suite("AgendaClock")
struct AgendaClockTests {

    /// A conversão pura: hora e minuto do `Calendar` viram minutos desde a
    /// meia-noite. É o que `InboxScreen`/`CalendarScreen` chamavam de
    /// `Fixtures.nowMinute` sempre, mesmo com uma conta real no ar — o
    /// primeiro teste com contas reais viu a linha de "agora" da agenda
    /// parada ao meio-dia, não importa a hora de verdade.
    @Test("minutesSinceMidnight lê hora e minuto do relógio informado")
    func minutesSinceMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let vinteUmEQuarenta = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 21, minute: 40)
        )!
        #expect(AgendaClock.minutesSinceMidnight(for: vinteUmEQuarenta, calendar: calendar) == 21 * 60 + 40)

        let meiaNoite = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 0, minute: 0)
        )!
        #expect(AgendaClock.minutesSinceMidnight(for: meiaNoite, calendar: calendar) == 0)
    }

    /// Mutação vermelha do relógio: `.fixed` devolve sempre o mesmo minuto,
    /// não importa o `Date` que o processo veria se perguntasse ao sistema.
    /// Se `AgendaClockReader` chamasse `AgendaClock.minutesSinceMidnight()`
    /// mesmo no caso `.fixed`, uma captura tirada em outro horário do dia
    /// deixaria de bater com a anterior — exatamente o que este caso existe
    /// para impedir.
    @Test(".fixed sempre entrega o mesmo minuto, .live não")
    @MainActor
    func fixedIsStable() {
        var capturado: Int?
        _ = AgendaClockReader(.fixed(720)) { now -> EmptyView in
            capturado = now
            return EmptyView()
        }.body
        #expect(capturado == 720)
    }
}
