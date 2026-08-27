import SwiftUI
import UNIDesign
import UNICore

public struct MessageRow: View {
    /// A barra colorida da conta na borda esquerda da linha.
    /// Protótipo: `box-shadow: inset 3px 0 0 (on ? a.c : soft(a.c, 45))` —
    /// ela existe em **toda** linha, só muda de opacidade quando selecionada.
    static let accountBarWidth: CGFloat = 3

    @Environment(\.theme) private var theme
    let message: Message
    let accountHost: String
    let accountTint: Color
    let isSelected: Bool

    public init(message: Message, accountHost: String, accountTint: Color, isSelected: Bool) {
        self.message = message
        self.accountHost = accountHost
        self.accountTint = accountTint
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {  // protótipo: margin-top: 3px
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.from.name)
                    .font(theme.sans.font(size: 13, weight: message.isRead ? .regular : .semibold))
                    .tracking(-0.005 * 13)  // letter-spacing: -0.005em a 13pt = -0.065pt
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(message.receivedAt, format: .dateTime.hour().minute())
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }

            Text(message.subject)
                .font(theme.body.font(size: theme.subjectSize, weight: theme.subjectWeight))
                .lineSpacing(0.35 * theme.subjectSize)  // line-height 1.35
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)

            Text(message.snippet)
                .font(theme.sans.font(size: 11.5))
                .lineSpacing(0.45 * 11.5)  // line-height 1.45 × 11.5 − 11.5 = 5.175
                .foregroundStyle(theme.ink3.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                TintChip(label: accountHost, tint: accountTint, emphasized: isSelected)
                ForEach(message.tags) { tag in
                    TagChip(tag: tag)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 5)  // 3 do VStack + 5 = os 8 do `margin-top` do protótipo
        }
        .padding(theme.rowPadding.edgeInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Protótipo: `background: soft(a.c, 10)` quando selecionada — a cor da
        // conta, não o accent do tema.
        .background(isSelected ? accountTint.opacity(0.10) : .clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accountTint.opacity(isSelected ? 1 : 0.45))
                .frame(width: Self.accountBarWidth)
        }
        .hairline(theme.line2, edges: .bottom)
        .contentShape(Rectangle())
    }
}

struct TagChip: View {
    @Environment(\.theme) private var theme
    let tag: Tag

    var body: some View {
        let tint = tag.tintHex.flatMap(TokenColor.init(css:)) ?? theme.ink3
        // O protótipo desenha as marcas com o mesmo `chip()` do host da conta.
        TintChip(label: tag.name, tint: tint.color)
    }
}
