import Foundation
import Testing
@testable import UNICore

@Suite("MonthAgenda — a grade de seis por sete")
struct MonthAgendaTests {

    /// Agosto de 2026 ancorado na terça 25. O protótipo desenha exatamente esta
    /// grade: começa na segunda 27 de julho e termina no domingo 6 de setembro.
    ///
    /// Trava as duas pontas em literal. Derivar a primeira do próprio
    /// `dayOffsets` provaria só que a função concorda consigo mesma.
    @Test("a grade de agosto de 2026 vai de -29 a +12")
    func augustGridEnds() {
        let offsets = MonthAgenda.dayOffsets(for: Fixtures.today)
        #expect(offsets.count == 42)
        #expect(offsets.first == -29)
        #expect(offsets.last == 12)
        // Contíguos, sem buraco nem repetição.
        #expect(offsets == Array(-29...12))
    }

    /// Um mês que **começa** na segunda não recua nada: a grade abre no dia 1º.
    /// Junho de 2026 começa numa segunda-feira.
    @Test("mês que começa na segunda abre no dia 1º")
    func monthStartingOnMonday() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 6; parts.day = 10; parts.hour = 12
        let june = Calendar(identifier: .gregorian).date(from: parts)!

        let offsets = MonthAgenda.dayOffsets(for: june)
        // Dia 10 é a âncora; o dia 1º está nove dias atrás.
        #expect(offsets.first == -9)
        #expect(offsets.count == 42)
    }

    /// A grade tem sempre seis linhas, inclusive num fevereiro que caberia em
    /// quatro. Fevereiro de 2027 começa numa segunda e tem 28 dias.
    @Test("a grade tem seis linhas mesmo quando o mês caberia em quatro")
    func gridIsAlwaysSixWeeks() {
        var parts = DateComponents()
        parts.year = 2027; parts.month = 2; parts.day = 1; parts.hour = 12
        let february = Calendar(identifier: .gregorian).date(from: parts)!

        let weeks = MonthAgenda.weeks(from: [], anchor: february)
        #expect(weeks.count == 6)
        #expect(weeks.allSatisfy { $0.days.count == 7 })
    }

    /// As pontas cinzas. Em agosto de 2026 são cinco dias de julho no começo e
    /// seis de setembro no fim — 31 dias de agosto e 42 células.
    @Test("as pontas de julho e setembro ficam marcadas como fora do mês")
    func outsideMonthFlags() {
        let days = MonthAgenda.weeks(from: [], anchor: Fixtures.today).flatMap(\.days)
        #expect(days.count == 42)
        #expect(days.filter { !$0.isOutsideMonth }.count == 31)

        // As cinco primeiras são julho; as seis últimas, setembro.
        #expect(days.prefix(5).allSatisfy { $0.isOutsideMonth })
        #expect(days.suffix(6).allSatisfy { $0.isOutsideMonth })

        // 1º e 2 de agosto caem na primeira linha e **não** são fora do mês.
        // O protótipo os marca `out: true` (linha 1638) — é engano dele, e a
        // conta com data real não o repete.
        #expect(days[5].dayNumber == 1)
        #expect(days[5].isOutsideMonth == false)
        #expect(days[6].dayNumber == 2)
        #expect(days[6].isOutsideMonth == false)
    }

    @Test("só a célula do dia 25 é hoje")
    func todayIsSingle() {
        let days = MonthAgenda.weeks(from: [], anchor: Fixtures.today).flatMap(\.days)
        let today = days.filter(\.isToday)
        #expect(today.count == 1)
        #expect(today.first?.dayNumber == 25)
        #expect(today.first?.dayOffset == 0)
    }

    /// A terça da grade do mês é a **mesma** terça da trilha e da semana:
    /// cinco blocos, com os títulos longos. Se `month` trouxesse a linha 4 do
    /// `MONTH` do protótipo, seriam três, com títulos curtos.
    @Test("o dia 25 no mês tem os mesmos cinco blocos da trilha")
    func tuesdayMatchesTheDailyRail() {
        let days = MonthAgenda.weeks(from: Fixtures.month, anchor: Fixtures.today).flatMap(\.days)
        let tuesday = days.first { $0.dayOffset == 0 }
        #expect(tuesday?.events.count == 5)
        #expect(tuesday?.events.map(\.title) == [
            "Standup produto", "1:1 Marina Duarte", "Almoço — bloqueado",
            "Revisão do contrato", "Foco: proposta TransRota",
        ])
    }

    /// Os pontos do seletor de data: que dias da grade têm compromisso.
    /// Trava dois dias vazios e dois cheios em literal.
    @Test("os dias com compromisso do mês batem com o protótipo")
    func daysWithEvents() {
        let days = MonthAgenda.weeks(from: Fixtures.month, anchor: Fixtures.today).flatMap(\.days)
        func day(_ offset: Int) -> MonthAgenda.Day {
            days.first { $0.dayOffset == offset }!
        }

        // 31 de julho, 1º e 2 de agosto: vazios no protótipo.
        #expect(day(-25).hasEvents == false)
        #expect(day(-24).hasEvents == false)
        // 5 de agosto: Standup + Kickoff cliente.
        #expect(day(-20).events.map(\.title) == ["Standup", "Kickoff cliente"])
        // 4 de setembro, já fora do mês: Renovar domínio.
        #expect(day(10).events.map(\.title) == ["Renovar domínio"])
        #expect(day(10).isOutsideMonth)
    }

    /// A contagem do cabeçalho conta **agosto**, não as 42 células. As pontas
    /// somam cinco: quatro standups de julho e o "Renovar domínio" de setembro.
    @Test("o cabeçalho do mês conta só os dias de agosto")
    func monthCountExcludesTheEdges() {
        let all = MonthAgenda.weeks(from: Fixtures.month, anchor: Fixtures.today)
            .flatMap(\.days).reduce(0) { $0 + $1.events.count }
        let inMonth = MonthAgenda.eventCount(from: Fixtures.month, anchor: Fixtures.today)

        #expect(all == 38)
        #expect(inMonth == 33)
    }

    // MARK: - Navegação

    @Test("o passo do dia não sai da grade")
    func stepClampsToTheGrid() {
        let anchor = Fixtures.today
        #expect(MonthAgenda.step(0, by: 1, anchor: anchor) == 1)
        #expect(MonthAgenda.step(0, by: -1, anchor: anchor) == -1)
        // Nas pontas ele para, em vez de trocar de mês.
        #expect(MonthAgenda.step(-29, by: -1, anchor: anchor) == -29)
        #expect(MonthAgenda.step(12, by: 1, anchor: anchor) == 12)
    }

    @Test("a faixa da grade é a das 42 células")
    func offsetRange() {
        let range = MonthAgenda.offsetRange(for: Fixtures.today)
        #expect(range == -29...12)
    }

    // MARK: - Rótulos

    @Test("o título longo do dia é o do protótipo")
    func longTitle() {
        #expect(MonthAgenda.longDayTitle(dayOffset: 0, anchor: Fixtures.today)
                == "Terça, 25 de agosto")
        #expect(MonthAgenda.longDayTitle(dayOffset: -1, anchor: Fixtures.today)
                == "Segunda, 24 de agosto")
        // Fora do mês o nome do mês acompanha, e não fica preso em agosto.
        #expect(MonthAgenda.longDayTitle(dayOffset: 10, anchor: Fixtures.today)
                == "Sexta, 4 de setembro")
    }

    @Test("o rótulo curto do botão sai sem ponto de abreviação")
    func shortLabel() {
        let label = MonthAgenda.shortDayLabel(dayOffset: 0, anchor: Fixtures.today)
        #expect(label == "ter, 25 ago")
        #expect(!label.contains("."))

        #expect(MonthAgenda.shortDayLabel(dayOffset: 10, anchor: Fixtures.today) == "sex, 4 set")
    }

    // MARK: - Task AJ, conserto 4: `focusedDate`, a base do seletor de data

    /// `DatePickerPopover` montava a grade e o título sempre a partir de
    /// `anchor`, ignorando o `focusOffset` que o navegador `‹ ›` acumulou —
    /// abrir o seletor depois de navegar mostrava sempre o mês da âncora, sem
    /// célula marcada, e escolher um dia teleportava a navegação de volta.
    /// `focusedDate` é a aritmética pura por trás do conserto: `anchor`
    /// deslocado por `focusOffset`, sem que `anchor` em si se mova. As quatro
    /// fronteiras pedidas no brief, cada uma checada de um jeito que não
    /// depende de `date(byAdding:)` para derivar o esperado — a mesma conta
    /// que a função usa por dentro provaria só que ela concorda consigo
    /// mesma.
    @Suite("focusedDate")
    struct FocusedDateTests {
        let calendar = Calendar(identifier: .gregorian)

        /// Fixtures.today é terça 25 de agosto de 2026, ao meio-dia local.
        var anchor: Date { Fixtures.today }

        @Test("mesma data: focusOffset 0 não move nada")
        func sameDate() {
            let result = MonthAgenda.focusedDate(anchor: anchor, focusOffset: 0, calendar: calendar)
            #expect(calendar.isDate(result, inSameDayAs: anchor))
        }

        @Test("véspera: focusOffset -1 é um dia antes")
        func eve() {
            let result = MonthAgenda.focusedDate(anchor: anchor, focusOffset: -1, calendar: calendar)
            let comps = calendar.dateComponents([.year, .month, .day], from: result)
            // 25 de agosto menos um dia: 24 de agosto, mesmo mês e ano —
            // então esta fronteira por si só não provaria nada se a função
            // sempre devolvesse `anchor` sem somar: checa o dia mudou.
            #expect(comps.year == 2026 && comps.month == 8 && comps.day == 24)
        }

        @Test("virada de mês: o deslocamento até 1º de setembro chega em setembro")
        func monthTurn() {
            // Deriva o deslocamento por SUBTRAÇÃO de calendário — mecanismo
            // diferente do `date(byAdding:)` que `focusedDate` usa por
            // dentro — para o teste não validar a função contra si mesma.
            let firstOfSeptember = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
            let offset = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: anchor), to: firstOfSeptember
            ).day!

            let result = MonthAgenda.focusedDate(anchor: anchor, focusOffset: offset, calendar: calendar)
            let comps = calendar.dateComponents([.year, .month, .day], from: result)
            #expect(comps.year == 2026 && comps.month == 9 && comps.day == 1)
        }

        @Test("virada de ano: o deslocamento até 1º de janeiro chega no ano seguinte")
        func yearTurn() {
            let newYearsDay = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
            let offset = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: anchor), to: newYearsDay
            ).day!

            let result = MonthAgenda.focusedDate(anchor: anchor, focusOffset: offset, calendar: calendar)
            let comps = calendar.dateComponents([.year, .month, .day], from: result)
            #expect(comps.year == 2027 && comps.month == 1 && comps.day == 1)
        }

        /// `anchor` propriamente dito nunca se move — só a data derivada.
        @Test("a âncora não muda de valor depois de pedir um foco distante")
        func anchorStaysPut() {
            _ = MonthAgenda.focusedDate(anchor: anchor, focusOffset: 400, calendar: calendar)
            #expect(calendar.isDate(anchor, inSameDayAs: Fixtures.today))
        }
    }
}
