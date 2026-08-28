import Foundation
import Testing
@testable import UNICore

@Suite("WeekAgenda")
struct WeekAgendaTests {

    private func item(
        _ id: String, _ start: Int, _ end: Int, day: Int = 0, title: String = "T"
    ) -> AgendaItem {
        AgendaItem(id: id, title: title, startMinute: start, endMinute: end,
                   accountID: "zoho", dayOffset: day)
    }

    // MARK: - O dia como inteiro

    @Test("um compromisso sem dia declarado é de hoje")
    func dayOffsetDefaultsToToday() {
        let legacy = AgendaItem(id: "x", title: "T", startMinute: 540,
                                endMinute: 600, accountID: "zoho")
        #expect(legacy.dayOffset == 0)
    }

    // MARK: - A semana de segunda a domingo

    @Test("a semana da terça vai de segunda a domingo")
    func weekOffsetsFromTuesday() {
        #expect(WeekAgenda.weekOffsets(for: Fixtures.today) == [-1, 0, 1, 2, 3, 4, 5])
    }

    @Test("a semana do domingo termina nele, não começa")
    func weekOffsetsFromSunday() {
        // 30/08/2026 é domingo — o último dia da mesma semana da fixture.
        let sunday = Calendar.current.date(byAdding: .day, value: 5, to: Fixtures.today)!
        #expect(WeekAgenda.weekOffsets(for: sunday) == [-6, -5, -4, -3, -2, -1, 0])
    }

    @Test("a semana de 25/08/2026 é a 35")
    func weekNumberIsThirtyFive() {
        #expect(WeekAgenda.weekNumber(for: Fixtures.today) == 35)
    }

    @Test("o título do cabeçalho sai da âncora")
    func monthTitleComesFromTheAnchor() {
        #expect(WeekAgenda.monthTitle(for: Fixtures.today) == "Agosto 2026")
    }

    // MARK: - Filtro por dia

    @Test("filtrar por hoje devolve a trilha diária, e só ela")
    func todayIsTheDailyRail() {
        let today = WeekAgenda.items(on: 0, in: Fixtures.week)
        #expect(today.map(\.id) == ["e1", "e2", "e3", "e4", "e5"])
        #expect(today.contains { $0.title == "Retro do sprint" } == false)
    }

    @Test("a terça da grade é a mesma terça da trilha, com os títulos inteiros")
    func tuesdayIsNotASecondCopy() {
        // O protótipo se contradiz aqui: `WEEK` lista três blocos com títulos
        // encurtados, `RAIL` lista cinco. Vale o `RAIL`, e os títulos inteiros —
        // encurtar é trabalho de quem desenha a coluna.
        let tuesday = WeekAgenda.items(on: 0, in: Fixtures.week)
        #expect(tuesday.map(\.title) == [
            "Standup produto",
            "1:1 Marina Duarte",
            "Almoço — bloqueado",
            "Revisão do contrato",
            "Foco: proposta TransRota",
        ])
    }

    @Test("o filtro devolve os compromissos em ordem de início")
    func filterSortsByStart() {
        let scrambled = [
            item("c", 900, 960), item("a", 540, 600), item("b", 660, 705),
            item("z", 480, 540, day: 1),
        ]
        #expect(WeekAgenda.items(on: 0, in: scrambled).map(\.id) == ["a", "b", "c"])
    }

    @Test("sábado não tem compromisso, e a coluna vazia é parte do desenho")
    func saturdayIsEmpty() {
        #expect(WeekAgenda.items(on: 4, in: Fixtures.week).isEmpty)
        #expect(WeekAgenda.items(on: 5, in: Fixtures.week).map(\.title) == ["Planejar semana"])
    }

    // MARK: - Faixas

    @Test("compromissos que não se tocam ficam cada um com a coluna inteira")
    func disjointEventsGetOneLane() {
        let placed = WeekAgenda.lanes([item("a", 540, 600), item("b", 660, 720)])
        #expect(placed.map(\.columns) == [1, 1])
        #expect(placed.map(\.column) == [0, 0])
    }

    @Test("encostar não é sobrepor: fim de um no início do outro abre grupo novo")
    func touchingIsNotOverlapping() {
        // A quarta da fixture é exatamente este caso: bloco 09:00–11:00 e
        // standup 11:00–11:30.
        let wednesday = WeekAgenda.items(on: 1, in: Fixtures.week)
        #expect(wednesday.map(\.startMinute) == [540, 660])
        #expect(WeekAgenda.lanes(wednesday).map(\.columns) == [1, 1])
    }

    @Test("três sobrepostos dividem a coluna em três faixas")
    func threeOverlappingShareTheColumn() {
        // C não encosta em B, mas encosta em A: o grupo cresce pelo fim mais
        // tardio já visto, não pelo fim do vizinho imediato.
        let placed = WeekAgenda.lanes([
            item("a", 540, 720), item("b", 600, 660), item("c", 700, 780),
        ])
        #expect(placed.count == 3)
        #expect(placed.map(\.columns) == [3, 3, 3])
        #expect(placed.map(\.id) == ["a", "b", "c"])
        #expect(placed.map(\.column) == [0, 1, 2])
    }

    @Test("dois sobrepostos e um solto depois: 2 faixas e depois 1")
    func overlapDoesNotLeakIntoTheNextGroup() {
        let placed = WeekAgenda.lanes([
            item("a", 540, 600), item("b", 570, 630), item("c", 900, 960),
        ])
        #expect(placed.map(\.id) == ["a", "b", "c"])
        #expect(placed.map(\.columns) == [2, 2, 1])
        #expect(placed.map(\.column) == [0, 1, 0])
    }

    // MARK: - A grade montada

    @Test("a grade tem sete colunas, de segunda 24 a domingo 30")
    func sevenColumns() {
        let days = WeekAgenda.days(from: Fixtures.week, anchor: Fixtures.today)
        #expect(days.map(\.dayNumber) == [24, 25, 26, 27, 28, 29, 30])
        #expect(days.map(\.weekdayLabel) == ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"])
        #expect(days.map(\.isToday) == [false, true, false, false, false, false, false])
    }

    @Test("cada coluna recebe só os compromissos do seu dia")
    func eventsLandOnTheRightColumn() {
        let days = WeekAgenda.days(from: Fixtures.week, anchor: Fixtures.today)
        #expect(days.map(\.events.count) == [2, 5, 2, 2, 1, 0, 1])
        #expect(days[3].events.map(\.item.title) == ["Standup", "Call do contrato"])
    }

    @Test("compromisso fora da semana não entra em coluna nenhuma")
    func itemsOutsideTheWeekAreDropped() {
        let stray = item("fora", 600, 660, day: 9, title: "Semana que vem")
        let days = WeekAgenda.days(from: Fixtures.week + [stray], anchor: Fixtures.today)
        let titles = days.flatMap { $0.events.map(\.item.title) }
        #expect(titles.contains("Semana que vem") == false)
        #expect(titles.count == 13)
    }
}
