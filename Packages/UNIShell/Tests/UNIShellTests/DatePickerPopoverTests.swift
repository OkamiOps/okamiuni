import Foundation
import Testing
import UNICore
@testable import UNIShell

/// Task AJ, conserto 4. `DatePickerPopover` montava a grade e o título sempre
/// a partir de `anchor`, ignorando o `focusOffset` que o navegador `‹ ›`
/// acumulou — o popover nunca conseguia mostrar o mês para o qual a pessoa
/// tinha acabado de navegar.
///
/// Reprodução exata do brief: aba Agenda → **Mês** → um clique em `›`. Antes
/// do conserto, `selectedDayOffset` vira 31 (25/09), a grade atrás mostra
/// setembro corretamente, mas abrir o seletor mostrava "Agosto 2026", sem
/// nenhuma célula marcada — offset 31 caía fora da faixa `-29…12` da grade de
/// agosto.
@Suite("DatePickerPopover")
@MainActor
struct DatePickerPopoverTests {

    private func loaded() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("depois de navegar um mês, o seletor mostra o mês focado com a célula certa")
    func popoverFollowsMonthNavigation() async throws {
        let store = await loaded()
        let anchor = Fixtures.today  // terça 25/08/2026

        // O mesmo passo que `CalendarScreen.step` calcularia para um `›` na
        // aba Mês — não um literal escolhido a dedo.
        let focusOffset = MonthAgenda.navigationStep(
            days: .month, from: 0, anchor: anchor, direction: 1
        )
        // Confirma que o cenário de fato sai do mês da âncora antes de testar
        // o popover — sem isto o teste passaria mesmo sem focusOffset nenhum.
        try #require(focusOffset != 0)

        let popover = DatePickerPopover(
            store: store, anchor: anchor, selectedDayOffset: focusOffset, onPickDay: { _ in }
        )

        // O título segue o mês focado, não o da âncora.
        #expect(WeekAgenda.monthTitle(for: popover.focusedDate) != WeekAgenda.monthTitle(for: anchor))

        // A grade de agosto (a da âncora) vai de -29 a 12 — sem o conserto,
        // `weeks` continuaria começando aí mesmo depois de navegar.
        #expect(popover.weeks.first?.days.first?.dayOffset != -29)

        // A grade tem uma célula com o offset selecionado: sem isto,
        // `isSelected` (`day.dayOffset == selectedDayOffset`) nunca fica
        // `true` em lugar nenhum do popover, e nenhum dia aparece marcado.
        let allOffsets = popover.weeks.flatMap(\.days).map(\.dayOffset)
        #expect(allOffsets.contains(focusOffset))
    }

    @Test("na âncora (sem navegar), o seletor continua mostrando o mês de sempre")
    func popoverAtAnchorIsUnchanged() async {
        let store = await loaded()
        let anchor = Fixtures.today

        let popover = DatePickerPopover(
            store: store, anchor: anchor, selectedDayOffset: 0, onPickDay: { _ in }
        )

        #expect(WeekAgenda.monthTitle(for: popover.focusedDate) == WeekAgenda.monthTitle(for: anchor))
        #expect(popover.weeks.first?.days.first?.dayOffset == -29)
        #expect(popover.weeks.flatMap(\.days).map(\.dayOffset).contains(0))
    }

    @Test("no 13º clique em › na visão Dia, o seletor também acompanha (fora da grade de agosto)")
    func popoverFollowsDayNavigationPastTheAugustGrid() async throws {
        let store = await loaded()
        let anchor = Fixtures.today

        var focusOffset = 0
        for _ in 0..<13 {
            focusOffset = MonthAgenda.navigationStep(
                days: .day, from: focusOffset, anchor: anchor, direction: 1
            )
        }
        // O brief: "Na visão Dia o mesmo acontece a partir do 13º clique em
        // ›" — offset 13 > 12, o fim da grade de agosto.
        try #require(focusOffset == 13)
        try #require(!(-29...12).contains(focusOffset))

        let popover = DatePickerPopover(
            store: store, anchor: anchor, selectedDayOffset: focusOffset, onPickDay: { _ in }
        )
        let allOffsets = popover.weeks.flatMap(\.days).map(\.dayOffset)
        #expect(allOffsets.contains(focusOffset))
    }
}
