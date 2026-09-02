import SwiftUI
import UNIDesign
import UNICore
import UNISync
#if canImport(AppKit)
import AppKit
#endif

enum InboxAssistantScope: Sendable, Hashable {
    case workspace
    case email(String)

    var mode: AssistantScope {
        switch self {
        case .workspace: .workspace
        case .email: .email
        }
    }
}

public struct InboxScreen: View {
    @Environment(\.theme) private var theme
    /// As quatro janelas da Task U são cenas de verdade, abertas por aqui.
    @Environment(\.openWindow) private var openWindow

    // Intenção do usuário, não resultado. Quem decide o que aparece é
    // `PaneLayout`, cruzando isto com a largura que a janela tem agora. Guardar
    // a intenção separada do resultado é o que faz a lateral voltar sozinha
    // quando a janela cresce de novo.
    @State private var wantsSidebar = true
    @State private var wantsAgenda = true

    /// A terceira e a quarta intenções, e as únicas que sobrevivem ao
    /// encerramento do app. Como `wantsSidebar`, elas entram na `PaneLayout` e
    /// saem de lá recortadas pelo que a janela comporta.
    @State private var paneWidths = PaneWidthStore()

    /// Largura que o painel tinha quando o gesto começou. O `DragGesture`
    /// reporta translação acumulada, não posição, então a soma precisa de uma
    /// origem fixa — sem ela, cada quadro somaria em cima do quadro anterior e
    /// a divisória dispararia para o fim da tela.
    @State private var listDragOrigin: CGFloat?
    @State private var agendaDragOrigin: CGFloat?

    /// O retorno com "Desfazer" das ações destrutivas, partilhado entre a
    /// lista, o leitor e a tecla ⌫ — ver `ActionReceipts`.
    @State private var receipts = ActionReceipts()

    @State private var workspace: Workspace = .mail
    @State private var query = ""
    /// Espelho do foco da busca. O campo mora na barra; o Esc da janela
    /// precisa saber se cancelar a busca é a camada de agora.
    @State private var searchFocused = false
    @State private var assistantOpen = false
    @State private var assistantScope: InboxAssistantScope = .workspace
    @State private var assistantSessionID = UUID()
    @State private var readerAssistantOpen = false
    /// A conversa do painel lateral. Nasce ao abrir e é cancelada ao
    /// fechar — o dono é esta tela, não o painel.
    @State private var assistantConversation: AssistantConversation?
    /// A conversa do Dashboard vive aqui: a aba some da árvore ao ir para
    /// Caixa ou Agenda, e o `@State` dela ia embora com ela.
    @State private var dashboardConversation: AssistantConversation?
    @State private var dashboardSelectedMailID: String?
    @State private var dashboardReadingID: String?
    let store: MailStore

    /// De onde vem o "agora" da trilha e das três visões da agenda.
    ///
    /// O padrão é `.fixed(Fixtures.nowMinute)` de propósito: é o que mantém
    /// `RenderHarness`, as capturas e os testes deste pacote — que chamam
    /// `InboxScreen(store:)` sem este parâmetro — byte a byte iguais a antes.
    /// Só quem quer o relógio vivo (o app de verdade, com conta real) passa
    /// `.live` explicitamente — ver `OkamiUNIApp`.
    let clock: AgendaClock
    /// Estado real do modelo local, traduzido pela composição do app. O padrão
    /// mantém previews e harnesses no estado disponível das fixtures.
    let intelligencePresentation: IntelligencePresentation
    /// Serviço local injetado pelo app. `nil` mantém previews e harnesses
    /// determinísticos, com a superfície ainda renderizável.
    let textAssistant: (any TextAssisting)?
    /// A mesma preferência que o roteador consulta no momento da pergunta.
    /// Ela existe aqui só para rotular honestamente a superfície interativa.
    let assistantSettings: AssistantSettingsStore?
    let composerIntelligence: ComposerIntelligenceGenerator?
    let onMessagePresented: (String) -> Void
    let debugReaderAssistantOpen: Bool
    /// Nulo nas previews e no harness: aí não há diretor, e a barra mostra o
    /// estado vazio com o recarregar desligado.
    let accountsModel: AccountsModel?

