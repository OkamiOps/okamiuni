import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Os retratos do shell **Vidro**: o gradiente, os painéis flutuantes, o
/// trilho da esquerda e a coluna de contexto.
///
/// Eles não repetem as asserções de pixel dos temas opacos (ver
/// `RenderHarnessTests.everyDarkThemeRendersTheInbox`): um painel translúcido
/// sobre gradiente não pinta `surface` em nenhum pixel. O que estes casos
/// afirmam é o que **é** verdade aqui: o gradiente aparece, o acento do tema
/// aparece, e o desenho sai no tamanho pedido.
@Suite("Shell Vidro")
@MainActor
struct VidroRenderTests {

    private func loja() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("a Caixa de vidro desenha no claro e no escuro", arguments: [
        "vidro", "vidro-noite",
    ])
    func glassInboxRenders(id: String) async throws {
        let theme = try #require(Theme.named(id))
        let store = await loja()
        let rep = try #require(Render.snapshot(
            InboxScreen(store: store).environment(ThemeStore()),
            named: "vidro-caixa-\(id)",
            size: CGSize(width: 1440, height: 916),
            theme: theme
        ))
        #expect(rep.pixelsWide == 1440)
        #expect(rep.pixelsHigh == 916)
        // O gradiente: a base dele tem de aparecer em algum lugar da janela,
        // senão algum painel está cobrindo a janela inteira e o vidro é só
        // um nome.
        let fundo = try #require(theme.backdrop).base
        #expect(
            rep.pixels(matching: fundo, tolerance: 0.06) > 500,
            "\(id): o fundo do gradiente não aparece"
        )
        #expect(
            rep.pixels(matching: theme.accent, tolerance: 0.05) > 200,
            "\(id): o acento sumiu (ação principal, ativo do trilho)"
        )
    }

    @Test("o trilho recolhido deixa só a navegação")
    func collapsedRailRenders() async throws {
        let store = await loja()
        // Janela abaixo da fronteira: a coluna de contexto recolhe sozinha.
        let estreita = PaneLayout.sidebarBreakpoint - 40
        #expect(
            !PaneLayout.contextSidebarOpen(width: estreita, wantsSidebar: true),
            "a fronteira deixou de recolher a coluna"
        )
        let rep = try #require(Render.snapshot(
            InboxScreen(store: store).environment(ThemeStore()),
            named: "vidro-trilho-recolhido",
            size: CGSize(width: estreita, height: 760),
            theme: .vidro
        ))
        #expect(rep.pixelsWide == Int(estreita))
    }

    @Test("o Painel e a Agenda de vidro desenham", arguments: [
        Workspace.dashboard, Workspace.calendar,
    ])
    func glassWorkspacesRender(workspace: Workspace) async throws {
        let store = await loja()
        let rep = try #require(Render.snapshot(
            InboxScreen(store: store, debugAssistantOpen: false, debugWorkspace: workspace)
                .environment(ThemeStore()),
            named: "vidro-\(workspace.rawValue)",
            size: CGSize(width: 1440, height: 916),
            theme: .vidro
        ))
        #expect(rep.pixelsWide == 1440)
    }
}
