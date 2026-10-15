import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// O vocabulário de **links profundos** para Configurações.
///
/// Ele sobreviveu ao redesenho de propósito: o menu do app, o item de contexto
/// da linha da conta e os testes mandam abrir "assinaturas" ou "agenda", e
/// essas palavras continuam valendo. O que mudou é onde elas **chegam** — ver
/// `SettingsSection.page(in:)`: o que era uma seção de assinaturas agora é a
/// página da conta, porque é lá que a assinatura mora.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    /// Aparência ganhou nome próprio no redesenho: tema, tamanho do texto,
    /// idioma e atualizações moram nela, e eram o conteúdo de "Geral".
    case appearance
    case agenda
    case accounts
    case intelligence
    case gestures
    case signatures
    case aliases
    case rules

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .general: L10n.tr("Visão geral")
        case .appearance: L10n.tr("Aparência")
        case .agenda: L10n.tr("Agenda")
        case .accounts: L10n.tr("Contas")
        case .intelligence: L10n.tr("Inteligência")
        case .gestures: L10n.tr("Gestos")
        case .signatures: L10n.tr("Assinaturas")
        case .aliases: L10n.tr("Remetentes")
        case .rules: L10n.tr("Regras")
        }
    }

    /// Para onde este link leva na janela nova.
    ///
    /// Agenda, Assinaturas, Remetentes e Contas caem todos na página da
    /// **primeira conta** (ou na Visão geral quando não há conta nenhuma):
    /// as três primeiras eram, cada uma, uma pergunta sobre uma conta, e agora
    /// elas vivem juntas lá.
    func page(in accounts: [AccountStatus]) -> ConfigPage {
        switch self {
        case .general: .overview
        case .appearance: .appearance
        case .intelligence: .intelligence
        case .gestures: .gestures
        case .rules: .rules
        case .agenda, .accounts, .signatures, .aliases:
            accounts.first.map { ConfigPage.account($0.accountID) } ?? .overview
        }
    }
}

/// A janela de Configurações, redesenhada em cima de `Config.dc.html`.
///
/// Dois painéis flutuantes com 10pt de folga: a navegação de 244 agrupada por
/// quem decide o quê (COMEÇO, VOCÊ, SUAS CONTAS, AUTOMAÇÃO) e a página. A
/// primeira página é "Tudo em ordem?", que põe os problemas antes dos ajustes.
///
/// Nos 26 temas clássicos o desenho é o **mesmo**: os painéis perdem o vidro e
/// viram superfícies opacas dos tokens do tema — ver `ConfigPanel`.
public struct AccountsWindow: View {
    @Environment(\.theme) private var theme

    private let model: AccountsModel
    private let assistantSettings: AssistantSettingsStore?
    private let assistantCredentials: (any AssistantCredentialStore)?
    private let textAssistant: (any TextAssisting)?
    private let liteLLMOAuthAuthorizer: (any LiteLLMOAuthAuthorizing)?
    private let providerOAuthAuthorizer: (any AssistantProviderOAuthAuthorizing)?
    private let backlogAnalysis: BacklogAnalysisController?
    private let emailRules: EmailRuleStore?
    private let themes: ThemeStore?
    private let swipes: SwipeSettingsStore?
    private let mailStore: MailStore?
    private let meetingRooms: MeetingRoomSettingsStore?
    private let updates: UpdateController?

    private let initialSection: SettingsSection
    /// Abre a página de Regras já em "Nova regra". É por aqui que o retrato de
    /// `Config-regra-nova` entra, e também o caminho de um link futuro que
    /// queira levar direto à montagem.
    private let startsNewRule: Bool
    /// Abre a Inteligência já numa folha ou numa página de detalhe, e fecha as
    /// portas que tocam disco e rede de loopback. É o caminho dos retratos —
    /// o mesmo de `startsNewRule`.
    private let initialIntelligenceSheet: ConfigIntelligenceSheet?
    private let initialIntelligencePage: ConfigIntelligencePage
    private let initialIntelligenceTab: ConfigIntelligenceTab
    /// A busca já digitada na folha de conectar.
    private let initialIntelligenceSearch: String
    private let intelligenceProbes: ConfigIntelligenceProbes

