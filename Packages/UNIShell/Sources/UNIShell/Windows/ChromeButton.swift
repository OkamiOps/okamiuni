import SwiftUI
import UNIDesign

/// Os botões dos rodapés das janelas. O protótipo escreve o mesmo bloco de CSS
/// quatro ou cinco vezes por tela, com três aparências:
///
/// - `accent`: `background: var(--accent); color: var(--on-accent); font-weight: 600`
/// - `enter`: ciano cheio — "Entrar" na reunião
/// - `remove`: magenta cheio — cancelar reunião ou tirar do calendário
/// - `outlined`: `border: 0.5px solid var(--btn-line); background: var(--btn);
///   box-shadow: var(--btn-shadow)`, com hover em `--accent`
/// - `quiet`: `background: var(--surface3); color: var(--ink3)`, sem borda
///
/// `outlinedOn` é o "Encaminhar" enquanto o painel está aberto (borda, fundo e
/// tinta trocados pelo acento); `muted` é o botão de enviar sem ninguém no campo.
struct ChromeButton<Label: View>: View {
    enum Appearance {
        case accent
        case enter
        case remove
        case outlined
        case outlinedOn
        case quiet
        case muted
    }

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var hovering = false

    let appearance: Appearance
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = 14
    /// Corpo do rótulo, do protótipo. `nil` deixa o rótulo escolher o próprio.
    var labelSize: CGFloat? = 12.5
    var labelWeight: Font.Weight = .medium  // CSS 550
    /// Força o anel de foco. Só para verificação fora da tela — ver `FocusRing`.
    var debugFocused = false
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(labelSize.map { theme.sans.font(size: $0, weight: labelWeight) })
                .lineLimit(1)
                .frame(height: height)
                .padding(.horizontal, horizontalPadding)
                .foregroundStyle(foreground)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        // Um pixel do dispositivo — ver `Hairline.thickness(_:)`.
                        // Meio ponto numa tela 1× vira meio pixel lavado, e a
                        // borda do botão saía `rgb(227,225,219)` onde o design
                        // mostra `rgb(218,214,206)`.
                        .strokeBorder(border, lineWidth: Hairline.thickness(displayScale))
                }
                .shadow(shadow)
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, forced: debugFocused, tint: focusTint)
        .onHover { hovering = $0 }
    }

    /// Sobre o acento cheio, um anel no próprio acento seria invisível: ali o
    /// contraste é a tinta que o design já usa em cima dele.
    private var focusTint: KeyPath<Theme, TokenColor> {
        switch appearance {
        case .accent: \.onAccent
        case .enter: \.onEnter
        case .remove: \.onRemove
        default: \.focus
        }
    }

    private var foreground: Color {
        switch appearance {
        case .accent: theme.onAccent.color
        case .enter: theme.onEnter.color
        case .remove: theme.onRemove.color
        case .outlined: hovering ? theme.accentInk.color : theme.ink2.color
        case .outlinedOn: theme.accentInk.color
        case .quiet: hovering ? theme.ink.color : theme.ink3.color
        case .muted: theme.ink4.color
        }
    }

    private var background: Color {
        switch appearance {
        case .accent: theme.accent.color
        case .enter: theme.enter.color
        case .remove: theme.remove.color
        case .outlined: theme.btn.color
        case .outlinedOn: theme.accentSoft.color
        case .quiet: hovering ? theme.line2.color : theme.surface3.color
        case .muted: theme.surface3.color
        }
    }

    private var border: Color {
        switch appearance {
        case .accent, .enter, .remove: .clear
        case .outlined: hovering ? theme.accent.color : theme.btnLine.color
        case .outlinedOn: theme.accent.color
        case .quiet: .clear
        case .muted: theme.line.color
        }
    }

    private var shadow: [ShadowToken] {
        switch appearance {
        case .outlined, .outlinedOn: theme.btnShadow
        case .accent, .enter, .remove, .quiet, .muted: []
        }
    }
}

extension ChromeButton where Label == Text {
    /// O caso comum: um rótulo de texto só.
    init(
        _ title: String,
        appearance: Appearance,
        size: CGFloat = 12.5,
        weight: Font.Weight = .medium,
        height: CGFloat = 32,
        horizontalPadding: CGFloat = 14,
        debugFocused: Bool = false,
        action: @escaping () -> Void
    ) {
        self.appearance = appearance
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.labelSize = size
        self.labelWeight = weight
        self.debugFocused = debugFocused
        self.action = action
        self.label = Text(title)
    }
}
