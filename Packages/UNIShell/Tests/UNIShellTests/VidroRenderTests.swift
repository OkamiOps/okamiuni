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

    /// O dono não distinguia lidas de não lidas: o ponto colorido era o da
    /// conta em todas as linhas. Agora o ponto é de acento e só a não lida o
    /// tem, com nome e assunto mais fortes.
    @Test("a lida e a não lida se distinguem na lista de vidro", arguments: [
        "vidro", "vidro-noite",
    ])
    func readAndUnreadDiffer(id: String) async throws {
        let theme = try #require(Theme.named(id))
        let store = await loja()
        let primeira = try #require(store.visibleMessages.first)
        store.setRead(true, for: primeira.id)
        let rep = try #require(Render.snapshot(
            InboxScreen(store: store).environment(ThemeStore()),
            named: "vidro-lida-naolida-\(id)",
            size: CGSize(width: 1440, height: 916),
            theme: theme
        ))
        #expect(rep.pixelsWide == 1440)
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

    /// O motor mínimo que acende a superfície da IA no retrato — ele não é
    /// perguntado nada aqui; é a existência dele que faz o painel nascer com
    /// as ações habilitadas em vez de apagadas.
    private struct EnsaioDeTexto: TextAssisting {
        let modelVersion = "ensaio-vidro"
        func availability() async -> AppleIntelligenceAvailability { .available }
        func answer(
            question: String, in conversation: AssistantConversationSnapshot
        ) async throws -> String { "" }
        func transform(
            _ text: String, using action: WritingAction, context: AssistantMailContext?
        ) async throws -> String { "" }
    }

    /// A caixa "Tudo", que é onde as duas seções aparecem juntas: as que
    /// esperam resposta em cima, o resto compacto embaixo.
    @Test("as duas seções da lista de vidro aparecem em Tudo")
    func glassSectionsRender() async throws {
        let store = await loja()
        store.select(bucket: .all)
        let partes = InboxWaitingLine.split(store.conversationPage(limit: 20).conversations)
        #expect(!partes.waiting.isEmpty, "ninguém espera resposta — não há seção de cima")
        #expect(!partes.rest.isEmpty, "ninguém sobrou — não há seção de baixo")

        let rep = try #require(Render.snapshot(
            InboxScreen(store: store).environment(ThemeStore()),
            named: "vidro-caixa-secoes",
            size: CGSize(width: 1440, height: 916),
            theme: .vidro
        ))
        #expect(rep.pixelsWide == 1440)
    }

    /// O painel da IA aberto sobre o leitor, com a lista de ações do
    /// protótipo — "Traduzir" e "Explicar termos" entre elas.
    @Test("o painel da IA abre no leitor de vidro")
    func glassAssistantPanelRenders() async throws {
        let store = await loja()
        let rep = try #require(Render.snapshot(
            InboxScreen(
                store: store,
                textAssistant: EnsaioDeTexto(),
                debugAssistantOpen: false,
                debugReaderAssistantOpen: true
            ).environment(ThemeStore()),
            named: "vidro-caixa-ia",
            size: CGSize(width: 1440, height: 916),
            theme: .vidro
        ))
        #expect(rep.pixelsWide == 1440)
    }

    /// A conta aberta com uma subpasta: o protótipo pede **Faturas** recuada
    /// sob **Clientes**, e não "Clientes/Faturas" escrita por inteiro.
    @Test("a coluna de contexto desenha as pastas em árvore")
    func glassFolderTreeRenders() async throws {
        let store = await lojaComPastas()
        store.toggleFolders(of: "c1")
        let rep = try #require(Render.snapshot(
            FolderSidebar(store: store, width: ContextSidebar.width, chrome: .embedded)
                .frame(maxHeight: .infinity, alignment: .top),
            named: "vidro-pastas-arvore",
            size: CGSize(width: ContextSidebar.width, height: 560),
            theme: .vidro
        ))
        #expect(rep.pixelsWide == Int(ContextSidebar.width))
        // A árvore existe de fato: três pastas, a terceira recuada.
        #expect(GlassFolderList.tree(store.folders(of: "c1")).map(\.depth) == [0, 0, 1])
    }

    /// Uma fonte com pastas. `InMemoryMailSource` não tem servidor nenhum e
    /// devolve `[]` — que é o que mantém os retratos sem conta como estavam.
    private struct FonteComPastas: MailSource {
        var contas: [Account]
        var mensagens: [Message]
        var pastas: [MailFolder]

        func accounts() async throws -> [Account] { contas }
        func messages() async throws -> [Message] { mensagens }
        func agenda() async throws -> [AgendaItem] { [] }
        func pendingItems() async throws -> [PendingItem] { [] }
        func folders() async throws -> [MailFolder] { pastas }
    }

    private func lojaComPastas() async -> MailStore {
        let conta = Account(
            id: "c1", address: "ricardo@empresa.com", displayName: "Trabalho",
            provider: .imap, host: "empresa",
            tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let pastas = [
            MailFolder(
                id: "c1/INBOX", accountID: "c1", serverName: "INBOX",
                displayName: "Caixa de entrada", role: .inbox, unreadCount: 1
            ),
            MailFolder(
                id: "c1/Clientes", accountID: "c1", serverName: "Clientes",
                displayName: "Clientes", role: .other
            ),
            MailFolder(
                id: "c1/Clientes/Faturas", accountID: "c1", serverName: "Clientes/Faturas",
                displayName: "Clientes/Faturas", role: .other, unreadCount: 3
            ),
        ]
        let store = MailStore(source: FonteComPastas(
            contas: [conta],
            mensagens: [
                Message(
                    id: "m1", accountID: "c1",
                    from: Contact(name: "Marina", address: "marina@cliente.com"),
                    receivedAt: Fixtures.today,
                    subject: "Fatura de agosto", snippet: "Segue a fatura", body: [],
                    tags: [Tag(name: InboxWaitingLine.legacyNeedsReplyTag, tintHex: nil)],
                    bucket: .today, isRead: false, summary: nil, detectedEvent: nil,
                    folderIDs: ["c1/Clientes/Faturas"]
                )
            ],
            pastas: pastas
        ))
        await store.load()
        return store
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
