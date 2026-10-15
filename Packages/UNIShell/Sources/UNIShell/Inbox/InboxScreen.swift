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
    @State private var assistantActionFailure: String?
    @State private var assistantScope: InboxAssistantScope = .workspace
    @State private var assistantSessionID = UUID()
    /// A conversa do painel lateral. Nasce ao abrir e é cancelada ao
    /// fechar — o dono é esta tela, não o painel.
    @State private var assistantConversation: AssistantConversation?
    /// A conversa do Dashboard vive aqui: a aba some da árvore ao ir para
    /// Caixa ou Agenda, e o `@State` dela ia embora com ela.
    @State private var dashboardConversation: AssistantConversation?
    @State private var dashboardBriefing: AssistantConversation?
    @State private var dashboardSelectedMailID: String?
    @State private var dashboardReadingID: String?
    /// O filtro do dashboard 08 vive aqui para sobreviver à troca de aba —
    /// "persistir na sessão" é literalmente isto.
    @State private var dashboardFilter = DayPlan.Filter.standard
    /// O estado da aba Agenda que o shell divide com a `CalendarScreen`: no
    /// Vidro o mês miúdo mora na coluna de contexto e a grade no painel ao
    /// lado. Ver `CalendarShellState`.
    @State private var calendarShell = CalendarShellState()
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
    /// A fila de análise automática parada. `nil` enquanto ela corre — e é o
    /// padrão de previews e harnesses, que não têm coordenador.
    let analysisPause: AnalysisPauseState?
    /// De onde o resumo de uma mensagem veio, pela versão do motor gravada
    /// com ele. É o que a legenda do TL;DR mostra: dizer "neste Mac" sobre um
    /// resumo que saiu daqui seria mentira, e nomear o provedor em cima de um
    /// resumo que ficou no histórico local seria a mentira oposta.
    let analysisDestination: @Sendable (String?) -> AssistantDestination
    /// Serviço local injetado pelo app. `nil` mantém previews e harnesses
    /// determinísticos, com a superfície ainda renderizável.
    let textAssistant: (any TextAssisting)?
    /// A mesma preferência que o roteador consulta no momento da pergunta.
    /// Ela existe aqui só para rotular honestamente a superfície interativa.
    let assistantSettings: AssistantSettingsStore?
    let agentServices: AgentApplicationServices
    let composerIntelligence: ComposerIntelligenceGenerator?
    let onMessagePresented: (String) -> Void
    let debugReaderAssistantOpen: Bool
    /// Nulo nas previews e no harness: aí não há diretor, e a barra mostra o
    /// estado vazio com o recarregar desligado.
    let accountsModel: AccountsModel?
    /// A fila de análise automática. A barra fina do chrome lê `isProcessing`
    /// dela — sem isto a fila trabalhava em silêncio.
    let analysisQueue: AnalysisQueueStateModel?
    /// A análise do acervo, que sabe onde está e quanto falta. É o único
    /// trabalho desta tela com fração de verdade.
    let backlogAnalysis: BacklogAnalysisController?
    /// Os rascunhos antecipados que a fila de UNISync escreve. `nil` nas
    /// previews e no harness — o dashboard então não promete resposta.
    let readyDrafts: ReadyDraftsModel?
    /// A fila de rascunho antecipado. Serve a **uma** coisa aqui: o botão
    /// "Gerar as prontas" do painel do dia, que é pedido explícito da pessoa e
    /// por isso não passa pelo portão do opt-in da fila de fundo.
    let readyDraftQueue: ReadyDraftCoordinator?
    /// A sessão do assistente: a gaveta (09), a janela destacada (10) e a
    /// conversa que as duas dividem.
    ///
    /// Vem de fora porque a janela destacada é **cena própria** e não está
    /// dentro desta árvore: só uma dona acima das duas faz "a mesma conversa
    /// nos dois lugares" ser verdade. O padrão é uma sessão local, para
    /// previews e para o harness.
    let assistantSession: AssistantSession
    /// O estado das atualizações, para o rodapé da lateral poder acender o
    /// botão da versão nova. `nil` nas previews e no harness.
    let updates: UpdateController?

    public init(
        store: MailStore,
        clock: AgendaClock = .fixed(Fixtures.nowMinute),
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisPause: AnalysisPauseState? = nil,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        textAssistant: (any TextAssisting)? = nil,
        assistantSettings: AssistantSettingsStore? = nil,
        agentServices: AgentApplicationServices = .init(),
        onMessagePresented: @escaping (String) -> Void = { _ in },
        accountsModel: AccountsModel? = nil,
        analysisQueue: AnalysisQueueStateModel? = nil,
        backlogAnalysis: BacklogAnalysisController? = nil,
        readyDrafts: ReadyDraftsModel? = nil,
        readyDraftQueue: ReadyDraftCoordinator? = nil,
        assistantSession: AssistantSession? = nil,
        updates: UpdateController? = nil
    ) {
        self.init(
            store: store,
            clock: clock,
            intelligencePresentation: intelligencePresentation,
            analysisPause: analysisPause,
            analysisDestination: analysisDestination,
            textAssistant: textAssistant,
            assistantSettings: assistantSettings,
            agentServices: agentServices,
            onMessagePresented: onMessagePresented,
            accountsModel: accountsModel,
            analysisQueue: analysisQueue,
            backlogAnalysis: backlogAnalysis,
            readyDrafts: readyDrafts,
            readyDraftQueue: readyDraftQueue,
            assistantSession: assistantSession,
            updates: updates,
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
        analysisPause: AnalysisPauseState? = nil,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        textAssistant: (any TextAssisting)? = nil,
        assistantSettings: AssistantSettingsStore? = nil,
        agentServices: AgentApplicationServices = .init(),
        onMessagePresented: @escaping (String) -> Void = { _ in },
        accountsModel: AccountsModel? = nil,
        analysisQueue: AnalysisQueueStateModel? = nil,
        backlogAnalysis: BacklogAnalysisController? = nil,
        readyDrafts: ReadyDraftsModel? = nil,
        readyDraftQueue: ReadyDraftCoordinator? = nil,
        assistantSession: AssistantSession? = nil,
        updates: UpdateController? = nil,
        debugAssistantOpen: Bool,
        debugAssistantScope: InboxAssistantScope = .workspace,
        debugReaderAssistantOpen: Bool = false,
        debugWorkspace: Workspace = .mail,
        /// A lateral recolhida de saída. O harness não clica em nada (ver
        /// `RenderHarness`), então sem esta porta o estado recolhido seria um
        /// que nenhum PNG mostraria.
        debugWantsSidebar: Bool = true
    ) {
        self.store = store
        self.clock = clock
        self.intelligencePresentation = intelligencePresentation
        self.analysisPause = analysisPause
        self.analysisDestination = analysisDestination
        self.textAssistant = textAssistant
        self.assistantSettings = assistantSettings
        self.agentServices = agentServices
        self.onMessagePresented = onMessagePresented
        self.accountsModel = accountsModel
        self.analysisQueue = analysisQueue
        self.backlogAnalysis = backlogAnalysis
        self.readyDrafts = readyDrafts
        self.readyDraftQueue = readyDraftQueue
        self.assistantSession = assistantSession ?? AssistantSession()
        self.updates = updates
        self.composerIntelligence = textAssistant.map {
            AssistantBridge.composerGenerator(using: $0)
        }
        self.debugReaderAssistantOpen = debugReaderAssistantOpen
        _assistantOpen = State(initialValue: debugAssistantOpen)
        _assistantScope = State(initialValue: debugAssistantScope)
        _workspace = State(initialValue: debugWorkspace)
        _wantsSidebar = State(initialValue: debugWantsSidebar)
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
    /// `MailStore.agendaReferenceDate`. A tela lê a âncora já atualizada junto
    /// com os eventos, nunca um Date() independente: à meia-noite isso punha
    /// aniversários e reuniões na coluna do dia seguinte.
    ///
    /// `internal`: `AgendaHojeTests` afere a decisão sem renderizar nada.
    var agendaAnchor: Date { store.agendaReferenceDate }

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

    /// Tudo que segura o dono esperando, somado no tipo puro `ChromeWorkload`.
    ///
    /// A barra fina sob a busca é a única animação que ele já reconhece como
    /// "está carregando", e antes disto ela só falava de sincronização — o
    /// dashboard e o assistente trabalhavam sem dizer nada. Aqui só se
    /// **recolhem** os sinais; a regra de como eles somam mora fora da `View`,
    /// com teste (`ChromeWorkloadTests`).
    /// "Gerar as prontas" em andamento.
    @State private var gerandoProntas = false

    var chromeWorkload: ChromeWorkload {
        var jobs: [ChromeWork] = [.sync(MailboxChromeStatus.from(accountsModel?.statuses ?? []))]
        for conversa in [dashboardConversation, dashboardBriefing, assistantConversation].compactMap({ $0 }) {
            if let kind = conversa.workKind {
                jobs.append(.assistant(kind: kind, destination: conversa.destination))
            }
        }
        // O "Gerar as prontas" do painel também segura o dono esperando: sem
        // isto o botão parecia não ter feito nada por dez segundos.
        if analysisQueue?.isProcessing == true || gerandoProntas { jobs.append(.analysisQueue) }
        if let acervo = backlogAnalysis, acervo.isRunning {
            jobs.append(.backlog(done: max(0, acervo.total - acervo.remaining), total: acervo.total))
        }
        if store.isLoadingAnyBody { jobs.append(.body) }
        return ChromeWorkload.combining(jobs)
    }

    public var body: some View {
        // Um shell só, para os 28 temas. A navegação é o trilho da esquerda, a
        // coluna de contexto é a segunda metade do painel da lateral e as
        // telas flutuam ao lado — era o shell dos dois temas Vidro, e agora é
        // o shell do app. O que o tema ainda decide é o **material**: o Vidro
        // flutua translúcido sobre o gradiente, os 26 clássicos flutuam
        // opacos sobre o `paper` deles (ver `PanelStyle.opaque(for:)`).
        shell
        .environment(receipts)
        // O aviso é a peça do app (`UNIConfirmation`), e não o `.alert` do
        // sistema: ele não vira com o tema e punha um terceiro idioma de
        // diálogo nesta tela. Uma ação só — não há o que escolher aqui —, e
        // por isso ela sai no acento em vez do vermelho.
        .uniConfirmation(
            assistantActionFailure.map {
                UNIConfirmationText(
                    title: L10n.tr("Não foi possível preparar a resposta"),
                    detail: $0,
                    confirm: L10n.tr("Entendi"),
                    cancel: L10n.tr("Fechar"),
                    icon: "exclamationmark.triangle",
                    isDestructive: false
                )
            },
            onConfirm: { assistantActionFailure = nil },
            onCancel: { assistantActionFailure = nil }
        )
        // A janela destacada clica no **mesmo** executor da gaveta: ela não
        // tem store nem fila, e um segundo caminho lá divergiria daqui.
        .task {
            assistantSession.install(runner: runProposalCard, reveal: { reveal($0) })
        }
        // O "Desfazer" do cartão vale enquanto **o recibo da leva dele**
        // estiver de pé. Um recibo de outra origem não serve, e por isso a
        // comparação é por id e não por "existe algum".
        .onChange(of: receipts.current?.id) { _, id in
            assistantSession.receiptChanged(to: id)
        }
        .task { await subscribeToSource() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.updateAgendaDay()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            store.updateAgendaDay()
        }
        .task {
            guard clock == .live else { return }
            while !Task.isCancelled {
                store.updateAgendaDay()
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
            }
        }
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

    // MARK: - O shell

    /// A folga entre painéis e deles para a borda da janela. Ela vem do
    /// `resolvedPanel`, que todo tema tem — e é a mesma em todos, porque é
    /// medida do desenho e não da paleta.
    private var gap: CGFloat { theme.panelGap }

    /// O fundo (gradiente no Vidro, `paper` nos outros), o painel da lateral
    /// (trilho + contexto) e os painéis da tela que está no ar.
    private var shell: some View {
        GeometryReader { proxy in
            let contextOpen = PaneLayout.contextSidebarOpen(
                width: proxy.size.width, wantsSidebar: wantsSidebar
            )
            let sidebarWidth = PaneLayout.glassSidebarWidth(contextOpen: contextOpen)
            // Duas folgas de borda e uma entre a lateral e o conteúdo.
            let contentWidth = max(
                0, proxy.size.width - sidebarWidth - gap * 3
            )

            ZStack(alignment: .trailing) {
                Backdrop()

                HStack(spacing: gap) {
                    sidebarPanel(contextOpen: contextOpen)
                    content(width: contentWidth)
                }
                .padding(gap)
                .opacity(
                    assistantSession.isDrawerOpen
                        ? AssistantDrawerMetrics.backdropOpacity : 1
                )

                if assistantSession.isDrawerOpen {
                    assistantDrawer
                        .transition(.move(edge: .trailing))
                        .zIndex(60)
                }

                if assistantOpen {
                    assistantPanel
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(50)
                }
            }
            .animation(Self.paneTransition, value: contextOpen)
        }
        // Duplo clique no alto da janela (gradiente ou vazio do trilho) faz o
        // que o sistema manda, e o arraste da janela pelo fundo continua de pé
        // — ver `TitleBarDoubleClick`, que também liga o
        // `isMovableByWindowBackground`.
        .titleBarDoubleClick(controls: [], barHeight: AppRail.dragStripHeight)
        // Os semáforos nativos sobem para o alto do trilho, dentro do painel.
        .trafficLightsInRail()
    }

    private func sidebarPanel(contextOpen: Bool) -> some View {
        HStack(spacing: 0) {
            AppRail(
                store: store,
                workspace: $workspace,
                intelligencePresentation: intelligencePresentation,
                onOpenAssistant: toggleDrawer,
                onOpenSettings: openAccounts,
                accountMonogram: accountMonogram,
                isSynced: !chromeWorkload.status.isBusy,
                updates: updates,
                contextCollapsed: !contextOpen,
                onReopenContext: expandSidebarAction
            )
            if contextOpen {
                // A hairline entre o trilho e o contexto, como no protótipo:
                // `border-right` no `<nav>` só quando a coluna está aberta.
                Rectangle()
                    .fill(theme.line.color)
                    .frame(width: 1)
                contextSidebar
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity)
        .glassPanel(theme)
    }

    private var contextSidebar: some View {
        ContextSidebar(
            store: store,
            workspace: workspace,
            query: $query,
            searchEverywhere: Binding(
                get: { store.searchEverywhere },
                set: { store.searchEverywhere = $0 }
            ),
            dashboardFilter: $dashboardFilter,
            intelligencePresentation: intelligencePresentation,
            analysisPause: analysisPause,
            syncStatus: chromeWorkload.status,
            statusPhrase: statusPhrase,
            onReloadMailbox: accountsModel == nil ? nil : { [accountsModel] in
                Task { await accountsModel?.syncNow() }
            },
            onSearchFocusChange: { searchFocused = $0 },
            onCollapse: toggleSidebar,
            onCompose: openNewMessage,
            onNewAppointment: { calendarShell.creatingAppointment = true },
            onOpenAssistant: openWorkspaceAssistant,
            onOpenSettings: openAccounts,
            updates: updates,
            calendarContent: workspace == .calendar
                ? AnyView(
                    CalendarSidebar(
                        store: store,
                        width: ContextSidebar.width,
                        intelligencePresentation: intelligencePresentation,
                        onOpenAssistant: openWorkspaceAssistant,
                        onCreate: { calendarShell.creatingAppointment = true },
                        onOpenAccounts: openAccounts,
                        anchor: agendaAnchor,
                        selectedDayOffset: calendarShell.selectedDayOffset,
                        onPickDay: { calendarShell.selectedDayOffset = $0 },
                        chrome: .embedded
                    )
                )
                : nil
        )
    }

    /// A frase que a barra fina de estado diz. Vinha da `WindowChrome`, que no
    /// shell Vidro já não existe nesta janela.
    var statusPhrase: String {
        if let detail = chromeWorkload.detail { return detail }
        if let caption = MailboxChromeStatus.lastSyncedCaption(
            from: accountsModel?.statuses ?? []
        ) {
            return L10n.tr("Atualizada \(caption)")
        }
        return chromeWorkload.status.label
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch workspace {
        case .dashboard:
            AgendaClockReader(clock) { now in
                dashboardContent(now: now)
            }
            .glassPanel(theme)
        case .mail:
            AgendaClockReader(clock) { _ in
                mailContent(width: width)
            }
        case .calendar:
            calendarContent
                .glassPanel(theme)
        }
    }

    /// A Caixa no shell Vidro: dois painéis, lista e leitor.
    ///
    /// A trilha da agenda (a quarta coluna) **não é colocada** aqui. O código
    /// dela segue inteiro e testado — ela continua montada no shell clássico —
    /// mas no redesenho o que o dono precisa dela cabe numa cápsula no topo do
    /// leitor ("Próximo: … em N min"), e três painéis já ocupam a janela.
    /// `internal` (era `private`) para `AgendaHojeTests` fotografar a Caixa
    /// e provar que o que ela desenha segue o relógio, e não a fixture.
    func mailContent(width: CGFloat) -> some View {
        let listWidth = PaneLayout.glassListWidth(
            contentWidth: max(0, width - gap), dragged: paneWidths.messageList
        )
        return HStack(spacing: gap) {
            MessageList(
                store: store,
                width: listWidth,
                today: agendaAnchor,
                onOpenWindow: openMessageWindow,
                portraitCaption: mailboxPortrait?.countCaption,
                gapCaption: mailboxPortrait?.gapCaption,
                onPullMissing: mailboxPortrait?.gapCaption == nil ? nil : { [accountsModel] in
                    Task { await accountsModel?.syncNow() }
                },
                // Só a linha de vidro escreve "· resposta pronta"; sem fila
                // de rascunho antecipado o dicionário é vazio e ela cala.
                readyDrafts: readyDrafts?.drafts ?? [:],
                // Recolhida, a lateral volta por aqui: o botão nasce antes do
                // "Hoje", na ponta esquerda do cabeçalho da lista.
                onExpandSidebar: expandSidebarAction
            )
            .glassPanel(theme)

            ReaderPane(
                store: store,
                debugEmailAssistantOpen: debugReaderAssistantOpen,
                onCompose: { openWindow(id: UNIWindow.composer, value: $0.value) },
                attachmentSaver: NativeAttachmentSaver(),
                intelligence: composerIntelligence,
                intelligencePresentation: intelligencePresentation,
                analysisDestination: analysisDestination,
                makeAssistantConversation: readerConversationFactory,
                onMessagePresented: onMessagePresented,
                nextEvent: AgendaSummary.nextEventCapsule(
                    for: WeekAgenda.items(on: 0, in: store.visibleAgenda),
                    now: dashboardNowMinute
                )
            )
            .assistantSteps(assistantSession.steps)
            .glassPanel(theme, kind: .reader)
        }
        .overlay(alignment: .topLeading) {
            // A divisória entre lista e leitor, centrada sobre a folga.
            PaneDivider(
                onDrag: { translation in
                    let origin = listDragOrigin ?? listWidth
                    listDragOrigin = origin
                    paneWidths.setMessageList(origin + translation)
                },
                onEnd: { listDragOrigin = nil },
                onReset: {
                    withAnimation(Self.paneTransition) { paneWidths.resetMessageList() }
                }
            )
            .offset(x: PaneDivider.leadingEdge(centeredOn: listWidth + gap / 2))
        }
        .coordinateSpace(.named(PaneDivider.coordinateSpace))
    }

    /// `internal` (era `private`) pelo mesmo motivo do `mailContent`.
    var calendarContent: some View {
        AgendaClockReader(clock) { now in
            CalendarScreen(
                store: store,
                now: now,
                anchor: agendaAnchor,
                wantsSidebar: false,
                intelligencePresentation: intelligencePresentation,
                onOpenAssistant: openWorkspaceAssistant,
                onCompose: openNewMessage,
                onOpenAccounts: openAccounts,
                onOpenEvent: openEventWindow,
                onRevealMessage: reveal,
                shell: calendarShell,
                showsSidebar: false
            )
            .expandingSidebar(expandSidebarAction)
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
            assistantOpen: assistantOpen || assistantSession.isDrawerOpen,
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
            // A gaveta primeiro: quando as duas estão abertas, a de cima é a
            // camada de agora.
            if assistantSession.isDrawerOpen { closeDrawer() } else { closeAssistant() }
            return true
        case .selection:
            store.clearChecked()
            return true
        }
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
        let briefing = dashboardBriefing ?? makeDashboardBriefing()
        return PainelDoDia(
            store: store,
            now: now,
            today: agendaAnchor,
            drafts: readyDrafts?.drafts ?? [:],
            conversation: conversation,
            briefing: briefing,
            // "Atualizando…" enquanto a barra fina do chrome trabalha — a
            // mesma soma, só lida (`ChromeWorkload` não é tocado aqui).
            isWorking: chromeWorkload.isBusy,
            filter: $dashboardFilter,
            selectedMailID: $dashboardSelectedMailID,
            readingMailID: $dashboardReadingID,
            onPresented: onMessagePresented,
            onOpenMessage: { reveal($0.id) },
            onOpenEvent: openEventWindow,
            // As ações rápidas e o menu da linha caem na **mesma** fila da
            // Caixa: `ActionReceipts` primeiro (é ele quem dá o "Desfazer"),
            // e o resto pelo runner de sempre.
            onCommand: runDashboardCommand,
            onDiscardDraft: { readyDrafts?.discardReadyDraft(messageID: $0) },
            // O botão "Perguntar · ⌘J" abre a **gaveta** (09) — o painel
            // antigo continua sendo o do leitor, ver o relatório da tarefa.
            onAskAssistant: openDrawer,
            // A folha de leitura do dashboard é o `ReaderPane`: as mesmas
            // dependências que a Caixa lhe entrega, e não uma segunda montagem.
            onCompose: { openWindow(id: UNIWindow.composer, value: $0.value) },
            intelligence: composerIntelligence,
            intelligencePresentation: intelligencePresentation,
            analysisDestination: analysisDestination,
            makeAssistantConversation: readerConversationFactory,
            // O portão do opt-in é o mesmo que a fila de rascunho consulta:
            // sem ele ligado, a rota remota não escreve nada sozinha, e o
            // cabeçalho do painel precisa poder dizer isso.
            automaticAnalysisOn:
                assistantSettings?.snapshot().automaticAnalysis == .configuredProvider,
            onGerarProntas: gerarAsProntas,
            onOpenAISettings: openAccounts,
            // Só o cabeçalho de vidro desenha este botão; o corpo clássico não
            // o chama, então passá-lo aqui não acende nada lá.
            onExpandSidebar: expandSidebarAction
        )
        .task {
            if dashboardConversation == nil { dashboardConversation = conversation }
            if dashboardBriefing == nil { dashboardBriefing = briefing }
        }
    }

    /// "Gerar as prontas": a pessoa pedindo o que a fila de fundo não pôde
    /// escrever, pela rota que ela mesma configurou. O progresso aparece na
    /// barra fina do chrome, como o resto do trabalho do app.
    private func gerarAsProntas(_ messageIDs: [String]) {
        guard let fila = readyDraftQueue, !gerandoProntas, !messageIDs.isEmpty else { return }
        gerandoProntas = true
        Task {
            await fila.generateOnDemand(messageIDs: messageIDs)
            readyDrafts?.reload()
            gerandoProntas = false
        }
    }

    /// A porta única das ações do dashboard.
    ///
    /// É o mesmo caminho da Caixa, na mesma ordem: `ActionReceipts.intercept`
    /// tem a primeira palavra (é ele quem monta a faixa com "Desfazer" antes
    /// de a mensagem sair do store) e o `MenuCommandRunner` cuida do resto,
    /// inclusive dos comandos que abrem janela. Um segundo caminho de
    /// execução para "Arquivar" faria a Caixa e o dashboard divergirem no
    /// primeiro conserto.
    private func runDashboardCommand(_ command: ContextCommand) {
        // "Arquivar e aprender" chega como **uma leva** (`.batch`), e não
        // como dois comandos soltos que alguém aqui teria de reconhecer como
        // par: o pareamento por remetente era frágil por grafia e por par
        // remanescente (I2). A leva abre o recibo composto, executa comando a
        // comando pelo caminho de sempre, e sela um Desfazer só.
        if case let .batch(comandos) = command {
            receipts.beginBatch()
            for comando in comandos { runSingleDashboardCommand(comando) }
            receipts.sealBatch(
                note: batchNote(for: comandos), stamp: ActionReceipts.stamp
            )
            return
        }
        runSingleDashboardCommand(command)
    }

    /// A frase do recibo de uma leva conhecida. `nil` deixa `ActionReceipts`
    /// escrever a genérica ("Feito — 3 emails · 14:32").
    private func batchNote(for comandos: [ContextCommand]) -> String? {
        guard comandos.count == 2,
              case let .move(messageID, .archived) = comandos[0],
              case .learnSender(_, true) = comandos[1],
              let mensagem = store.message(messageID) else { return nil }
        return L10n.tr("Arquivada e aprendida — \(mensagem.from.display) · ") + ActionReceipts.stamp
    }

    private func runSingleDashboardCommand(_ command: ContextCommand) {
        MenuCommandRunner(
            store: store,
            openWindow: openWindow,
            onReveal: { reveal($0) },
            intercept: { candidate in
                receipts.intercept(candidate, on: store, stamp: ActionReceipts.stamp)
            }
        )
        .run(command)
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

    /// O botão do trilho que devolve a coluna de contexto, só quando foi o
    /// dono quem a recolheu.
    private var expandSidebarAction: (() -> Void)? {
        wantsSidebar ? nil : { toggleSidebar() }
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
                subject: L10n.tr("Todo o OkamiUNI"),
                sender: "\(accountCount) \(accountCount == 1 ? L10n.tr("conta") : L10n.tr("contas")) · \(emailCount) \(emailCount == 1 ? L10n.tr("email") : L10n.tr("emails"))",
                conversationLabel: "\(agendaCount) \(agendaCount == 1 ? L10n.tr("compromisso") : L10n.tr("compromissos"))"
            )
        case let .email(messageID):
            guard let message = store.messages.first(where: { $0.id == messageID }) else {
                return AssistantContext(
                    subject: L10n.tr("Email indisponível"),
                    sender: L10n.tr("A mensagem saiu da caixa")
                )
            }
            let count = store.conversation(of: messageID)?.count ?? 1
            return AssistantContext(
                subject: message.subject,
                sender: message.from.display,
                conversationLabel: count > 1 ? L10n.tr("\(count) mensagens") : nil
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

    /// Uma closure, e não um valor: a conversa do dashboard vive em `@State`
    /// pela sessão inteira e Ajustes é outra janela. Congelar o destino aqui
    /// era o que fazia o rodapé dizer "neste Mac" com o Grok escolhido.
    private var assistantDestination: @Sendable () -> AssistantDestination {
        let settings = assistantSettings
        return { settings.map {
            let value = $0.snapshot()
            return value.agent.enabled ? value.agent.destination : AssistantDestination(settings: value)
        } ?? .unconfigured }
    }

    /// Só é conhecido quando o provedor é uma assinatura: sem ele um 401 do
    /// Grok viraria "tentar de novo" em vez de "reconectar". Lido na hora,
    /// pelo mesmo motivo do destino.
    private var assistantProvider: @Sendable () -> AssistantProviderOAuthKind? {
        let store = assistantSettings
        return {
            guard let settings = store?.snapshot() else { return nil }
            return !settings.agent.enabled && settings.provider == .providerOAuth ? settings.providerOAuth.kind : nil
        }
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
            context: AssistantContext(subject: L10n.tr("Caixa e agenda de hoje")),
            destination: assistantDestination,
            engine: makeEngine(
                supportsDraftReply: textAssistant != nil,
                resolving: {
                    let selected = workspace == .dashboard ? dashboardSelectedMailID : store.selectedMessageID
                    return AssistantDrawerCopy.context(chosen: assistantSession.chosenContext, hasSelection: selected != nil) == .selectedEmail
                        ? selected.map(InboxAssistantScope.email) ?? .workspace : .workspace
                }
            ),
            provider: assistantProvider
        )
    }

    private func makeDashboardBriefing() -> AssistantConversation {
        AssistantConversation(
            scope: .workspace, context: AssistantContext(subject: L10n.tr("Caixa e agenda de hoje")),
            destination: { assistantSettings.map { AssistantDestination(settings: $0.snapshot()) } ?? .unconfigured },
            engine: textAssistant.map { assistant in
                AssistantBridge.engine(using: assistant, supportsDraftReply: false,
                    mailContext: { AssistantMailContext(workspace: store, dashboardOnly: true,
                        nowMinute: dashboardNowMinute, dashboardAccountIDs: dashboardFilter.accounts) },
                    currentDraft: { "" })
            } ?? .unavailable,
            provider: assistantProvider
        )
    }

    private func makeEngine(
        supportsDraftReply: Bool,
        resolving scope: @escaping @MainActor () -> InboxAssistantScope
    ) -> AssistantEngine {
        guard let textAssistant else { return .unavailable }
        let settingsStore = assistantSettings
        let agent = WorkspaceAgentAssistant(
            base: textAssistant,
            settings: { settingsStore?.snapshot() ?? .default },
            makeTools: { agentServices.tools(store: store, open: { id in
                runDashboardCommand(.openMessageWindow(messageID: id))
            }) },
            onActivity: { assistantSession.activity = $0 }
        )
        return AssistantBridge.engine(
            using: agent,
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
                    L10n.tr("O email selecionado não está mais disponível.")
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

    // MARK: - A gaveta (09) e a janela (10)

    /// A gaveta desenhada, com a conversa do dashboard — a **mesma** que a
    /// janela destacada mostra.
    private var assistantDrawer: some View {
        // A sessão primeiro: ela é a dona, e é dela que a janela destacada
        // lê. Só quando não há nenhuma é que a tela monta a sua.
        let conversation = assistantSession.conversation
            ?? dashboardConversation ?? makeDashboardConversation()
        return AssistantDrawer(
            conversation: conversation,
            session: assistantSession,
            context: drawerContext,
            heroName: drawerHeroName,
            onSwapContext: {
                assistantSession.chosenContext = AssistantDrawerCopy.toggled(drawerContext)
            },
            onDetach: detachAssistant,
            onClose: closeDrawer,
            onRun: runProposalCard,
            onReveal: { reveal($0) }
        )
        .task {
            if dashboardConversation == nil { dashboardConversation = conversation }
            assistantSession.adopt(conversation)
        }
    }

    /// De que a gaveta está falando agora.
    var drawerContext: AssistantDrawerContext {
        // A seleção que conta é a **da aba que está aberta**: a do dashboard
        // no dashboard, a da Caixa na Caixa. Somar as duas faria a gaveta
        // dizer "o email selecionado" olhando um email que a pessoa não vê.
        let selecionado = workspace == .dashboard
            ? dashboardSelectedMailID
            : store.selectedMessageID
        return AssistantDrawerCopy.context(
            chosen: assistantSession.chosenContext,
            hasSelection: selecionado != nil
        )
    }

    /// Quem é o herói do dia — o primeiro chip diz o nome dele.
    private var drawerHeroName: String? {
        let plano = DashboardPlanInput.plan(
            store: store, drafts: readyDrafts?.drafts ?? [:],
            filter: dashboardFilter, today: agendaAnchor,
            nowMinute: dashboardNowMinute
        )
        guard let heroi = plano.hero,
              let mensagem = store.message(heroi.messageID) else { return nil }
        return mensagem.from.display
    }

    /// O minuto que a aba Dashboard está desenhando agora.
    private var dashboardNowMinute: Int {
        switch clock {
        case let .fixed(minuto): minuto
        case .live: AgendaClock.minutesSinceMidnight()
        }
    }

    func openDrawer() {
        guard !assistantSession.isDetached else {
            openWindow(id: UNIWindow.assistant)
            return
        }
        assistantSession.open()
    }

    func closeDrawer() { assistantSession.close() }

    /// ⌘J. Com a janela destacada, ele traz a janela — abrir gaveta com a
    /// conversa em outra tela seria a mesma conversa em dois lugares ao mesmo
    /// tempo.
    func toggleDrawer() {
        if assistantSession.isDetached {
            openWindow(id: UNIWindow.assistant)
        } else if assistantSession.isDrawerOpen {
            closeDrawer()
        } else {
            openDrawer()
        }
    }

    private func detachAssistant() {
        if dashboardConversation == nil { dashboardConversation = makeDashboardConversation() }
        dashboardConversation.map(assistantSession.adopt)
        assistantSession.detach()
        openWindow(id: UNIWindow.assistant)
    }

    /// **O clique.** Nada aqui acontece sem ele: a leva do cartão sai pela
    /// mesma porta do dashboard e da Caixa (`runDashboardCommand`), e as duas
    /// escritas de agenda que não têm comando próprio vão direto ao store.
    func runProposalCard(_ card: AssistantProposalCard) {
        // **A leva é uma coisa só.** Um recibo por comando faria "Desfazer"
        // devolver o décimo terceiro arquivamento e deixar os outros doze
        // arquivados; nenhum recibo faria o cartão herdar o Desfazer da ação
        // anterior de outra pessoa. Ver `ActionReceipts.beginBatch`.
        receipts.beginBatch()
        for efeito in card.effects {
            switch efeito {
            case let .command(comando):
                if case let .revealMessage(id) = comando, store.message(id)?.bucket == .drafts {
                    runDashboardCommand(.openMessageWindow(messageID: id))
                } else { runDashboardCommand(comando) }
            case let .prepareReply(messageID, draft):
                do {
                    let saved = try MailAgentTools(store: store).saveReplyDraft(
                        messageID: messageID, text: draft, requestID: String(card.id.prefix(100))
                    )
                    runDashboardCommand(.openMessageWindow(messageID: saved.id))
                } catch {
                    assistantActionFailure = error.localizedDescription
                    _ = receipts.sealBatch(undoable: false, stamp: ActionReceipts.stamp)
                    return
                }
            case let .addToAgenda(messageID):
                guard let mensagem = store.message(messageID),
                      let evento = mensagem.detectedEvent else { continue }
                _ = store.addToAgenda(evento, from: mensagem)
            case let .reserveBlock(day, start, minutes, title):
                let conta = store.selectedAccountID ?? store.accounts.first?.id ?? ""
                _ = store.addManualAgendaItem(
                    title: title, startMinute: start, endMinute: start + minutes,
                    dayOffset: day, accountID: conta, sendInvites: false
                )
            }
        }
        let recibo = receipts.sealBatch(
            undoable: card.isUndoable, stamp: ActionReceipts.stamp
        )
        // O "Desfazer" do cartão aponta para **este** recibo, por id: um
        // recibo de outra origem na barra não pode se passar por ele.
        assistantSession.markDone(card.id, undoing: recibo?.id)
    }

}

#if os(macOS)
#Preview {
    InboxScreen(store: MailStore(source: InMemoryMailSource.fixtures))
        .environment(ThemeStore())
        .frame(width: 1440, height: 916)
}
#endif