    @State private var page: ConfigPage?
    @State private var query = ""
    @State private var addingAccount = false
    @State private var removendo: String?
    @State private var reconectandoImap: AccountStatus?
    /// O painel de conexão existente, aberto numa rota escolhida. É ele que
    /// guarda os formulários de OAuth, chave de API, LiteLLM e CLI.
    @State private var connectionRoute: AssistantProvider?
    @State private var composingRule = false

    // Inteligência
    @State private var draft = AssistantSettings.default
    @State private var oauthStatus: AssistantProviderOAuthStatus = .idle
    @State private var oauthMonitor: Task<Void, Never>?
    @State private var models: [AssistantProviderModel] = []
    @State private var lastTest: String?
    @State private var lastTestFailed = false
    @State private var testing = false
    /// A folha da Inteligência mora aqui, e não dentro da página, porque o véu
    /// do desenho cobre a navegação também.
    @State private var intelligenceSheet: ConfigIntelligenceSheet?
    /// A página que a folha pediu ao se fechar.
    @State private var intelligencePage: ConfigIntelligencePage?
    @State private var cliInstallations: [AssistantCLIInstallation] = []
    @State private var cliAuthentication: [AssistantCLIKind: AssistantCLIAuthenticationState] = [:]
    /// Só a **presença** da chave. Esta janela nunca pede o segredo ao cofre.
    @State private var apiKeyPresent = false

    @AppStorage(AppLanguage.defaultsKey) private var interfaceLanguage = AppLanguage.portugueseBrazil.rawValue
    @State private var languageAtOpening = AppLanguage.selected.rawValue

    public init(
        model: AccountsModel,
        initialSection: SettingsSection = .accounts,
        startsNewRule: Bool = false,
        initialIntelligenceSheet: ConfigIntelligenceSheet? = nil,
        initialIntelligencePage: ConfigIntelligencePage = .main,
        initialIntelligenceTab: ConfigIntelligenceTab = .connections,
        initialIntelligenceSearch: String = "",
        intelligenceProbes: ConfigIntelligenceProbes = .live,
        assistantSettings: AssistantSettingsStore? = nil,
        assistantCredentials: (any AssistantCredentialStore)? = nil,
        textAssistant: (any TextAssisting)? = nil,
        liteLLMOAuthAuthorizer: (any LiteLLMOAuthAuthorizing)? = nil,
        providerOAuthAuthorizer: (any AssistantProviderOAuthAuthorizing)? = nil,
        backlogAnalysis: BacklogAnalysisController? = nil,
        emailRules: EmailRuleStore? = nil,
        themes: ThemeStore? = nil,
        swipes: SwipeSettingsStore? = nil,
        mailStore: MailStore? = nil,
        meetingRooms: MeetingRoomSettingsStore? = nil,
        updates: UpdateController? = nil
    ) {
        self.model = model
        self.initialSection = initialSection
        self.startsNewRule = startsNewRule
        self.initialIntelligenceSheet = initialIntelligenceSheet
        self.initialIntelligencePage = initialIntelligencePage
        self.initialIntelligenceTab = initialIntelligenceTab
        self.initialIntelligenceSearch = initialIntelligenceSearch
        self.intelligenceProbes = intelligenceProbes
        self.assistantSettings = assistantSettings
        self.assistantCredentials = assistantCredentials
        self.textAssistant = textAssistant
        self.liteLLMOAuthAuthorizer = liteLLMOAuthAuthorizer
        self.providerOAuthAuthorizer = providerOAuthAuthorizer
        self.backlogAnalysis = backlogAnalysis
        self.emailRules = emailRules
        self.themes = themes
        self.swipes = swipes
        self.mailStore = mailStore
        self.meetingRooms = meetingRooms
        self.updates = updates
        _oauthStatus = State(initialValue: providerOAuthAuthorizer?.sessionState.status ?? .idle)
        _composingRule = State(initialValue: startsNewRule)
        _intelligenceSheet = State(initialValue: initialIntelligenceSheet)
        // O que a tela já sabe antes de a varredura responder. Vazio na vida
        // real; é a porta por onde um retrato entra com CLIs no primeiro
        // quadro, sem depender do que está instalado na máquina da suíte.
        _cliInstallations = State(initialValue: intelligenceProbes.seededCLIs)
        _cliAuthentication = State(initialValue: intelligenceProbes.seededAuthentication)
    }

