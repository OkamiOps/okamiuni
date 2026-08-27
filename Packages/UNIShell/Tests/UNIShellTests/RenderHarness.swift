import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Renderiza telas **fora da tela**, sem abrir janela e sem tocar em mouse ou
/// teclado da máquina. É assim que este projeto verifica aparência: dirigir a
/// interface com eventos sintéticos rouba o computador de quem está usando.
///
/// `ImageRenderer` desenha a hierarquia SwiftUI direto num bitmap. Não há
/// `NSWindow`, não há foco, não há ponteiro.
@MainActor
enum Render {

    /// Onde os PNGs saem. Vazio = não escreve (o padrão, para a suíte ficar rápida).
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["UNI_RENDER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Renderiza uma view num tamanho e tema dados e devolve o bitmap.
    ///
    /// Usa uma `NSWindow` posicionada **muito fora da área visível** e nunca
    /// trazida à frente. O AppKit desenha a hierarquia completa — inclusive
    /// `ScrollView`, `TextField` e tudo que tem respaldo nativo, que o
    /// `ImageRenderer` deixa em branco — mas a janela não aparece em tela, não
    /// vira janela-chave e não recebe evento nenhum. Nada de foco roubado.
    static func bitmap<V: View>(
        _ view: V,
        size: CGSize,
        theme: Theme,
        scale: CGFloat = 1
    ) -> NSBitmapImageRep? {
        // ATENÇÃO ao comparar texto de data com o app rodando: parte do código
        // formata com `Locale(identifier: "pt_BR")` fixo e parte com
        // `Locale.current`. `Locale.current` resolve contra as localizações
        // declaradas no bundle — o app tem, o bundle de teste não — então aqui
        // essas datas saem em inglês ("AUG 25") e no app saem em português
        // ("25 DE AGO."). Injetar `\.locale` no ambiente NÃO corrige: esses
        // formatadores leem `Locale.current` direto, sem passar pelo ambiente.
        //
        // Isso é inconsistência real do código, registrada para conserto. Até
        // lá, não relate a diferença de idioma aqui como defeito de aparência.
        let root = view
            .theme(theme)
            .environment(\.locale, Locale(identifier: "pt_BR"))
            .frame(width: size.width, height: size.height)

        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)

        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        // O SwiftUI resolve conteúdo preguiçoso num segundo passe; sem isto as
        // listas saem vazias.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        content.layoutSubtreeIfNeeded()

        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        window.close()
        return rep
    }

    /// Renderiza e, se `UNI_RENDER_DIR` estiver definido, grava um PNG para
    /// inspeção humana. Devolve o bitmap de qualquer jeito.
    @discardableResult
    static func snapshot<V: View>(
        _ view: V,
        named name: String,
        size: CGSize,
        theme: Theme
    ) -> NSBitmapImageRep? {
        guard let rep = bitmap(view, size: size, theme: theme) else { return nil }
        if let dir = outputDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        return rep
    }
}

@Suite("Renderização fora da tela")
@MainActor
struct RenderHarnessTests {

    @Test("a caixa de entrada renderiza sem janela, no tamanho pedido")
    func inboxRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let rep = try #require(
            Render.snapshot(
                InboxScreen(store: store).environment(ThemeStore()),
                named: "inbox-tinta",
                size: CGSize(width: 1440, height: 916),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 1440)
        #expect(rep.pixelsHigh == 916)
    }

    /// A caixa "Tudo", que é onde as sete mensagens do design aparecem juntas
    /// nos dois grupos. A caixa que abre por padrão mostra três — o design
    /// filtra por triagem, não por dia.
    ///
    /// Renderizar não prova rótulo (a comparação é humana, olhando o PNG), mas
    /// prova que a lista inteira desenha sem estourar altura nem sumir. As
    /// asserções de conteúdo estão em `MessageListTests`.
    @Test("a caixa Tudo desenha as sete mensagens em dois grupos")
    func allBucketRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        #expect(store.visibleMessages.count == 7)
        #expect(MessageGroup.build(from: store.visibleMessages).map(\.label) == ["Hoje", "Ontem"])

        let rep = try #require(
            Render.snapshot(
                InboxScreen(store: store).environment(ThemeStore()),
                named: "inbox-tudo-tinta",
                size: CGSize(width: 1440, height: 916),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 1440)
    }

    /// A trilha recolhida a 62pt, onde "HOSTINGER" não cabe e vira "HOS".
    /// O PNG é para conferir que a marca curta não estoura os 40pt da pastilha.
    @Test("a trilha recolhida desenha a marca curta do host")
    func collapsedRailRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.accounts.map { HostMark.rail($0.host) } == ["ZOH", "GMA", "HOS", "ICL"])

        let rep = try #require(
            Render.snapshot(
                SidebarRail(store: store),
                named: "trilha-recolhida-tinta",
                size: CGSize(width: PaneLayout.railWidth, height: 480),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == Int(PaneLayout.railWidth))
    }

    /// A barra expandida a 236pt, onde o mesmo host aparece por extenso.
    @Test("a barra expandida desenha o host por extenso")
    func expandedSidebarRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let rep = try #require(
            Render.snapshot(
                FolderSidebar(store: store),
                named: "barra-expandida-tinta",
                size: CGSize(width: PaneLayout.expandedSidebarWidth, height: 700),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == Int(PaneLayout.expandedSidebarWidth))
    }
}

@Suite("Porta de depuração de lançamento")
struct LaunchWindowRequestTests {

    @Test("sem bandeira, lançamento normal não abre janela nenhuma")
    func noFlagNoWindow() {
        #expect(LaunchWindowRequest.parse([]) == nil)
        #expect(LaunchWindowRequest.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test("cada bandeira mapeia para a cena dela", arguments: [
        ("--nova-mensagem", UNIWindow.newMessage),
        ("--responder", UNIWindow.composer),
        ("--mensagem", UNIWindow.message),
        ("--compromisso", UNIWindow.event),
    ])
    func flagMapsToScene(flag: String, expected: String) throws {
        let request = try #require(LaunchWindowRequest.parse([flag]))
        #expect(request.windowID == expected)
    }

    @Test("o valor vem colado ou separado")
    func valueForms() throws {
        let inline = try #require(LaunchWindowRequest.parse(["--mensagem=m2"]))
        #expect(inline.value == "m2")
        let separate = try #require(LaunchWindowRequest.parse(["--mensagem", "m2"]))
        #expect(separate.value == "m2")
    }

    @Test("uma bandeira seguida de outra não engole a seguinte como valor")
    func flagIsNotAValue() throws {
        let request = try #require(LaunchWindowRequest.parse(["--mensagem", "--responder"]))
        #expect(request.windowID == UNIWindow.message)
        #expect(request.value == "")
    }

    @Test("só a primeira bandeira vale")
    func firstFlagWins() throws {
        let request = try #require(
            LaunchWindowRequest.parse(["--compromisso", "a1", "--nova-mensagem"])
        )
        #expect(request.windowID == UNIWindow.event)
        #expect(request.value == "a1")
    }

    @Test("bandeira desconhecida é ignorada, não confundida com as nossas")
    func unknownFlagIgnored() throws {
        #expect(LaunchWindowRequest.parse(["--nova-mensagem-falsa"]) == nil)
        let request = try #require(
            LaunchWindowRequest.parse(["--qualquer", "coisa", "--responder", "m1"])
        )
        #expect(request.windowID == UNIWindow.composer)
        #expect(request.value == "m1")
    }
}
