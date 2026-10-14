import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A lateral do Vidro medida contra `design/Sidebar.dc.html`: o trilho de 64, a
/// coluna de contexto de 216, e o botão que a traz de volta quando ela está
/// recolhida.
///
/// Os retratos das três telas, abertas e recolhidas, no claro e no escuro, saem
/// daqui com `UNI_RENDER_DIR` — é com eles que a fidelidade é conferida. O que
/// os casos **afirmam** são as medidas que o protótipo fixa e que um PNG não
/// prova sozinho: largura do trilho, do alvo de uma tela, da coluna, e a altura
/// reservada aos semáforos.
@Suite("Trilho do Vidro")
@MainActor
struct VidroTrilhoTests {

    private func loja() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    // MARK: - As medidas do protótipo

    @Test("o trilho tem as medidas do protótipo")
    func railMetrics() {
        #expect(AppRail.width == 64, "`<nav aria-label=\"Telas\">`: width 64px")
        #expect(AppRail.itemWidth == 52, "o `<a>` de uma tela: width 52px")
        #expect(AppRail.actionSize == 40, "o quadrado do ícone: 40×40")
        #expect(AppRail.actionRadius == 12, "border-radius 12px")
        // 2 de folga em cima + 11 da bolinha + 16 embaixo.
        #expect(AppRail.trafficLightReserve == 29, "a fila dos semáforos: padding 2px 0 16px")
        #expect(ThemeSwitch.size == CGSize(width: 34, height: 62), "o interruptor: 34×62")
        #expect(ThemeSwitch.knob == 28, "o botão do interruptor: 28×28")
    }

    @Test("a coluna de contexto tem as medidas do protótipo")
    func contextMetrics() {
        #expect(ContextSidebar.width == 216)
        // `padding: 6px 8px` sobre 13px de linha.
        #expect(ContextSidebar.rowHeight == 28)
        #expect(ContextSidebar.rowInset == 8)
        #expect(ContextSidebar.childInset == 30, "`indent: '30px'` nas pastas da conta")
    }

    /// O centro das bolinhas do sistema cai onde o trilho o reserva.
    ///
    /// Duas contas que têm de fechar: a plataforma desenha os semáforos a
    /// `TrafficLightLayout.railCenterFromTop` do topo **da janela**, e o trilho
    /// reserva o lugar deles dentro do painel, que começa `vidroGap` abaixo.
    /// Se as duas discordarem, as bolinhas sobem para cima do primeiro botão de
    /// tela ou descem para dentro dele — e nenhum teste de pixel acusaria, já
    /// que elas não são `View` nossa.
    @Test("o lugar reservado aos semáforos é onde o sistema os desenha")
    func trafficLightReserveMatchesPlatform() {
        // 14pt do alto do `<nav>` + 2pt do `padding-top` da fila + metade da
        // bolinha de 11.
        let centroNoPainel: CGFloat = 14 + 2 + 5.5
        let centroNaJanela = PanelStyle.vidroGap + centroNoPainel
        #expect(
            abs(centroNaJanela - TrafficLightLayout.railCenterFromTop) <= 0.5,
            "o trilho reserva \(centroNaJanela) e a plataforma desenha em \(TrafficLightLayout.railCenterFromTop)"
        )
    }

    // MARK: - Os retratos

    @Test(
        "as três telas desenham a lateral aberta e recolhida",
        arguments: [Workspace.mail, Workspace.dashboard, Workspace.calendar],
        ["vidro", "vidro-noite"]
    )
    func screensRender(workspace: Workspace, tema: String) async throws {
        let theme = try #require(Theme.named(tema))
        for aberta in [true, false] {
            let store = await loja()
            let estado = aberta ? "aberta" : "recolhida"
            let rep = try #require(Render.snapshot(
                InboxScreen(
                    store: store,
                    debugAssistantOpen: false,
                    debugWorkspace: workspace,
                    debugWantsSidebar: aberta
                )
                .environment(ThemeStore()),
                named: "trilho-\(workspace.rawValue)-\(estado)-\(tema)",
                size: CGSize(width: 1440, height: 916),
                theme: theme
            ))
            #expect(rep.pixelsWide == 1440)
        }
    }

    /// Recolhida, o trilho não desenha controle de expandir nenhum: ele mora no
    /// cabeçalho do primeiro painel de conteúdo. O protótipo nunca pôs um no
    /// trilho, e a versão que punha foi recusada pelo dono (14/10/2026).
    @Test("o trilho recolhido é só navegação e o pé do protótipo")
    func collapsedRailHasNoExpandControl() async throws {
        let store = await loja()
        let rep = try #require(Render.snapshot(
            AppRail(
                store: store,
                workspace: .constant(.mail),
                intelligencePresentation: .onThisMac,
                onOpenAssistant: {},
                onOpenSettings: {},
                accountMonogram: "RI",
                isSynced: true,
                contextCollapsed: true
            )
            .environment(ThemeStore())
            .glassPanel(.vidro),
            named: "trilho-so-o-trilho",
            size: CGSize(width: AppRail.width, height: 760),
            theme: .vidro
        ))
        #expect(rep.pixelsWide == Int(AppRail.width))
    }
}
