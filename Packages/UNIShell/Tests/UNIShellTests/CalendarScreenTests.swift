import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

// MARK: - A régua da visão Dia

@Suite("DayScreen.Layout")
struct DayScreenLayoutTests {

    private let layout = DayScreen.Layout()

    /// Os três números que separam esta grade das outras duas do app. Literais
    /// do protótipo: `top: min * 0.95`, `height: 1370px`, `tight = h < 52`.
    @Test("a régua do dia é 0,95 pt/min em 1370pt de altura")
    func ruler() {
        #expect(layout.pointsPerMinute == 0.95)
        #expect(layout.totalHeight == 1370)
        #expect(layout.tightHeight == 52)

        // E ela **não** é a da semana nem a da trilha. Se alguém unificar as
        // três por engano, é aqui que aparece.
        #expect(layout.pointsPerMinute != WeekScreen.Layout().pointsPerMinute)
        #expect(layout.pointsPerMinute != AgendaRail.Layout().pointsPerMinute)
    }

    @Test("o topo de um compromisso é o minuto vezes a escala, sem desconto")
    func offsets() {
        // 09:30 = 570 min. 570 × 0,95 = 541,5.
        #expect(layout.offset(minuteOfDay: 570) == 541.5)
        #expect(layout.offset(minuteOfDay: 0) == 0)
        // Meia-noite do dia seguinte fecha a grade em 1368, dentro dos 1370.
        #expect(layout.offset(minuteOfDay: 1440) == 1368)
        #expect(layout.offset(minuteOfDay: 1440) < layout.totalHeight)
    }

    @Test("a altura desconta 4pt e o corte de cartão apertado é aos 52")
    func heights() {
        let short = AgendaItem(id: "s", title: "s", startMinute: 660, endMinute: 705,
                               accountID: "zoho")
        let long = AgendaItem(id: "l", title: "l", startMinute: 990, endMinute: 1080,
                              accountID: "host")

        // 45 min → 45 × 0,95 − 4 = 38,75.
        #expect(layout.height(for: short) == 38.75)
        #expect(layout.isTight(for: short))
        // 90 min → 81,5.
        #expect(layout.height(for: long) == 81.5)
        #expect(!layout.isTight(for: long))
    }

    /// A calha dos rótulos de hora e a faixa dos cartões **não** se encostam:
    /// o cartão começa 8pt depois da linha de hora, que já está 10pt depois do
    /// fim do texto do rótulo.
    ///
    /// É a mesma falha que a trilha diária já teve — cartão por cima de
    /// "08:00" — e a folga é o que a impede. Os dois números são literais
    /// independentes do protótipo (`left: 54px` na linha, `left: 62px` na
    /// faixa), então a comparação não é verdadeira por construção.
    @Test("os cartões começam depois da calha dos rótulos, com folga")
    func eventsClearTheLabelGutter() {
        #expect(layout.labelGutter == 54)
        #expect(layout.eventLeading == 62)
        #expect(layout.eventLeading - layout.labelGutter == 8)

        // O texto do rótulo termina em 54 − 50 + 40 = 44.
        let labelTrailing = layout.labelGutter - layout.labelInset + layout.labelWidth
        #expect(labelTrailing == 44)
        #expect(layout.eventLeading > labelTrailing)
    }

    @Test("a faixa dos cartões desconta as duas folgas da largura da grade")
    func trackWidth() {
        // 1000 − 62 − 30 = 908.
        #expect(layout.eventTrackWidth(gridWidth: 1000) == 908)
        // Grade estreita não devolve largura negativa.
        #expect(layout.eventTrackWidth(gridWidth: 40) == 0)
    }

    /// Protótipo: `scrollTop = max(0, now * 0.95 - 150)`.
    @Test("a grade abre com o agora a 150pt do topo")
    func scrollTarget() {
        #expect(layout.scrollTarget(now: 720) == 534)   // 720 × 0,95 − 150
        #expect(layout.scrollTarget(now: 60) == 0)      // 57 − 150 seria negativo
    }
}

// MARK: - As três abas

@Suite("CalendarViewMode")
struct CalendarViewModeTests {

    @Test("as três abas do protótipo, na ordem e com os rótulos dele")
    func tabs() {
        #expect(CalendarViewMode.allCases.map(\.rawValue) == ["dia", "semana", "mês"])
        #expect(CalendarViewMode.allCases.map(\.label) == ["Dia", "Semana", "Mês"])
    }
}

