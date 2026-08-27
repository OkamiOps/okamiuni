import SwiftUI
import UNIDesign
import UNICore

public struct MessageRow: View {
    @Environment(\.theme) private var theme
    let message: Message
    let accountHost: String
    let isSelected: Bool

    public init(message: Message, accountHost: String, isSelected: Bool) {
        self.message = message
        self.accountHost = accountHost
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.from.name)
                    .font(theme.sans.font(size: 12.5, weight: message.isRead ? .regular : .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(message.receivedAt, format: .dateTime.hour().minute())
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }

            Text(message.subject)
                .font(theme.body.font(size: theme.subjectSize, weight: theme.subjectWeight))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)

            Text(message.snippet)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                Text(accountHost)
                    .font(theme.mono.font(size: 9))
                    .foregroundStyle(theme.ink4.color)
                ForEach(message.tags) { tag in
                    TagChip(tag: tag)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(theme.rowPadding.edgeInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? theme.accentSoft.color : .clear)
        .hairline(theme.line2, edges: .bottom)
        .contentShape(Rectangle())
    }
}

struct TagChip: View {
    @Environment(\.theme) private var theme
    let tag: Tag

    var body: some View {
        let tint = tag.tintHex.flatMap(TokenColor.init(css:)) ?? theme.ink3
        Text(tag.name)
            .font(theme.mono.font(size: 8.5, weight: .medium))
            .tracking(theme.capsTracking(at: 8.5))
            .textCase(.uppercase)
            .foregroundStyle(tint.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
