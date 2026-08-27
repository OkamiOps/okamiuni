import SwiftUI
import UNIDesign
import UNICore

/// Um dia de mensagens, com o rótulo que a lista mostra no cabeçalho.
public struct MessageGroup: Identifiable {
    public let id: String
    public let label: String
    public let messages: [Message]

    /// Agrupa por dia preservando a ordem que veio (mais recente primeiro).
    public static func build(
        from messages: [Message],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [MessageGroup] {
        guard !messages.isEmpty else { return [] }

        var order: [Date] = []
        var byDay: [Date: [Message]] = [:]
        for message in messages {
            let day = calendar.startOfDay(for: message.receivedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(message)
        }

        return order.map { day in
            MessageGroup(
                id: ISO8601DateFormatter().string(from: day),
                label: label(for: day, calendar: calendar, now: now),
                messages: byDay[day] ?? []
            )
        }
    }

    private static func label(for day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDateInToday(day) { return "Hoje" }
        if calendar.isDateInYesterday(day) { return "Ontem" }
        return day.formatted(.dateTime.day().month(.abbreviated))
    }
}

public struct MessageList: View {
    public static let width: CGFloat = 370

    @Environment(\.theme) private var theme
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    /// Formata o rótulo de contagem de mensagens com plural correto.
    public static func messageCountLabel(_ count: Int) -> String {
        count == 1 ? "1 mensagem" : "\(count) mensagens"
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .frame(width: Self.width)
        .background(theme.surface.color)
        .hairline(theme.line, edges: .trailing)
    }

    /// Protótipo: `height: 40px; padding: 0 16px; align-items: baseline; gap: 8px;
    /// border-bottom: 0.5px solid var(--line2)` sobre `var(--surface)`, com o
    /// título em `var(--serif)` 16/600 e a contagem em `var(--mono)` 10.
    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(theme.serif.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.messageCountLabel(store.visibleMessages.count))
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(theme.surface.color)
        .hairline(theme.line2, edges: .bottom)
    }

    /// A cor da conta, que a linha usa na barra da borda e no chip do host.
    /// Sem `switch` sobre provedores: vem do que a conta declarar.
    private func accountTint(_ account: Account?) -> Color {
        account
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.ink3.color
    }

    private var headerTitle: String {
        if let selectedAccountID = store.selectedAccountID,
           let account = store.account(selectedAccountID) {
            return account.host
        }
        return store.bucket.label
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(MessageGroup.build(from: store.visibleMessages)) { group in
                    Section {
                        ForEach(group.messages) { message in
                            let account = store.account(message.accountID)
                            Button { store.select(message: message.id) } label: {
                                MessageRow(
                                    message: message,
                                    accountHost: account?.host ?? "",
                                    accountTint: accountTint(account),
                                    isSelected: message.id == store.selectedMessageID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        // Protótipo: `padding: 9px 16px 5px;` e `font-size: 9.5px`.
                        Text(group.label)
                            .capsLabel(size: 9.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 9)
                            .padding(.bottom, 5)
                            .background(theme.surface.color)
                    }
                }
            }
            footer
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Text(store.visibleMessages.isEmpty ? "Nada nesta caixa agora." : "Fim da lista")
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink4.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 44)
    }
}
