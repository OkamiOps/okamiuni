import SwiftUI
import UNICore
#if canImport(AppKit)
import AppKit
#endif

/// Ensaia o **duplo clique na barra de título** dentro do app de verdade.
///
/// ## Por que existe
///
/// A Task AL consertou `TitleBarDoubleClick` com testes de `NSView.hitTest`, e o
/// dono do projeto respondeu que na prática continua morto. O teste de `hitTest`
/// só prova o primeiro passo: ele não diz se `mouseDown:` chega, nem se o
/// `clickCount` 2 chega na **mesma** view, nem se alguém por cima engole o
/// evento. Este ensaio prova o caminho inteiro do jeito mais direto que existe:
/// clica duas vezes na área vazia da barra e compara `window.frame` antes e
/// depois. Zoom mexe na moldura; morto não mexe.
///
/// `--ensaiar-barra` liga. Nenhum evento é postado no sistema.
public struct TitleBarRehearsal: Sendable {
    public static func parse(_ arguments: [String]) -> TitleBarRehearsal? {
        arguments.contains("--ensaiar-barra") ? TitleBarRehearsal() : nil
    }

    public static var fromProcess: TitleBarRehearsal? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }

    /// Onde o ensaio clica, contado do topo da janela.
    ///
    /// A barra tem 58pt e os controles vivem na faixa de `2 × 22` do topo —
    /// nenhum deles passa de 36. 48 é barra vazia com folga dos dois lados, e
    /// x=700 fica longe dos semáforos (que terminam em 70) e do "+ Escrever"
    /// (que fecha a barra, à direita).
    public static let emptySpot = CGPoint(x: 700, y: 48)
}

extension View {
    public func rehearseTitleBarIfRequested(_ request: TitleBarRehearsal?) -> some View {
        modifier(TitleBarRehearsalModifier(request: request))
    }
}

private struct TitleBarRehearsalModifier: ViewModifier {
    let request: TitleBarRehearsal?
    @State private var started = false

    func body(content: Content) -> some View {
        content.background(
            TitleBarProbe(request: request, started: $started).frame(width: 0, height: 0)
        )
    }
}

private struct TitleBarProbe: NSViewRepresentable {
    let request: TitleBarRehearsal?
    @Binding var started: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard request != nil, !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard let window = view.window else {
                RehearsalStage.log("barra: sem janela"); NSApp.terminate(nil); return
            }
            await TitleBarDriver(window: window).run()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private final class TitleBarDriver {
    let driver: RehearsalDriver
    var window: NSWindow { driver.window }

    init(window: NSWindow) {
        self.driver = RehearsalDriver(window: window)
    }

    func run() async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settle(0.5)

        let spot = driver.point(
            x: TitleBarRehearsal.emptySpot.x, fromTop: TitleBarRehearsal.emptySpot.y
        )
        RehearsalStage.log("barra: ponto \(descrever(spot)) na janela \(descrever(window.frame))")
        RehearsalStage.log("barra: quem responde ao ponto — \(quemPega(spot))")
        RehearsalStage.log("barra: captura — \(estadoDaCaptura(spot))")
        RehearsalStage.log(
            "barra: ajuste do sistema AppleActionOnDoubleClick = "
            + "\(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "«ausente» (padrão zoom)")"
        )

        let antes = window.frame
        driver.doubleClick(at: spot)
        await settle(0.9)
        let depois = window.frame
        RehearsalStage.log(
            "duplo clique na área vazia: \(descrever(antes)) → \(descrever(depois)) — "
            + "\(antes == depois ? "MORTO (moldura não mudou)" : "AGIU")"
        )

        // O ponto é recalculado: a janela mudou de altura no zoom, e o ponto
        // guardado apontaria para outro lugar da tela.
        driver.doubleClick(at: pontoDaBarra())
        await settle(0.9)
        RehearsalStage.log(
            "duplo clique de volta: \(descrever(window.frame)) — "
            + "\(window.frame == antes ? "VOLTOU" : "não voltou")"
        )

        await duploCliqueNoControle()
        await cliqueSimples(at: pontoDaBarra())
    }