    public var body: some View {
        ZStack {
            Backdrop()
            HStack(alignment: .top, spacing: ConfigMetrics.panelGap) {
                ConfigNav(
                    accounts: model.statuses,
                    pendingCount: alerts.count,
                    versionLine: versionLine,
                    readyUpdate: readyUpdate,
                    page: Binding(get: { currentPage }, set: { page = $0 }),
                    query: $query,
                    addAccount: { addingAccount = true }
                )
                main
            }
            .padding(ConfigMetrics.windowPadding)
        }
        // Antes do `.environment`: um overlay acrescentado depois dele seria
        // irmão da janela, não filho, e a folha nasceria sem a paleta.
        .centeredModal(
            isPresented: intelligenceSheet != nil,
            onDismiss: { intelligenceSheet = nil }
        ) {
            intelligenceSheetContent
        }
        .environment(\.configPalette, ConfigPalette(theme))
        .tint(theme.accent.color)
        .trafficLightsInConfigNav()
        .task { await model.start() }
        .task { await loadAssistant() }
        .task { await loadCLIs() }
        .onDisappear {
            oauthMonitor?.cancel()
            oauthMonitor = nil
        }
        .onChange(of: model.statuses) { _, statuses in
            // A conta aberta saiu da lista: a janela volta para a visão geral
            // em vez de desenhar uma página sem dono.
            if case .account(let id) = currentPage,
               !statuses.contains(where: { $0.accountID == id }) {
                page = .overview
            }
        }
        .sheet(isPresented: $addingAccount) {
            ConfigSheet(title: L10n.tr("Adicionar conta")) { addingAccount = false } content: {
                AddAccountForm(model: model)
            }
        }
        .sheet(item: $reconectandoImap) { status in
            ReconnectImapForm(model: model, status: status) { reconectandoImap = nil }
        }
        .sheet(item: $connectionRoute) { route in
            ConfigSheet(title: L10n.tr("Conectar a inteligência")) {
                connectionRoute = nil
                Task { await loadAssistant() }
            } content: {
                GeneralSettingsView(
                    scope: .intelligence,
                    settingsStore: assistantSettings,
                    credentialStore: assistantCredentials,
                    textAssistant: textAssistant,
                    liteLLMOAuthAuthorizer: liteLLMOAuthAuthorizer,
                    providerOAuthAuthorizer: providerOAuthAuthorizer,
                    backlogAnalysis: backlogAnalysis,
                    themes: themes,
                    swipes: swipes,
                    moveDestinations: swipeMoveDestinations
                )
                .id(route)
            }
        }
        .confirmationDialog(
            L10n.tr("Remover esta conta?"),
            isPresented: Binding(get: { removendo != nil }, set: { if !$0 { removendo = nil } })
        ) {
            Button(L10n.tr("Remover"), role: .destructive) {
                if let id = removendo { Task { await model.remove(id) } }
                removendo = nil
            }
            Button(L10n.tr("Cancelar"), role: .cancel) { removendo = nil }
        } message: {
            Text(L10n.tr("As mensagens já baixadas e a senha guardada no Keychain serão apagadas. A conta no servidor não é tocada."))
        }
    }

    /// A página aberta. `initialSection` decide a primeira, e é aqui que o
    /// link profundo antigo é traduzido — depois que as contas carregaram.
    private var currentPage: ConfigPage {
        page ?? initialSection.page(in: model.statuses)
    }

    // MARK: O painel de conteúdo

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .padding(.top, ConfigMetrics.mainTop)
        .padding(.horizontal, ConfigMetrics.mainSide)
        .padding(.bottom, ConfigMetrics.mainBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .configPanel(theme)
    }

