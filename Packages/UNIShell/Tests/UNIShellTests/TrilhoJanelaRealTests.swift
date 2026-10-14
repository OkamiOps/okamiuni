import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O trilho medido na **janela de verdade**, com os semáforos do sistema
/// dentro da foto.
///
/// Os retratos de `Render` nunca contiveram os três botões — eles moram no
/// `NSThemeFrame`, que aquele harness não fotografa — e foi por isso que o
/// trilho foi entregue duas vezes com as bolinhas encostadas na quina do
/// painel sem nenhum PNG acusar. Ver `JanelaReal`.
@Suite("Trilho na janela real")
@MainActor
struct TrilhoJanelaRealTests {

    static let janela = CGSize(width: 1440, height: 916)

    private func loja() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    // MARK: - O que o protótipo manda

    /// As contas do `Sidebar.dc.html` em coordenadas da janela, com y do topo.
    ///
    /// O painel da lateral é afastado da borda por `PanelStyle.vidroGap`; o
    /// `<nav>` tem `padding: 14px 0 12px` e `align-items: center`; a fila dos
    /// semáforos tem `padding: 2px 0 16px` e bolinhas de 11 com `gap: 5px`.
    @MainActor
    enum Mock {
        static let painelX = PanelStyle.vidroGap                       // 10

        /// A largura que o **desenho** dá ao trilho. O app usa 72: ver
        /// `PaneLayout.appRailWidth`, e `folgaLateralDoDesenho` abaixo, que é
        /// o motivo.
        static let trilhoDoDesenho: CGFloat = 64
        /// A largura que o **app** usa, e contra a qual tudo é medido.
        static var trilhoLargura: CGFloat { AppRail.width }            // 72
        static var trilhoCentroX: CGFloat { painelX + trilhoLargura / 2 }  // 46

        static let bolinha: CGFloat = 11
        static let entreBolinhas: CGFloat = 5
        static var grupoLargura: CGFloat { 3 * bolinha + 2 * entreBolinhas }  // 43
        /// A folga de cada lado da fila no desenho: (64 − 43) / 2. É **esta**
        /// a medida que o trilho de 72 existe para preservar.
        static var folgaLateralDoDesenho: CGFloat {
            (trilhoDoDesenho - grupoLargura) / 2                       // 10,5
        }

        /// O que o protótipo de fato fixa: a folga acima da fila. É ela que
        /// atravessa para os botões do sistema, que são maiores que as
        /// bolinhas do desenho — ver `TrafficLightLayout.railCenterFromTop`.
        static var filaTopo: CGFloat { painelX + 14 + 2 }              // 26
        static let filaFolgaAbaixo: CGFloat = 16

        /// Com os botões de 14 do macOS no lugar das bolinhas de 11.
        static var botao: CGFloat { TrafficLightLayout.nativeButtonSide }
        static var botaoCentroY: CGFloat { filaTopo + botao / 2 }      // 33
        /// Onde a fila acaba de ocupar espaço.
        static var filaFim: CGFloat { filaTopo + botao + filaFolgaAbaixo }  // 56
        /// A folga lateral que os três botões de 14 têm de fato: (72 − 52) / 2.
        /// Com o trilho de 64 do desenho ela caía para 6, que é o que o dono
        /// recusou — daí os 72.
        static var botaoFolgaLateral: CGFloat {
            (trilhoLargura - TrafficLightLayout.railRowWidth) / 2       // 10
        }

        // Uma tela do trilho: `padding: 2px 0 4px`, quadrado 40, `gap: 4px`,
        // legenda de 10px (altura de linha ≈ 12). Entre telas, `gap: 6px`.
        static let legendaAltura: CGFloat = 12
        static var itemAltura: CGFloat { 2 + 40 + 4 + legendaAltura + 4 }  // 62
        static var passoEntreTelas: CGFloat { itemAltura + 6 }             // 68
        /// Centro do quadrado da primeira tela, contado do topo da janela.
        static var primeiroQuadradoCentroY: CGFloat { filaFim + 6 + 2 + 20 }  // 84
    }

