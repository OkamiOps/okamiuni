import SwiftUI
import AppKit

/// Faz o duplo clique na nossa barra respeitar o ajuste do sistema.
///
/// Numa janela `.hiddenTitleBar` a barra de título nativa fica atrás do nosso
/// conteúdo, então o duplo clique nunca chega nela e a janela não faz o que o
/// usuário configurou em Ajustes do Sistema ▸ Área de Trabalho e Dock ▸
/// "Clicar duas vezes na barra de título de uma janela para".
///
/// O ajuste vive em `AppleActionOnDoubleClick` e tem três valores: `Maximize`
/// (o padrão, que é o "preencher a tela"), `Minimize` e `None`. Respeitamos os
/// três — cravar zoom ignoraria quem escolheu minimizar.
struct TitleBarDoubleClick: ViewModifier {
    func body(content: Content) -> some View {
        content.background(DoubleClickCatcher())
    }
}

extension View {
    func titleBarDoubleClick() -> some View {
        modifier(TitleBarDoubleClick())
    }
}

private struct DoubleClickCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CatcherView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class CatcherView: NSView {
    /// Deixa passar o clique simples: arrastar a janela pela barra continua
    /// funcionando, e os controles por cima recebem os cliques deles.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isMovableByWindowBackground = true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        Self.performSystemAction(on: window)
    }

    static func performSystemAction(on window: NSWindow?) {
        guard let window else { return }
        let setting = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch DoubleClickAction.forSystemSetting(setting) {
        case .zoom: window.performZoom(nil)
        case .miniaturize: window.performMiniaturize(nil)
        case .none: break
        }
    }
}


/// O que o duplo clique faz, segundo o ajuste do sistema. Fora da `View` para
/// poder ser testado — um `NSView` não se instancia num teste sem janela.
enum DoubleClickAction: Equatable {
    case zoom, miniaturize, none

    /// `AppleActionOnDoubleClick`. Ausente ou desconhecido cai em `zoom`, que é
    /// o padrão de fábrica do macOS — nunca em `none`, que deixaria a janela
    /// muda sem ninguém ter pedido.
    static func forSystemSetting(_ value: String?) -> DoubleClickAction {
        switch value {
        case "Minimize": .miniaturize
        case "None": .none
        default: .zoom
        }
    }
}
