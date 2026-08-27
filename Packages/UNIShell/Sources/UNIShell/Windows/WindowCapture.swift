import SwiftUI

/// Fotografa a própria janela e encerra o app.
///
/// ## Por que existe
///
/// Um defeito de contorno que o dono do projeto vê na tela dele **não aparece**
/// em nenhuma renderização fora da tela. Já custou duas hipóteses erradas
/// minhas. A diferença é o que só existe numa janela de verdade: ser a
/// janela-chave de um app ativo, o fundo real da janela, e a escala da tela.
///
/// Em vez de continuar supondo, o app passa a entregar os próprios pixels:
///
/// ```
/// ./Tools/rodar.sh --capturar
/// ```
///
/// A janela aparece por cerca de um segundo, é fotografada pelo caminho normal
/// de desenho do AppKit — que inclui tudo que o AppKit desenha por cima, anel de
/// foco entre outras coisas — e o app encerra sozinho. Não toma mouse nem
/// teclado, e não fica aberto.
public struct WindowCapture: Sendable {
    public let path: String
    /// Segundos de espera antes de fotografar, para o layout assentar.
    public let delay: Double

    public init(path: String, delay: Double = 1.2) {
        self.path = path
        self.delay = delay
    }

    /// `--capturar=/caminho.png`, ou `--capturar` sozinho para o padrão.
    public static func parse(_ arguments: [String]) -> WindowCapture? {
        for argument in arguments where argument.hasPrefix("--capturar") {
            let value = argument.contains("=")
                ? String(argument.drop { $0 != "=" }.dropFirst())
                : ""
            return WindowCapture(path: value.isEmpty ? "/tmp/uni-real.png" : value)
        }
        return nil
    }

    public static var fromProcess: WindowCapture? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }
}

extension View {
    /// Liga a captura quando a bandeira estiver presente. Sem ela, não faz nada.
    public func captureWindowIfRequested(_ request: WindowCapture?) -> some View {
        modifier(WindowCaptureModifier(request: request))
    }
}

private struct WindowCaptureModifier: ViewModifier {
    let request: WindowCapture?
    @State private var done = false

    func body(content: Content) -> some View {
        content.background(
            CaptureProbe(request: request, done: $done).frame(width: 0, height: 0)
        )
    }
}

/// Precisa de uma `NSView` para alcançar a `NSWindow` de verdade.
private struct CaptureProbe: NSViewRepresentable {
    let request: WindowCapture?
    @Binding var done: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let request, !done else { return }
        done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + request.delay) {
            capture(from: view, to: request.path)
            NSApp.terminate(nil)
        }
    }

    private func capture(from view: NSView, to path: String) {
        guard let window = view.window, let content = window.contentView else {
            FileHandle.standardError.write(Data("captura: sem janela\n".utf8))
            return
        }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            FileHandle.standardError.write(Data("captura: sem bitmap\n".utf8))
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        let scale = window.backingScaleFactor
        FileHandle.standardError.write(Data(
            "captura: \(rep.pixelsWide)x\(rep.pixelsHigh) px, escala \(scale), chave \(window.isKeyWindow) -> \(path)\n".utf8
        ))
    }
}
