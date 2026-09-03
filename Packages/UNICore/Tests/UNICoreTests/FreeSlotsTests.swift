import Foundation
import Testing

@testable import UNICore

/// O que sobra do expediente. Quinta, 3 de setembro de 2026, para o fim de
/// semana cair no lugar certo.
@Suite("FreeSlots · as folgas do expediente")
struct FreeSlotsTests {

    private let quinta: Date = {
        var partes = DateComponents()
        partes.year = 2026
        partes.month = 9
        partes.day = 3
        partes.hour = 9
        return Calendar.current.date(from: partes)!
    }()

    private func compromisso(
        _ id: String, _ inicio: Int, _ fim: Int, dia: Int = 0, cancelado: Bool = false
    ) -> AgendaItem {
        AgendaItem(
            id: id, title: id, startMinute: inicio, endMinute: fim,
            accountID: "gmail", dayOffset: dia, isCancelled: cancelado
        )
    }

    @Test("o almoço marcado parte o dia em duas folgas")
    func lunchSplitsTheDay() {
        let folgas = FreeSlots.next(
            days: 1, minMinutes: 20, agenda: [compromisso("almoço", 720, 780)],
            workday: FreeSlots.workday, now: quinta, nowMinute: 540
        )
        #expect(folgas.count == 2)
        #expect(folgas.first.map { [$0.day, $0.start, $0.end] } == [0, 540, 720])
        #expect(folgas.last.map { [$0.day, $0.start, $0.end] } == [0, 780, 1080])
    }

    @Test("folga que já passou não é folga")
    func neverReturnsThePast() {
        let folgas = FreeSlots.next(
            days: 1, minMinutes: 20, agenda: [], workday: FreeSlots.workday,
            now: quinta, nowMinute: 1000
        )
        #expect(folgas.map(\.start) == [1000])
        #expect(folgas.allSatisfy { $0.start >= 1000 })
    }

    @Test("sábado e domingo não são expediente")
    func skipsTheWeekend() {
        let folgas = FreeSlots.next(
            days: 4, minMinutes: 20, agenda: [], workday: FreeSlots.workday,
            now: quinta, nowMinute: 540
        )
        // Quinta e sexta. Sábado e domingo saem.
        #expect(folgas.map(\.day) == [0, 1])
    }

    @Test("compromissos sobrepostos não inventam folga negativa")
    func mergesOverlappingMeetings() {
        let folgas = FreeSlots.next(
            days: 1, minMinutes: 20,
            agenda: [compromisso("a", 600, 720), compromisso("b", 660, 780)],
            workday: FreeSlots.workday, now: quinta, nowMinute: 540
        )
        #expect(folgas.map { [$0.start, $0.end] } == [[540, 600], [780, 1080]])
    }

    @Test("compromisso cancelado não ocupa o dia")
    func cancelledDoesNotBlock() {
        let folgas = FreeSlots.next(
            days: 1, minMinutes: 20,
            agenda: [compromisso("cancelado", 600, 900, cancelado: true)],
            workday: FreeSlots.workday, now: quinta, nowMinute: 540
        )
        #expect(folgas.map { [$0.start, $0.end] } == [[540, 1080]])
    }

    @Test("folga menor que o mínimo não conta")
    func belowMinimumIsNotASlot() {
        let folgas = FreeSlots.next(
            days: 1, minMinutes: 20,
            agenda: [compromisso("a", 550, 720), compromisso("b", 730, 1080)],
            workday: FreeSlots.workday, now: quinta, nowMinute: 540
        )
        // 540–550 e 720–730 são curtas demais.
        #expect(folgas.isEmpty)
    }

    @Test("a assinatura sem nowMinute tira o minuto da própria data")
    func dateOnlyOverloadDerivesTheMinute() {
        let calendario = Calendar.current
        let partes = calendario.dateComponents([.hour, .minute], from: quinta)
        let minuto = (partes.hour ?? 0) * 60 + (partes.minute ?? 0)
        let pelaData = FreeSlots.next(
            days: 1, minMinutes: 20, agenda: [], workday: FreeSlots.workday, now: quinta
        )
        let peloMinuto = FreeSlots.next(
            days: 1, minMinutes: 20, agenda: [], workday: FreeSlots.workday,
            now: quinta, nowMinute: minuto
        )
        #expect(pelaData.map(\.start) == peloMinuto.map(\.start))
        #expect(pelaData.map(\.start) == [minuto])
    }
}