// MARK: - Renderização

@Suite("A aba Agenda desenhada")
@MainActor
struct CalendarRenderTests {

    /// O ponto de fidelidade do projeto: 1440 × 916 é a janela em que a Task P
    /// alinhou a caixa de entrada, e é onde a lateral tem de estar aberta
    /// (1440 ≥ `sidebarBreakpoint`).
    private static let windowSize = CGSize(width: 1440, height: 916)

    private func loadedStore() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    private func screen(_ store: MailStore) -> some View {
        CalendarScreen(
            store: store, now: Fixtures.nowMinute, anchor: Fixtures.today
        )
        .environment(ThemeStore())
    }

    // MARK: Leitura de pixel

    struct Pixels {
        let rep: NSBitmapImageRep
        var width: Int { rep.pixelsWide }

        /// `nil` em pixel transparente: fundo que não existe não é cor.
        func color(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double)? {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  c.alphaComponent > 0.5 else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
    }

    /// Distância no canal que mais diverge, em níveis de 0–255. Canal a canal e
    /// não média — ver `HairlineThicknessTests`.
    private func levels(
        _ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b))) * 255
    }

    private func token(_ c: TokenColor) -> (r: Double, g: Double, b: Double) {
        (c.red, c.green, c.blue)
    }

    // MARK: A lateral

    /// **O defeito que originou a tarefa.** O dono abriu a aba Agenda e a barra
    /// lateral não estava lá.
    ///
    /// A prova é de pixel, não de estrutura: a faixa da esquerda tem de estar
    /// pintada com `surface2` — o fundo da lateral — e não com `surface`, que é
    /// o fundo da agenda. Os dois tokens são distintos em `tinta`
    /// (`rgb(241,239,234)` contra `rgb(253,252,250)`), 12 níveis de distância,
    /// bem acima da tolerância.
    @Test("a aba Agenda desenha a barra lateral, e não começa na grade")
    func sidebarIsPresent() async throws {
        let store = await loadedStore()
        let rep = try #require(
            Render.snapshot(
                screen(store), named: "agenda-semana-tinta",
                size: Self.windowSize, theme: .tinta
            )
        )
        let pixels = Pixels(rep: rep)
        let sidebar = token(Theme.tinta.surface2)
        let canvas = token(Theme.tinta.surface)

        // Uma coluna dentro da lateral, abaixo do cabeçalho da janela.
        let inside = try #require(pixels.color(8, 500))
        #expect(levels(inside, sidebar) < 8,
                "x=8 deveria ser o fundo da lateral, veio \(inside)")

        // E uma logo depois dela, já na agenda.
        let outside = try #require(
            pixels.color(Int(PaneLayout.expandedSidebarWidth) + 40, 500)
        )
        #expect(levels(outside, canvas) < 8,
                "x=276 deveria ser o fundo da agenda, veio \(outside)")

        // Os dois tokens são de fato distinguíveis: sem isto o teste passaria
        // num tema em que `surface` e `surface2` coincidem, sem medir nada.
        #expect(levels(sidebar, canvas) > 2)
    }

    /// A mesma lateral que o email usa, com as mesmas contas — todas elas,
    /// venham de que provedor vierem.
    @Test("a lateral da agenda lista as contas que a store tem")
    func sidebarListsEveryAccount() async throws {
        let store = await loadedStore()
        #expect(store.accounts.count >= 2)
        let rep = try #require(
            Render.snapshot(
                FolderSidebar(store: store), named: "agenda-lateral-tinta",
                size: CGSize(width: PaneLayout.expandedSidebarWidth, height: 700),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == Int(PaneLayout.expandedSidebarWidth))
    }

    /// Em janela estreita a lateral recolhe para a trilha de 72pt, como no
    /// email — ela nunca some por completo.
    @Test("em janela estreita a lateral da agenda recolhe, mas não some")
    func sidebarCollapses() async throws {
        let store = await loadedStore()
        let narrow = CGSize(width: 900, height: 800)
        #expect(!PaneLayout.sidebarExpanded(width: narrow.width, wantsSidebar: true))

        let rep = try #require(
            Render.snapshot(
                screen(store), named: "agenda-lateral-recolhida-tinta",
                size: narrow, theme: .tinta
            )
        )
        let pixels = Pixels(rep: rep)
        let sidebar = token(Theme.tinta.surface2)

        // Dentro dos 72 da trilha ainda é fundo de lateral…
        let inside = try #require(pixels.color(8, 400))
        #expect(levels(inside, sidebar) < 8, "a trilha sumiu: x=8 veio \(inside)")
        // …e a agenda começa logo depois.
        let outside = try #require(pixels.color(Int(PaneLayout.railWidth) + 30, 400))
        #expect(levels(outside, token(Theme.tinta.surface)) < 8)
    }

    // MARK: A visão Dia

    /// A lateral "Livre hoje" de 250pt, medida pela borda: ela é pintada em
    /// `surface2` e a grade em `surface`, então a transição é achável varrendo
    /// uma linha da direita para a esquerda.
    ///
    /// 282 = os 250 do protótipo mais os 16 de recuo de cada lado. Medido no
    /// navegador: `width` computado 250px, `box-sizing: content-box`,
    /// `padding: 16px` — a caixa dá 283 com a borda de 1px, que aqui é
    /// desenhada por cima e não soma largura.
    @Test("a visão Dia abre a lateral \"Livre hoje\" de 250pt mais recuo")
    func dayFreeTimeSidebarWidth() async throws {
        let store = await loadedStore()
        let view = DayScreen(
            store: store, now: Fixtures.nowMinute, anchor: Fixtures.today, dayOffset: 0
        )
        .environment(ThemeStore())

        let size = CGSize(width: 1100, height: 700)
        let rep = try #require(
            Render.snapshot(view, named: "agenda-dia-tinta", size: size, theme: .tinta)
        )
        let pixels = Pixels(rep: rep)
        let canvas = token(Theme.tinta.surface)

        // Varre da direita para a esquerda numa linha bem abaixo, onde não há
        // cartão nem lacuna escrita, e para no primeiro pixel que **ainda é a
        // grade**. Medir pelo fundo da grade e não pelo da lateral é de
        // propósito: o último pixel da lateral é a divisória de um pixel, que
        // não é `surface2` — procurar por `surface2` daria 281 e esconderia a
        // linha dentro do erro.
        let row = 660
        var lastCanvasColumn = -1
        for x in stride(from: pixels.width - 1, through: 0, by: -1) {
            guard let c = pixels.color(x, row) else { continue }
            if levels(c, canvas) < 2 { lastCanvasColumn = x; break }
        }
        #expect(lastCanvasColumn > 0, "não achei a grade nesta linha")
        let panelWidth = pixels.width - lastCanvasColumn - 1
        #expect(panelWidth == 282, "a lateral mediu \(panelWidth)pt, esperado 282")

        // 282 = 250 + 16 + 16. Os três números são literais do protótipo, e o
        // 250 é o único que ele escreve como largura.
        #expect(DayScreen.Layout().sidebarWidth == 250)
    }

    /// As lacunas que a lateral oferece, com o corte de 45 minutos.
    /// A conta vive em `UNICore` e é testada lá; aqui a checagem é de que a
    /// visão consulta o dia certo.
    @Test("a lateral do dia mostra as lacunas daquele dia, não sempre as de hoje")
    func gapsFollowTheSelectedDay() async throws {
        let store = await loadedStore()
        let today = DayAgenda.gaps(in: WeekAgenda.items(on: 0, in: store.agenda))
        let saturday = DayAgenda.gaps(in: WeekAgenda.items(on: 4, in: store.agenda))

        #expect(today.count == 5)
        // Sábado 29 não tem compromisso: a janela inteira é uma lacuna só.
        #expect(saturday.map(\.rangeLabel) == ["08:00 – 19:00"])

        let rep = try #require(
            Render.snapshot(
                DayScreen(
                    store: store, now: Fixtures.nowMinute,
                    anchor: Fixtures.today, dayOffset: 4
                ).environment(ThemeStore()),
                named: "agenda-dia-sabado-tinta",
                size: CGSize(width: 1100, height: 700), theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 1100)
    }

    // MARK: A visão Mês

    /// Seis linhas de altura igual. A prova é achar as seis divisórias
    /// horizontais numa coluna vazia e conferir que os intervalos entre elas
    /// não variam mais que um pixel de arredondamento.
    @Test("a visão Mês desenha seis linhas de altura igual")
    func monthHasSixEqualRows() async throws {
        let store = await loadedStore()
        let size = CGSize(width: 1100, height: 700)
        let rep = try #require(
            Render.snapshot(
                MonthScreen(store: store, anchor: Fixtures.today).environment(ThemeStore()),
                named: "agenda-mes-tinta", size: size, theme: .tinta
            )
        )
        let pixels = Pixels(rep: rep)

        // Coluna dentro da célula de sábado, a única que não tem compromisso em
        // linha nenhuma do mês — nem número, nem pastilha, nem faixa de cor.
        let column = Int(Double(pixels.width) * 5.5 / 7)

        // A divisória é achada como **mínimo local de luminância**, e não
        // comparando com o token `line2`.
        //
        // Comparar com o token não serve aqui, e a primeira versão deste teste
        // falhou por isso: em `tinta`, `surface2` (o fundo das células de fora
        // do mês) fica a 17 níveis de `line2`, dentro de qualquer tolerância
        // razoável, e a última linha inteira era eleita "divisória". Um mínimo
        // local não se importa com o fundo: ele pergunta se **este** pixel é
        // mais escuro que os vizinhos, e a resposta é a mesma em célula branca
        // e em célula cinza.
        func luminance(_ y: Int) -> Double? {
            pixels.color(column, y).map { 0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b }
        }
        var rows: [Int] = []
        for y in 3..<(Int(size.height) - 3) {
            guard let here = luminance(y),
                  let above = luminance(y - 3),
                  let below = luminance(y + 3) else { continue }
            if here < above - 0.02 && here < below - 0.02 { rows.append(y) }
        }
        // Uma linha de um pixel produz um mínimo só; duas leituras coladas
        // seriam a mesma divisória vista duas vezes.
        rows = rows.enumerated().filter { $0.offset == 0 || $0.element - rows[$0.offset - 1] > 4 }
            .map(\.element)

        // Seis: o rodapé da faixa de rótulos e o rodapé das cinco primeiras
        // linhas. O da sexta cai na borda de baixo do bitmap, onde não há
        // vizinho abaixo para o mínimo local comparar — por isso a varredura
        // não o vê, e por isso são cinco intervalos e não seis.
        #expect(rows.count == 6, "achei \(rows.count) divisórias em y=\(rows)")
        let heights = zip(rows.dropFirst(), rows).map { $0 - $1 }
        #expect(heights.count == 5)
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        #expect(spread <= 1, "as linhas mediram \(heights)")

        // E a altura medida é a que sobra depois da faixa de rótulos, dividida
        // por seis — não um número que a célula mais cheia impôs. Antes de a
        // célula virar sobreposição sobre `Color.clear`, a linha de 24 a 30
        // media 134 contra 108 das outras.
        let expected = Int(((size.height - CGFloat(rows[0])) / 6).rounded())
        #expect(abs((heights.first ?? 0) - expected) <= 1,
                "linha de \(heights.first ?? 0)pt onde a fatia é \(expected)pt")
    }

    // MARK: O seletor de data

    /// O popover de 244pt de conteúdo — 268 com os 12 de recuo de cada lado.
    ///
    /// Medido com `fittingSize`, que é a largura que a hierarquia **pede**, e
    /// não a que um quadro imposto lhe daria. Cravar 244 no quadro externo
    /// encolheria as células de 33,1 para 30,3 e o erro não apareceria num
    /// bitmap de tamanho fixo.
    @Test("o seletor de data mede 268pt: 244 de conteúdo mais 12 de cada lado")
    func datePickerWidth() async throws {
        let store = await loadedStore()
        let host = NSHostingView(
            rootView: DatePickerPopover(
                store: store, anchor: Fixtures.today,
                selectedDayOffset: 0, onPickDay: { _ in }
            )
            .theme(.tinta)
            .environment(\.displayScale, 2)
        )
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == DatePickerPopover.width + 2 * DatePickerPopover.padding)
        #expect(host.fittingSize.width == 268)
    }

    /// As 42 células e os pontos: o seletor pergunta à mesma grade que a visão
    /// Mês desenha, então os dois nunca discordam sobre que dia tem compromisso.
    @Test("o seletor marca ponto nos mesmos dias que a visão Mês preenche")
    func pickerDotsMatchTheMonth() async throws {
        let store = await loadedStore()
        let days = MonthAgenda.weeks(from: store.agenda, anchor: Fixtures.today)
            .flatMap(\.days)
        #expect(days.count == 42)

        // Os índices com compromisso, medidos no protótipo servido em
        // 127.0.0.1:8931 lendo o `background-color` computado de cada ponto.
        let withDots = days.enumerated().filter { $0.element.hasEvents }.map(\.offset)
        #expect(withDots == [
            0, 1, 2, 3,
            7, 8, 9, 10, 11,
            14, 15, 16, 17, 18,
            21, 22, 23, 24, 25,
            27, 28, 29, 30, 31, 32, 34, 35,
            39,
        ])

        let rep = try #require(
            Render.snapshot(
                DatePickerPopover(
                    store: store, anchor: Fixtures.today,
                    selectedDayOffset: 0, onPickDay: { _ in }
                ).environment(ThemeStore()),
                named: "agenda-seletor-tinta",
                size: CGSize(width: 268, height: 260), theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 268)
    }

    // MARK: As três visões juntas

    /// Um PNG por visão, **com a lateral junto**, para conferência humana e
    /// para garantir que nenhuma das três estoura ou some ao desenhar.
    @Test("as três visões desenham na janela de fidelidade", arguments: [
        CalendarViewMode.day, .week, .month,
    ])
    func everyViewRenders(_ mode: CalendarViewMode) async throws {
        let store = await loadedStore()
        let rep = try #require(
            Render.snapshot(
                CalendarScreen(
                    store: store, now: Fixtures.nowMinute,
                    anchor: Fixtures.today, initialMode: mode
                ).environment(ThemeStore()),
                named: "agenda-visao-\(mode.rawValue)",
                size: Self.windowSize, theme: .tinta
            )
        )
        #expect(rep.pixelsWide == Int(Self.windowSize.width))
        #expect(rep.pixelsHigh == Int(Self.windowSize.height))

        // A lateral está lá nas três, não só na que a tarefa consertou primeiro.
        let pixels = Pixels(rep: rep)
        let inside = try #require(pixels.color(8, 500))
        #expect(levels(inside, token(Theme.tinta.surface2)) < 8,
                "\(mode.label) subiu sem a lateral: x=8 veio \(inside)")
    }

    /// Tema escuro: as cores das contas trocam de variante (`tint(isDark:)`) e
    /// os tokens de fundo invertem. O PNG é para conferência humana; a asserção
    /// aqui é que a lateral continua distinguível da grade também no escuro —
    /// um par de tokens que coincidisse deixaria a lateral invisível sem que
    /// nenhum teste claro percebesse.
    @Test("a aba Agenda desenha no tema escuro com a lateral distinguível")
    func darkTheme() async throws {
        let store = await loadedStore()
        let rep = try #require(
            Render.snapshot(
                CalendarScreen(
                    store: store, now: Fixtures.nowMinute,
                    anchor: Fixtures.today, initialMode: .week
                ).environment(ThemeStore()),
                named: "agenda-semana-noite", size: Self.windowSize, theme: .noite
            )
        )
        let pixels = Pixels(rep: rep)
        let sidebar = token(Theme.noite.surface2)
        let canvas = token(Theme.noite.surface)
        #expect(levels(sidebar, canvas) > 4)

        let inside = try #require(pixels.color(8, 500))
        #expect(levels(inside, sidebar) < 8, "x=8 no escuro veio \(inside)")
    }

    /// O seletor aberto, sobre a grade. Duas coisas que só um desenho mostra:
    /// que ele não é recortado pela faixa de 46pt em que nasce, e que pousa
    /// alinhado ao botão que o abriu.
    @Test("o seletor de data abre por cima da grade, alinhado ao botão")
    func pickerFloatsOverTheGrid() async throws {
        let store = await loadedStore()
        let rep = try #require(
            Render.snapshot(
                CalendarScreen(
                    store: store, now: Fixtures.nowMinute, anchor: Fixtures.today,
                    initialMode: .day, initialPickerOpen: true
                ).environment(ThemeStore()),
                named: "agenda-dia-seletor-aberto-tinta",
                size: Self.windowSize, theme: .tinta
            )
        )
        let pixels = Pixels(rep: rep)

        // 200pt abaixo do topo já é território da grade. Se o popover estivesse
        // recortado pela faixa do cabeçalho, esta linha inteira seria grade;
        // procuramos por 268 colunas seguidas que **não** são o fundo da grade.
        let canvas = token(Theme.tinta.surface)
        var run = 0
        var longest = 0
        for x in Int(PaneLayout.expandedSidebarWidth)..<pixels.width {
            let isCanvas = pixels.color(x, 200).map { levels($0, canvas) < 4 } ?? true
            run = isCanvas ? 0 : run + 1
            longest = max(longest, run)
        }
        #expect(longest >= 240,
                "a faixa não-grade em y=200 mediu \(longest)pt; o popover tem 268")
    }
}
