import AppKit
import SwiftUI
import UNIDesign
import UNICore

/// O alvo de arraste de uma divisória vertical entre dois painéis.
///
/// ## Por que ela não desenha a linha
///
/// A linha já existe: cada painel pinta a sua própria `hairline` na borda
/// (`MessageList` na `trailing`, `AgendaRail` na `leading`). Esta `View` não
/// repinta nada em repouso — se pintasse, ficariam duas linhas em cima uma da
/// outra, e a hairline do design tem regras de espessura e alinhamento de pixel
/// que a `Hairline` já resolveu. Ela só acrescenta o realce de 2pt quando o
/// ponteiro chega ou o arraste começa, para o usuário ver o que está agarrando.
///
/// ## Por que ela não ocupa largura
///
/// Um painel de 6pt entre a lista e o leitor deslocaria a tela inteira em 6pt e
/// quebraria o ponto de fidelidade da Task P. Por isso o `InboxScreen` a coloca
/// como sobreposição posicionada por `offset`, fora do `HStack`: o alvo tem 6pt
/// de largura para o mouse e 0 para o layout.
///
/// ## Por que é `NSView`, não `DragGesture`
///
/// A janela é `isMovableByWindowBackground`. `Color.clear` no SwiftUI não é
/// opaco, então o AppKit trata o clique na calha como arraste **da janela** —
/// o app inteiro anda e a divisória não. `mouseDownCanMoveWindow = false` é o
/// interruptor que o `NSSplitView` usa; o `NSView` abaixo faz o mesmo.
public struct PaneDivider: View {
    /// Largura do alvo de arraste.
    ///
    /// A linha desenhada tem **um pixel do dispositivo** — um ponto numa tela
    /// 1×, meio ponto numa 2× (ver `Hairline.thickness(_:)`). Um alvo de um
    /// pixel é impossível de acertar com o mouse: exigiria acertar a coluna de
    /// pixels exata, e o ponteiro do macOS nem reporta essa precisão. Seis
    /// pontos é o que o próprio `NSSplitView` usa como zona de agarrar, e é a
    /// menor medida em que o gesto vira confiável.
    public nonisolated static let hitWidth: CGFloat = 6

    /// Nome do espaço de coordenadas em que a translação do arraste é medida.
    ///
    /// Sem isto o `DragGesture` mede no espaço **local**, que é o da própria
    /// calha — e a calha é desenhada exatamente sobre a borda que o arraste
    /// está movendo. Ela corre atrás do cursor, o referencial corre junto, e a
    /// translação medida vira a metade da real: arrastar 120pt movia a
    /// divisória 60, arrastar −150 movia −72. Na mão isso é a divisória
    /// "resistindo" ao ponteiro e descolando dele.
    ///
    /// O `InboxScreen` ancora este nome no retângulo do conteúdo da janela, que
    /// não se mexe durante o gesto. Quem mudar isso precisa conferir que o
    /// ancestral escolhido de fato está parado: ancorar num que também se
    /// desloca traz o defeito de volta, só que menor e mais difícil de ver.
    public nonisolated static let coordinateSpace = "okamiuni.panes"

    /// Onde a calha de 6pt começa para ficar **centrada** na linha em
    /// `boundaryX`. Centrada, e não encostada de um lado: o ponteiro chega à
    /// divisória pelos dois painéis, e um alvo colado só no painel da esquerda
    /// obrigaria a mirar 3pt à esquerda da linha que se vê.
    ///
    /// `nonisolated` de propósito: `PaneDivider` é uma `View` e portanto
    /// `@MainActor` no Swift 6; sem isto, um teste nonisolated que chamasse este
    /// `static` trapava em runtime.
    public nonisolated static func leadingEdge(centeredOn boundaryX: CGFloat) -> CGFloat {
        boundaryX - hitWidth / 2
    }

    /// Espessura do realce de hover. Deliberadamente maior que a hairline: o
    /// realce é uma resposta ao ponteiro, não uma divisória a mais.
    nonisolated static let highlightThickness: CGFloat = 2

    @Environment(\.theme) private var theme

    /// Translação horizontal acumulada desde o início do gesto, em pontos.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    /// Duplo clique: volta à largura canônica.
    let onReset: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    public init(
        onDrag: @escaping (CGFloat) -> Void,
        onEnd: @escaping () -> Void = {},
        onReset: @escaping () -> Void = {}
    ) {
        self.onDrag = onDrag
        self.onEnd = onEnd
        self.onReset = onReset
    }

    public var body: some View {
        PaneDividerHandle(
            onDrag: { translation in
                isDragging = true
                onDrag(translation)
            },
            onEnd: {
                isDragging = false
                onEnd()
            },
            onReset: onReset,
            onHover: { isHovering = $0 }
        )
        .frame(width: Self.hitWidth)
        .frame(maxHeight: .infinity)
        .overlay(highlight)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Divisória de painel")
        .accessibilityHint("Arraste para redimensionar. Duplo clique volta à largura padrão.")
    }

    private var highlight: some View {
        Rectangle()
            .fill(isDragging ? theme.accent.color : theme.line.color)
            .frame(width: Self.highlightThickness)
            .opacity(isHovering || isDragging ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// Calha nativa: o clique não move a janela.
private struct PaneDividerHandle: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void
    var onReset: () -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        context.coordinator.onDrag = onDrag
        context.coordinator.onEnd = onEnd
        context.coordinator.onReset = onReset
        context.coordinator.onHover = onHover
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onReset: () -> Void = {}
        var onHover: (Bool) -> Void = { _ in }
        var originX: CGFloat = 0
    }

    final class Catcher: NSView {
        var coordinator: Coordinator?

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            coordinator?.onHover(true)
        }

        override func mouseExited(with event: NSEvent) {
            coordinator?.onHover(false)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                coordinator?.onReset()
                return
            }
            coordinator?.originX = event.locationInWindow.x
            coordinator?.onDrag(0)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let coordinator else { return }
            coordinator.onDrag(event.locationInWindow.x - coordinator.originX)
        }

        override func mouseUp(with event: NSEvent) {
            coordinator?.onEnd()
        }
    }
}
