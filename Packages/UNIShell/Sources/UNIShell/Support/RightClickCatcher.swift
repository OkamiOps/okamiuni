import AppKit
import SwiftUI

/// Pega o **botão direito** sobre uma superfície sem tirar nada do que já
/// funcionava nela.
///
/// ## Por que não dá para fazer isto em SwiftUI
///
/// O SwiftUI não tem gesto de botão direito. `onTapGesture` só conhece o
/// esquerdo, e `contextMenu` — a única porta que existia — é justamente o que
/// esta tarefa está tirando: ele monta um `NSMenu`. Então a captura desce ao
/// AppKit.
///
/// ## O que não pode quebrar, e como isto garante
///
/// A linha da lista tem, no mesmo pedaço de tela, um `Button` (selecionar), um
/// `TapGesture(count: 2)` (abrir em janela) e um `DragGesture`
/// (`MessageSwipe`). Uma `NSView` opaca por cima roubaria os três.
///
/// A saída é o `hitTest`: esta `View` **só existe para o mouse quando o evento
/// corrente é de botão direito** (ou o Control-clique, que no macOS é o mesmo
/// gesto). Para qualquer outro evento ela devolve `nil`, e o AppKit segue
/// procurando — cai na `NSHostingView`, que faz o teste de acerto do SwiftUI
/// como sempre fez. Clique, duplo clique e arraste não veem diferença nenhuma:
/// o `DragGesture` do arraste lateral continua acompanhando só o botão
/// esquerdo, e o botão direito continua sem engatá-lo.
///
/// `menu(for:)` devolve `nil` de propósito: é a porta pela qual uma `NSView`
/// entrega um `NSMenu` ao sistema, e nenhuma superfície deste app entrega mais.
struct RightClickCatcher: NSViewRepresentable {
    /// Chamado com o ponto do clique em coordenadas de **tela** e a janela de
    /// origem.
    let onRightClick: (CGPoint, NSWindow?) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        // O fechamento carrega as entradas do menu, que mudam com o estado da
        // mensagem. Trocar a cada atualização é o que mantém "Marcar como não
        // lida" coerente com a linha.
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint, NSWindow?) -> Void)?

        /// Ver a nota do tipo: invisível para tudo que não é botão direito.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            fire(event)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else {
                super.mouseDown(with: event)
                return
            }
            fire(event)
        }

        /// Nenhuma superfície deste app oferece `NSMenu` ao sistema.
        override func menu(for event: NSEvent) -> NSMenu? { nil }

        private func fire(_ event: NSEvent) {
            // `NSEvent.mouseLocation` já é tela, e é a mesma referência em que
            // `NSScreen.visibleFrame` e `NSWindow.setFrame` falam. Converter à
            // mão pela janela seria uma chance a mais de errar o sinal do y.
            onRightClick?(NSEvent.mouseLocation, event.window ?? window)
        }
    }
}