    public init(
        store: MailStore,
        clock: AgendaClock = .fixed(Fixtures.nowMinute),
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        textAssistant: (any TextAssisting)? = nil,
        assistantSettings: AssistantSettingsStore? = nil,
        onMessagePresented: @escaping (String) -> Void = { _ in },
        accountsModel: AccountsModel? = nil
    ) {
        self.init(
            store: store,
            clock: clock,
            intelligencePresentation: intelligencePresentation,
            textAssistant: textAssistant,
            assistantSettings: assistantSettings,
            onMessagePresented: onMessagePresented,
            accountsModel: accountsModel,
            debugAssistantOpen: false,
            debugReaderAssistantOpen: false
        )
    }

    /// Porta exclusiva do harness offscreen; não sintetiza clique nem abre
    /// janela visível.
    init(
        store: MailStore,
        clock: AgendaClock = .fixed(Fixtures.nowMinute),
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        textAssistant: (any TextAssisting)? = nil,
        assistantSettings: AssistantSettingsStore? = nil,
        onMessagePresented: @escaping (String) -> Void = { _ in },
        accountsModel: AccountsModel? = nil,
        debugAssistantOpen: Bool,
        debugAssistantScope: InboxAssistantScope = .workspace,
        debugReaderAssistantOpen: Bool = false
    ) {
        self.store = store
        self.clock = clock
        self.intelligencePresentation = intelligencePresentation
        self.textAssistant = textAssistant
        self.assistantSettings = assistantSettings
        self.onMessagePresented = onMessagePresented
        self.accountsModel = accountsModel
        self.composerIntelligence = textAssistant.map {
            AssistantBridge.composerGenerator(using: $0)
        }
        self.debugReaderAssistantOpen = debugReaderAssistantOpen
        _assistantOpen = State(initialValue: debugAssistantOpen)
        _assistantScope = State(initialValue: debugAssistantScope)
        _readerAssistantOpen = State(initialValue: debugReaderAssistantOpen)
    }

    /// O **hoje** de tudo que esta tela desenha com data: o carimbo de cada
    /// linha da lista, o cabeçalho da trilha do dia e as três visões da aba
    /// Agenda.
    ///
    /// Um lugar só, e é o motivo de ele existir. O minuto já vinha do relógio
    /// desde a M3-4, mas o **dia** era `Fixtures.today` escrito à mão em dois
    /// pontos daqui — a trilha e a `CalendarScreen` —, de modo que com conta
    /// conectada a agenda continuava destacando terça, 25 de agosto: a âncora
    /// congelada do Marco 1. Dois "hojes" no mesmo processo também poriam um
    /// compromisso criado num dia e desenhado noutro; ver
    /// `MailStore.agendaReferenceDay`, que recebe este mesmo relógio pelo
    /// `OkamiUNIApp`.
    ///
    /// `internal`: `AgendaHojeTests` afere a decisão sem renderizar nada.
    var agendaAnchor: Date { clock.today }

