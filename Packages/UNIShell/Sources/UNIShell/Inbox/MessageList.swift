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
            if store.visibleMessages.isEmpty {
                Spacer()
            } else {
                list
            }
            footer
        }
        .frame(width: Self.width)
        .background(theme.surface.color)
        .hairline(theme.line, edges: .trailing)
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Spacer()
            Text(Self.messageCountLabel(store.visibleMessages.count))
                .font(theme.mono.font(size: 9.5))
                .foregroundStyle(theme.ink4.color)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .bottom)
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
                            Button { store.select(message: message.id) } label: {
                                MessageRow(
                                    message: message,
                                    accountHost: store.account(message.accountID)?.host ?? "",
                                    isSelected: message.id == store.selectedMessageID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(group.label)
                            .capsLabel()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(theme.surface.color)
                    }
                }
            }
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
        .padding(.vertical, 24)
    }
}