    /// O ponto da área vazia da barra, na janela do tamanho que ela tem agora.
    private func pontoDaBarra() -> NSPoint {
        driver.point(x: TitleBarRehearsal.emptySpot.x, fromTop: TitleBarRehearsal.emptySpot.y)
    }

    /// Duplo clique **sobre um controle** não é da janela.
    ///
    /// É o que separa esta barra de uma que engole tudo: em qualquer app
    /// nativo, clicar duas vezes num botão da barra são dois cliques no botão.
    /// O ensaio clica no meio de cada controle medido e afere que a moldura da
    /// janela não se mexeu.
    private func duploCliqueNoControle() async {
        guard let catcher = Self.procurar(CatcherView.self, in: window.contentView ?? NSView()),
              !catcher.controls.isEmpty else {
            RehearsalStage.log("duplo clique em controle: sem molduras medidas")
            return
        }
        for (índice, moldura) in catcher.controls.enumerated() {
            let antes = window.frame
            driver.doubleClick(at: driver.point(x: moldura.midX, fromTop: moldura.midY))
            await settle(0.5)
            RehearsalStage.log(
                "duplo clique no controle \(índice) (\(Int(moldura.midX)),\(Int(moldura.midY))): "
                + "\(window.frame == antes ? "janela parada, como deve ser" : "DEFEITO (deu zoom)")"
            )
            if window.frame != antes { return }
        }
    }

    /// O clique **simples** na barra não pode fazer nada — e a janela tem de
    /// continuar arrastável pelo fundo.
    ///
    /// O arraste em si não é sintetizado: `isMovableByWindowBackground` é
    /// atendido por um laço de rastreamento do AppKit que lê a fila real de
    /// eventos do sistema, e um evento fabricado não entra nela. O que este
    /// ensaio pode afirmar sem mentir é o que decide o arraste: a janela
    /// continua marcada como arrastável pelo fundo, e o clique simples não é
    /// engolido por um gesto nosso.
    private func cliqueSimples(at spot: NSPoint) async {
        let antes = window.frame
        driver.click(at: spot, clickCount: 1)
        await settle(0.6)
        RehearsalStage.log(
            "clique simples: \(descrever(window.frame)) — "
            + "\(window.frame == antes ? "sem efeito, como deve ser" : "MEXEU (defeito)")"
        )
        RehearsalStage.log(
            "arrastável pelo fundo: \(window.isMovableByWindowBackground)"
        )
    }

    /// Onde a `CatcherView` está e o que ela sabe. Sem isto o ensaio só diz
    /// "morto" — com isto ele diz **por quê**: ausente da árvore, na moldura
    /// errada ou com o ponto caindo em cima de um controle.
    private func estadoDaCaptura(_ point: NSPoint) -> String {
        guard let root = window.contentView,
              let catcher = Self.procurar(CatcherView.self, in: root) else {
            return "CatcherView ausente da árvore de views"
        }
        let local = catcher.convert(point, from: nil)
        let vazio = TitleBarHitZone.isEmptyArea(
            local, barHeight: catcher.barHeight, controls: catcher.controls
        )
        let molduras = catcher.controls
            .map { "\(Int($0.minX))…\(Int($0.maxX))×\(Int($0.minY))…\(Int($0.maxY))" }
            .joined(separator: " ")
        return "moldura=\(descrever(catcher.frame)) ponto local=\(descrever(local)) "
            + "barra=\(Int(catcher.barHeight)) vazio=\(vazio) controles[\(catcher.controls.count)]: \(molduras)"
    }

    private static func procurar<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for subview in view.subviews {
            if let found = procurar(type, in: subview) { return found }
        }
        return nil
    }

    private func quemPega(_ point: NSPoint) -> String {
        guard let root = window.contentView?.superview ?? window.contentView else {
            return "sem view raiz"
        }
        guard let hit = root.hitTest(root.convert(point, from: nil)) else { return "ninguém" }
        var chain: [String] = []
        var view: NSView? = hit
        while let current = view, chain.count < 6 {
            chain.append(String(describing: type(of: current)))
            view = current.superview
        }
        return chain.joined(separator: " ← ")
    }

    private func descrever(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))×\(Int(rect.height))"
    }

    private func descrever(_ point: NSPoint) -> String {
        "\(Int(point.x)),\(Int(point.y))"
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
