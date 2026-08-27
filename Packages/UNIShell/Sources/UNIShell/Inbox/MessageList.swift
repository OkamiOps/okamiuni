import SwiftUI
import UNIDesign
import UNICore

/// Um dia de mensagens, com o rótulo que a lista mostra no cabeçalho.
public struct MessageGroup: Identifiable {
    /// O dia do grupo, em dias a partir de hoje: `0`, `-1`, ...
    public let dayOffset: Int
    public let label: String
    public let messages: [Message]

    public var id: Int { dayOffset }

    /// Agrupa pelo **dia que a mensagem declara**, preservando a ordem que veio.
    ///
    /// Antes agrupava por `calendar.startOfDay(for: message.receivedAt)` e
    /// rotulava com `isDateInToday` contra `Date.now`. As duas metades tinham o
    /// mesmo defeito: perguntavam ao relógio da máquina o que é dado da
    /// mensagem. Com `Fixtures.today` em 25/08/2026, em qualquer outro dia o
    /// grupo "Hoje" do design saía como "25 DE AGO." — que foi o que o dono do
    /// projeto viu na janela. É a mesma classe do bug de fuso em
    /// `docs/decisoes-de-engenharia.md`.
    ///
    /// `now` e `calendar` não entram mais porque não há mais nada a perguntar
    /// a eles: dia é `dayOffset`, e o nome dele é `DayLabel`.
    public static func build(from messages: [Message]) -> [MessageGroup] {
        guard !messages.isEmpty else { return [] }

        var order: [Int] = []
        var byDay: [Int: [Message]] = [:]
        for message in messages {
            if byDay[message.dayOffset] == nil { order.append(message.dayOffset) }
            byDay[message.dayOffset, default: []].append(message)
        }

        return order.map { offset in
            let inDay = byDay[offset] ?? []
            return MessageGroup(
                dayOffset: offset,
                label: label(forOffset: offset, sample: inDay.first),
                messages: inDay
            )
        }
    }

    /// "Hoje" e "Ontem" saem do offset; um dia mais antigo não tem nome e cai
    /// na data de uma mensagem dele — a data ali é só formatação, não é ela que
    /// decide o grupo.
    private static func label(forOffset offset: Int, sample: Message?) -> String {
        if let name = DayLabel.name(forOffset: offset) { return name }
        guard let sample else { return "" }
        return sample.receivedAt.formatted(.dateTime.day().month(.abbreviated))
    }
}

public struct MessageList: View {
    /// A largura que a lista tem no ponto de fidelidade da Task P (1440 com
    /// tudo visível). Não é mais uma largura aplicada: é o que `PaneLayout`
    /// devolve naquela largura de janela, e o que este `View` usa quando ninguém
    /// resolveu layout por ele.
    public static let width: CGFloat = 370

    @Environment(\.theme) private var theme
    let store: MailStore

    /// A largura resolvida que a janela concedeu — entre 320 e 420 conforme a
    /// faixa. Ao contrário dos outros painéis, esta de fato varia.
    let listWidth: CGFloat

    /// Duplo clique numa linha abre a janela 05. Protótipo: a própria linha tem
    /// `onDoubleClick="{{ m.onOpenWin }}"` e `title="Duplo clique abre em janela"`.
    let onOpenWindow: (Message) -> Void

    public init(
        store: MailStore,
        width: CGFloat = MessageList.width,
        onOpenWindow: @escaping (Message) -> Void = { _ in }
    ) {
        self.store = store
        self.listWidth = width
        self.onOpenWindow = onOpenWindow
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
        .frame(width: listWidth)
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
                            .focusRing(in: Rectangle())
                            .help("Duplo clique abre em janela")
                            // O clique simples continua sendo o do `Button`
                            // (selecionar); este gesto só acrescenta o duplo,
                            // como o protótipo, que declara os dois na linha.
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { onOpenWindow(message) }
                            )
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
