import SwiftUI
import UNIDesign

/// A etiqueta em versalete que o protótipo usa para hosts de conta e para as
/// marcas das mensagens. Lá ela é uma função só — `chip(color, on)` —, então
/// aqui também: a barra lateral, a lista e o leitor desenham a mesma coisa.
///
/// Protótipo (`chip(c, on)`):
/// ```
/// font-family: var(--mono); font-size: 9px; letter-spacing: 0.06em;
/// text-transform: uppercase; padding: 2px 6px 1.5px; border-radius: 4px;
/// color: c; background: soft(c, on ? 22 : 14); border: 0.5px solid soft(c, 32);
/// ```
///
/// O `letter-spacing` é 0.06em **literal**, não `var(--caps)` — quem usar
/// `theme.capsTracking(at:)` aqui dobra o espaçamento nos temas de caps largo.
/// Sem largura fixa: o chip mede o próprio texto, como no protótipo (`flex: none`).
public struct TintChip: View {
    /// `0.06em` do protótipo, em em. Multiplicado pelo corpo vira ponto.
    public static let trackingEm: CGFloat = 0.06
    /// `font-size: 9px` do protótipo.
    public static let fontSize: CGFloat = 9
    /// `border-radius: 4px` do protótipo — literal lá, literal aqui.
    public static let cornerRadius: CGFloat = 4

    let label: String
    let tint: Color
    let emphasized: Bool

    public init(label: String, tint: Color, emphasized: Bool = false) {
        self.label = label
        self.tint = tint
        self.emphasized = emphasized
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        Text(label)
            .font(theme.mono.font(size: Self.fontSize, weight: .medium))
            .tracking(Self.trackingEm * Self.fontSize)  // 0.06em × 9pt = 0.54pt
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .padding(.bottom, 1.5)
            .background(tint.opacity(emphasized ? 0.22 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(tint.opacity(0.32), lineWidth: 0.5)
            }
            .fixedSize()
    }
}
