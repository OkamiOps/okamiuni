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

/// Interno, não `private`: o teste de roteamento chama `hitTest` nela direto.
/// Ver `TitleBarDoubleClickTests`.
final class CatcherView: NSView {
    /// **Tem de responder ao `hitTest`.** Devolvendo `nil` — que era o que ela
    /// fazia — o AppKit nunca roteia `mouseDown:` para cá, `mouseDown` nunca
    /// roda e o duplo clique na barra não fazia nada: o recurso inteiro estava
    /// morto. É `super.hitTest`, e não `self` cravado: assim um `NSView` de
    /// controle **por cima** dela continua ganhando o ponto, que é a ordem
    /// normal do AppKit (subviews do topo para baixo).
    ///
    /// Os controles da barra são desenhados pelo SwiftUI, que resolve o toque
    /// pela ordem em que as views se empilham — a `CatcherView` entra como
    /// `background`, portanto **atrás** de tudo o que a barra desenha. Botão,
    /// aba e busca continuam recebendo o clique deles; ela só fica com a área
    /// vazia.
    ///
    /// O clique simples também não é engolido: `mouseDown` só age no duplo e
    /// repassa o resto ao `super`, que o entrega à janela — é assim que
    /// arrastar a janela pela barra (`isMovableByWindowBackground`) continua
    /// funcionando.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) }

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
