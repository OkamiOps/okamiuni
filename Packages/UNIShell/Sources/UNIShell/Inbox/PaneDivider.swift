import SwiftUI
import UNIDesign
import UNICore

/// O alvo de arraste de uma divisória vertical entre dois painéis.
///
/// ## Por que ela não desenha a linha
///
/// A linha já existe: cada painel pinta a sua própria `hairline` de 0.5pt na
/// borda (`MessageList` na `trailing`, `AgendaRail` na `leading`). Esta `View`
/// não repinta nada em repouso — se pintasse, ficariam duas linhas em cima uma
/// da outra, e a de 0.5pt do design tem regras de alinhamento de pixel que a
/// `Hairline` já resolveu. Ela só acrescenta o realce de 2pt quando o ponteiro
/// chega ou o arraste começa, para o usuário ver o que está agarrando.
///
/// ## Por que ela não ocupa largura
///
/// Um painel de 6pt entre a lista e o leitor deslocaria a tela inteira em 6pt e
/// quebraria o ponto de fidelidade da Task P. Por isso o `InboxScreen` a coloca
/// como sobreposição posicionada por `offset`, fora do `HStack`: o alvo tem 6pt
/// de largura para o mouse e 0 para o layout.
public struct PaneDivider: View {
    /// Largura do alvo de arraste.
    ///
    /// A linha desenhada tem `Hairline.thickness` — meio ponto. Um alvo de meio
    /// ponto é impossível de acertar com o mouse: exigiria acertar a coluna de
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
        Color.clear
            .frame(width: Self.hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(highlight)
            // Cursor de redimensionamento horizontal. `columnResize` é
            // exatamente o que o AppKit mostra na calha de um `NSSplitView`
            // vertical, e o modificador se equilibra sozinho — nada de
            // `NSCursor.push()` sem o `pop()` correspondente quando o painel
            // some com o ponteiro em cima.
            .pointerStyle(.columnResize)
            .onHover { isHovering = $0 }
            // Antes do arraste: um `DragGesture` com `minimumDistance` maior
            // que zero deixa o duplo clique passar.
            .onTapGesture(count: 2, perform: onReset)
            .gesture(
                // O espaço nomeado é obrigatório aqui, não um refinamento: ver
                // `coordinateSpace` acima. No espaço local a divisória anda
                // metade do que o cursor anda.
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { value in
                        isDragging = true
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEnd()
                    }
            )
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
    }
}
