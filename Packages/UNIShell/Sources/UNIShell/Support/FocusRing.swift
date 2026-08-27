import SwiftUI
import UNIDesign

/// O indicador de foco de teclado, na linguagem do design.
///
/// ## Por que existe
///
/// O dono do projeto relatou três vezes "contorno duplo" nos botões, com print:
/// borda nítida, **folga**, segundo anel — nos quatro lados. Uma das causas era
/// a sombra `inset` desenhada como sombra externa (consertada em `4993e2e`); a
/// que sobrava é o **anel de foco do macOS**, que o AppKit desenha justamente
/// com folga em volta do controle.
///
/// Ele nunca apareceu em nenhuma renderização nossa porque o AppKit só o desenha
/// quando a janela é a **janela-chave** e o app está ativo — e a janela do
/// `Render`, a 50.000pt fora da área visível, nunca é nem uma coisa nem outra.
/// Daí a assimetria: na tela dele aparece, na nossa nunca.
///
/// ## O que fazemos no lugar
///
/// O protótipo não tem anel de foco nenhum: `cursor: default` nos controles e
/// nenhum `outline`. O do sistema é divergência. Mas apagar sem repor deixa quem
/// navega por teclado sem saber onde está — então `focusEffectDisabled()` mata o
/// do sistema e este anel entra no lugar, com três regras:
///
/// 1. **Dentro** da forma do próprio controle, nunca por fora.
/// 2. **Encostado** na borda do controle (recuo = espessura da hairline), para
///    não reabrir a folga que faz o do sistema parecer contorno duplo.
/// 3. Cor do `Theme` — `accent` por padrão, `onAccent` sobre fundo de acento.
///
/// ## Como se verifica sem lançar o app
///
/// Foco não acontece sozinho fora da tela. O parâmetro `forced` força o desenho,
/// no mesmo padrão de `ComposerWindow(store:mode:debugOpenPanel:)`, e o teste
/// renderiza com e sem, comparando os dois bitmaps. Ver `FocusRingTests`.
enum FocusRingMetrics {
    /// Onde o anel começa, medido da borda do controle **para dentro**. É a
    /// espessura da hairline do design: o anel encosta nela em vez de deixar
    /// folga.
    static let inset: CGFloat = Hairline.thickness

    /// Espessura do anel. Um ponto — em 2× dá dois pixels cheios, visível sem
    /// competir com a borda de 0,5.
    static let thickness: CGFloat = 1

    /// Quanto o anel cresce **para fora** do controle. Zero por construção, e é
    /// isso que o separa do anel do sistema.
    static var outwardBleed: CGFloat { 0 }
}

/// Ver `FocusRingMetrics`.
struct FocusRing<S: InsettableShape>: ViewModifier {
    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    let shape: S
    /// Força o anel mesmo sem foco real. Só para verificação fora da tela.
    let forced: Bool
    let tint: KeyPath<Theme, TokenColor>

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            // Mata o anel do sistema, que é o que desenha a folga.
            .focusEffectDisabled()
            .overlay {
                shape
                    .inset(by: FocusRingMetrics.inset)
                    .strokeBorder(
                        theme[keyPath: tint].color,
                        lineWidth: FocusRingMetrics.thickness
                    )
                    .opacity(isFocused || forced ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Troca o anel de foco do sistema pelo do design, numa forma qualquer.
    func focusRing<S: InsettableShape>(
        in shape: S,
        forced: Bool = false,
        tint: KeyPath<Theme, TokenColor> = \.accent
    ) -> some View {
        modifier(FocusRing(shape: shape, forced: forced, tint: tint))
    }

    /// O caso comum: a mesma cápsula arredondada que o controle já usa.
    func focusRing(
        cornerRadius: CGFloat,
        forced: Bool = false,
        tint: KeyPath<Theme, TokenColor> = \.accent
    ) -> some View {
        focusRing(
            in: RoundedRectangle(cornerRadius: cornerRadius),
            forced: forced,
            tint: tint
        )
    }
}
