import SwiftUI
import UNIDesign

/// Os quatro botões de 26pt do cabeçalho da agenda: `‹`, `›`, "Hoje" e o que
/// abre o seletor de data (protótipo, linhas 1404–1407 e `pickerBtnStyle` na
/// 2373).
///
/// Não é o `ChromeButton` das janelas por dois motivos que se somam: aquele é
/// de 32pt com tinta `ink2`, e o seletor fechado é `ink` — um token de
/// diferença, mas é o único botão da faixa que fica mais escuro que os
/// vizinhos, e apagar isso apagaria a hierarquia que o desenho deu a ele. O
/// segundo motivo é de fronteira: `ChromeButton` mora em `Windows/`, que outra
/// tarefa está editando agora.
struct CalendarButton<Label: View>: View {

    /// Protótipo: os três primeiros compartilham
    /// `border: 0.5px solid var(--btn-line); background: var(--btn);
    /// box-shadow: var(--btn-shadow)`, com hover trocando borda e tinta pelo
    /// acento. O seletor aberto troca os três de vez.
    enum Appearance {
        /// `‹`, `›`, "Hoje" — tinta `ink2`.
        case quiet
        /// O seletor fechado — mesma moldura, tinta `ink`.
        case strong
        /// O seletor aberto: `accent-soft` sob `accent-ink`, borda no acento.
        case active
    }

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var hovering = false

    let appearance: Appearance
    /// Protótipo: `width: 26px` nas setas, `padding: 0 10/11px` nos outros.
    var width: CGFloat?
    var horizontalPadding: CGFloat
    let action: () -> Void
    @ViewBuilder var label: Label

    /// Protótipo: `height: 26px` nos quatro.
    private static var height: CGFloat { 26 }

    var body: some View {
        Button(action: action) {
            label
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(width: width, height: Self.height)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        // Um pixel do dispositivo. `strokeBorder` com meio ponto
                        // pinta com alfa parcial em vez de arredondar, e a borda
                        // sai lavada — ver `Hairline.thickness(_:)`.
                        .strokeBorder(border, lineWidth: Hairline.thickness(displayScale))
                }
                .shadow(theme.btnShadow)
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch appearance {
        case .quiet: hovering ? theme.accentInk.color : theme.ink2.color
        case .strong: hovering ? theme.accentInk.color : theme.ink.color
        case .active: theme.accentInk.color
        }
    }

    private var background: Color {
        appearance == .active ? theme.accentSoft.color : theme.btn.color
    }

    private var border: Color {
        switch appearance {
        case .active: theme.accent.color
        case .quiet, .strong: hovering ? theme.accent.color : theme.btnLine.color
        }
    }
}