    @ViewBuilder
    private var header: some View {
        switch currentPage {
        case .overview:
            ConfigPageHeader(
                title: alerts.isEmpty ? L10n.tr("Tudo em ordem") : L10n.tr("Tudo em ordem?"),
                subtitle: alerts.isEmpty
                    ? L10n.tr("Nada pede a sua atenção agora")
                    : (alerts.count == 1
                        ? L10n.tr("Quase — uma coisa pede um minuto seu")
                        : L10n.tr("Quase — \(alerts.count) coisas pedem um minuto seu"))
            )
        case .appearance:
            ConfigPageHeader(
                title: L10n.tr("Aparência"),
                subtitle: L10n.tr("Tema, tamanho do texto e idioma")
            )
        case .intelligence:
            // A Inteligência desenha o próprio cabeçalho: ele tem as duas abas
            // e o "‹ Inteligência" das páginas de detalhe, que o cabeçalho
            // comum das outras páginas não conhece.
            EmptyView()
        case .account(let id):
            if let status = model.statuses.first(where: { $0.accountID == id }) {
                ConfigPageHeader(
                    title: status.address,
                    subtitle: AccountsCopy.status(status, now: Date(), calendar: .current),
                    avatarInitial: ConfigAccountTint.initial(for: status),
                    avatarTint: nil,
                    action: (
                        label: L10n.tr("Sincronizar agora"),
                        run: { Task { await model.loadInitial(status.accountID) } }
                    )
                )
            }
        case .gestures:
            ConfigPageHeader(
                title: L10n.tr("Gestos"),
                subtitle: L10n.tr("O que acontece quando você arrasta um e-mail")
            )
        case .rules:
            if composingRule {
                ConfigPageHeader(
                    title: L10n.tr("Nova regra"),
                    subtitle: L10n.tr("Descreva, confira o que ela pegaria, e pronto")
                )
            } else {
                ConfigPageHeader(
                    title: L10n.tr("Regras"),
                    subtitle: L10n.tr("Cuidam dos e-mails novos antes de você ver"),
                    action: (label: L10n.tr("+ Nova regra"), run: { composingRule = true })
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch currentPage {
        case .overview:
            ConfigOverview(alerts: alerts, tiles: tiles, checkedNote: L10n.tr("conferido agora há pouco"), updates: updates)
        case .appearance:
            ConfigAppearance(
                themes: themes,
                language: $interfaceLanguage,
                languageAtOpening: languageAtOpening
            )
        case .intelligence:
            ConfigIntelligence(
                draft: $draft,
                sheet: $intelligenceSheet,
                requestedPage: $intelligencePage,
                oauthStatus: oauthStatus,
                availableModels: models,
                cliInstallations: cliInstallations,
                cliAuthentication: cliAuthentication,
                apiKeyPresent: apiKeyPresent,
                lastTest: lastTest,
                lastTestFailed: lastTestFailed,
                testing: testing,
                save: saveAssistant,
                test: testAssistant,
                storeAPIKey: storeAssistantAPIKey,
                removeAPIKey: removeAssistantAPIKey,
                openAdvancedPanel: { connectionRoute = .openAICompatible },
                probeLocal: intelligenceProbes.localServer,
                initialPage: initialIntelligencePage,
                initialTab: initialIntelligenceTab
            )
        case .account(let id):
            if let status = model.statuses.first(where: { $0.accountID == id }) {
                ConfigAccountPage(
                    model: model,
                    status: status,
                    mailStore: mailStore,
                    meetingRooms: meetingRooms,
                    remove: { removendo = status.accountID }
                )
                .id(status.accountID)
            }
        case .gestures:
            ConfigGestures(store: swipes, moveDestinations: swipeMoveDestinations)
        case .rules:
            ConfigRules(
                store: emailRules,
                accounts: model.statuses,
                moveDestinations: swipeMoveDestinations,
                messages: mailStore?.messages ?? [],
                textAssistant: textAssistant,
                composing: $composingRule
            )
        }
    }

    // MARK: A visão geral

    /// Os problemas pendentes, cada um com **uma** saída.
    private var alerts: [ConfigAlert] {
        var list: [ConfigAlert] = []
        for status in model.statuses where AccountsCopy.isFailing(status) {
            list.append(ConfigAlert(
                id: "conta-\(status.accountID)",
                tone: .needsYou,
                symbol: "lock",
                tag: L10n.tr("PRECISA DE VOCÊ"),
                title: L10n.tr("\(status.address) pede a senha de novo"),
                detail: AccountsCopy.status(status, now: Date(), calendar: .current),
                action: L10n.tr("Reconectar"),
                run: { reconnect(status) }
            ))
        }
        if let updates, updates.showsReadyButton, let version = updates.readyVersion {
            list.append(ConfigAlert(
                id: "atualizacao",
                tone: .whenever,
                symbol: "arrow.down",
                tag: L10n.tr("QUANDO QUISER"),
                title: L10n.tr("A \(version) está pronta"),
                detail: L10n.tr("Baixada em segundo plano. Instala em segundos e reabre onde você estava."),
                action: L10n.tr("Instalar e reabrir"),
                link: (label: L10n.tr("Notas da versão"), run: { updates.showChangelog() }),
                run: { updates.installAndRelaunch() }
            ))
        }
        return list
    }

    /// Os azulejos: cada um é um fato e um atalho para onde mudá-lo.
    private var tiles: [ConfigOverviewTile] {
        let palette = ConfigPalette(theme)
        var list: [ConfigOverviewTile] = []

        list.append(ConfigOverviewTile(
            id: "aparencia",
            area: L10n.tr("Aparência"),
            symbol: "paintpalette",
            tint: palette.ink2,
            headline: themeHeadline,
            detail: L10n.tr("\(ConfigAppearance.typographyLabel(themes?.typographyPreset ?? .standard)) no tamanho do texto"),
            ornament: .swatch(AnyView(ConfigThemePreview(theme: theme))),
            open: { page = .appearance }
        ))

        list.append(ConfigOverviewTile(
            id: "ia",
            area: L10n.tr("Inteligência"),
            symbol: "sparkles",
            tint: palette.accentInk,
            headline: isConnected
                ? L10n.tr("\(AssistantDestination(settings: draft).label) conectada")
                : L10n.tr("ainda não conectada"),
            detail: draft.automaticAnalysis == .configuredProvider
                ? L10n.tr("analisando e-mails novos sozinha")
                : L10n.tr("nada sai deste Mac sem você pedir"),
            open: { page = .intelligence }
        ))

        let healthy = model.statuses.count { !AccountsCopy.isFailing($0) }
        list.append(ConfigOverviewTile(
            id: "contas",
            area: L10n.tr("Suas contas"),
            symbol: "person.crop.circle",
            tint: palette.ink2,
            headline: L10n.tr("\(healthy) de \(model.statuses.count) em dia"),
            detail: model.statuses.map(\.hostMark).joined(separator: " · "),
            ornament: .faces(model.statuses.prefix(3).map {
                (initial: ConfigAccountTint.initial(for: $0),
                 tint: ConfigAccountTint.color(for: $0, theme: theme))
            }),
            open: { if let first = model.statuses.first { page = .account(first.accountID) } }
        ))

        let activeRules = emailRules?.rules.count { $0.enabled } ?? 0
        list.append(ConfigOverviewTile(
            id: "automacao",
            area: L10n.tr("Automação"),
            symbol: "arrow.triangle.branch",
            tint: palette.green,
            headline: L10n.tr("\(activeRules) regras ativas"),
            detail: L10n.tr("e os gestos de arrastar"),
            open: { page = .rules }
        ))

        return list
    }

    private var themeHeadline: String {
        if themes?.followsSystemAppearance == true { return L10n.tr("Automático") }
        return theme.name
    }

    // MARK: Inteligência — as folhas

    /// A folha aberta sobre a janela: escolher uma IA, ou entrar numa conta.
    @ViewBuilder
    private var intelligenceSheetContent: some View {
        switch intelligenceSheet {
        case .choose:
            ConfigIntelligenceChooseSheet(
                initialQuery: initialIntelligenceSearch,
                close: { intelligenceSheet = nil },
                choose: chooseIntelligence
            )
        case .login(let kind):
            ConfigIntelligenceLoginSheet(
                kind: kind,
                status: oauthStatus,
                models: models,
                connect: { startLogin(kind) },
                recheck: { recheckLogin(kind) },
                signOut: { signOutLogin(kind) },
                close: { intelligenceSheet = nil }
            )
        case nil:
            EmptyView()
        }
    }

    /// O que acontece quando a pessoa escolhe uma linha do catálogo.
    ///
    /// Nada é conectado aqui: a escolha leva ao lugar onde ela se completa — o
    /// formulário da chave, a página do Mac, a folha do login, o painel dos
    /// agentes.
    private func chooseIntelligence(_ preset: ConfigAIPreset) {
        switch preset.route {
        case .appleIntelligence:
            draft.provider = .foundationModels
            draft.automaticAnalysis = .onDeviceOnly
            saveAssistant()
            intelligenceSheet = nil
            intelligencePage = .local
        case .localServer:
            if let baseURL = preset.baseURL {
                draft.openAICompatible.endpoint = baseURL
                draft.openAICompatible.authenticationMode = .none
            }
            intelligenceSheet = nil
            intelligencePage = .local
        case .apiKey(let presetID):
            if let baseURL = preset.baseURL {
                draft.openAICompatible.endpoint = baseURL
                draft.openAICompatible.authenticationMode = .apiKey
            } else {
                draft.openAICompatible.endpoint = ""
            }
            intelligenceSheet = nil
            intelligencePage = .apiKey(presetID: presetID)
        case .login(let kind):
            draft.providerOAuth.kind = kind
            draft.providerOAuth.credentialID = kind.defaultCredentialID
            intelligenceSheet = .login(kind)
        case .cli(let kind):
            draft.provider = .cli
            draft.cli.kind = kind
            saveAssistant()
            intelligenceSheet = nil
        case .agent:
            intelligenceSheet = nil
            connectionRoute = .openAICompatible
        }
    }

    private func startLogin(_ kind: AssistantProviderOAuthKind) {
        draft.providerOAuth.kind = kind
        draft.providerOAuth.credentialID = kind.defaultCredentialID
        startProviderOAuth()
    }

    private func recheckLogin(_ kind: AssistantProviderOAuthKind) {
        guard let providerOAuthAuthorizer else { return }
        let configuration = draft.providerOAuth
        Task {
            await providerOAuthAuthorizer.refreshStatus(configuration: configuration)
            oauthStatus = providerOAuthAuthorizer.sessionState.status
            if oauthStatus == .signedIn {
                models = (try? await providerOAuthAuthorizer
                    .availableModels(configuration: configuration)) ?? []
            }
        }
    }

    private func signOutLogin(_ kind: AssistantProviderOAuthKind) {
        guard let providerOAuthAuthorizer else { return }
        let configuration = draft.providerOAuth
        Task {
            await providerOAuthAuthorizer.signOut(configuration: configuration)
            oauthStatus = providerOAuthAuthorizer.sessionState.status
            models = []
            intelligenceSheet = nil
        }
    }

    /// Entrega a chave ao Keychain. O texto não volta para a tela e não entra
    /// no documento de preferências.
    private func storeAssistantAPIKey(_ key: String) {
        guard let assistantCredentials else { return }
        try? assistantCredentials.storeAPIKey(key, for: draft.openAICompatible.credentialID)
        apiKeyPresent = (try? assistantCredentials
            .containsAPIKey(for: draft.openAICompatible.credentialID)) ?? false
    }

    private func removeAssistantAPIKey() {
        guard let assistantCredentials else { return }
        try? assistantCredentials.removeAPIKey(for: draft.openAICompatible.credentialID)
        draft.openAICompatible.endpoint = ""
        draft.openAICompatible.model = ""
        if draft.provider == .openAICompatible {
            draft.provider = .foundationModels
            draft.automaticAnalysis = .onDeviceOnly
        }
        saveAssistant()
        apiKeyPresent = false
    }

    /// Quais CLIs existem e quais estão logados. É uma varredura de disco e uma
    /// pergunta de estado a cada um — fora da `MainActor`, porque ela espera
    /// processo.
    private func loadCLIs() async {
        let installations = await intelligenceProbes.cliScan()
        cliInstallations = installations
        cliAuthentication = await intelligenceProbes.cliAuthentication(installations)
    }

    // MARK: Inteligência — a mecânica

    private var isConnected: Bool {
        switch draft.provider {
        case .foundationModels: true
        case .providerOAuth: oauthStatus == .signedIn
        case .openAICompatible: !draft.openAICompatible.endpoint.isEmpty
        case .cli: true
        }
    }

    private func loadAssistant() async {
        guard let assistantSettings else { return }
        draft = assistantSettings.snapshot()
        // Só a presença: `containsAPIKey` consulta atributos do Keychain e
        // nunca materializa o segredo.
        apiKeyPresent = (try? assistantCredentials?
            .containsAPIKey(for: draft.openAICompatible.credentialID)) == true
        if let providerOAuthAuthorizer, draft.provider == .providerOAuth {
            await providerOAuthAuthorizer.refreshStatus(configuration: draft.providerOAuth)
            oauthStatus = providerOAuthAuthorizer.sessionState.status
            if oauthStatus == .signedIn {
                models = (try? await providerOAuthAuthorizer
                    .availableModels(configuration: draft.providerOAuth)) ?? []
            }
        }
    }

    private func saveAssistant() {
        guard let assistantSettings else { return }
        if let saved = try? assistantSettings.save(draft) { draft = saved }
    }

    private func testAssistant() {
        guard let textAssistant else { return }
        testing = true
        Task {
            let started = Date()
            do {
                _ = try await textAssistant.answer(
                    question: L10n.tr("Responda somente: pronto."),
                    in: AssistantConversationSnapshot(mailContext: Self.emptyMailContext)
                )
                let seconds = Date().timeIntervalSince(started)
                lastTest = L10n.tr("respondeu em \(String(format: "%.1f", seconds)) s")
                lastTestFailed = false
            } catch {
                lastTest = error.localizedDescription
                lastTestFailed = true
            }
            testing = false
        }
    }

    /// "Conectar agora": começa a autorização de verdade. Sem autorizador
    /// montado neste build, abre o painel de conexão — que é onde as outras
    /// rotas moram — em vez de um botão que não faz nada.
    private func startProviderOAuth() {
        guard let providerOAuthAuthorizer else {
            connectionRoute = .providerOAuth
            return
        }
        draft.provider = .providerOAuth
        saveAssistant()
        oauthMonitor?.cancel()
        let configuration = draft.providerOAuth
        Task {
            try? await providerOAuthAuthorizer.start(configuration: configuration)
        }
        oauthMonitor = Task { @MainActor in
            // O ator publica; a tela observa. Sem este laço o código do
            // dispositivo aparecia e nunca sumia depois do login.
            while !Task.isCancelled {
                oauthStatus = providerOAuthAuthorizer.sessionState.status
                if oauthStatus == .signedIn {
                    models = (try? await providerOAuthAuthorizer
                        .availableModels(configuration: configuration)) ?? []
                    return
                }
                if case .failed = oauthStatus { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static let emptyMailContext = AssistantMailContext.workspace(
        AssistantWorkspaceContext(
            accounts: [], emailCount: 0, unreadCount: 0,
            mailboxes: [], emails: [], agenda: []
        )
    )

    // MARK: Os fatos da moldura

    private var versionLine: String {
        updates?.versionLine ?? GeneralSettingsView.bundleVersionLine
    }

    private var readyUpdate: String? {
        guard let updates, updates.showsReadyButton else { return nil }
        return updates.readyVersion
    }

    private func reconnect(_ status: AccountStatus) {
        switch AccountsCopy.reconnectRoute(for: status) {
        case .google: Task { await model.reconnectGoogle(status.accountID) }
        case .imapForm: reconectandoImap = status
        case nil: page = .account(status.accountID)
        }
    }

    /// Os destinos são construídos a partir das pastas reais já sincronizadas.
    /// Gmail recebe somente marcadores pessoais e remove INBOX; em IMAP a
    /// pessoa pode escolher qualquer pasta fora da entrada. Não há inferência
    /// por nome, nem uma lista de provedores fechada.
    private var swipeMoveDestinations: [SwipeMoveDestination] {
        guard let mailStore else { return [] }
        var destinations: [SwipeMoveDestination] = []
        for account in mailStore.accounts {
            let folders = mailStore.folders(of: account.id)
            switch account.provider {
            case .gmail:
                guard let inbox = folders.first(where: { $0.role == .inbox }) else { continue }
                destinations += folders.compactMap { folder in
                    guard folder.role == .other else { return nil }
                    return SwipeMoveDestination(
                        gmailLabel: folder,
                        removing: inbox,
                        accountLabel: account.address
                    )
                }
            case .imap, .microsoft:
                destinations += folders
                    .filter { $0.role != .inbox }
                    .map { folder in
                        SwipeMoveDestination(imapFolder: folder, accountLabel: account.address)
                    }
            }
        }
        return destinations.sorted {
            if $0.accountLabel != $1.accountLabel {
                return ($0.accountLabel ?? $0.accountID)
                    .localizedCaseInsensitiveCompare($1.accountLabel ?? $1.accountID) == .orderedAscending
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

/// A moldura das folhas que a janela abre: um título, um "Pronto" e o
/// conteúdo. Os formulários de dentro são de outra mão — esta é só a borda.
struct ConfigSheet<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(theme.sans.font(size: 15, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Spacer(minLength: 0)
                Button(L10n.tr("Pronto"), action: close)
                    .buttonStyle(.plain)
                    .configPrimaryButton(
                        palette, font: theme.sans.font(size: 13, weight: .semibold),
                        radius: 9, horizontal: 14, vertical: 7
                    )
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            ScrollView { content }
        }
        .frame(width: 820, height: 640)
        .background(theme.glassWindow.color)
    }
}

extension AssistantProvider: Identifiable {
    public var id: String { rawValue }
}
