import AppKit
import SwiftUI
import UNIDesign
@testable import UNIShell

/// Fotografa a janela **com os semáforos do sistema dentro**.
///
/// `Render` (o harness de sempre) hospeda a view numa janela `.borderless` e
/// fotografa a `contentView`. Os três botões do macOS não moram ali: eles são
/// subviews do `NSThemeFrame`, que é o **pai** da `contentView`, e numa janela
/// sem título nem existem. Resultado: todo PNG deste projeto mostrava o trilho
/// com o lugar dos semáforos vazio, e o desencontro de 14/10/2026 — bolinhas
/// coladas na quina do painel — atravessou doze retratos sem ser visto.
///
/// Aqui a janela é `.titled` com `fullSizeContentView`, como a do app, e o que
/// é fotografado é a `contentView.superview` — o quadro inteiro, botões
/// inclusos. A janela continua a −50.000pt, nunca é trazida à frente e não
/// recebe evento nenhum.
@MainActor
enum JanelaReal {

    /// Onde os PNGs saem. Mesmo contrato do `Render`.
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["UNI_RENDER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// O que uma foto devolve: o bitmap do quadro inteiro e os quadros dos três
    /// botões, já em coordenadas da janela com y contado **do topo** — a mesma
    /// referência do protótipo e da acessibilidade.
    struct Foto {
        let bitmap: NSBitmapImageRep
        /// Fechar, minimizar e zoom, nessa ordem, em coordenadas do **quadro
        /// fotografado**, com y contado do topo.
        let semaforos: [CGRect]
        /// O retângulo que a `contentView` ocupa dentro do quadro, na mesma
        /// referência. Com `fullSizeContentView` ele é o quadro inteiro; se um
        /// dia deixar de ser, é aqui que a diferença aparece em vez de
        /// envenenar todas as contas em silêncio.
        let conteudo: CGRect
        let tamanho: CGSize

        var grupo: CGRect { semaforos.reduce(semaforos[0]) { $0.union($1) } }
    }

    static func fotografar<V: View>(
        _ view: V,
        size: CGSize,
        theme: Theme,
        named name: String? = nil
    ) -> Foto? {
        // Sem `.frame(...)` fixo e **com** o `ignoresSafeArea(.container, .top)`
        // que `OkamiUNIApp.barraColadaNoTopo()` aplica à cena principal. Sem
        // ele, o `NSHostingView` respeita a área segura da barra de título e
        // empurra o shell inteiro 32pt para baixo: o painel nascia em y=42 em
        // vez de y=10, e toda medida tirada daqui seria de outra janela que
        // não a do app.
        let root = view
            .theme(theme)
            .environment(\.locale, Locale(identifier: "pt_BR"))
            .environment(\.displayScale, 1)
            .ignoresSafeArea(.container, edges: .top)

        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: size.width, height: size.height),
            // `.titled` é o ponto inteiro deste harness: sem ele não há
            // `NSThemeFrame` com botões para fotografar.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // O mesmo que `.windowStyle(.hiddenTitleBar)` faz na cena do app.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: root)
        // O quadro — não o `contentRect` — é o que vale: com
        // `fullSizeContentView` a `contentView` ocupa o quadro inteiro, e o
        // `contentRect` do `init` ainda soma a barra de título por cima. Sem
        // esta linha a janela saía 948 de alto quando o pedido eram 916.
        window.setFrame(
            NSRect(x: -50_000, y: -50_000, width: size.width, height: size.height),
            display: false
        )
        defer { window.close() }

        guard let content = window.contentView, let frame = content.superview else { return nil }

        // O alinhador dos semáforos responde a `didBecomeKey` e a
        // `frameDidChange`; sem a janela ordenada ele nunca roda. `orderBack` a
        // põe atrás de tudo, a −50.000pt — não vira janela-chave, não ativa o
        // app. O `align()` explícito fecha a conta para o caso de nenhuma
        // notificação ter chegado.
        window.orderBack(nil)
        for _ in 0..<6 {
            frame.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        frame.layoutSubtreeIfNeeded()

        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)

        // Tudo é medido no quadro **fotografado**, não em "coordenadas da
        // janela": `window.frame` pode ser mais alto que o `contentRect` que
        // pedimos, e usar a altura errada punha os semáforos em y negativo.
        let alturaDoQuadro = frame.bounds.height
        func doTopo(_ rect: NSRect) -> NSRect {
            NSRect(
                x: rect.origin.x, y: alturaDoQuadro - rect.maxY,
                width: rect.width, height: rect.height
            )
        }

        let tipos: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let botoes: [NSRect] = tipos.compactMap {
            guard let botao = window.standardWindowButton($0) else { return nil }
            return doTopo(botao.convert(botao.bounds, to: frame))
        }
        guard botoes.count == 3 else { return nil }
        let conteudo = doTopo(content.convert(content.bounds, to: frame))

        if let name, let dir = outputDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        return Foto(
            bitmap: rep, semaforos: botoes, conteudo: conteudo,
            tamanho: frame.bounds.size
        )
    }
}
