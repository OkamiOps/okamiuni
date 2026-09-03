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
    /// O filtro do dashboard 08 vive aqui para sobreviver à troca de aba —
    /// "persistir na sessão" é literalmente isto.
    @State private var dashboardFilter = DayPlan.Filter.standard
    /// A primeira metade de "Arquivar e aprender", esperando a segunda para
    /// selar o recibo conjunto — ver `runDashboardCommand`.
    @State private var dashboardArchiveLearnPair: DashboardArchivePair?
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
    /// A sessão do assistente: a gaveta (09), a janela destacada (10) e a
    /// conversa que as duas dividem.
    ///
    /// Vem de fora porque a janela destacada é **cena própria** e não está
    /// dentro desta árvore: só uma dona acima das duas faz "a mesma conversa
    /// nos dois lugares" ser verdade. O padrão é uma sessão local, para
    /// previews e para o harness.
    let assistantSession: AssistantSession

    public init(
        store: MailStore,
        clock: AgendaClock = .fixed(Fixtures.nowMinute),
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisPause: AnalysisPauseState? = nil,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        textAssistant: (any TextAssisting)? = nil,
        assistantSettings: AssistantSettingsStore? = nil,
        onMessagePresented: @escaping (String) -> Void = { _ in },
        accountsModel: AccountsModel? = nil,
        analysisQueue: AnalysisQueueStateModel? = nil,
        backlogAnalysis: BacklogAnalysisController? = nil,
        readyDrafts: ReadyDraftsModel? = nil,
        assistantSession: AssistantSession? = nil
    ) {
        self.init(
            store: store,
            clock: clock,
            intelligencePresentation: intelligencePresentation,
            analysisPause: analysisPause,
            analysisDestination: analysisDestination,
            textAssistant: textAssistant,
            assistantSettings: assistantSettings,
            onMessagePresented: onMessagePresented,
            accountsModel: accountsModel,
            analysisQueue: analysisQueue,
            backlogAnalysis: backlogAnalysis,
            readyDrafts: readyDrafts,
            assistantSession: assistantSession,
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
        onMessagePresented: @escaping (String) -> Void = { _ in },
        accountsModel: AccountsModel? = nil,
        analysisQueue: AnalysisQueueStateModel? = nil,
        backlogAnalysis: BacklogAnalysisController? = nil,
        readyDrafts: ReadyDraftsModel? = nil,
        assistantSession: AssistantSession? = nil,
        debugAssistantOpen: Bool,
        debugAssistantScope: InboxAssistantScope = .workspace,
        debugReaderAssistantOpen: Bool = false,
        debugWorkspace: Workspace = .mail
    ) {
        self.store = store
        self.clock = clock
        self.intelligencePresentation = intelligencePresentation
        self.analysisPause = analysisPause
        self.analysisDestination = analysisDestination
        self.textAssistant = textAssistant
        self.assistantSettings = assistantSettings
        self.onMessagePresented = onMessagePresented
        self.accountsModel = accountsModel
        self.analysisQueue = analysisQueue
        self.backlogAnalysis = backlogAnalysis
        self.readyDrafts = readyDrafts
        self.assistantSession = assistantSession ?? AssistantSession()
        self.composerIntelligence = textAssistant.map {
            AssistantBridge.composerGenerator(using: $0)
        }
        self.debugReaderAssistantOpen = debugReaderAssistantOpen
        _assistantOpen = State(initialValue: debugAssistantOpen)
        _assistantScope = State(initialValue: debugAssistantScope)
        _readerAssistantOpen = State(initialValue: debugReaderAssistantOpen)
        _workspace = State(initialValue: debugWorkspace)
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

    /// Tudo que segura o dono esperando, somado no tipo puro `ChromeWorkload`.
    ///
    /// A barra fina sob a busca é a única animação que ele já reconhece como
    /// "está carregando", e antes disto ela só falava de sincronização — o
    /// dashboard e o assistente trabalhavam sem dizer nada. Aqui só se
    /// **recolhem** os sinais; a regra de como eles somam mora fora da `View`,
    /// com teste (`ChromeWorkloadTests`).
    var chromeWorkload: ChromeWorkload {
        var jobs: [ChromeWork] = [.sync(MailboxChromeStatus.from(accountsModel?.statuses ?? []))]
        for conversa in [dashboardConversation, assistantConversation].compactMap({ $0 }) {
            if let kind = conversa.workKind {
                jobs.append(.assistant(kind: kind, destination: conversa.destination))
            }
        }
        if analysisQueue?.isProcessing == true { jobs.append(.analysisQueue) }
        if let acervo = backlogAnalysis, acervo.isRunning {
            jobs.append(.backlog(done: max(0, acervo.total - acervo.remaining), total: acervo.total))
        }
        if store.isLoadingAnyBody { jobs.append(.body) }
        return ChromeWorkload.combining(jobs)
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
                syncStatus: chromeWorkload.status,
                syncCaption: MailboxChromeStatus.lastSyncedCaption(from: accountsModel?.statuses ?? []),
                statusDetail: chromeWorkload.detail,
                onReloadMailbox: accountsModel == nil ? nil : { [accountsModel] in
                    Task { await accountsModel?.syncNow() }
                },
                onSearchFocusChange: { searchFocused = $0 }
            )

            ZStack(alignment: .trailing) {
                // O fundo da tela mora **fora** do esmaecimento. Sem isto, os
                // 45% deixam a própria janela translúcida e o que aparece
                // atrás do dashboard é a mesa do macOS — o mockup esmaece o
                // conteúdo sobre o `paper`, não sobre o vazio.
                theme.paper.color

                // Conteúdo principal
                Group {
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
                }
                // A gaveta é **overlay**: o que está atrás esmaece e fica
                // exatamente onde estava. Empurrar a caixa para o lado faria
                // a pessoa perder o parágrafo que estava lendo por ter feito
                // uma pergunta.
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
        }
        .environment(receipts)
        // A janela destacada clica no **mesmo** executor da gaveta: ela não
        // tem store nem fila, e um segundo caminho lá divergiria daqui.
        .task {
            assistantSession.install(runner: runProposalCard, reveal: { reveal($0) })
        }
        // O "Feito · Desfazer" do cartão vale enquanto o desfazer da barra
        // existir. Quando o recibo sai, o cartão volta a ser cartão.
        .onChange(of: receipts.current == nil) { _, semRecibo in
            assistantSession.hasUndo = !semRecibo
            if semRecibo { assistantSession.forgetDone() }
        }
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
                        analysisPause: analysisPause,
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
                    analysisDestination: analysisDestination,
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
            drafts: readyDrafts?.drafts ?? [:],
            conversation: conversation,
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
            makeAssistantConversation: readerConversationFactory
        )
        .task {
            if dashboardConversation == nil { dashboardConversation = conversation }
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
        // "Arquivar e aprender" chega como **dois** comandos na mesma leva —
        // `.move(.archived)` e `.learnSender` — e o recibo dos dois é um só:
        // o estado é fotografado antes de arquivar, e quando o `learnSender`
        // do mesmo remetente chega logo atrás, o Desfazer vira o comando
        // conjunto (`restoreArchivedAndForgetSender`). Qualquer outro comando
        // no meio desfaz o pareamento.
        if case let .move(messageID, .archived) = command,
           let mensagem = store.message(messageID) {
            dashboardArchiveLearnPair = DashboardArchivePair(
                message: mensagem, states: store.states(of: [messageID])
            )
        } else if case let .learnSender(address, true) = command,
                  let par = dashboardArchiveLearnPair,
                  par.message.from.address == address {
            dashboardArchiveLearnPair = nil
            StoreCommand.run(command, on: store)
            receipts.current = SwipeReceipt(
                messageID: par.message.id,
                note: "Arquivada e aprendida — \(par.message.from.display) · "
                    + ActionReceipts.stamp,
                undo: .restoreArchivedAndForgetSender(
                    states: par.states, address: address
                )
            )
            return
        } else {
            dashboardArchiveLearnPair = nil
        }
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

    /// Uma closure, e não um valor: a conversa do dashboard vive em `@State`
    /// pela sessão inteira e Ajustes é outra janela. Congelar o destino aqui
    /// era o que fazia o rodapé dizer "neste Mac" com o Grok escolhido.
    private var assistantDestination: @Sendable () -> AssistantDestination {
        let settings = assistantSettings
        return { settings.map { AssistantDestination(settings: $0.snapshot()) } ?? .unconfigured }
    }

    /// Só é conhecido quando o provedor é uma assinatura: sem ele um 401 do
    /// Grok viraria "tentar de novo" em vez de "reconectar". Lido na hora,
    /// pelo mesmo motivo do destino.
    private var assistantProvider: @Sendable () -> AssistantProviderOAuthKind? {
        let store = assistantSettings
        return {
            guard let settings = store?.snapshot() else { return nil }
            return settings.provider == .providerOAuth ? settings.providerOAuth.kind : nil
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
        for efeito in card.effects {
            switch efeito {
            case let .command(comando):
                runDashboardCommand(comando)
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
        assistantSession.markDone(card.id)
        assistantSession.hasUndo = receipts.current != nil
    }

}

#if os(macOS)
#Preview {
    InboxScreen(store: MailStore(source: InMemoryMailSource.fixtures))
        .environment(ThemeStore())
        .frame(width: 1440, height: 916)
}
#endif

/// O par de "Arquivar e aprender" em trânsito: a mensagem e o estado
/// fotografado **antes** de arquivar — sem a foto, o Desfazer conjunto não
/// teria para onde voltar.
struct DashboardArchivePair {
    let message: Message
    let states: [MessageState]
}
