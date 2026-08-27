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

    /// Quanto tempo o retorno de uma ação de arraste fica na tela antes de
    /// sumir sozinho. Longo o bastante para ler a frase e alcançar "Desfazer".
    static let receiptLifetime: Duration = .seconds(6)

    @Environment(\.theme) private var theme

    /// A escolha de quais ações ficam de cada lado.
    ///
    /// Opcional de propósito: sem ninguém no ambiente — o harness de
    /// renderização, uma preview — a lista continua desenhando com o padrão em
    /// vez de trapar. É o mesmo alcance que o `Theme` tem por `@Entry`.
    @Environment(SwipeSettingsStore.self) private var swipeSettings: SwipeSettingsStore?

    let store: MailStore

    /// Qual linha está com o painel de ações à mostra. Só uma por vez: abrir
    /// uma fecha a outra.
    @State private var openSwipeRowID: String?

    /// O que a última ação de arraste fez, e como desfazê-la. Mora aqui, e não
    /// na linha, porque a linha **some** quando a ação é arquivar — um retorno
    /// preso a ela morreria junto com o que precisava desfazer.
    @State private var receipt: SwipeReceipt?

    /// A largura resolvida que a janela concedeu — entre 320 e 420 conforme a
    /// faixa. Ao contrário dos outros painéis, esta de fato varia.
    let listWidth: CGFloat

    /// Como as linhas marcam "não lida". O padrão é o do app inteiro
    /// (`UnreadEmphasis.standard`); fica fora do `init` porque só o harness de
    /// comparação troca — é ele que gera os três PNGs de escolha.
    var unreadEmphasis: UnreadEmphasis = .standard

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
        // O retorno some sozinho, mas nunca **antes** de dar tempo de desfazer.
        // A tarefa é reiniciada por `id`: uma segunda ação troca a faixa e
        // reinicia a contagem em vez de herdar o resto do relógio da primeira.
        .task(id: receipt?.id) {
            guard receipt != nil else { return }
            try? await Task.sleep(for: Self.receiptLifetime)
            guard !Task.isCancelled else { return }
            withAnimation(SwipeMotion.transition) { receipt = nil }
        }
    }

    /// A configuração viva, ou o padrão quando ninguém a proveu.
    var swipeConfiguration: SwipeConfiguration {
        swipeSettings?.configuration ?? .default
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
                            row(message)
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
        .overlay(alignment: .bottom) { undoBand }
    }

    /// Uma linha da lista, com os quatro gestos que ela responde.
    ///
    /// A ordem importa e é esta:
    ///
    /// - **arrastar** é do `SwipeRow`, que roda `simultaneousGesture` com a
    ///   rolagem e só engata quando a horizontal domina a vertical;
    /// - **clicar** é do `Button`, e enquanto o arraste está em curso ou a
    ///   linha está aberta ele **fecha** a linha em vez de selecionar;
    /// - **duplo clique** abre a janela, pelo mesmo `simultaneousGesture` de
    ///   antes — ele não anda 12pt, então nunca engata o arraste;
    /// - **botão direito** abre `ContextMenus.messageRow` no painel que o app
    ///   desenha, e o `DragGesture` nem o enxerga: o arraste só acompanha o
    ///   botão esquerdo.
    private func row(_ message: Message) -> some View {
        let account = store.account(message.accountID)
        return SwipeRow(
            message: message,
            configuration: swipeConfiguration,
            // A linha tem a largura da lista, e é dela que sai o limiar do
            // arraste longo: disparar a três quartos da linha só significa
            // alguma coisa se a linha souber quanto mede.
            rowWidth: listWidth,
            openRowID: $openSwipeRowID,
            onFire: { fire($0, on: message) }
        ) { swipe in
            Button {
                if swipe.isBlocked { swipe.dismiss() } else { store.select(message: message.id) }
            } label: {
                MessageRow(
                    message: message,
                    accountHost: account?.host ?? "",
                    accountTint: accountTint(account),
                    isSelected: message.id == store.selectedMessageID,
                    emphasis: unreadEmphasis
                )
            }
            .buttonStyle(.plain)
            .focusRing(in: Rectangle())
            .help(swipe.isBlocked
                  ? "Clique para fechar as ações"
                  : "Arraste para o lado revela ações · duplo clique abre em janela")
            // O clique simples continua sendo o do `Button` (selecionar);
            // este gesto só acrescenta o duplo, como o protótipo, que
            // declara os dois na linha.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard !swipe.isBlocked else { return }
                    onOpenWindow(message)
                }
            )
            // Botão direito na linha. O conteúdo é dado —
            // `ContextMenus.messageRow` — e muda com o estado da mensagem:
            // "Marcar como não lida" só aparece em mensagem lida, e "Mover
            // para" não oferece a caixa em que ela já está.
            .uniContextMenu(ContextMenus.messageRow(message), store: store)
        }
    }

    // MARK: - O que uma ação de arraste faz

    /// Dispara a ação e guarda o caminho de volta **no mesmo instante**.
    ///
    /// O recibo tem de nascer aqui, antes da mudança: depois de arquivada a
    /// mensagem não sabe mais de que caixa veio, e um "Desfazer" que
    /// adivinhasse a caixa seria a versão silenciosa do botão mudo.
    private func fire(_ action: SwipeAction, on message: Message) {
        guard let command = action.command(for: message) else { return }
        let made = SwipeReceipt.of(
            action,
            message: message,
            stamp: Date.now.formatted(date: .omitted, time: .shortened)
        )
        StoreCommand.run(command, on: store)
        withAnimation(SwipeMotion.transition) { receipt = made }
    }

    private func undo(_ receipt: SwipeReceipt) {
        StoreCommand.run(receipt.undo, on: store)
        withAnimation(SwipeMotion.transition) { self.receipt = nil }
    }

    /// A faixa de retorno, flutuando no pé da lista.
    ///
    /// Flutua, e não empurra: a lista não pode pular porque uma ação
    /// aconteceu. Por isso `overlay`, não uma linha a mais no `VStack`.
    @ViewBuilder
    private var undoBand: some View {
        if let receipt {
            SwipeUndoBand(receipt: receipt) { undo(receipt) }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
