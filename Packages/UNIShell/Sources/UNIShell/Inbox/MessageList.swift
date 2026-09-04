import SwiftUI
import UNIDesign
import UNICore

/// A apresentação dos filtros de categoria na caixa Hoje.
///
/// O estado continua no `MailStore`: esta enum só dá à superfície os textos e
/// símbolos estáveis que ela precisa. A lista de casos é deliberadamente
/// fechada — "Todos" permanece a visão sem filtro, em vez de a classificação
/// criar abas arbitrárias cujo significado ninguém consegue explicar.
enum InboxCategoryFilter: CaseIterable, Identifiable {
    case all
    case primary
    case transactions
    case updates
    case promotions
    case social

    var id: String {
        switch self {
        case .all: "all"
        case .primary: "primary"
        case .transactions: "transactions"
        case .updates: "updates"
        case .promotions: "promotions"
        case .social: "social"
        }
    }

    var category: MailCategory? {
        switch self {
        case .all: nil
        case .primary: .primary
        case .transactions: .transactions
        case .updates: .updates
        case .promotions: .promotions
        case .social: .social
        }
    }

    var label: String {
        switch self {
        case .all: L10n.tr("Todos")
        case .primary: L10n.tr("Principal")
        case .transactions: L10n.tr("Transações")
        case .updates: L10n.tr("Atualizações")
        case .promotions: L10n.tr("Promoções")
        case .social: L10n.tr("Social")
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .primary: "person.crop.circle"
        case .transactions: "creditcard"
        case .updates: "bell"
        case .promotions: "tag"
        case .social: "person.2"
        }
    }
}

/// Um dia de **conversas**, com o rótulo que a lista mostra no cabeçalho.
public struct MessageGroup: Identifiable {
    /// O dia do grupo, em dias a partir de hoje: `0`, `-1`, ...
    public let dayOffset: Int
    public let label: String
    /// As conversas do dia, na ordem em que a lista as entregou. Uma linha da
    /// lista é uma destas.
    public let conversations: [Conversation]

    public var id: Int { dayOffset }

