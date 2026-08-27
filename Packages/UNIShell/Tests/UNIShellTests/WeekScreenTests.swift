import Testing
import UNICore
@testable import UNIShell

@Suite("WeekScreen")
struct WeekScreenTests {

    private let layout = WeekScreen.Layout()

    private func item(_ start: Int, _ end: Int) -> AgendaItem {
        AgendaItem(id: "x", title: "T", startMinute: start, endMinute: end, accountID: "zoho")
    }

    // MARK: - A escala da grade

    @Test("a grade da semana começa à meia-noite, não às 08:00")
    func offsetCountsFromMidnight() {
        // 09:30 = 570 min × 0.9 = 513pt. A trilha diária desconta 480 daqui;
        // a grade não, porque a faixa dela é o dia inteiro.
        #expect(layout.offset(for: item(570, 600)) == 513)
        #expect(layout.offset(minuteOfDay: 0) == 0)
    }

    @Test("a grade cobre as 24 horas")
    func totalHeight() {
        #expect(layout.totalHeight == 1300)
        #expect(layout.offset(minuteOfDay: 1440) == 1296)
    }

    @Test("a escala da semana é 0.9, e não a 0.78 da trilha diária")
    func scaleDivergesFromTheRail() {
        #expect(layout.pointsPerMinute == 0.9)
        #expect(layout.pointsPerMinute != AgendaRail.Layout().pointsPerMinute)
    }

    @Test("a altura do cartão é a duração menos 3")
    func cardHeight() {
        // 30 min × 0.9 − 3 = 24pt. Sem piso: a grade da semana não tem o
        // mínimo de 42 que a trilha diária aplica.
        #expect(layout.height(for: item(570, 600)) == 24)
        #expect(layout.height(for: item(990, 1080)) == 78)
    }

    @Test("abaixo de 40pt o cartão perde a linha do horário")
    func tightThreshold() {
        // 47 min × 0.9 − 3 = 39.3 < 40 → apertado.
        #expect(layout.isTight(for: item(600, 647)))
        // 48 min × 0.9 − 3 = 40.2 ≥ 40 → cabe.
        #expect(layout.isTight(for: item(600, 648)) == false)
    }

    // MARK: - A calha e as colunas

    @Test("a calha dos rótulos tem 54pt e o rótulo cabe nela")
    func labelGutter() {
        #expect(layout.labelGutter == 54)
        // O rótulo ocupa de x=4 a x=44; sobram 10pt até a linha em x=54, que é
        // o que dispensa o ajuste que a trilha diária precisou fazer.
        #expect(layout.labelGutter - layout.labelInset == 4)
        #expect(layout.labelInset - layout.labelWidth == 10)
    }

    @Test("as sete colunas dividem o que sobra depois da calha")
    func columnWidth() {
        #expect(layout.columnWidth(gridWidth: 1440) == 198)
        // Janela estreita não produz coluna negativa.
        #expect(layout.columnWidth(gridWidth: 20) == 0)
    }

    // MARK: - Rolagem inicial

    @Test("a grade abre com o 'agora' a 150pt do topo")
    func scrollTarget() {
        // Meio-dia: 720 × 0.9 − 150 = 498.
        #expect(layout.scrollTarget(now: Fixtures.nowMinute) == 498)
    }

    @Test("de madrugada a grade abre no topo, sem deslocamento negativo")
    func scrollTargetClampsAtZero() {
        #expect(layout.scrollTarget(now: 100) == 0)
    }

    // MARK: - Rótulos

    @Test("a última linha da grade diz 00:00, não 24:00")
    func hourLabelWraps() {
        #expect(WeekScreen.hourLabel(minuteOfDay: 1440) == "00:00")
        #expect(WeekScreen.hourLabel(minuteOfDay: 0) == "00:00")
        #expect(WeekScreen.hourLabel(minuteOfDay: 540) == "09:00")
        #expect(WeekScreen.hourLabel(minuteOfDay: Fixtures.nowMinute) == "12:00")
    }

    // MARK: - A trilha diária continua sendo de um dia

    @Test("a trilha diária não empilha a semana sobre hoje")
    func theRailStillShowsOneDay() {
        // A store carrega a semana inteira numa lista só, para a janela 04
        // achar qualquer compromisso pelo id. Quem mostra um dia filtra.
        #expect(Fixtures.week.count == 13)
        #expect(WeekAgenda.items(on: 0, in: Fixtures.week).count == 5)
    }

    @Test("o rótulo do próximo compromisso continua olhando só para hoje")
    func nextUpIgnoresTheRestOfTheWeek() {
        // Às 18:20 não há mais nada hoje — mas o domingo tem "Planejar semana"
        // às 19:00. Se a trilha lesse a semana inteira, ela anunciaria isso.
        let today = WeekAgenda.items(on: 0, in: Fixtures.week)
        #expect(AgendaRail.nextUpLabel(for: today, now: 1100) == "nada mais hoje")
    }
}
