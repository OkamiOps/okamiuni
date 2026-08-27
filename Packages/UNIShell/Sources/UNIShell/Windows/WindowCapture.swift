import SwiftUI
import UNICore

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

    /// Um arquivo por estado, no mesmo diretório do caminho base.
    public func path(for stage: CaptureStage) -> String {
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-\(stage.fileSuffix).png")
            .path
    }

    /// Onde a foto pode ser escrita.
    ///
    /// **O app é sandboxed** (`com.apple.security.app-sandbox`), então `/tmp` e
    /// qualquer caminho fora do contêiner são negados — silenciosamente, do
    /// ponto de vista de quem só olha se o arquivo apareceu. A primeira versão
    /// deste instrumento escrevia em `/tmp` e não produziu nada.
    ///
    /// `NSTemporaryDirectory()` dentro do sandbox aponta para o contêiner do
    /// app, que é escrevível. O caminho absoluto vai para o stderr, e o script
    /// copia de lá para onde o usuário pediu.
    public static var containerFile: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("uni-real.png")
    }

    /// `--capturar` liga a captura. O caminho de destino é resolvido pelo
    /// script, fora do sandbox — aqui a foto vai sempre para o contêiner.
    public static func parse(_ arguments: [String]) -> WindowCapture? {
        for argument in arguments where argument.hasPrefix("--capturar") {
            return WindowCapture(path: containerFile)
        }
        return nil
    }

    public static var fromProcess: WindowCapture? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }
}

extension View {
    /// Liga a captura quando a bandeira estiver presente. Sem ela, não faz nada.
    public func captureWindowIfRequested(
        _ request: WindowCapture?,
        store: MailStore? = nil
    ) -> some View {
        modifier(WindowCaptureModifier(request: request, store: store))
    }
}

private struct WindowCaptureModifier: ViewModifier {
    let request: WindowCapture?
    let store: MailStore?
    @State private var done = false

    func body(content: Content) -> some View {
        content.background(
            CaptureProbe(request: request, store: store, done: $done).frame(width: 0, height: 0)
        )
    }
}

/// Os estados que a captura percorre numa passada só.
///
/// Existe porque cada ida e volta custa uma rodada do dono do projeto: a
/// primeira foto pegou a faixa de resposta **vazia**, com os botões
/// desabilitados, e o defeito que ele relata aparece com eles **ativos**.
/// Pedir outra rodada por estado não é aceitável.
public enum CaptureStage: String, CaseIterable, Sendable {
    /// Como o app abre.
    case inicial
    /// Faixa de resposta com destinatário e texto: os três botões acendem.
    case faixaAtiva

    public var fileSuffix: String { rawValue }
}

/// Precisa de uma `NSView` para alcançar a `NSWindow` de verdade.
private struct CaptureProbe: NSViewRepresentable {
    let request: WindowCapture?
    let store: MailStore?
    @Binding var done: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let request, !done else { return }
        done = true
        // Percorre os estados numa passada: fotografa, muda, espera assentar,
        // fotografa de novo, e só então encerra.
        Task { @MainActor in
            for stage in CaptureStage.allCases {
                try? await Task.sleep(for: .seconds(request.delay))
                prepare(stage)
                try? await Task.sleep(for: .seconds(0.4))
                capture(from: view, to: request.path(for: stage))
            }
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func prepare(_ stage: CaptureStage) {
        guard case .faixaAtiva = stage, let store else { return }
        // Com destinatário e texto os três botões do rodapé da faixa acendem —
        // que é o estado do print do dono.
        guard let message = store.selectedMessage else { return }
        store.setReplyDraft(
            ReplyDraft(to: [message.from], text: "Fechado para quinta às 15h."),
            for: message.id
        )
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
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("captura: PNG falhou\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try png.write(to: url)
        } catch {
            // O sandbox nega sem avisar quem só verifica se o arquivo existe.
            FileHandle.standardError.write(Data("captura: escrita negada em \(path) — \(error)\n".utf8))
            return
        }
        let scale = window.backingScaleFactor
        FileHandle.standardError.write(Data(
            "captura: \(rep.pixelsWide)x\(rep.pixelsHigh) px, escala \(scale), chave \(window.isKeyWindow) -> \(path)\n".utf8
        ))
    }
}