    /// As mensagens do dia, achatadas.
    ///
    /// Continua existindo porque a pergunta "que mensagens este dia tem" é
    /// legítima e é a que os testes fazem — mas ela deixou de ser o que a lista
    /// desenha. Numa caixa sem conversa nenhuma (as fixtures do Marco 1) esta
    /// lista é idêntica à de antes desta tarefa, mensagem por mensagem e na
    /// mesma ordem: cada conversa tem uma mensagem só.
    public var messages: [Message] { conversations.flatMap(\.messages) }

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
    /// **As conversas vêm antes do dia**, e a ordem das duas operações não é
    /// livre: agrupar por dia primeiro partiria em duas linhas a conversa que
    /// tem uma mensagem de ontem e a resposta de hoje — que é a conversa mais
    /// comum que existe. Primeiro a conversa, depois o dia **da mais recente
    /// dela**, que é a data que a linha mostra.
    public static func build(from messages: [Message]) -> [MessageGroup] {
        guard !messages.isEmpty else { return [] }

        var order: [Int] = []
        var byDay: [Int: [Conversation]] = [:]
        for conversation in Conversation.build(from: messages) {
            let offset = conversation.latest.dayOffset
            if byDay[offset] == nil { order.append(offset) }
            byDay[offset, default: []].append(conversation)
        }

        return order.map { offset in
            let inDay = byDay[offset] ?? []
            return MessageGroup(
                dayOffset: offset,
                label: label(forOffset: offset, sample: inDay.first?.latest),
                conversations: inDay
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
    public static let width: CGFloat = 400

    /// Quanto tempo o retorno de uma ação de arraste fica na tela antes de
    /// sumir sozinho. Longo o bastante para ler a frase e alcançar "Desfazer".
    static let receiptLifetime: Duration = .seconds(6)

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

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

    /// Quantas conversas a lista monta. Tudo tem milhares; o clique só pede
    /// a primeira página, e o final da página pede a seguinte.
    @State private var rowLimit = MessageList.rowPageSize
    static let rowPageSize = 20

    /// O que a última ação fez, e como desfazê-la.
    ///
    /// Vem do ambiente porque o menu do leitor e a tecla ⌫ produzem o mesmo
    /// retorno — ver `ActionReceipts`. Sem ninguém no ambiente (harness,
    /// preview) a lista usa o objeto próprio, em vez de trapar.
    @Environment(ActionReceipts.self) private var sharedReceipts: ActionReceipts?
    @State private var ownReceipts = ActionReceipts()

    var receipts: ActionReceipts { sharedReceipts ?? ownReceipts }

    private var receipt: SwipeReceipt? {
        get { receipts.current }
        nonmutating set { receipts.current = newValue }
    }

    /// A largura resolvida que a janela concedeu — entre 320 e 400 conforme a
    /// faixa. Ao contrário dos outros painéis, esta de fato varia.
    let listWidth: CGFloat

    /// Como as linhas marcam "não lida". O padrão é o do app inteiro
    /// (`UnreadEmphasis.standard`); fica fora do `init` porque só o harness de
    /// comparação troca — é ele que gera os três PNGs de escolha.
    var unreadEmphasis: UnreadEmphasis = .standard

    /// Duplo clique numa linha abre a janela 05. Protótipo: a própria linha tem
    /// `onDoubleClick="{{ m.onOpenWin }}"` e `title="Duplo clique abre em janela"`.
    let onOpenWindow: (Message) -> Void

    /// Que dia é hoje, repassado a cada linha para o carimbo de horário. Ver
    /// `MessageRow.today` e `AgendaClock.today`.
    let today: Date

    /// "Gmail Entrada 165 · aqui 162". Nulo cai no rótulo de sempre.
    var portraitCaption: String?
    /// "3 não estão no app" — só quando o provedor tem mais.
    var gapCaption: String?
    var onPullMissing: (() -> Void)?

    public init(
        store: MailStore,
        width: CGFloat = MessageList.width,
        today: Date = Fixtures.today,
        onOpenWindow: @escaping (Message) -> Void = { _ in },
        portraitCaption: String? = nil,
        gapCaption: String? = nil,
        onPullMissing: (() -> Void)? = nil
    ) {
        self.store = store
        self.listWidth = width
        self.today = today
        self.onOpenWindow = onOpenWindow
        self.portraitCaption = portraitCaption
        self.gapCaption = gapCaption
        self.onPullMissing = onPullMissing
    }

    /// Formata o rótulo de contagem de mensagens com plural correto.
    public static func messageCountLabel(_ count: Int) -> String {
        messageCountLabel(count, hasMore: false)
    }

    public static func messageCountLabel(_ count: Int, hasMore: Bool) -> String {
        if hasMore { return L10n.tr("\(count)+ mensagens") }
        return count == 1 ? L10n.tr("1 mensagem") : L10n.tr("\(count) mensagens")
    }

    /// O que o cabeçalho escreve quando há lote: a contagem das marcadas,
    /// não a da caixa. Feminino porque é conversa.
    public static func selectedCountLabel(_ count: Int) -> String {
        count == 1 ? L10n.tr("1 selecionada") : L10n.tr("\(count) selecionadas")
    }

    /// Há lote nesta caixa. Vale em Hoje, Depois, Arquivado, Lixeira,
    /// Enviadas, Tudo e pasta do provedor — a seleção não é um modo de Hoje.
    var isSelecting: Bool { store.hasChecked }

    private var recorteID: String {
        [
            store.bucket.rawValue,
            store.selectedAccountID ?? "",
            store.selectedFolderID ?? "",
            store.categoryFilter?.rawValue ?? "",
            store.query,
            store.searchEverywhere ? "tudo" : "caixa",
        ].joined(separator: "|")
    }

    public var body: some View {
        let page = store.conversationPage(limit: rowLimit)
        // Só as contas das linhas visíveis. Pedir pasta de toda conta em Tudo
        // copiava a caixa inteira no clique.
        let accountIDs = Set(page.conversations.map(\.latest.accountID))
        let foldersByAccount = Dictionary(
            uniqueKeysWithValues: accountIDs.map { ($0, store.folders(of: $0)) }
        )

        VStack(spacing: 0) {
            header(messageCount: page.messageCount, hasMore: page.hasMore)
            messageList(
                page.conversations,
                foldersByAccount: foldersByAccount,
                isEmpty: page.conversations.isEmpty && !page.hasMore,
                hasMore: page.hasMore
            )
        }
        // Sem teto de altura a lista pede o tamanho de **todas** as linhas —
        // clicar em Tudo materializava a caixa inteira e travava. A barra
        // lateral já documenta o mesmo limite.
        .frame(width: listWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(theme.surface.color)
        .hairline(theme.line, edges: .trailing)
        // O ⌫ e as setas. Não é `keyboardShortcut` porque tecla sem
        // modificador seria roubada do campo de busca e do editor do
        // composer — ver `BareKeyMonitor`.
        .bareKeyShortcuts { key in
            handleBareKey(key)
        }
        .onExitCommand {
            guard isSelecting else { return }
            store.clearChecked()
        }
        .onChange(of: recorteID) { _, _ in
            rowLimit = Self.rowPageSize
        }
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

    /// Cabeçalho de produto do novo shell: título forte e a contagem como
    /// metadado, em vez da antiga faixa tipográfica de uma linha.
    ///
    /// O checkbox vive **aqui**, na moldura da lista, e não numa coluna de
    /// cada linha: marca todas as conversas visíveis desta caixa. A faixa de
    /// lote substitui as categorias de Hoje quando há seleção, e aparece em
    /// qualquer caixa — não só em Hoje.
    private func header(messageCount: Int, hasMore: Bool) -> some View {
        VStack(alignment: .leading, spacing: showsHeaderRail ? 8 : 3) {
            HStack(alignment: .center, spacing: 10) {
                headerCheckbox(isEmpty: messageCount == 0 && !hasMore)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headerTitle)
                        .font(theme.serif.font(size: 20, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    headerCountLine(messageCount: messageCount, hasMore: hasMore)
                }
                Spacer(minLength: 8)
                if isSelecting {
                    Button {
                        store.clearChecked()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.ink3.color)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Limpar seleção"))
                    .accessibilityLabel(L10n.tr("Limpar seleção"))
                }
            }

            if isSelecting {
                batchActionRail
            } else if showsCategoryFilters {
                categoryFilterRail
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .frame(height: Self.headerHeight(
            for: store.bucket,
            selecting: isSelecting,
            searchingEverywhere: store.searchesEverywhereNow
        ))
        .clipped()
        .background(theme.surface.color)
        .hairline(theme.line2, edges: .bottom)
    }

    @ViewBuilder
    private func headerCountLine(messageCount: Int, hasMore: Bool) -> some View {
        if isSelecting {
            Text(Self.selectedCountLabel(store.checkedConversations.count))
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink2.color)
        } else {
            HStack(spacing: 6) {
                Text(portraitCaption ?? Self.messageCountLabel(messageCount, hasMore: hasMore))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(1)
                if let gapCaption, let puxar = onPullMissing {
                    Button(gapCaption, action: puxar)
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.accentInk.color)
                        .help(L10n.tr("Sincroniza agora para trazer o que falta"))
                        .accessibilityLabel(gapCaption)
                }
            }
        }
    }

    /// Só Hoje recebe esta camada de organização. Depois continua sendo a
    /// decisão explícita de adiar, e as outras caixas são o mapa do servidor —
    /// duplicar categorias nelas esconderia a navegação que a pessoa escolheu.
    private var showsCategoryFilters: Bool {
        store.bucket == .today && !store.searchesEverywhereNow
    }

    private var showsHeaderRail: Bool { isSelecting || showsCategoryFilters }

    /// A altura antiga fica intacta em toda caixa exceto Hoje; é importante
    /// para não deslocar a lista quando a pessoa troca entre Arquivado, Tudo e
    /// Depois. Com lote, todas crescem para caber a faixa de ações. Tudo na
    /// busca esconde a trilha — o vão das cápsulas não pode ficar vazio.
    static func headerHeight(
        for bucket: TriageBucket,
        selecting: Bool = false,
        searchingEverywhere: Bool = false
    ) -> CGFloat {
        (selecting || (bucket == .today && !searchingEverywhere)) ? 118 : 74
    }

    /// O checkbox do cabeçalho: marca todas as visíveis, ou limpa. O traço
    /// no meio é o estado misto (algumas, não todas).
    private func headerCheckbox(isEmpty: Bool) -> some View {
        let all = store.allVisibleChecked
        let some = store.someVisibleChecked
        return Button {
            store.toggleSelectAllVisible()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(all || some ? theme.accent.color : Color.clear)
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(
                        all || some ? theme.accent.color : theme.ink3.color,
                        lineWidth: max(1, Hairline.thickness(displayScale))
                    )
                if all {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(theme.onAccent.color)
                } else if some {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(theme.onAccent.color)
                        .frame(width: 8, height: 1.5)
                }
            }
            .frame(width: 16, height: 16)
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A página já sabe se a caixa está vazia. `visibleConversations`
        // agrupa Tudo inteiro — era o tranco a cada clique na caixa.
        .disabled(isEmpty)
        .help(all ? L10n.tr("Desmarcar todas nesta caixa") : L10n.tr("Selecionar todas nesta caixa"))
        .accessibilityLabel(L10n.tr("Selecionar todas"))
        .accessibilityValue(all ? L10n.tr("Tudo") : some ? L10n.tr("Algumas") : L10n.tr("Nenhuma"))
        .accessibilityAddTraits(all ? .isSelected : [])
    }

    /// A coluna mede 400pt: seis controles completos não cabem sem encolher
    /// texto, então a faixa rola na horizontal como os filtros do Mail. Cada
    /// cápsula mantém uma área de clique de 28pt e pode receber foco de teclado.
    /// Clique-arraste **e** roda: `DragScrollRail`, não `ScrollView` — no macOS
    /// a `ScrollView` ignora o botão esquerdo e o recognizer do AppKit perdia
    /// para os `Button` de dentro.
    private var categoryFilterRail: some View {
        DragScrollRail {
            HStack(spacing: 5) {
                ForEach(InboxCategoryFilter.allCases) { filter in
                    categoryFilterChip(filter)
                }
            }
            .padding(.vertical, 1)
            .padding(.trailing, 16)
        }
        .frame(height: 30)
        .mask(railFadeMask)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Categorias de Hoje"))
    }

    /// O corte duro no último chip parecia texto quebrado. O fade diz que a
    /// faixa continua, em vez de morder "Atualizações" no meio.
    private var railFadeMask: some View {
        HStack(spacing: 0) {
            Color.white
            LinearGradient(
                colors: [.white, .white.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14)
        }
    }

    /// Zero não é número útil nesta trilha: seis "0" viram ruído. A cápsula
    /// continua clicável; o valor vai no `accessibilityValue`.
    nonisolated static func categoryCountLabel(_ count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }

    private func categoryFilterChip(_ filter: InboxCategoryFilter) -> some View {
        let active = store.categoryFilter == filter.category
        let count = store.categoryCount(filter.category)
        let radius = max(theme.radiusSmall, 7)

        return Button {
            store.select(category: filter.category)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(filter.label)
                    .font(theme.sans.font(size: 11.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                if let label = Self.categoryCountLabel(count) {
                    Text(label)
                        .font(theme.mono.font(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle((active ? theme.accentInk : theme.ink3).color)
                }
            }
            .foregroundStyle((active ? theme.accentInk : theme.ink2).color)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(active ? theme.accentSoft.color : theme.surface2.color.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        active ? theme.accentLine.color : theme.line2.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: radius)
        .help(L10n.tr("Filtrar Hoje por \(filter.label)"))
        .accessibilityLabel(L10n.tr("Filtrar por \(filter.label)"))
        .accessibilityValue(active ? L10n.tr("Selecionado, \(count) mensagens") : L10n.tr("\(count) mensagens"))
        .accessibilityHint(active ? L10n.tr("Filtro atual") : L10n.tr("Mostra somente mensagens desta categoria"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// A faixa de ações do lote. Rola na horizontal, como as categorias: a
    /// coluna tem 400pt e seis controles com rótulo não cabem sem quebrar.
    private var batchActionRail: some View {
        DragScrollRail {
            HStack(spacing: 6) {
                ForEach(batchBucketTargets, id: \.self) { bucket in
                    batchChip(
                        label: Self.batchBucketLabel(bucket),
                        symbol: Self.batchBucketSymbol(bucket),
                        help: L10n.tr("Mover as selecionadas para \(bucket.label)")
                    ) {
                        moveChecked(to: bucket)
                    }
                }
                batchChip(
                    label: store.bucket == .trash ? L10n.tr("Apagar de vez") : L10n.tr("Apagar"),
                    symbol: "trash",
                    help: store.bucket == .trash
                        ? L10n.tr("Tirar as selecionadas da Lixeira de vez")
                        : L10n.tr("Mover as selecionadas para a Lixeira"),
                    destructive: true
                ) {
                    _ = deleteChecked()
                }
                batchFolderMenu
                batchChip(
                    label: batchWillMarkRead ? L10n.tr("Lida") : L10n.tr("Não lida"),
                    symbol: batchWillMarkRead ? "envelope.open" : "envelope.badge",
                    help: batchWillMarkRead
                        ? L10n.tr("Marcar as selecionadas como lidas")
                        : L10n.tr("Marcar as selecionadas como não lidas")
                ) {
                    toggleCheckedRead()
                }
                batchChip(
                    label: batchWillFlag ? L10n.tr("Sinalizar") : L10n.tr("Tirar"),
                    symbol: batchWillFlag ? "star" : "star.slash",
                    help: batchWillFlag
                        ? L10n.tr("Sinalizar as selecionadas")
                        : L10n.tr("Tirar a sinalização das selecionadas")
                ) {
                    toggleCheckedFlag()
                }
            }
            .padding(.vertical, 1)
            .padding(.trailing, 16)
        }
        .frame(height: 30)
        .mask(railFadeMask)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Ações em lote"))
    }

    /// Destinos de triagem do lote, sem a caixa já aberta e sem "Tudo", que
    /// não é estado. Lixeira fica de fora: "Apagar" é o botão ao lado.
    var batchBucketTargets: [TriageBucket] {
        [.today, .later, .archived].filter { $0 != store.bucket }
    }

    nonisolated static func batchBucketLabel(_ bucket: TriageBucket) -> String {
        bucket == .archived ? L10n.tr("Arquivar") : bucket.label
    }

    nonisolated static func batchBucketSymbol(_ bucket: TriageBucket) -> String {
        switch bucket {
        case .today: "tray.and.arrow.down"
        case .later: "clock"
        case .archived: "archivebox"
        default: "tray"
        }
    }

    private var batchWillMarkRead: Bool {
        store.checkedConversations.contains { $0.hasUnread }
    }

    private var batchWillFlag: Bool {
        store.checkedConversations.contains { conversation in
            conversation.messages.contains { !$0.isFlagged }
        }
    }

    @ViewBuilder
    private var batchFolderMenu: some View {
        if let accountID = store.checkedAccountID,
           let account = store.account(accountID) {
            let folders = store.folders(of: accountID)
            let sample = store.checkedConversations.first?.latest
            switch account.provider {
            case .imap:
                let targets = folders.filter {
                    ![FolderRole.sent, .drafts, .trash].contains($0.role)
                }
                if !targets.isEmpty {
                    Menu {
                        ForEach(targets) { folder in
                            Button(folder.displayName) {
                                placeChecked(in: folder, mode: .move)
                            }
                        }
                    } label: {
                        batchChipLabel(label: L10n.tr("Mover para"), symbol: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L10n.tr("Mover as selecionadas para uma pasta"))
                }
            case .gmail:
                let userLabels = folders.filter { $0.role == .other }
                if !userLabels.isEmpty, let sample {
                    Menu {
                        if let source = gmailMoveSource(for: sample, folders: folders) {
                            Section(L10n.tr("Mover para marcador")) {
                                ForEach(userLabels.filter { $0.id != source.id }) { folder in
                                    Button(folder.displayName) {
                                        moveCheckedGmail(from: source, to: folder)
                                    }
                                }
                            }
                        }
                        Section(L10n.tr("Aplicar marcador")) {
                            ForEach(userLabels) { folder in
                                Button(folder.displayName) {
                                    placeChecked(in: folder, mode: .label)
                                }
                            }
                        }
                    } label: {
                        batchChipLabel(label: L10n.tr("Mover para"), symbol: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L10n.tr("Mover ou aplicar marcador nas selecionadas"))
                }
            case .microsoft:
                EmptyView()
            }
        }
    }

    private func gmailMoveSource(
        for message: Message, folders: [MailFolder]
    ) -> MailFolder? {
        if let selectedFolderID = store.selectedFolderID {
            return folders.first {
                $0.id == selectedFolderID
                    && $0.accountID == message.accountID
                    && message.folderIDs.contains($0.id)
                    && [.inbox, .other].contains($0.role)
            }
        }
        guard store.bucket == .today else { return nil }
        return folders.first {
            $0.accountID == message.accountID
                && $0.role == .inbox
                && message.folderIDs.contains($0.id)
        }
    }

    private func batchChip(
        label: String,
        symbol: String,
        help: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            batchChipLabel(label: label, symbol: symbol, destructive: destructive)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
    }

    private func batchChipLabel(
        label: String, symbol: String, destructive: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .accessibilityHidden(true)
            Text(label)
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(destructive ? theme.ink.color : theme.ink2.color)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background {
            Capsule().fill(
                destructive
                    ? theme.surface2.color
                    : theme.surface2.color.opacity(0.72)
            )
        }
        .overlay {
            if destructive {
                Capsule().strokeBorder(
                    theme.line.color, lineWidth: Hairline.thickness(displayScale)
                )
            }
        }
        .contentShape(Capsule())
    }

    /// A cor da conta, que a linha usa na barra da borda e no chip do host.
    /// Sem `switch` sobre provedores: vem do que a conta declarar.
    private func accountTint(_ account: Account?) -> Color {
        account
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.ink3.color
    }

    private var headerTitle: String {
        if store.searchesEverywhereNow { return L10n.tr("Tudo") }
        if let selectedAccountID = store.selectedAccountID,
           let account = store.account(selectedAccountID) {
            return account.host
        }
        return store.bucket == .all ? L10n.tr("Caixa unificada") : store.bucket.label
    }

    private func messageList(
        _ conversations: [Conversation],
        foldersByAccount: [String: [MailFolder]],
        isEmpty: Bool,
        hasMore: Bool
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // O rodapé entra **dentro** do LazyVStack. Como irmão, o
                // ScrollView precisava da altura de todas as linhas para
                // posicioná-lo — Tudo deixava de ser preguiçoso.
                LazyVStack(spacing: 0) {
                    ForEach(conversations) { conversation in
                        row(
                            conversation,
                            folders: foldersByAccount[conversation.latest.accountID] ?? []
                        )
                        .id(conversation.key)
                        .onAppear {
                            if hasMore, conversation.key == conversations.last?.key {
                                rowLimit += Self.rowPageSize
                            }
                        }
                    }
                    if !hasMore {
                        footer(isEmpty: isEmpty)
                    }
                }
            }
            .onChange(of: store.selectedMessageID) { _, id in
                guard let id, let key = store.conversation(of: id)?.key else { return }
                proxy.scrollTo(key)
            }
            .overlay(alignment: .bottom) { undoBand }
        }
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
    /// Uma linha é **uma conversa**. Quando ela tem uma mensagem só — o caso
    /// das fixtures e de quase toda caixa — tudo aqui dentro se resolve na
    /// mensagem dela, e o desenho é exatamente o de antes desta tarefa.
    private func row(_ conversation: Conversation, folders: [MailFolder]) -> some View {
        let message = conversation.latest
        let account = store.account(message.accountID)
        return SwipeRow(
            message: message,
            configuration: swipeConfiguration,
            // A linha tem a largura da lista, e é dela que sai o limiar do
            // arraste longo: disparar a três quartos da linha só significa
            // alguma coisa se a linha souber quanto mede.
            rowWidth: listWidth,
            openRowID: $openSwipeRowID,
            onFire: { fire($0, on: conversation, side: nil, folders: folders) },
            onFireWithSide: { action, side in
                fire(action, on: conversation, side: side, folders: folders)
            }
        ) { swipe in
            Button {
                if swipe.isBlocked {
                    swipe.dismiss()
                } else {
                    store.select(message: message.id)
                    if message.bucket == .drafts { onOpenWindow(message) }
                }
            } label: {
                MessageRow(
                    message: message,
                    accountHost: account?.host ?? "",
                    accountTint: accountTint(account),
                    // Selecionada quando **qualquer** mensagem da conversa está
                    // aberta: expandir a resposta antiga no leitor não pode
                    // apagar o realce da linha que a contém.
                    isSelected: conversation.contains(store.selectedMessageID),
                    emphasis: unreadEmphasis,
                    // O selo, e o "não lida" da conversa: `nil` e `1` na
                    // conversa de uma mensagem só, que é a garantia de a linha
                    // desenhar o que sempre desenhou.
                    conversationCount: conversation.count,
                    unread: conversation.hasUnread,
                    today: today,
                    isChecked: store.isChecked(conversation.key),
                    onToggleCheck: { store.toggleChecked(conversation.key) }
                )
            }
            .buttonStyle(.plain)
            .focusRing(in: Rectangle())
            .help(swipe.isBlocked
                  ? L10n.tr("Clique para fechar as ações")
                  : L10n.tr("Arraste para o lado revela ações · duplo clique abre em janela"))
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
            .uniContextMenu(
                ContextMenus.messageRow(
                    message,
                    accountAddress: account?.address ?? "",
                    provider: account?.provider,
                    folders: folders,
                    selectedFolderID: store.selectedFolderID,
                    currentBucket: store.bucket
                ),
                store: store,
                // O menu é montado sobre a mensagem mais recente (é ela que
                // decide os rótulos: "Marcar como não lida" só numa lida), mas
                // o que ele faz alcança a conversa — a linha é a conversa.
                intercept: { act($0, on: conversation) }
            )
        }
    }

    // MARK: - O que uma ação de arraste faz

    /// Dispara a ação e guarda o caminho de volta **no mesmo instante**.
    ///
    /// O recibo tem de nascer aqui, antes da mudança: depois de arquivada a
    /// mensagem não sabe mais de que caixa veio, e um "Desfazer" que
    /// adivinhasse a caixa seria a versão silenciosa do botão mudo.
    private func fire(
        _ action: SwipeAction,
        on conversation: Conversation,
        side: SwipeSide?,
        folders: [MailFolder]
    ) {
        let conversation = store.conversation(of: conversation.latest.id) ?? conversation
        let message = conversation.latest
        let destination = side.flatMap {
            swipeConfiguration.destination(on: $0, for: message.accountID)
        }
        guard let command = action.command(for: message, destination: destination) else { return }
        if action == .moveToDestination, let destination {
            fireMoveDestination(
                destination, command: command, on: conversation, folders: folders
            )
            return
        }
        guard conversation.count > 1 else {
            // O caminho de sempre, intocado: uma conversa de uma mensagem só é
            // a mensagem.
            let made = SwipeReceipt.of(action, message: message, stamp: ActionReceipts.stamp)
            StoreCommand.run(command, on: store)
            withAnimation(SwipeMotion.transition) { receipt = made }
            return
        }
        // O estado de **cada** mensagem, antes: as três podem estar em caixas
        // diferentes, e "Desfazer" não pode empilhá-las na caixa da mais
        // recente.
        let antes = store.states(of: conversation.messageIDs)
        let made = SwipeReceipt.ofConversation(
            action, conversation: conversation, states: antes, stamp: ActionReceipts.stamp
        )
        _ = act(command, on: conversation)
        withAnimation(SwipeMotion.transition) { receipt = made }
    }

    /// Executa a coluna configurada "Mover para…" e monta o inverso antes da
    /// projeção otimista alterar as associações de pasta. A operação ainda é
    /// um `ContextCommand` comum (`placeMessage` ou `moveGmailMessage`): este
    /// método só conhece o detalhe adicional que um gesto precisa para desfazer.
    private func fireMoveDestination(
        _ destination: SwipeMoveDestination,
        command: ContextCommand,
        on conversation: Conversation,
        folders: [MailFolder]
    ) {
        let undos = conversation.messages.compactMap {
            folderUndo(for: $0, destination: destination, folders: folders)
        }
        let stamp = ActionReceipts.stamp
        let made = undos.isEmpty ? nil : SwipeReceipt(
            messageID: conversation.latest.id,
            note: SwipeReceipt.note(
                destination.receiptTitle(), message: conversation.latest,
                count: conversation.count, stamp: stamp
            ),
            undo: .restoreFolderPlacements(undos)
        )

        if conversation.count == 1 {
            StoreCommand.run(command, on: store)
        } else {
            _ = act(command, on: conversation)
        }
        if let made {
            withAnimation(SwipeMotion.transition) { receipt = made }
        }
    }

    /// O Gmail precisa apenas recolocar `INBOX`: remover o marcador destino ao
    /// desfazer apagaria uma associação que talvez já existisse antes do
    /// gesto. No IMAP, a mensagem tem uma única pasta e a referência real vem
    /// do retrato de pastas que a linha recebeu.
    private func folderUndo(
        for message: Message,
        destination: SwipeMoveDestination,
        folders: [MailFolder]
    ) -> FolderPlacementUndo? {
        guard destination.command(for: message) != nil else { return nil }
        switch destination.transport {
        case .gmailLabelFromInbox:
            guard let inbox = destination.source?.folder else { return nil }
            return .restoreGmailInbox(messageID: message.id, inbox: inbox)

        case .imapFolder:
            guard let sourceID = message.folderIDs.first,
                  let source = folders.first(where: { $0.id == sourceID })
            else { return nil }
            return .moveToFolder(messageID: message.id, folder: source)
        }
    }

    /// O comando, aplicado à **conversa**.
    ///
    /// Devolve `true` quando já cuidou de tudo — é o contrato de `intercept`,
    /// e é o que impede `MenuCommandRunner` de repetir a mutação na mensagem
    /// sozinha depois de ela ter sido feita na conversa inteira.
    ///
    /// Conversa de uma mensagem só cai direto no caminho de antes desta tarefa
    /// (`receipted`), sem passar por nada novo: é assim que os retratos do
    /// Marco 1 continuam idênticos byte a byte.
    @discardableResult
    func act(_ command: ContextCommand, on conversation: Conversation) -> Bool {
        guard conversation.count > 1 else { return receipted(command) }
        switch command {
        case .move(_, let bucket):
            // Só a Lixeira ganha faixa com "Desfazer" — a mesma decisão que
            // `ActionReceipts.intercept` já toma para a mensagem: encher a tela
            // de confirmação de "adiada para depois" seria ruído.
            let made = bucket == .trash
                ? SwipeReceipt.ofConversation(
                    .trash, conversation: conversation,
                    states: store.states(of: conversation.messageIDs),
                    stamp: ActionReceipts.stamp
                )
                : nil
            store.move(conversation, to: bucket)
            if let made { withAnimation(SwipeMotion.transition) { receipt = made } }
            return true

        case .placeMessage(_, let folder, let mode):
            store.place(conversation, in: folder, mode: mode)
            return true

        case .moveGmailMessage(_, let source, let target):
            store.moveGmail(conversation, from: source, to: target)
            return true

        case .setRead(_, let isRead):
            store.setRead(isRead, for: conversation)
            return true

        case .setFlagged(_, let isFlagged):
            store.setFlagged(isFlagged, for: conversation)
            return true

        case .deleteForever:
            let made = SwipeReceipt.ofConversationDeleteForever(
                conversation: conversation, stamp: ActionReceipts.stamp
            )
            store.deleteForever(conversation)
            withAnimation(SwipeMotion.transition) { receipt = made }
            return true

        default:
            // Responder, abrir janela, copiar: são ações sobre **a** mensagem,
            // e alcançar a conversa com elas não quer dizer nada.
            return receipted(command)
        }
    }

    /// O retorno visível de uma ação destrutiva, com a animação da faixa.
    /// A decisão de **o que** ganha recibo é de `ActionReceipts`; aqui só se
    /// anima a chegada dela.
    func receipted(_ command: ContextCommand) -> Bool {
        var acted = false
        withAnimation(SwipeMotion.transition) {
            acted = receipts.intercept(command, on: store, stamp: ActionReceipts.stamp)
        }
        return acted
    }

    /// O ⌫ da lista: com lote, apaga as marcadas; sem lote, a conversa aberta.
    /// Na Lixeira, apaga de vez — a mesma decisão que `ContextMenus.deleteItem`
    /// escreve no rótulo do menu, e por isso ela sai de lá.
    ///
    /// `false` quando não há o que apagar: aí a tecla segue o caminho dela em
    /// vez de ser engolida por um atalho que não fez nada.
    /// O ⌫ e as setas da lista. Extraído para o teste afirmar a tecla sem
    /// sintetizar evento de sistema.
    func handleBareKey(_ key: BareKey) -> Bool {
        switch key {
        case .delete: deleteSelected()
        case .up: store.selectAdjacentConversation(offset: -1)
        case .down: store.selectAdjacentConversation(offset: 1)
        case .escape: false
        // A Caixa já abre no clique: selecionar **é** abrir aqui, e o ⏎ não
        // tem segundo passo para dar. Quem o usa é o dashboard.
        case .enter: false
        }
    }

    func deleteSelected() -> Bool {
        if !store.checkedConversations.isEmpty {
            return deleteChecked()
        }
        guard let message = store.selectedMessage else { return false }
        // A decisão inteira mora em `ActionReceipts.delete`, e não aqui: desde a
        // M3-18 o **botão "Apagar" da barra do leitor** faz exatamente a mesma
        // coisa, e duas cópias divergiriam no primeiro conserto.
        var apagou = false
        withAnimation(SwipeMotion.transition) {
            apagou = receipts.delete(message, on: store)
        }
        return apagou
    }

    /// Move o lote para uma caixa de triagem. Um recibo só, com o estado de
    /// cada mensagem fotografado antes — as conversas podiam ter vindo de
    /// caixas diferentes.
    func moveChecked(to bucket: TriageBucket) {
        let batch = store.checkedConversations.filter { conversation in
            conversation.messages.contains { $0.bucket != bucket }
        }
        guard !batch.isEmpty else { return }
        let states = store.states(of: batch.flatMap(\.messageIDs))
        let action: SwipeAction? = switch bucket {
        case .today: .today
        case .later: .later
        case .archived: .archive
        case .trash: .trash
        default: nil
        }
        withAnimation(SwipeMotion.transition) {
            for conversation in batch { store.move(conversation, to: bucket) }
            if let action {
                receipt = SwipeReceipt.ofBatch(
                    action, conversations: batch, states: states,
                    stamp: ActionReceipts.stamp
                )
            }
        }
    }

    @discardableResult
    func deleteChecked() -> Bool {
        let batch = store.checkedConversations
        guard !batch.isEmpty else { return false }
        let forever = store.bucket == .trash
        withAnimation(SwipeMotion.transition) {
            if forever {
                receipt = SwipeReceipt.ofBatchDeleteForever(
                    conversations: batch, stamp: ActionReceipts.stamp
                )
                for conversation in batch { store.deleteForever(conversation) }
            } else {
                let states = store.states(of: batch.flatMap(\.messageIDs))
                receipt = SwipeReceipt.ofBatch(
                    .trash, conversations: batch, states: states,
                    stamp: ActionReceipts.stamp
                )
                for conversation in batch { store.move(conversation, to: .trash) }
            }
        }
        return true
    }

    func toggleCheckedRead() {
        let batch = store.checkedConversations
        guard !batch.isEmpty else { return }
        let markRead = batch.contains { $0.hasUnread }
        for conversation in batch { store.setRead(markRead, for: conversation) }
    }

    func toggleCheckedFlag() {
        let batch = store.checkedConversations
        guard !batch.isEmpty else { return }
        let flag = batch.contains { conversation in
            conversation.messages.contains { !$0.isFlagged }
        }
        for conversation in batch { store.setFlagged(flag, for: conversation) }
    }

    func placeChecked(in folder: MailFolder, mode: FolderPlacement) {
        let batch = store.checkedConversations
        guard !batch.isEmpty else { return }
        for conversation in batch { store.place(conversation, in: folder, mode: mode) }
    }

    func moveCheckedGmail(from source: MailFolder, to destination: MailFolder) {
        let batch = store.checkedConversations
        guard !batch.isEmpty else { return }
        for conversation in batch {
            store.moveGmail(conversation, from: source, to: destination)
        }
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

    nonisolated static var emptyBox: String { L10n.tr("Nada nesta caixa agora.") }
    nonisolated static var emptySearchHere: String { L10n.tr("Nada nesta caixa. Tudo procura nas outras pastas.") }
    nonisolated static var emptySearchEverywhere: String { L10n.tr("Nada com este termo.") }

    nonisolated static func emptyFooter(
        isEmpty: Bool, query: String, searchingEverywhere: Bool
    ) -> String {
        guard isEmpty else { return L10n.tr("Fim da lista") }
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return emptyBox }
        return searchingEverywhere ? emptySearchEverywhere : emptySearchHere
    }

    private func emptyFooter(isEmpty: Bool) -> String {
        Self.emptyFooter(
            isEmpty: isEmpty,
            query: store.query,
            searchingEverywhere: store.searchesEverywhereNow
        )
    }

    private func footer(isEmpty: Bool) -> some View {
        VStack(spacing: 0) {
            Text(emptyFooter(isEmpty: isEmpty))
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink4.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 44)
    }
}
