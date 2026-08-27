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
}
