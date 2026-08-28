import SwiftUI
import UNICore
#if canImport(AppKit)
import AppKit
#endif

/// Ensaia o arraste lateral **dentro do app de verdade** e fotografa cada fase.
///
/// ## Por que existe
///
/// O gesto foi consertado três vezes no modelo e no harness — e o dono do
/// projeto continuou vendo a linha não parar, disparar sozinha e acender os
/// dois lados. A ordem dele foi literal: "pega essa porra, abre o app e tenta
/// arrastar pro lado que tu vai entender". Este instrumento faz exatamente
/// isso, sem tocar no mouse nem no teclado da máquina: os eventos de mouse são
/// sintetizados **dentro do processo** e entregues à janela por
/// `NSWindow.sendEvent(_:)` — o mesmo cano por onde um arrasto real chega ao
/// `DragGesture` — e a janela se fotografa a cada fase, como `WindowCapture`.
///
/// `open -g --args --ensaiar-arraste` liga; sem a bandeira, nada acontece.
public struct SwipeRehearsal: Sendable {
    public static func parse(_ arguments: [String]) -> SwipeRehearsal? {
        arguments.contains("--ensaiar-arraste") ? SwipeRehearsal() : nil
    }

    public static var fromProcess: SwipeRehearsal? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }

    /// O contêiner é o único lugar em que o sandbox deixa escrever.
    static func framePath(_ index: Int, _ name: String) -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent(String(format: "ensaio-%02d-%@.png", index, name))
    }
}

extension View {
    public func rehearseSwipeIfRequested(_ request: SwipeRehearsal?) -> some View {
        modifier(SwipeRehearsalModifier(request: request))
    }
}

private struct SwipeRehearsalModifier: ViewModifier {
    let request: SwipeRehearsal?
    @State private var started = false

    func body(content: Content) -> some View {
        content.background(
            RehearsalProbe(request: request, started: $started).frame(width: 0, height: 0)
        )
    }
}

private struct RehearsalProbe: NSViewRepresentable {
    let request: SwipeRehearsal?
    @Binding var started: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard request != nil, !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard let window = view.window else {
                rehearsalLog("ensaio: sem janela"); NSApp.terminate(nil); return
            }
            await Driver(window: window).run()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private final class Driver {
    let window: NSWindow
    var eventNumber = 40_000
    var frame = 0

    init(window: NSWindow) { self.window = window }

    /// Ponto de partida: dentro da lista de mensagens, na primeira linha.
    /// Lista começa depois da lateral (236); a primeira linha fica logo sob o
    /// cabeçalho da lista. Em coordenadas AppKit o y cresce para cima.
    var start: NSPoint {
        let bounds = window.contentView?.bounds ?? .zero
        return NSPoint(x: 300, y: bounds.height - 150)
    }

    func run() async {
        await shoot("inicio")

        // Gesto 1: abre para a direita (+200) e solta — tem de ficar PARADA.
        await drag(from: start, dx: 200, steps: 25, label: "g1")
        await shoot("g1-solto-descanso")
        try? await Task.sleep(for: .seconds(0.6))
        await shoot("g1-descanso-estavel")

        // Gesto 2: na linha aberta, arrasta de volta (-120) e solta — tem de
        // FECHAR sem acender o lado direito.
        await drag(from: start, dx: -120, steps: 15, label: "g2", midShot: "g2-meio")
        await shoot("g2-solto-fechada")
        try? await Task.sleep(for: .seconds(0.5))

        // Gesto 3: arraste longo (+320) — a inundação tem de aparecer antes de
        // soltar, e soltar dispara a primeira ação com o recibo de Desfazer.
        await drag(from: start, dx: 320, steps: 30, label: "g3", midShot: "g3-inundada")
        await shoot("g3-solto-disparo")
        try? await Task.sleep(for: .seconds(0.8))
        await shoot("g3-recibo")
    }

    /// Um arrasto completo: down, N drags espaçados, up. Fotografa no meio e
    /// imediatamente antes do up.
    func drag(from origin: NSPoint, dx: CGFloat, steps: Int, label: String, midShot: String? = nil) async {
        post(.leftMouseDown, at: origin)
        for i in 1...steps {
            let p = NSPoint(x: origin.x + dx * CGFloat(i) / CGFloat(steps), y: origin.y)
            post(.leftMouseDragged, at: p)
            try? await Task.sleep(for: .milliseconds(12))
            if let midShot, i == steps / 2 { await shoot(midShot) }
        }
        await shoot("\(label)-antes-de-soltar")
        post(.leftMouseUp, at: NSPoint(x: origin.x + dx, y: origin.y))
        try? await Task.sleep(for: .milliseconds(120))
    }

    func post(_ type: NSEvent.EventType, at p: NSPoint) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type, location: p, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { rehearsalLog("ensaio: evento \(type) falhou"); return }
        window.sendEvent(event)
    }

    func shoot(_ name: String) async {
        // Uma volta do runloop para o SwiftUI desenhar o que o evento causou.
        try? await Task.sleep(for: .milliseconds(60))
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            rehearsalLog("ensaio: sem bitmap para \(name)"); return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        frame += 1
        let path = SwipeRehearsal.framePath(frame, name)
        do {
            try png.write(to: URL(fileURLWithPath: path))
            rehearsalLog("ensaio: \(path)")
        } catch {
            rehearsalLog("ensaio: escrita negada em \(path) — \(error)")
        }
    }
}

private func rehearsalLog(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