    /// Despeja as medidas reais. Não afirma nada: é o instrumento, e serve
    /// para ler números antes de fixá-los nos casos acima.
    @Test("medidas da janela real", .disabled("diagnóstico sob demanda"))
    func dumpRealMeasurements() async throws {
        let store = await loja()
        let foto = try #require(JanelaReal.fotografar(
            InboxScreen(store: store).environment(ThemeStore()),
            size: Self.janela, theme: .vidro
        ))
        print("QUADRO \(foto.tamanho) CONTEUDO \(foto.conteudo)")
        for (i, r) in foto.semaforos.enumerated() { print("BOTAO \(i) \(r)") }
        print("GRUPO \(foto.grupo)")
    }

    // MARK: - Os semáforos

    @Test("os semáforos caem onde o protótipo os desenha", arguments: ["vidro", "vidro-noite"])
    func trafficLightsLandWhereTheMockDraws(tema: String) async throws {
        let theme = try #require(Theme.named(tema))
        let store = await loja()
        let foto = try #require(JanelaReal.fotografar(
            InboxScreen(store: store).environment(ThemeStore()),
            size: Self.janela, theme: theme,
            named: "real-caixa-aberta-\(tema)"
        ))

        let grupo = foto.grupo
        // Centrado no trilho, como o `align-items: center` do `<nav>`.
        #expect(
            abs(grupo.midX - Mock.trilhoCentroX) <= 0.5,
            "\(tema): o grupo centra em \(grupo.midX), o trilho em \(Mock.trilhoCentroX)"
        )
        // O topo da fila é a folga que o protótipo fixa: 14 do `<nav>` mais 2
        // da fila, abaixo do painel. **Esta** é a asserção que pega a queixa
        // do dono: com `railCenterFromTop: 31` o topo caía em 24, 14pt abaixo
        // do painel em vez de 16, e os botões entravam na quina do vidro.
        #expect(
            abs(grupo.minY - Mock.filaTopo) <= 0.5,
            "\(tema): a fila começa em y=\(grupo.minY), o protótipo em \(Mock.filaTopo)"
        )
        #expect(
            abs(grupo.midY - Mock.botaoCentroY) <= 0.5,
            "\(tema): o grupo centra em y=\(grupo.midY), esperado \(Mock.botaoCentroY)"
        )
        // E com a folga do desenho nos dois lados, igual nos dois. É o que o
        // trilho de 72 compra: com os 64 do desenho, a mesma fila de botões
        // de 14 ficava a 6pt das arestas.
        let folgaEsquerda = grupo.minX - Mock.painelX
        let folgaDireita = (Mock.painelX + Mock.trilhoLargura) - grupo.maxX
        #expect(
            folgaEsquerda >= Mock.folgaLateralDoDesenho - 0.5,
            "\(tema): o grupo começa a \(folgaEsquerda)pt da aresta do trilho; o desenho pede \(Mock.folgaLateralDoDesenho)"
        )
        #expect(
            abs(folgaEsquerda - folgaDireita) <= 0.5,
            "\(tema): o grupo não está centrado — \(folgaEsquerda) à esquerda, \(folgaDireita) à direita"
        )
    }

    // MARK: - O passo entre as telas

    /// O protótipo e o app têm de concordar sobre a altura de uma tela do
    /// trilho e sobre a distância de uma para a outra.
    @Test("o passo entre as telas do trilho é o do protótipo")
    func railItemPitchMatchesTheMock() {
        #expect(AppRail.itemWidth == 52)
        #expect(AppRail.actionSize == 40)
        #expect(AppRail.itemTopPadding == 2)
        #expect(AppRail.itemBottomPadding == 4)
        #expect(AppRail.itemSpacing == 4, "o `gap: 4px` entre o quadrado e a legenda")
        #expect(AppRail.gap == 6, "o `gap: 6px` do `<nav>`")
        #expect(
            AppRail.itemPitch == Mock.passoEntreTelas,
            "o app anda \(AppRail.itemPitch) entre telas e o protótipo \(Mock.passoEntreTelas)"
        )
    }

    /// A fila dos semáforos ocupa, no trilho, exatamente o que o protótipo
    /// reserva para ela — senão a primeira tela sobe ou desce.
    @Test("a faixa reservada aos semáforos é a do protótipo")
    func trafficLightBandMatchesTheMock() {
        #expect(AppRail.topPadding == 14, "`padding-top: 14px` do `<nav>`")
        #expect(AppRail.bottomPadding == 12, "`padding-bottom: 12px`")
        #expect(
            AppRail.trafficLightReserve == 2 + Mock.botao + Mock.filaFolgaAbaixo,
            "`padding: 2px 0 16px` sobre os botões de \(Mock.botao) do sistema"
        )
        // O centro do quadrado da primeira tela, contado do topo da janela.
        let primeiro = PanelStyle.vidroGap + AppRail.topPadding
            + AppRail.trafficLightReserve + AppRail.gap
            + AppRail.itemTopPadding + AppRail.actionSize / 2
        #expect(
            abs(primeiro - Mock.primeiroQuadradoCentroY) <= 0.01,
            "a primeira tela centra em \(primeiro) e o protótipo em \(Mock.primeiroQuadradoCentroY)"
        )
    }

    // MARK: - A coluna de contexto

    /// A pilha da coluna, somada constante a constante contra o protótipo.
    ///
    /// Medido na foto da janela real (`real-mail-aberta-vidro.png`): título em
    /// 24, busca em 65, ação principal em 112, primeira linha em 160. O
    /// protótipo pede 24, 65, 105 e 153 — os 7pt de diferença a partir da ação
    /// principal são a barra fina de estado da busca, que o desenho não tem e
    /// o app tem porque ela diz que a caixa está sincronizando.
    @Test("a pilha da coluna de contexto é a do protótipo")
    func contextColumnStackMatchesTheMock() {
        #expect(ContextSidebar.topPadding == 14)
        #expect(ContextSidebar.horizontalPadding == 10)
        #expect(ContextSidebar.bottomPadding == 12)
        #expect(ContextSidebar.headerLeading == 8)
        #expect(ContextSidebar.headerTrailing == 4)
        #expect(ContextSidebar.headerBottom == 12)
        #expect(
            SidebarToggleButton.side == 29,
            "o botão de recolher: `padding: 6px` em volta de um ícone de 17"
        )

        let painel = PanelStyle.vidroGap
        let tituloTopo = painel + ContextSidebar.topPadding
        #expect(tituloTopo == 24, "o título começa em \(tituloTopo)")
        // A fila do título tem a altura do botão, que é o mais alto nela.
        let buscaTopo = tituloTopo + SidebarToggleButton.side + ContextSidebar.headerBottom
        #expect(buscaTopo == 65, "a busca começa em \(buscaTopo)")
        // Daqui para baixo o app anda 7pt à frente do desenho: a barra fina.
        let acaoTopoNoDesenho = buscaTopo + ContextSidebar.searchFieldHeight
            + ContextSidebar.searchBottom
        #expect(acaoTopoNoDesenho == 105, "a ação principal do desenho em \(acaoTopoNoDesenho)")
        let primeiraLinhaNoDesenho = acaoTopoNoDesenho + ContextSidebar.primaryHeight
            + ContextSidebar.primaryBottom
        #expect(primeiraLinhaNoDesenho == 153, "a primeira linha do desenho em \(primeiraLinhaNoDesenho)")
        // E o passo entre linhas: 28 de altura com `gap: 1px`.
        #expect(ContextSidebar.rowHeight + 1 == 29)
    }

    // MARK: - Os retratos que faltavam

    @Test(
        "as três telas, abertas e recolhidas, com os semáforos na foto",
        arguments: [Workspace.mail, Workspace.dashboard, Workspace.calendar],
        ["vidro", "vidro-noite"]
    )
    func realWindowPortraits(workspace: Workspace, tema: String) async throws {
        let theme = try #require(Theme.named(tema))
        for aberta in [true, false] {
            let store = await loja()
            let estado = aberta ? "aberta" : "recolhida"
            let foto = try #require(JanelaReal.fotografar(
                InboxScreen(
                    store: store,
                    debugAssistantOpen: false,
                    debugWorkspace: workspace,
                    debugWantsSidebar: aberta
                ).environment(ThemeStore()),
                size: Self.janela, theme: theme,
                named: "real-\(workspace.rawValue)-\(estado)-\(tema)"
            ))
            #expect(foto.bitmap.pixelsWide == Int(Self.janela.width))
            // Recolhido ou aberto, o trilho é o mesmo e os semáforos também.
            #expect(abs(foto.grupo.midX - Mock.trilhoCentroX) <= 0.5)
        }
    }
}
