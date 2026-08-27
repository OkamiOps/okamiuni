import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
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

    // MARK: - Task AJ, conserto 5: o marcador de "agora" só aparece na semana de hoje

    /// Consertava `WeekScreen.swift:187`: `nowMarker` entrava na `ZStack` sem
    /// guarda nenhuma. Um `›` na Semana continuava desenhando a linha
    /// vermelha e a pastilha do horário atual sobre a semana seguinte, como
    /// se "agora" estivesse nela. `DayScreen` já guardava com `showsNow`
    /// (`dayOffset == 0`); a Semana não tinha o equivalente.
    @MainActor
    private func loadedStore() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("com focusOffset 0, a semana de hoje mostra o marcador de agora")
    @MainActor
    func showsNowOnTheCurrentWeek() async {
        let store = await loadedStore()
        let week = WeekScreen(store: store, now: Fixtures.nowMinute, anchor: Fixtures.today, focusOffset: 0)
        #expect(week.showsNow)
    }

    @Test("um › na Semana tira o marcador de agora — ele não pertence à semana seguinte")
    @MainActor
    func hidesNowOnAnyOtherWeek() async {
        let store = await loadedStore()
        // Provado quebrando: sem a guarda (`nowMarker` incondicional), este
        // teste não tem como falhar — não existe `showsNow` para checar. É a
        // própria ausência da propriedade, antes do conserto, que denuncia o
        // defeito: não havia onde travar "não desenha fora da semana de hoje".
        let nextWeek = WeekScreen(store: store, now: Fixtures.nowMinute, anchor: Fixtures.today, focusOffset: 7)
        #expect(nextWeek.showsNow == false)

        let twoWeeksAhead = WeekScreen(
            store: store, now: Fixtures.nowMinute, anchor: Fixtures.today, focusOffset: 14
        )
        #expect(twoWeeksAhead.showsNow == false)

        let priorWeek = WeekScreen(store: store, now: Fixtures.nowMinute, anchor: Fixtures.today, focusOffset: -7)
        #expect(priorWeek.showsNow == false)
    }

    /// `showsNow` sozinho não prova que a `ZStack` de fato a obedece — um
    /// regresso poderia manter `showsNow` correto e ainda desenhar
    /// `nowMarker` incondicionalmente. Renderiza a tela de verdade e procura
    /// pelo vermelho exato de `SemanticColor.live` (`#D73337` em tema claro,
    /// `EventWindow.swift:22`) em qualquer pixel — sem depender de saber onde
    /// a linha cairia.
    @Test("navegar uma semana para a frente tira a linha vermelha de 'agora' da tela")
    @MainActor
    func nowMarkerPixelDisappearsAfterNavigating() async throws {
        let store = await loadedStore()
        let live = TokenColor(red: 0xD7 / 255, green: 0x33 / 255, blue: 0x37 / 255)

        func containsLiveRed(focusOffset: Int) throws -> Bool {
            let screen = WeekScreen(
                store: store, now: Fixtures.nowMinute, anchor: Fixtures.today, focusOffset: focusOffset
            )
            let size = CGSize(width: 900, height: 700)
            let rep = try #require(Render.bitmap(screen, size: size, theme: .tinta, scale: 1))
            let pixels = HairlineThicknessTests.Pixels(rep: rep)
            for y in stride(from: 0, to: Int(size.height), by: 2) {
                for x in stride(from: 0, to: Int(size.width), by: 2) {
                    if HairlineThicknessTests.levels(pixels.color(x, y), live) < 15 { return true }
                }
            }
            return false
        }

        #expect(try containsLiveRed(focusOffset: 0), "a semana de hoje devia mostrar o traço de agora")
        #expect(try containsLiveRed(focusOffset: 7) == false, "a semana seguinte não devia mostrar o traço de agora")
    }
}