    /// Contagem local vs Entrada do Gmail, quando uma conta está selecionada.
    var mailboxPortrait: MailboxPortrait? {
        let page = store.conversationPage(limit: MessageList.rowPageSize)
        let conta = store.selectedAccountID.flatMap { store.account($0) }
        let status: AccountStatus?
        if let id = store.selectedAccountID {
            status = accountsModel?.statuses.first { $0.accountID == id }
        } else {
            status = accountsModel?.statuses.count == 1 ? accountsModel?.statuses.first : nil
        }
        return MailboxPortrait.from(
            account: conta,
            status: status,
            localCount: page.messageCount,
            hasMore: page.hasMore
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Barra do topo (58px)
            WindowChrome(
                workspace: $workspace,
                query: $query,
                searchEverywhere: Binding(
                    get: { store.searchEverywhere },
                    set: { store.searchEverywhere = $0 }
                ),
                accountCount: store.accounts.count,
                onToggleSidebar: toggleSidebar,
                onToggleAgenda: toggleAgenda,
                onCompose: openNewMessage,
                accountMonogram: accountMonogram,
                onOpenAccounts: openAccounts,
                syncStatus: MailboxChromeStatus.from(accountsModel?.statuses ?? []),
                syncCaption: MailboxChromeStatus.lastSyncedCaption(from: accountsModel?.statuses ?? []),
                onReloadMailbox: accountsModel == nil ? nil : { [accountsModel] in
                    Task { await accountsModel?.syncNow() }
                },
                onSearchFocusChange: { searchFocused = $0 }
            )

            ZStack(alignment: .trailing) {
                // Conteúdo principal
                switch workspace {
                case .dashboard:
                    AgendaClockReader(clock) { now in
                        dashboardContent(now: now)
                    }
                case .mail:
                    // A lista depende do mesmo relógio vivo que o MailStore
                    // recebe. O reader a redesenha a cada minuto; assim, a
                    // chave temporal do store é relida ao cruzar a meia-noite
                    // sem criar outro timer nem afetar os retratos `.fixed`.
                    AgendaClockReader(clock) { _ in
                        mailContent
                    }
                case .calendar:
                    calendarContent
                }

                if assistantOpen {
                    assistantPanel
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(50)
                }
            }
        }
        .environment(receipts)
        .task { await subscribeToSource() }
        .task { await accountsModel?.start() }
        .onChange(of: query) { _, newQuery in
            Task { await searchChanged(to: newQuery) }
            workspace = workspace.switchingToMailIfSearching(newQuery)
        }
        // Revelar uma mensagem pode vir de **fora** desta tela: o botão "Email"
        // da janela 04 é outra cena e só alcança o `MailStore`. `revealCount`
        // é o único caminho que ele tem até a aba, e sem a troca o clique
        // selecionaria uma mensagem numa lista que não está na tela.
        .onChange(of: store.revealCount) { _, _ in
            workspace = .mail
            query = store.query
        }
        .bareKeyShortcuts { key in
            guard key == .escape else { return false }
            let wasSearch = searchFocused || BareKeyFocus.isSearchField(
                NSApp.keyWindow?.firstResponder
            )
            let acted = handleEscape()
            if acted, wasSearch {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            return acted
        }
    }

    // MARK: A fiação com a fonte
    //
    // Os dois métodos abaixo são o corpo do `.task` e o do `onChange` da busca,
    // fora dos modificadores **para poderem ser chamados de um teste**. A
    // primeira versão desta fiação era testada renderizando a tela numa janela
    // fora do ar e esperando o efeito com um teto de tempo: passava sozinha,
    // passava numa rodada da suíte inteira e falhava na seguinte, porque quem
    // entrega o `.task` de uma `View` é o ator principal, disputado por dezenas
    // de renderizações. Teste assim não prova fiação, sorteia. Chamados
    // diretamente, com um duplo de fonte que conta as chamadas, os dois viram
    // afirmação determinística — e o que resta sem cobertura é uma linha visível
    // em cada modificador acima.

    /// Assina a fonte. **Assina**, e não puxa: com a fonte em memória do
    /// Marco 1 `observe()` entrega um retrato e termina — exatamente o `load()`
    /// que estava aqui, e é por isso que a troca não muda nada sem conta. Com o
    /// banco, é ele que acorda a lista enquanto a carga inicial baixa: sem isto
    /// a pessoa adicionaria uma conta e ficaria olhando uma tela parada até
    /// reabrir o app.
    func subscribeToSource() async {
        await store.observe()
    }

    /// A busca mudou: o termo vai para o modelo e o **corpo** é perguntado à
    /// fonte.
    ///
    /// Perguntar é assíncrono (é consulta ao índice do banco) e a lista é
    /// síncrona — a tela não pode esperar disco a cada tecla. Fonte que não sabe
    /// procurar no corpo devolve "não sei", e a busca do Marco 1 (remetente,
    /// assunto, prévia) continua sendo o que decide.
    func searchChanged(to termo: String) async {
        store.query = termo
        await store.refreshBodyMatches()
    }

    /// Esc: uma camada por toque. A busca focada, o assistente, o lote, o
    /// termo que ainda recorta a lista. `searchFocused` o teste passa; na
    /// tela, o foco vivo da barra e o respondedor do AppKit se combinam.
    @discardableResult
    func handleEscape(searchFocused forced: Bool? = nil) -> Bool {
        let focused: Bool
        if let forced {
            focused = forced
        } else {
            #if canImport(AppKit)
            focused = searchFocused || BareKeyFocus.isSearchField(
                NSApp.keyWindow?.firstResponder
            )
            #else
            focused = searchFocused
            #endif
        }
        let termo = query.isEmpty ? store.query : query
        guard let step = EscapeCancel.next(
            searchFocused: focused,
            query: termo,
            assistantOpen: assistantOpen,
            selecting: store.hasChecked,
            overlayOpen: dashboardReadingID != nil
        ) else { return false }
        switch step {
        case .search, .searchQuery:
            query = ""
            store.query = ""
            searchFocused = false
            return true
        case .overlay:
            dashboardReadingID = nil
            return true
        case .assistant:
            closeAssistant()
            return true
        case .selection:
            store.clearChecked()
            return true
        }
    }

    /// O `GeometryReader` existe por um motivo só: dar a largura real da janela
    /// a `PaneLayout`. A decisão em si não mora aqui — este `View` é `@MainActor`
    /// e a aritmética precisa ser chamável de teste nonisolated.
    /// `internal` (era `private`) para `AgendaHojeTests` fotografar só a coluna
    /// da trilha e provar que a data do cabeçalho dela segue o relógio.
    var mailContent: some View {
        GeometryReader { proxy in
            let layout = PaneLayout.resolve(
                width: proxy.size.width,
                wantsSidebar: wantsSidebar,
                wantsAgenda: wantsAgenda,
                draggedListWidth: paneWidths.messageList,
                draggedAgendaWidth: paneWidths.agenda
            )

            HStack(spacing: 0) {
                // Barra lateral. Ela nunca some por completo: recolhida, é a
                // trilha de 62pt da Task 7B.
                if layout.sidebarExpanded {
                    FolderSidebar(
                        store: store,
                        width: layout.sidebarWidth,
                        intelligencePresentation: intelligencePresentation,
                        onOpenAssistant: openWorkspaceAssistant,
                        onOpenSettings: openAccounts,
                        onCompose: openNewMessage,
                        onOpenAccounts: openAccounts
                    )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    SidebarRail(
                        store: store,
                        width: layout.sidebarWidth,
                        intelligencePresentation: intelligencePresentation,
                        onOpenAssistant: openWorkspaceAssistant,
                        onOpenSettings: openAccounts,
                        onCompose: openNewMessage,
                        onOpenAccounts: openAccounts
                    )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // Lista de mensagens — o único painel cuja largura de fato varia.
                MessageList(
                    store: store,
                    width: layout.messageListWidth,
                    // O carimbo de horário de cada linha compara a data da
                    // mensagem com **este** dia: `Fixtures.today` no mundo
                    // congelado dos retratos, o dia da máquina com conta real.
                    today: agendaAnchor,
                    onOpenWindow: openMessageWindow,
                    portraitCaption: mailboxPortrait?.countCaption,
                    gapCaption: mailboxPortrait?.gapCaption,
                    onPullMissing: mailboxPortrait?.gapCaption == nil ? nil : { [accountsModel] in
                        Task { await accountsModel?.syncNow() }
                    }
                )

                // Painel de leitura: fica com tudo o que sobrar.
                ReaderPane(
                    store: store,
                    debugEmailAssistantOpen: debugReaderAssistantOpen,
                    onCompose: { openWindow(id: UNIWindow.composer, value: $0.value) },
                    attachmentSaver: NativeAttachmentSaver(),
                    intelligence: composerIntelligence,
                    intelligencePresentation: intelligencePresentation,
                    makeAssistantConversation: readerConversationFactory,
                    onMessagePresented: onMessagePresented,
                    onEmailAssistantOpenChange: { open in
                        readerAssistantOpen = open
                    }
                )
                // O popover sai dos limites do leitor para caber ao lado do
                // ícone. Elevar só o cabeçalho não o coloca acima da lista.
                .zIndex(readerAssistantOpen ? 100 : 0)

                // Trilha de agenda — o primeiro painel a sair quando aperta.
                // A data do cabeçalho e o minuto seguem o **mesmo** relógio:
                // fixos nos retratos e nas capturas, vivos com conta real.
                // Escrever `Fixtures.today` aqui era o que fazia a trilha dizer
                // "Terça-feira, 25 de agosto" em qualquer dia do ano.
                if layout.agendaVisible {
                    AgendaClockReader(clock) { now in
                        AgendaRail(
                            store: store,
                            now: now,
                            headerDate: agendaAnchor,
                            width: layout.agendaRailWidth,
                            onOpenEvent: openEventWindow,
                            onRevealMessage: reveal
                        )
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // Só as duas decisões discretas animam. Animar `messageListWidth`
            // junto faria a lista arrastar atrás do cursor durante o
            // redimensionamento, com 0.18s de atraso a cada quadro.
            .animation(Self.paneTransition, value: layout.sidebarExpanded)
            .animation(Self.paneTransition, value: layout.agendaVisible)
            // As divisórias vêm por cima, e não dentro do `HStack`: seis pontos
            // de alvo entre a lista e o leitor empurrariam a tela inteira em
            // seis pontos e desalinhariam o marco da Task P. Aqui elas custam
            // zero ao layout.
            .overlay(alignment: .topLeading) {
                dividers(layout: layout, windowWidth: proxy.size.width)
                    // A calha é um overlay do HStack inteiro; nenhum zIndex de
                    // um filho passa por ela. Enquanto o popover está aberto,
                    // a linha some e deixa de roubar clique.
                    .opacity(readerAssistantOpen ? 0 : 1)
                    .allowsHitTesting(!readerAssistantOpen)
            }
            // O referencial em que o arraste é medido, e o motivo de ele vir
            // **depois** do `.overlay`: assim as divisórias são descendentes
            // dele. O retângulo que ele nomeia é o do conteúdo da janela, preso
            // ao `proxy` — o único ancestral por aqui que não se mexe enquanto a
            // divisória se mexe. Medir no espaço local da própria calha fazia a
            // divisória andar metade do cursor; ver `PaneDivider.coordinateSpace`.
            .coordinateSpace(.named(PaneDivider.coordinateSpace))
        }
    }

    // MARK: - As divisórias arrastáveis

    /// As duas calhas de arraste, posicionadas sobre as linhas que os painéis
    /// já desenham: lista ↔ leitor e leitor ↔ agenda.
    ///
    /// A da lateral fica de fora de propósito. A lateral não tem largura
    /// contínua: ela é aberta (248) ou trilha (72), duas medidas canônicas que
    /// a `SidebarRail` e a `FolderSidebar` usam para escolher o que desenham em
    /// cada uma. Torná-la arrastável não é acrescentar um alvo, é trocar o
    /// modelo dela — e o botão da barra do topo já faz o que ela precisa.
    @ViewBuilder
    private func dividers(layout: PaneLayout, windowWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            divider(
                at: layout.messageListTrailingEdge,
                onDrag: { translation in
                    let origin = listDragOrigin ?? layout.messageListWidth
                    listDragOrigin = origin
                    // Puxar para a direita alarga a lista.
                    paneWidths.setMessageList(origin + translation)
                },
                onEnd: { listDragOrigin = nil },
                onReset: {
                    withAnimation(Self.paneTransition) { paneWidths.resetMessageList() }
                }
            )

            if layout.agendaVisible {
                divider(
                    at: layout.agendaLeadingEdge(inWindowOfWidth: windowWidth),
                    onDrag: { translation in
                        let origin = agendaDragOrigin ?? layout.agendaRailWidth
                        agendaDragOrigin = origin
                        // A agenda cresce para a esquerda: puxar para a direita
                        // a estreita.
                        paneWidths.setAgenda(origin - translation)
                    },
                    onEnd: { agendaDragOrigin = nil },
                    onReset: {
                        withAnimation(Self.paneTransition) { paneWidths.resetAgenda() }
                    }
                )
            }
        }
    }

    /// Centra o alvo de 6pt sobre a linha em `x`, para o ponteiro poder chegar
    /// pelos dois lados.
    private func divider(
        at x: CGFloat,
        onDrag: @escaping (CGFloat) -> Void,
        onEnd: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        PaneDivider(onDrag: onDrag, onEnd: onEnd, onReset: onReset)
            .offset(x: PaneDivider.leadingEdge(centeredOn: x))
    }

    /// A mesma curva do toggle manual, para recolher por arraste e por clique
    /// parecerem a mesma coisa.
    private static let paneTransition: Animation = .easeInOut(duration: 0.18)

    /// Briefing de prioridades. Sem lateral e sem trilha: o recorte já
    /// mistura e-mail e agenda, e as outras duas abas existem para o
    /// detalhe. Clicar um e-mail abre a leitura por cima; "Abrir na Caixa"
    /// é que cai em `reveal`.
    func dashboardContent(now: Int) -> some View {
        // A conversa é criada uma vez e guardada; construí-la no corpo faria
        // uma máquina de estado nova a cada repintura.
        let conversation = dashboardConversation ?? makeDashboardConversation()
        return DashboardScreen(
            store: store,
            now: now,
            today: agendaAnchor,
            conversation: conversation,
            selectedMailID: $dashboardSelectedMailID,
            readingMailID: $dashboardReadingID,
            onPresented: onMessagePresented,
            onOpenMessage: { reveal($0.id) },
            onOpenEvent: openEventWindow,
            onShowMail: { workspace = .mail },
            onShowCalendar: { workspace = .calendar },
            onOpenSettings: openAccounts
        )
        .task {
            if dashboardConversation == nil { dashboardConversation = conversation }
        }
    }

    /// A aba Agenda leva a **mesma** barra lateral do email, porque no
    /// protótipo ela é do shell e não da tela do email — ver `CalendarScreen`.
    /// Por isso `wantsSidebar` atravessa daqui: é a intenção que o botão da
    /// barra do topo mexe, e ela tem de valer nas duas abas.
    ///
    /// `internal` (era `private`) pelo mesmo motivo do `mailContent`.
    var calendarContent: some View {
        AgendaClockReader(clock) { now in
            CalendarScreen(
                store: store,
                now: now,
                anchor: agendaAnchor,
                wantsSidebar: wantsSidebar,
                intelligencePresentation: intelligencePresentation,
                onOpenAssistant: openWorkspaceAssistant,
                onCompose: openNewMessage,
                onOpenAccounts: openAccounts,
                onOpenEvent: openEventWindow,
                onRevealMessage: reveal
            )
        }
    }

    // MARK: - Janelas

    /// 05 Email em janela. Gancho do duplo clique na lista.
    private func openMessageWindow(_ message: Message) {
        if message.bucket == .drafts {
            openWindow(id: UNIWindow.composer, value: ComposerRoute.draft(messageID: message.id).value)
            return
        }
        openWindow(id: UNIWindow.message, value: message.id)
    }

    /// 04 Detalhe do compromisso. Gancho do clique na trilha de agenda.
    private func openEventWindow(_ item: AgendaItem) {
        openWindow(id: UNIWindow.event, value: item.id)
    }

    /// "Ir para o email de origem", do menu de contexto de um compromisso.
    ///
    /// Precisa trocar de aba, e é por isso que ele mora aqui e não no menu:
    /// `workspace` é estado desta tela. Sem a troca, o item clicado da aba
    /// Agenda selecionaria a mensagem numa lista que não está na tela — a
    /// definição de botão mudo.
    private func reveal(_ messageID: String) {
        workspace = .mail
        store.reveal(messageID)
        // O campo de busca é `@State` daqui e o `MailStore` é a outra ponta do
        // mesmo valor. `reveal` pode ter limpado a busca do lado de lá; sem
        // esta linha o campo continuaria escrito com o termo que já não filtra
        // nada.
        query = store.query
    }

    /// 06 Nova mensagem. Chega por ⌘N (menu do app) e, quando a barra do topo
    /// ganhar o botão "Escrever", por ele — é este o fechamento que o
    /// `WindowChrome` precisa receber.
    public func openNewMessage() {
        openWindow(id: UNIWindow.newMessage, value: store.selectedAccountID ?? "")
    }

    private func openAccounts() {
        openWindow(id: UNIWindow.accounts)
    }

    private var accountMonogram: String {
        let selected = store.selectedAccountID.flatMap { store.account($0) }
        let address = selected?.address
            ?? store.accounts.first?.address
            ?? "UNI"
        let local = address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address
        return String(local.prefix(2)).uppercased()
    }

    private func toggleSidebar() {
        withAnimation(Self.paneTransition) {
            wantsSidebar.toggle()
        }
    }

    private func toggleAgenda() {
        withAnimation(Self.paneTransition) {
            wantsAgenda.toggle()
        }
    }

    // MARK: - Assistente

    private func assistantContext(for scope: InboxAssistantScope) -> AssistantContext {
        switch scope {
        case .workspace:
            let accountCount = store.accounts.count
            let emailCount = store.messages.count
            let agendaCount = store.agenda.count
            return AssistantContext(
                subject: "Todo o OkamiUNI",
                sender: "\(accountCount) \(accountCount == 1 ? "conta" : "contas") · \(emailCount) \(emailCount == 1 ? "email" : "emails")",
                conversationLabel: "\(agendaCount) \(agendaCount == 1 ? "compromisso" : "compromissos")"
            )
        case let .email(messageID):
            guard let message = store.messages.first(where: { $0.id == messageID }) else {
                return AssistantContext(
                    subject: "Email indisponível",
                    sender: "A mensagem saiu da caixa"
                )
            }
            let count = store.conversation(of: messageID)?.count ?? 1
            return AssistantContext(
                subject: message.subject,
                sender: message.from.display,
                conversationLabel: count > 1 ? "\(count) mensagens" : nil
            )
        }
    }

    private var assistantPanel: some View {
        // A conversa é criada por quem abre o painel. O `??` cobre a porta do
        // harness, que abre a superfície sem passar pela ação.
        let conversation = assistantConversation ?? makeConversation(for: assistantScope)
        return AssistantPanel(
            conversation: conversation,
            onOpenSettings: openAccounts,
            onClose: closeAssistant
        )
        .task {
            if assistantConversation == nil { assistantConversation = conversation }
        }
        .id(assistantSessionID)
        .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 10)
    }

    /// Nula quando não há assistente: é o que apaga o botão do leitor em
    /// vez de o deixar aceso sem destino.
    private var readerConversationFactory: ((String) -> AssistantConversation)? {
        guard textAssistant != nil else { return nil }
        return { messageID in makeConversation(for: .email(messageID)) }
    }

    private var assistantDestination: AssistantDestination {
        assistantSettings.map { AssistantDestination(settings: $0.snapshot()) } ?? .unconfigured
    }

    /// Só é conhecido quando o provedor é uma assinatura: sem ele um 401 do
    /// Grok viraria "tentar de novo" em vez de "reconectar".
    private var assistantProvider: AssistantProviderOAuthKind? {
        guard let settings = assistantSettings?.snapshot() else { return nil }
        return settings.provider == .providerOAuth ? settings.providerOAuth.kind : nil
    }

    func makeConversation(for scope: InboxAssistantScope) -> AssistantConversation {
        AssistantConversation(
            scope: scope.mode,
            context: assistantContext(for: scope),
            destination: assistantDestination,
            engine: makeEngine(
                supportsDraftReply: scope.mode == .email,
                resolving: { scope }
            ),
            provider: assistantProvider
        )
    }

    /// O dashboard troca de foco sem trocar de conversa: o escopo é
    /// resolvido no momento da chamada, a partir do email selecionado.
    private func makeDashboardConversation() -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: AssistantContext(subject: "Caixa e agenda de hoje"),
            destination: assistantDestination,
            engine: makeEngine(
                supportsDraftReply: textAssistant != nil,
                resolving: { dashboardSelectedMailID.map(InboxAssistantScope.email) ?? .workspace }
            ),
            provider: assistantProvider
        )
    }

    private func makeEngine(
        supportsDraftReply: Bool,
        resolving scope: @escaping @MainActor () -> InboxAssistantScope
    ) -> AssistantEngine {
        guard let textAssistant else { return .unavailable }
        return AssistantBridge.engine(
            using: textAssistant,
            supportsDraftReply: supportsDraftReply,
            mailContext: { try await self.mailContext(for: scope()) },
            currentDraft: {
                guard case let .email(id) = scope() else { return "" }
                return store.replyDraft(for: id)?.text ?? ""
            }
        )
    }

    /// O que `askAssistant` fazia antes, agora só a resolução do contexto —
    /// a máquina de estado é da conversa.
    private func mailContext(for scope: InboxAssistantScope) async throws -> AssistantMailContext {
        switch scope {
        case .workspace:
            // O snapshot é global e leve: cabeçalhos/prévias, contagens e
            // agenda. Corpos integrais continuam no botão do próprio e-mail.
            return AssistantMailContext(workspace: store)
        case let .email(messageID):
            let ids = store.conversation(of: messageID)?.messageIDs ?? [messageID]
            for id in ids { await store.loadBodyIfNeeded(id) }
            guard let loaded = store.assistantMailContext(for: messageID) else {
                throw TextAssistantError.invalidRequest(
                    "O email selecionado não está mais disponível."
                )
            }
            return loaded
        }
    }

    private func openWorkspaceAssistant() {
        assistantScope = .workspace
        assistantSessionID = UUID()
        assistantConversation = makeConversation(for: .workspace)
        withAnimation(Self.paneTransition) { assistantOpen = true }
    }

    private func openEmailAssistant() {
        guard let messageID = store.selectedMessageID else { return }
        assistantScope = .email(messageID)
        assistantSessionID = UUID()
        assistantConversation = makeConversation(for: .email(messageID))
        withAnimation(Self.paneTransition) { assistantOpen = true }
    }

    private func closeAssistant() {
        assistantConversation?.cancel()
        withAnimation(Self.paneTransition) { assistantOpen = false }
    }

}

#if os(macOS)
#Preview {
    InboxScreen(store: MailStore(source: InMemoryMailSource.fixtures))
        .environment(ThemeStore())
        .frame(width: 1440, height: 916)
}
#endif
