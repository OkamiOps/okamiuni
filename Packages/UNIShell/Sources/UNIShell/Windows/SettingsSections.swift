import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UNISync

// MARK: - Geral

/// Mantém as preferências em uma mesma implementação, mas apresenta cada
/// decisão no contexto em que a pessoa a procura na central de controle.
/// Assim, abrir “Gestos” não exige escanear campos de IA e vice-versa.
enum GeneralSettingsScope: Equatable {
    case general
    case intelligence
    case gestures
}

struct GeneralSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let settingsStore: AssistantSettingsStore?
    let credentialStore: (any AssistantCredentialStore)?
    let textAssistant: (any TextAssisting)?
    let themes: ThemeStore?
    let swipes: SwipeSettingsStore?
    let moveDestinations: [SwipeMoveDestination]
    /// O serviço é opcional porque a composição pode não ter configurado o
    /// callback PKCE neste build. Sem ele a interface explica o próximo passo,
    /// em vez de oferecer um botão de login que não faz nada.
    let liteLLMOAuthAuthorizer: (any LiteLLMOAuthAuthorizing)?
    /// Login da assinatura pelo runtime oficial do provedor. Este fluxo não
    /// depende de LiteLLM, chave de API ou de um CLI separado instalado.
    let providerOAuthAuthorizer: (any AssistantProviderOAuthAuthorizing)?
    let scope: GeneralSettingsScope

    @State private var draft = AssistantSettings.default
    @State private var credential = ""
    @State private var credentialPresence: AssistantCredentialPresence = .absent
    @State private var checkingCredentialPresence = true
    @State private var liteLLMOAuthStatus: LiteLLMOAuthStatus = .idle
    @State private var providerOAuthStatus: AssistantProviderOAuthStatus = .idle
    @State private var providerOAuthMonitor: Task<Void, Never>?
    @State private var providerOAuthModels: [AssistantProviderModel] = []
    @State private var providerOAuthModelsLoading = false
    @State private var providerOAuthModelsError: String?
    @State private var providerOAuthModelsTask: Task<Void, Never>?
    /// O endpoint ao qual a credencial atualmente selecionada pertence.
    /// Trocar o endpoint invalida essa associação para que uma chave da OpenAI,
    /// por exemplo, nunca seja enviada por acidente a outro servidor.
    @State private var credentialScopeEndpoint = ""
    @State private var promptKind: AssistantPromptKind = .questions
    @State private var cliInstallations: [AssistantCLIInstallation] = []
    @State private var cliAuthenticationStates: [AssistantCLIKind: AssistantCLIAuthenticationState] = [:]
    @State private var checkingCLIAuthentication = false
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var saving = false
    @State private var testing = false

    init(
        scope: GeneralSettingsScope = .general,
        settingsStore: AssistantSettingsStore?,
        credentialStore: (any AssistantCredentialStore)?,
        textAssistant: (any TextAssisting)?,
        liteLLMOAuthAuthorizer: (any LiteLLMOAuthAuthorizing)? = nil,
        providerOAuthAuthorizer: (any AssistantProviderOAuthAuthorizing)? = nil,
        themes: ThemeStore?,
        swipes: SwipeSettingsStore?,
        moveDestinations: [SwipeMoveDestination] = []
    ) {
        self.scope = scope
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.textAssistant = textAssistant
        self.liteLLMOAuthAuthorizer = liteLLMOAuthAuthorizer
        self.providerOAuthAuthorizer = providerOAuthAuthorizer
        self.themes = themes
        self.swipes = swipes
        self.moveDestinations = moveDestinations
        _liteLLMOAuthStatus = State(initialValue: liteLLMOAuthAuthorizer?.sessionState.status ?? .idle)
        _providerOAuthStatus = State(initialValue: providerOAuthAuthorizer?.sessionState.status ?? .idle)
        // A varredura só consulta uma allowlist pequena de caminhos. Fazê-la
        // já na construção evita o flash enganoso de "CLI não encontrado"
        // enquanto a tarefa assíncrona confirma a sessão.
        _cliInstallations = State(initialValue: AssistantCLIDiscovery().scan())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch scope {
                case .general:
                    generalWelcome
                    appearanceCard
                case .intelligence:
                    intelligenceWelcome
                    promptCard
                    assistantCard
                    cliCard
                case .gestures:
                    gesturesWelcome
                    gesturesCard
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 840, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
        .task { await load() }
        .onDisappear {
            providerOAuthMonitor?.cancel()
            providerOAuthMonitor = nil
            providerOAuthModelsTask?.cancel()
            providerOAuthModelsTask = nil
        }
    }

    private var appearanceCard: some View {
        SettingsCard(
            eyebrow: "AMBIENTE",
            title: "Deixe o OkamiUNI com a sua cara",
            subtitle: "O tema muda cor, tipografia e contraste em todas as janelas."
        ) {
            if let themes {
                SettingsLabeledRow(label: "Tema ativo") {
                    Picker("Tema", selection: Binding(
                        get: { themes.theme.id },
                        set: { id in if let chosen = Theme.named(id) { themes.select(chosen) } }
                    )) {
                        ForEach(themes.all) { candidate in
                            Text(candidate.name).tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Tema ativo")
                    .frame(maxWidth: 280)
                }
                SettingsLabeledRow(label: "Tamanho do texto") {
                    Picker("Tamanho do texto", selection: Binding(
                        get: { themes.typographyPreset },
                        set: { themes.selectTypography($0) }
                    )) {
                        ForEach(TypographyPreset.allCases) { preset in
                            Text(typographyLabel(preset)).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Tamanho do texto")
                    .frame(width: 220, alignment: .leading)
                }
                SettingsNotice(
                    symbol: theme.isDark ? "moon.stars" : "sun.max",
                    title: "\(theme.name) está em uso",
                    text: "\(theme.note) O tamanho do texto vale para todas as janelas e não altera o e-mail enviado."
                )
            } else {
                SettingsNotice(
                    symbol: "paintpalette",
                    title: "Temas indisponíveis nesta janela",
                    text: "O seletor de aparência aparece quando o app fornece o armazenamento de temas."
                )
            }
        }
    }

    private func typographyLabel(_ preset: TypographyPreset) -> String {
        switch preset {
        case .compact: "Menor"
        case .standard: "Padrão"
        case .enlarged: "Maior"
        }
    }

    private var generalWelcome: some View {
        SettingsIntro(
            symbol: "rectangle.3.group",
            eyebrow: "CENTRAL DE CONTROLE",
            title: "Ajustes que fazem o e-mail caber na sua rotina.",
            text: "Use a barra lateral para cuidar das contas, definir como o assistente escreve e escolher o que acontece ao arrastar uma mensagem."
        )
    }

    private var intelligenceWelcome: some View {
        SettingsIntro(
            symbol: "sparkles",
            eyebrow: "ASSISTENTE",
            title: "A IA só entra quando você pede.",
            text: "Conecte uma conta, escolha um modelo e defina o seu jeito de escrever. O conteúdo do e-mail não é enviado em segundo plano."
        )
    }

    private var gesturesWelcome: some View {
        SettingsIntro(
            symbol: "hand.draw",
            eyebrow: "CAIXA DE ENTRADA",
            title: "Menos cliques para chegar a uma inbox limpa.",
            text: "Defina até três ações por lado. A primeira é disparada no arraste longo; as demais continuam disponíveis ao abrir a mensagem."
        )
    }

    @ViewBuilder
    private var gesturesCard: some View {
        if let swipes {
            VStack(alignment: .leading, spacing: 16) {
                SwipeRehearsalCard(configuration: swipes.configuration)

                HStack(alignment: .top, spacing: 12) {
                    SwipeSideSettingsCard(
                        side: .leading,
                        store: swipes,
                        moveDestinations: moveDestinations
                    )
                    SwipeSideSettingsCard(
                        side: .trailing,
                        store: swipes,
                        moveDestinations: moveDestinations
                    )
                }

                if moveDestinations.isEmpty {
                    SettingsNotice(
                        symbol: "folder.badge.gearshape",
                        title: "Pastas e marcadores aparecem depois da primeira sincronização",
                        text: "O OkamiUNI só oferece destinos reais da conta. Assim “Mover para” nunca vira um gesto com nome bonito e sem lugar para onde levar a mensagem."
                    )
                }

                HStack(spacing: 9) {
                    Button("Restaurar gestos padrão") { swipes.resetToDefault() }
                        .settingsQuietButton()
                    Text("Você pode deixar um lado sem ações.")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                    Spacer(minLength: 0)
                }
            }
        } else {
            SettingsCard(
                eyebrow: "GESTOS",
                title: "Gestos indisponíveis nesta janela",
                subtitle: "O armazenamento de preferências de arraste ainda não foi conectado."
            ) {
                SettingsNotice(
                    symbol: "hand.draw",
                    title: "Nenhuma escolha será perdida",
                    text: "Quando o armazenamento estiver disponível, você poderá configurar cada lado e restaurar o padrão aqui."
                )
            }
        }
    }

    private var assistantCard: some View {
        SettingsCard(
            eyebrow: "CONEXÃO",
            title: "Escolha de onde vem a resposta",
            subtitle: "A escolha vale apenas quando você pede uma resposta, uma análise ou ajuda para escrever."
        ) {
            SettingsLabeledRow(label: "Provedor") {
                Picker("", selection: Binding(
                    get: { draft.provider },
                    set: { updateProvider($0) }
                )) {
                    Text("Apple Intelligence · neste Mac").tag(AssistantProvider.foundationModels)
                    Text("OAuth direto · Codex ou Grok").tag(AssistantProvider.providerOAuth)
                    Text("API / LiteLLM · chave ou proxy").tag(AssistantProvider.openAICompatible)
                    Text("CLI · sessão já instalada").tag(AssistantProvider.cli)
                }
                .labelsHidden()
                .accessibilityLabel("Provedor de IA")
                .frame(width: Self.assistantSelectionWidth, alignment: .leading)
            }

            assistantRoutingNotice

            switch draft.provider {
            case .foundationModels:
                SettingsNotice(
                    symbol: "lock.shield",
                    title: "Processamento local",
                    text: "Perguntas e escrita usam Foundation Models. A análise automática de mensagens também continua local."
                )
            case .openAICompatible:
                remoteFields
                remoteAuthenticationNotice
                SettingsNotice(
                    symbol: "network",
                    title: "Conteúdo pode sair deste Mac",
                    text: "Ao usar a IA, assunto, corpo, histórico e contexto necessário são enviados ao endpoint configurado. O OkamiUNI não envia nada em segundo plano para este provedor."
                )
            case .providerOAuth:
                providerOAuthFields
            case .cli:
                cliProviderFields
            }

            if let feedback {
                Text(feedback)
                    .font(theme.sans.font(size: 11.5, weight: .medium))
                    .foregroundStyle(feedbackIsError ? theme.danger.color : theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                Button {
                    save()
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Salvar IA") }
                }
                .settingsPrimaryButton()
                .disabled(saving || testing || settingsStore == nil)

                Button {
                    testSavedConfiguration()
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Testar configuração salva") }
                }
                .settingsQuietButton()
                .disabled(saving || testing || textAssistant == nil)

                Spacer(minLength: 0)
            }
        }
    }

    private var assistantRoutingNotice: some View {
        SettingsNotice(
            symbol: draft.provider == .foundationModels ? "lock.shield" : "arrow.triangle.branch",
            title: "Perguntas e escrita: \(assistantRouteLabel)",
            text: "Este é o destino usado quando você aciona Resumo, Pontos-chave, Insights ou Gerar resposta. “TL;DR · neste Mac” é outro recurso: ele continua local, mesmo quando você escolhe outro provedor."
        )
    }

    private var assistantRouteLabel: String {
        draft.interactiveProviderLabel
    }

    @ViewBuilder
    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ATALHOS DE ENDPOINT")
                .capsLabel()
            HStack(spacing: 7) {
                endpointPreset("LiteLLM local", endpoint: "http://127.0.0.1:4000/v1")
            }
        }

        SettingsLabeledRow(label: "Endpoint") {
            TextField("https://seu-proxy.example/v1", text: Binding(
                get: { draft.openAICompatible.endpoint },
                set: { updateEndpoint($0) }
            ))
            .settingsTextField()
        }
        SettingsLabeledRow(label: "Modelo") {
            TextField("Nome do modelo ou alias configurado no proxy", text: Binding(
                get: { draft.openAICompatible.model },
                set: { draft.openAICompatible.model = $0; clearFeedback() }
            ))
            .settingsTextField()
        }

        SettingsLabeledRow(label: "Autenticação") {
            Picker("", selection: Binding(
                get: { draft.openAICompatible.authenticationMode },
                set: { updateRemoteAuthenticationMode($0) }
            )) {
                Text("Sem autenticação").tag(OpenAICompatibleAuthenticationMode.none)
                Text("Chave de API").tag(OpenAICompatibleAuthenticationMode.apiKey)
                Text("OAuth LiteLLM (PKCE)").tag(OpenAICompatibleAuthenticationMode.litellmOAuthPKCE)
            }
            .labelsHidden()
            .accessibilityLabel("Método de autenticação")
            .frame(width: 250)
        }

        switch draft.openAICompatible.authenticationMode {
        case .none:
            EmptyView()
        case .apiKey:
            apiKeyField
        case .litellmOAuthPKCE:
            liteLLMOAuthFields
        }
    }

    @ViewBuilder
    private var apiKeyField: some View {
        SettingsLabeledRow(label: "Chave de API") {
            VStack(alignment: .leading, spacing: 5) {
                SecureField(
                    credentialPresence == .present
                        ? "Chave salva · digite para substituir"
                        : "Chave do provedor ou do proxy",
                    text: $credential
                )
                .settingsTextField()
                HStack(spacing: 8) {
                    Text(credentialStatusLabel)
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                    if credentialPresence == .present {
                        Button("Remover chave") { removeCredential() }
                            .buttonStyle(.plain)
                            .font(theme.sans.font(size: 10.5, weight: .semibold))
                            .foregroundStyle(theme.danger.color)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var remoteAuthenticationNotice: some View {
        switch draft.openAICompatible.authenticationMode {
        case .none:
            SettingsNotice(
                symbol: "checkmark.shield",
                title: "Sem credencial neste endpoint",
                text: "O OkamiUNI não envia o cabeçalho Authorization. Use apenas se o seu LiteLLM ou proxy aceita chamadas sem autenticação."
            )
        case .apiKey:
            SettingsNotice(
                symbol: "key.horizontal",
                title: "Chave usada somente neste modo",
                text: "A chave fica no Keychain e é enviada só ao endpoint configurado. Uma assinatura de chat ou uma sessão de CLI não se transforma em API key."
            )
        case .litellmOAuthPKCE:
            SettingsNotice(
                symbol: "person.badge.key",
                title: "OAuth do seu proxy LiteLLM",
                text: "O login abre o fluxo PKCE do LiteLLM. Device grant não faz parte deste fluxo; sessões de Codex, Claude Code e OpenCode ficam na opção CLI."
            )
        }
    }

    @ViewBuilder
    private var liteLLMOAuthFields: some View {
        SettingsLabeledRow(label: "Sessão LiteLLM") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(liteLLMOAuthStatusColor)
                        .frame(width: 8, height: 8)
                    Text(liteLLMOAuthStatusLabel)
                        .capsLabel()
                }

                if liteLLMOAuthAuthorizer != nil,
                   let endpoint = validRemoteEndpoint {
                    if isLiteLLMOAuthSignedIn {
                        Button("Sair") { signOutLiteLLMOAuth() }
                            .settingsQuietButton()
                    } else {
                        Button("Entrar com OAuth (PKCE)") { startLiteLLMOAuth() }
                            .settingsQuietButton()
                            .disabled(isLiteLLMOAuthBusy || settingsStore == nil)
                    }
                    Text("A sessão é associada a \(endpoint.host ?? "este endpoint") e o app não lê nem exibe tokens.")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                } else if liteLLMOAuthAuthorizer == nil {
                    Text("O fluxo OAuth ainda não está disponível nesta composição. Configure o serviço LiteLLM no app para habilitar o login seguro.")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                } else {
                    Text("Informe um endpoint HTTPS válido para habilitar OAuth (PKCE).")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                }
            }
        }
    }

    @ViewBuilder
    private var providerOAuthFields: some View {
        SettingsLabeledRow(label: "Conta para IA") {
            Picker("", selection: Binding(
                get: { draft.providerOAuth.kind },
                set: { updateProviderOAuthKind($0) }
            )) {
                Text("Codex · conta ChatGPT").tag(AssistantProviderOAuthKind.codex)
                Text("Grok · conta xAI").tag(AssistantProviderOAuthKind.xAI)
            }
            .labelsHidden()
            .accessibilityLabel("Conta para IA")
            .frame(width: Self.assistantSelectionWidth, alignment: .leading)
        }

        SettingsLabeledRow(label: "Modelo da conta") {
            providerOAuthModelSelector
        }

        SettingsLabeledRow(label: "Conexão") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(providerOAuthStatusColor)
                        .frame(width: 8, height: 8)
                    Text(providerOAuthStatusLabel)
                        .capsLabel()
                }

                providerOAuthSessionActions
            }
        }

        switch draft.providerOAuth.kind {
        case .codex:
            SettingsNotice(
                symbol: "person.badge.key",
                title: "Device Code oficial do Codex",
                text: "Conecta sua assinatura ChatGPT por código de dispositivo dentro do OkamiUNI. A sessão fica no espaço privado do app e o catálogo vem do runtime oficial Codex disponível neste Mac, sem expor tokens. Isso não transforma a assinatura em créditos da API."
            )
        case .xAI:
            SettingsNotice(
                symbol: "flask",
                title: "OAuth Grok/xAI experimental",
                text: "O fluxo usa a conta xAI diretamente, sem CLI. A elegibilidade depende do provedor e algumas assinaturas podem receber 403; nesse caso use a opção API com uma chave xAI."
            )
        }

        SettingsNotice(
            symbol: "network",
            title: "Conteúdo enviado somente ao provedor escolhido",
            text: "Nas ações explícitas de IA, assunto, corpo e contexto necessário são enviados ao endpoint fixo do Codex ou da xAI. A sessão de um provedor nunca é reutilizada no outro nem enviada a uma URL configurável."
        )
    }

    @ViewBuilder
    private var providerOAuthModelSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if providerOAuthModelsLoading, providerOAuthModels.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Carregando modelos da conta…")
                        .font(theme.sans.font(size: 11))
                        .foregroundStyle(theme.ink3.color)
                } else if providerOAuthModelOptions.isEmpty {
                    Text(isProviderOAuthSignedIn
                         ? "Nenhum modelo carregado"
                         : "Conecte a conta para carregar os modelos")
                        .font(theme.sans.font(size: 11))
                        .foregroundStyle(theme.ink3.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("", selection: Binding(
                        get: { draft.providerOAuth.model },
                        set: { draft.providerOAuth.model = $0; clearFeedback() }
                    )) {
                        ForEach(providerOAuthModelOptions) { model in
                            Text(providerOAuthModelLabel(model)).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Modelo da conta")
                    .frame(width: Self.assistantSelectionWidth - 34, alignment: .leading)
                }

                if isProviderOAuthSignedIn {
                    Button {
                        refreshProviderOAuthModels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Atualizar modelos da conta")
                    .help("Atualizar modelos da conta")
                    .disabled(providerOAuthModelsLoading)
                }
            }
            .frame(minHeight: 28)

            if let providerOAuthModelsError {
                Text(providerOAuthModelsError)
                    .font(theme.sans.font(size: 10.5))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !providerOAuthModels.isEmpty {
                Text("Lista carregada da conta autenticada; o app não mantém um catálogo fixo.")
                    .font(theme.sans.font(size: 9.8))
                    .foregroundStyle(theme.ink4.color)
            }
        }
        .frame(width: Self.assistantSelectionWidth, alignment: .leading)
    }

    @ViewBuilder
    private var providerOAuthSessionActions: some View {
        if providerOAuthAuthorizer == nil {
            Text("Este build não recebeu o serviço de OAuth direto.")
                .font(theme.sans.font(size: 10.5))
                .foregroundStyle(theme.ink3.color)
        } else {
            switch providerOAuthStatus {
            case .idle, .signedOut, .failed:
                Button(providerOAuthLoginButtonLabel) {
                    startProviderOAuth()
                }
                .settingsQuietButton()
                .disabled(settingsStore == nil)
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verificando uma sessão segura neste Mac…")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                }
            case let .awaitingDeviceCode(presentation):
                providerOAuthDeviceCodeCard(presentation)
            case .signedIn:
                HStack(spacing: 8) {
                    Button("Desconectar neste Mac") { signOutProviderOAuth() }
                        .settingsQuietButton()
                    Text("Tokens não são exibidos nem copiados para a configuração.")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                }
            }
        }
    }

    private func providerOAuthDeviceCodeCard(
        _ presentation: AssistantProviderOAuthDeviceAuthorization
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("CONTINUE NO NAVEGADOR")
                    .capsLabel(size: 8.5)
                Spacer(minLength: 0)
                if presentation.expiresAt != .distantFuture {
                    Text("expira às \(presentation.expiresAt.formatted(date: .omitted, time: .shortened))")
                        .font(theme.mono.font(size: 9.5))
                        .foregroundStyle(theme.ink4.color)
                }
            }

            Text("Abra a página oficial do provedor e informe este código. Esta janela acompanha a confirmação automaticamente.")
                .font(theme.sans.font(size: 10.5))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                Text(presentation.userCode)
                    .font(theme.mono.font(size: 19, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink.color)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.accentLine.color, lineWidth: Hairline.thickness(displayScale))
                    }
                    .accessibilityLabel("Código de dispositivo \(presentation.userCode)")

                Button("Copiar") { copyProviderOAuthCode(presentation.userCode) }
                    .settingsQuietButton()
                Button("Abrir página") { openProviderOAuthPage(presentation.verificationURL) }
                    .settingsPrimaryButton()
                Button("Cancelar") { cancelProviderOAuth() }
                    .settingsQuietButton()
            }

            Text(presentation.verificationURL.absoluteString)
                .font(theme.mono.font(size: 9.5))
                .foregroundStyle(theme.ink4.color)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(13)
        .background(theme.accentSoft.color, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.accentLine.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    @ViewBuilder
    private var cliProviderFields: some View {
        SettingsLabeledRow(label: "CLI") {
            Picker("", selection: Binding(
                get: { draft.cli.kind },
                set: { draft.cli.kind = $0; clearFeedback() }
            )) {
                ForEach(AssistantCLIKind.allCases) { kind in
                    Text(kind.authenticationDisplayName).tag(kind)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Assistente por CLI")
            .frame(width: 350)
        }

        SettingsLabeledRow(label: "Estado") {
            HStack(spacing: 8) {
                Circle()
                    .fill(selectedCLIAuthenticationColor)
                    .frame(width: 8, height: 8)
                Text(selectedCLIAuthenticationLabel)
                    .capsLabel()
            }
        }

        SettingsNotice(
            symbol: selectedCLIAuthenticationSymbol,
            title: selectedCLIAuthenticationTitle,
            text: selectedCLIAuthenticationText
        )
    }

    private var promptCard: some View {
        SettingsCard(
            eyebrow: "SEU JEITO DE TRABALHAR",
            title: "Como você quer que o assistente responda",
            subtitle: "Defina o tom, o idioma e orientações diferentes para perguntas e para escrita."
        ) {
            VStack(alignment: .leading, spacing: 9) {
                Text("PREFERÊNCIAS RÁPIDAS")
                    .capsLabel(size: 8.5)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    SettingsBehaviorMenu(
                        title: "Tom",
                        selection: Binding(
                            get: { draft.behavior.tone },
                            set: { draft.behavior.tone = $0; clearFeedback() }
                        ),
                        choices: AssistantTonePreference.allCases,
                        label: \.label
                    )
                    SettingsBehaviorMenu(
                        title: "Comprimento",
                        selection: Binding(
                            get: { draft.behavior.detail },
                            set: { draft.behavior.detail = $0; clearFeedback() }
                        ),
                        choices: AssistantDetailPreference.allCases,
                        label: \.label
                    )
                    SettingsBehaviorMenu(
                        title: "Idioma",
                        selection: Binding(
                            get: { draft.behavior.language },
                            set: { draft.behavior.language = $0; clearFeedback() }
                        ),
                        choices: AssistantLanguagePreference.allCases,
                        label: \.label
                    )
                    SettingsBehaviorMenu(
                        title: "Formato",
                        selection: Binding(
                            get: { draft.behavior.format },
                            set: { draft.behavior.format = $0; clearFeedback() }
                        ),
                        choices: AssistantFormatPreference.allCases,
                        label: \.label
                    )
                }

                Toggle("Sugerir próximos passos quando fizer sentido", isOn: Binding(
                    get: { draft.behavior.suggestNextSteps },
                    set: { draft.behavior.suggestNextSteps = $0; clearFeedback() }
                ))
                .toggleStyle(.switch)
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ORIENTAÇÕES PARA ESTA AJUDA")
                        .capsLabel(size: 8.5)
                    Spacer(minLength: 0)
                    Text("\(purposeInstructions.wrappedValue.count) / \(AssistantSettings.maximumPurposeInstructionsCharacters)")
                        .font(theme.mono.font(size: 9.5))
                        .foregroundStyle(theme.ink4.color)
                }
                Picker("Finalidade", selection: $promptKind) {
                    ForEach(AssistantPromptKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: purposeInstructions)
                    .settingsTextEditor(minHeight: 96)
                    .accessibilityLabel("Instruções para \(promptKind.label)")

                Text(promptKind == .questions
                     ? "Ex.: destaque riscos, decisões e pendências antes de sugerir uma resposta."
                     : "Ex.: preserve nomes próprios, não invente prazo e escreva como se a mensagem fosse sua.")
                    .font(theme.sans.font(size: 10))
                    .foregroundStyle(theme.ink3.color)
            }

            DisclosureGroup("Orientações para todas as respostas e prévia técnica") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Use apenas para uma regra que vale em qualquer ajuda, como uma especialidade ou uma preferência permanente.")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)

                    TextEditor(text: Binding(
                        get: { draft.additionalInstructions },
                        set: { draft.additionalInstructions = $0; clearFeedback() }
                    ))
                    .settingsTextEditor(minHeight: 84)

                    HStack {
                        Text("\(draft.additionalInstructions.count) / \(AssistantSettings.maximumAdditionalInstructionsCharacters)")
                            .font(theme.mono.font(size: 9.5))
                            .foregroundStyle(theme.ink4.color)
                        Spacer()
                        Button("Limpar instruções globais") {
                            draft.additionalInstructions = ""
                            clearFeedback()
                        }
                        .settingsQuietButton()
                    }

                    Text("PRÉVIA TÉCNICA · \(promptKind.label.uppercased())")
                        .capsLabel(size: 8.5)

                    ScrollView {
                        Text(AssistantPromptCatalog.effectiveSystemPrompt(
                            for: promptKind,
                            settings: draft
                        ))
                        .font(theme.mono.font(size: 10.5))
                        .foregroundStyle(theme.ink2.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(height: 210)
                    .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
                    }
                    Text("O contexto da mensagem, a ação e o histórico só são anexados no momento da chamada. As proteções do OkamiUNI permanecem fixas.")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                }
                .padding(.top, 8)
            }
            .font(theme.sans.font(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.ink2.color)
        }
    }

    private var purposeInstructions: Binding<String> {
        Binding(
            get: {
                switch promptKind {
                case .questions: draft.behavior.questionsInstructions
                case .writing: draft.behavior.writingInstructions
                }
            },
            set: { value in
                switch promptKind {
                case .questions: draft.behavior.questionsInstructions = value
                case .writing: draft.behavior.writingInstructions = value
                }
                clearFeedback()
            }
        )
    }

    private var cliCard: some View {
        SettingsCard(
            title: "CLIs OAuth/device",
            subtitle: "Detecção e estado de sessão sem importar tokens, sessões ou arquivos de credencial"
        ) {
            ForEach(cliInstallations) { installation in
                HStack(spacing: 10) {
                    Circle()
                        .fill(cliAuthenticationColor(for: installation))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installation.kind.displayName)
                            .font(theme.sans.font(size: 12, weight: .semibold))
                            .foregroundStyle(theme.ink.color)
                        Text(installation.executablePath ?? "Não encontrado pelo app")
                            .font(theme.mono.font(size: 9.5))
                            .foregroundStyle(theme.ink3.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Text(cliAuthenticationLabel(for: installation))
                        .capsLabel()
                }
                .padding(.vertical, 3)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Verificar novamente") {
                    refreshCLIInstallations()
                }
                .settingsQuietButton()
            }
            SettingsNotice(
                symbol: "checkmark.shield",
                title: "Status seguro, sem importar a sessão",
                text: "O OkamiUNI consulta apenas os comandos de status de Codex, Claude Code e OpenCode. Não abre login, não executa modelos, não lê arquivos de sessão nem mostra a saída do CLI. Se o sandbox impedir a consulta ou a resposta não for inequívoca, o estado permanece não confirmado."
            )
        }
    }

    private func endpointPreset(_ label: String, endpoint: String) -> some View {
        Button(label) {
            updateEndpoint(endpoint)
        }
        .settingsQuietButton()
    }

    private func updateEndpoint(_ endpoint: String) {
        guard endpoint != draft.openAICompatible.endpoint else { return }

        let invalidatedAPIKey = remoteAuthenticationRequiresAPIKey
            && (hasStoredCredential || !credential.isEmpty)
        draft.openAICompatible.endpoint = endpoint
        if endpoint != credentialScopeEndpoint,
           remoteAuthenticationRequiresAPIKey {
            draft.openAICompatible.credentialID = "openai-compatible-\(UUID().uuidString.lowercased())"
            credentialScopeEndpoint = endpoint
            credential = ""
            credentialPresence = .absent
            checkingCredentialPresence = false
        }

        if invalidatedAPIKey {
            feedback = "O endpoint mudou. Informe a chave correspondente ao novo servidor."
            feedbackIsError = false
        } else {
            clearFeedback()
        }
        refreshLiteLLMOAuthStatus()
    }

    private func updateProvider(_ provider: AssistantProvider) {
        guard provider != draft.provider else { return }
        let deixaOAuthDireto = draft.provider == .providerOAuth && provider != .providerOAuth
        if deixaOAuthDireto {
            providerOAuthMonitor?.cancel()
            providerOAuthMonitor = nil
            clearProviderOAuthModels()
        }
        draft.provider = provider
        credential = ""
        clearFeedback()
        Task {
            // Cancelar é conversa com o ator: acontece antes de perguntar o
            // estado de novo, para a resposta não descrever o login anterior.
            if deixaOAuthDireto { await providerOAuthAuthorizer?.cancelAuthorization() }
            await refreshCredentialPresence()
            refreshLiteLLMOAuthStatus()
            await refreshProviderOAuthStatus()
        }
    }

    private func updateProviderOAuthKind(_ kind: AssistantProviderOAuthKind) {
        guard kind != draft.providerOAuth.kind else { return }
        providerOAuthMonitor?.cancel()
        providerOAuthMonitor = nil
        clearProviderOAuthModels()
        // Cada provedor recebe uma referência própria. O modelo fica vazio até
        // a conta devolver seu catálogo; não há fallback compilado no app.
        draft.providerOAuth = .init(kind: kind)
        providerOAuthStatus = .checking
        clearFeedback()
        Task {
            await providerOAuthAuthorizer?.cancelAuthorization()
            await refreshProviderOAuthStatus()
        }
    }

    private func updateRemoteAuthenticationMode(_ mode: OpenAICompatibleAuthenticationMode) {
        guard mode != draft.openAICompatible.authenticationMode else { return }

        draft.openAICompatible.authenticationMode = mode
        credential = ""
        // API key e OAuth usam serviços distintos no Keychain; conservar a
        // referência permite voltar de modo sem reinterpretar um segredo como
        // o outro. A seleção do modo decide qual cofre o roteador consulta.
        credentialScopeEndpoint = draft.openAICompatible.endpoint
        credentialPresence = .absent
        checkingCredentialPresence = false
        clearFeedback()

        Task {
            await refreshCredentialPresence()
            refreshLiteLLMOAuthStatus()
        }
    }

    private func swipeBinding(_ store: SwipeSettingsStore, side: SwipeSide) -> Binding<SwipeAction> {
        Binding(
            get: {
                let current = side == .leading
                    ? store.configuration.leading : store.configuration.trailing
                return current.first ?? (side == .leading ? .archive : .toggleRead)
            },
            set: { action in
                var current = side == .leading
                    ? store.configuration.leading : store.configuration.trailing
                if current.isEmpty { current = [action] } else { current[0] = action }
                store.setActions(current, on: side)
            }
        )
    }

    private func load() async {
        if let settingsStore { draft = settingsStore.snapshot() }
        guard scope == .intelligence else { return }
        credentialScopeEndpoint = draft.openAICompatible.endpoint
        await refreshCredentialPresence()
        refreshLiteLLMOAuthStatus()
        await refreshProviderOAuthStatus()
        await scanCLIInstallations()
    }

    private func save() {
        guard let settingsStore else { return }
        saving = true
        clearFeedback()
        let draft = draft
        let key = credential
        let credentialStore = credentialStore
        Task {
            do {
                let normalized = try draft.migrated()
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if requiresAPIKey(normalized), normalizedKey.isEmpty {
                    guard let credentialStore else {
                        throw OpenAICompatibleTextAssistantError.missingAPIKey
                    }
                    let presence = await readCredentialPresence(
                        in: credentialStore,
                        credentialID: normalized.openAICompatible.credentialID
                    )
                    guard hasPresentCredential(presence) else {
                        throw OpenAICompatibleTextAssistantError.missingAPIKey
                    }
                }
                if requiresAPIKey(normalized), !normalizedKey.isEmpty {
                    guard let credentialStore else {
                        throw AssistantCredentialStoreError.invalidAPIKey
                    }
                    try await Task.detached {
                        try credentialStore.storeAPIKey(
                            normalizedKey, for: normalized.openAICompatible.credentialID
                        )
                    }.value
                }
                self.draft = try settingsStore.save(normalized)
                credentialScopeEndpoint = normalized.openAICompatible.endpoint
                credential = ""
                await refreshCredentialPresence()
                refreshLiteLLMOAuthStatus()
                await refreshProviderOAuthStatus()
                feedback = "Configuração salva. A próxima ação de IA já usa este provedor."
                feedbackIsError = false
            } catch {
                feedback = error.localizedDescription
                feedbackIsError = true
            }
            saving = false
        }
    }

    private func removeCredential() {
        guard let credentialStore else { return }
        let credentialID = draft.openAICompatible.credentialID
        Task {
            do {
                try await Task.detached {
                    try credentialStore.removeAPIKey(for: credentialID)
                }.value
                credential = ""
                credentialPresence = .absent
                checkingCredentialPresence = false
                feedback = "Chave removida do Keychain."
                feedbackIsError = false
            } catch {
                feedback = error.localizedDescription
                feedbackIsError = true
            }
        }
    }

    private func testSavedConfiguration() {
        guard let textAssistant else { return }
        testing = true
        clearFeedback()
        Task {
            do {
                let emptyWorkspace = AssistantWorkspaceContext(
                    accounts: [], emailCount: 0, unreadCount: 0,
                    mailboxes: [], emails: [], agenda: []
                )
                _ = try await textAssistant.answer(
                    question: "Responda somente com OK para confirmar que o assistente está disponível.",
                    in: .init(mailContext: .workspace(emptyWorkspace))
                )
                feedback = "Conexão confirmada."
                feedbackIsError = false
            } catch {
                feedback = error.localizedDescription
                feedbackIsError = true
            }
            testing = false
        }
    }

    private func clearFeedback() {
        feedback = nil
        feedbackIsError = false
    }

    private var credentialStatusLabel: String {
        if checkingCredentialPresence { return "Verificando o Keychain…" }
        return hasStoredCredential ? "Guardada no Keychain" : "Nenhuma chave guardada"
    }

    private func refreshCLIInstallations() {
        Task { await scanCLIInstallations() }
    }

    private func scanCLIInstallations() async {
        let installations = await Task.detached {
            AssistantCLIDiscovery().scan()
        }.value
        cliInstallations = installations
        checkingCLIAuthentication = true
        let statuses = await AssistantCLIAuthenticationProbe().statuses(for: installations)
        cliAuthenticationStates = Dictionary(
            uniqueKeysWithValues: statuses.map { ($0.kind, $0.state) }
        )
        checkingCLIAuthentication = false
    }

    private func readCredentialPresence(
        in store: any AssistantCredentialStore,
        credentialID: String
    ) async -> AssistantCredentialPresence {
        await Task.detached {
            do {
                return try store.credentialPresence(for: credentialID)
            } catch {
                return .absent
            }
        }.value
    }

    private var remoteAuthenticationRequiresAPIKey: Bool {
        guard case .openAICompatible = draft.provider,
              case .apiKey = draft.openAICompatible.authenticationMode
        else { return false }
        return true
    }

    private var hasStoredCredential: Bool {
        hasPresentCredential(credentialPresence)
    }

    private var selectedCLIDetected: Bool {
        cliInstallations.contains { installation in
            installation.kind == draft.cli.kind && installation.isDetected
        }
    }

    private var selectedCLIAuthenticationState: AssistantCLIAuthenticationState {
        guard selectedCLIDetected else { return .unavailable }
        return cliAuthenticationStates[draft.cli.kind] ?? .unknown
    }

    private var selectedCLIAuthenticationLabel: String {
        if checkingCLIAuthentication, selectedCLIDetected {
            return "DETECTADO · VERIFICANDO SESSÃO"
        }
        switch selectedCLIAuthenticationState {
        case .authenticated:
            return "DETECTADO · AUTENTICADO"
        case .unauthenticated:
            return "DETECTADO · NÃO AUTENTICADO"
        case .unavailable:
            return "CLI NÃO ENCONTRADO"
        case .unknown:
            return "DETECTADO · SESSÃO NÃO CONFIRMADA"
        }
    }

    private var selectedCLIAuthenticationColor: Color {
        if checkingCLIAuthentication, selectedCLIDetected { return theme.accent.color }
        return cliAuthenticationColor(selectedCLIAuthenticationState)
    }

    private var selectedCLIAuthenticationSymbol: String {
        if checkingCLIAuthentication, selectedCLIDetected { return "hourglass" }
        switch selectedCLIAuthenticationState {
        case .authenticated: return "checkmark.shield"
        case .unauthenticated: return "person.crop.circle.badge.exclamationmark"
        case .unavailable: return "terminal.badge.minus"
        case .unknown: return "questionmark.shield"
        }
    }

    private var selectedCLIAuthenticationTitle: String {
        if checkingCLIAuthentication, selectedCLIDetected { return "Verificando a sessão do CLI" }
        switch selectedCLIAuthenticationState {
        case .authenticated: return "Sessão confirmada pelo CLI"
        case .unauthenticated: return "O CLI não tem uma sessão ativa"
        case .unavailable: return "Disponibilize o CLI e tente de novo"
        case .unknown: return "A sessão não pôde ser confirmada"
        }
    }

    private var selectedCLIAuthenticationText: String {
        if checkingCLIAuthentication, selectedCLIDetected {
            return "O OkamiUNI consulta apenas o comando de status de \(draft.cli.kind.displayName), sem tocar em tokens, arquivos de sessão ou modelos."
        }
        switch selectedCLIAuthenticationState {
        case .authenticated:
            return "O comando de status de \(draft.cli.kind.displayName) confirmou uma sessão. A credencial continua no próprio CLI; o OkamiUNI não a lê nem a copia."
        case .unauthenticated:
            return "Conclua OAuth ou device auth no próprio \(draft.cli.kind.displayName) e use “Verificar novamente”. Nenhum token precisa ser colado no OkamiUNI."
        case .unavailable:
            return "Instale ou exponha \(draft.cli.kind.displayName) no PATH e depois use “Verificar novamente”."
        case .unknown:
            return "O executável foi encontrado, mas o status não trouxe evidência inequívoca. Isso também ocorre quando o sandbox bloqueia o acesso da ferramenta à própria sessão. Conclua OAuth/device no CLI e teste a configuração quando o estado mudar."
        }
    }

    private func cliAuthenticationState(
        for installation: AssistantCLIInstallation
    ) -> AssistantCLIAuthenticationState {
        guard installation.isDetected else { return .unavailable }
        return cliAuthenticationStates[installation.kind] ?? .unknown
    }

    private func cliAuthenticationLabel(for installation: AssistantCLIInstallation) -> String {
        let state = cliAuthenticationState(for: installation)
        if checkingCLIAuthentication, state != .unavailable {
            return "DETECTADO · VERIFICANDO"
        }
        switch state {
        case .authenticated: return "DETECTADO · AUTENTICADO"
        case .unauthenticated: return "DETECTADO · NÃO AUTENTICADO"
        case .unavailable: return "AUSENTE"
        case .unknown: return "DETECTADO · NÃO CONFIRMADO"
        }
    }

    private func cliAuthenticationColor(
        for installation: AssistantCLIInstallation
    ) -> Color {
        let state = cliAuthenticationState(for: installation)
        if checkingCLIAuthentication, state != .unavailable { return theme.accent.color }
        return cliAuthenticationColor(state)
    }

    private func cliAuthenticationColor(_ state: AssistantCLIAuthenticationState) -> Color {
        switch state {
        case .authenticated: return theme.success.color
        case .unauthenticated: return theme.danger.color
        case .unavailable, .unknown: return theme.line2.color
        }
    }

    private func requiresAPIKey(_ settings: AssistantSettings) -> Bool {
        guard case .openAICompatible = settings.provider,
              case .apiKey = settings.openAICompatible.authenticationMode
        else { return false }
        return true
    }

    private func hasPresentCredential(_ value: AssistantCredentialPresence) -> Bool {
        if case .present = value { return true }
        return false
    }

    private func refreshCredentialPresence() async {
        guard remoteAuthenticationRequiresAPIKey,
              let credentialStore
        else {
            credentialPresence = .absent
            checkingCredentialPresence = false
            return
        }

        checkingCredentialPresence = true
        let credentialID = draft.openAICompatible.credentialID
        let presence = await readCredentialPresence(
            in: credentialStore,
            credentialID: credentialID
        )
        // A consulta é assíncrona. Se a pessoa alterou endpoint ou modo no
        // intervalo, a presença pertence a outra referência e não pode ser
        // exibida como se fosse da configuração atual.
        guard draft.openAICompatible.credentialID == credentialID,
              remoteAuthenticationRequiresAPIKey
        else { return }
        credentialPresence = presence
        checkingCredentialPresence = false
    }

    private var validRemoteEndpoint: URL? {
        let value = draft.openAICompatible.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return nil }
        return components.url
    }

    private var liteLLMOAuthStatusLabel: String {
        guard liteLLMOAuthAuthorizer != nil else {
            return "INTEGRAÇÃO INDISPONÍVEL"
        }
        switch liteLLMOAuthStatus {
        case .idle:
            return "AGUARDANDO CONFIGURAÇÃO"
        case .checking:
            return "VERIFICANDO SESSÃO"
        case .signedOut:
            return "NÃO CONECTADO"
        case .authorizing:
            return "ABRINDO LOGIN"
        case .signedIn:
            return "AUTENTICADO"
        case .failed:
            return "ERRO DE AUTENTICAÇÃO"
        }
    }

    private var liteLLMOAuthStatusColor: Color {
        guard liteLLMOAuthAuthorizer != nil else { return theme.line2.color }
        switch liteLLMOAuthStatus {
        case .signedIn:
            return theme.success.color
        case .failed:
            return theme.danger.color
        case .checking, .authorizing:
            return theme.accent.color
        case .idle, .signedOut:
            return theme.line2.color
        }
    }

    private var isLiteLLMOAuthSignedIn: Bool {
        if case .signedIn = liteLLMOAuthStatus { return true }
        return false
    }

    private var isLiteLLMOAuthBusy: Bool {
        switch liteLLMOAuthStatus {
        case .checking, .authorizing:
            return true
        case .idle, .signedOut, .signedIn, .failed:
            return false
        }
    }

    private func refreshLiteLLMOAuthStatus() {
        guard case .openAICompatible = draft.provider,
              case .litellmOAuthPKCE = draft.openAICompatible.authenticationMode,
              let authorizer = liteLLMOAuthAuthorizer,
              let endpoint = validRemoteEndpoint
        else { return }
        let credentialID = draft.openAICompatible.credentialID
        // Uma sessão já confirmada não precisa piscar como indisponível toda
        // vez que a janela abre. A checagem continua em segundo plano e troca
        // o estado se o vínculo com o endpoint tiver mudado.
        if !isLiteLLMOAuthSignedIn {
            liteLLMOAuthStatus = .checking
        }
        Task {
            await authorizer.refreshStatus(endpoint: endpoint, credentialID: credentialID)
            liteLLMOAuthStatus = authorizer.sessionState.status
        }
    }

    private func startLiteLLMOAuth() {
        guard let authorizer = liteLLMOAuthAuthorizer,
              let settingsStore
        else { return }

        // O login é parte da configuração, não uma sessão órfã. Validar e
        // persistir primeiro impede que a tela anuncie "autenticado" enquanto
        // o roteador continua usando o provedor anterior ou um modelo vazio.
        let normalized: AssistantSettings
        do {
            normalized = try settingsStore.save(draft)
            self.draft = normalized
            credentialScopeEndpoint = normalized.openAICompatible.endpoint
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
            return
        }
        guard let endpoint = validRemoteEndpoint else {
            feedback = AssistantSettingsError.invalidEndpoint.localizedDescription
            feedbackIsError = true
            return
        }
        let credentialID = normalized.openAICompatible.credentialID
        liteLLMOAuthStatus = .authorizing
        Task {
            do {
                try await authorizer.start(endpoint: endpoint, credentialID: credentialID)
                liteLLMOAuthStatus = authorizer.sessionState.status
                feedback = "Sessão OAuth do LiteLLM conectada."
                feedbackIsError = false
            } catch {
                liteLLMOAuthStatus = authorizer.sessionState.status
                feedback = error.localizedDescription
                feedbackIsError = true
            }
        }
    }

    private func signOutLiteLLMOAuth() {
        guard let authorizer = liteLLMOAuthAuthorizer,
              let endpoint = validRemoteEndpoint
        else { return }
        let credentialID = draft.openAICompatible.credentialID
        liteLLMOAuthStatus = .checking
        Task {
            await authorizer.signOut(endpoint: endpoint, credentialID: credentialID)
            liteLLMOAuthStatus = authorizer.sessionState.status
            if case .signedOut = authorizer.sessionState.status {
                feedback = "Sessão LiteLLM desconectada neste Mac."
                feedbackIsError = false
            } else if case let .failed(message) = authorizer.sessionState.status {
                feedback = message
                feedbackIsError = true
            }
        }
    }

    private var isProviderOAuthSignedIn: Bool {
        if case .signedIn = providerOAuthStatus { return true }
        return false
    }

    private var providerOAuthModelOptions: [AssistantProviderModel] {
        // O Picker sempre representa o catálogo vivo da conta autenticada.
        // Um ID salvo pode ficar obsoleto entre sessões e nunca deve parecer
        // uma opção ainda utilizável só para preservar a seleção visual.
        providerOAuthModels
    }

    private func providerOAuthModelLabel(_ model: AssistantProviderModel) -> String {
        model.displayName == model.id
            ? model.id
            : "\(model.displayName) · \(model.id)"
    }

    private var providerOAuthStatusLabel: String {
        guard providerOAuthAuthorizer != nil else { return "INTEGRAÇÃO INDISPONÍVEL" }
        switch providerOAuthStatus {
        case .idle: return "AGUARDANDO CONFIGURAÇÃO"
        case .checking: return "VERIFICANDO SESSÃO"
        case .signedOut: return "NÃO CONECTADO"
        case .awaitingDeviceCode: return "AGUARDANDO CONFIRMAÇÃO NO NAVEGADOR"
        case .signedIn: return "AUTENTICADO"
        case .failed: return "ERRO DE AUTENTICAÇÃO"
        }
    }

    private var providerOAuthStatusColor: Color {
        guard providerOAuthAuthorizer != nil else { return theme.line2.color }
        switch providerOAuthStatus {
        case .signedIn: return theme.success.color
        case .failed: return theme.danger.color
        case .checking, .awaitingDeviceCode: return theme.accent.color
        case .idle, .signedOut: return theme.line2.color
        }
    }

    private var providerOAuthLoginButtonLabel: String {
        switch draft.providerOAuth.kind {
        case .codex: "Entrar com Codex / ChatGPT"
        case .xAI: "Entrar com Grok / xAI"
        }
    }

    private func refreshProviderOAuthStatus() async {
        guard draft.provider == .providerOAuth,
              let authorizer = providerOAuthAuthorizer
        else { return }

        providerOAuthMonitor?.cancel()
        providerOAuthMonitor = nil
        if case .awaitingDeviceCode = authorizer.sessionState.status {
            // Reabrir Configurações durante o device flow deve manter o código
            // visível. Consultar o Keychain aqui ainda não encontraria uma
            // sessão concluída e faria a tela piscar como desconectada.
            providerOAuthStatus = authorizer.sessionState.status
            monitorProviderOAuth(authorizer)
            return
        }
        let configuration = draft.providerOAuth
        if case .signedIn = providerOAuthStatus {
            // Mantém o estado estável enquanto o Keychain é consultado.
        } else {
            providerOAuthStatus = .checking
        }
        await authorizer.refreshStatus(configuration: configuration)
        guard draft.provider == .providerOAuth,
              draft.providerOAuth.kind == configuration.kind,
              draft.providerOAuth.credentialID == configuration.credentialID
        else { return }
        providerOAuthStatus = authorizer.sessionState.status
        if case .signedIn = authorizer.sessionState.status {
            await loadProviderOAuthModels()
        } else {
            clearProviderOAuthModels(keepingSavedSelection: true)
        }
    }

    private func startProviderOAuth() {
        guard let authorizer = providerOAuthAuthorizer else { return }

        let configuration: AssistantProviderOAuthConfiguration
        do {
            configuration = try draft.providerOAuth.validatedForAuthorization()
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
            return
        }

        providerOAuthMonitor?.cancel()
        providerOAuthStatus = .checking
        clearFeedback()
        Task {
            do {
                try await authorizer.start(configuration: configuration)
                providerOAuthStatus = authorizer.sessionState.status
                if case let .awaitingDeviceCode(presentation) = authorizer.sessionState.status {
                    openProviderOAuthPage(presentation.verificationURL)
                    feedback = "Confirme o código no navegador. Esta janela atualiza quando o provedor concluir o login."
                    feedbackIsError = false
                    monitorProviderOAuth(authorizer)
                } else if case .signedIn = authorizer.sessionState.status {
                    refreshProviderOAuthModels()
                    feedback = "Sessão OAuth conectada. Escolha um modelo carregado e salve a configuração."
                    feedbackIsError = false
                }
            } catch {
                providerOAuthStatus = authorizer.sessionState.status
                feedback = error.localizedDescription
                feedbackIsError = true
            }
        }
    }

    private func monitorProviderOAuth(
        _ authorizer: any AssistantProviderOAuthAuthorizing
    ) {
        providerOAuthMonitor?.cancel()
        providerOAuthMonitor = Task { @MainActor in
            while !Task.isCancelled {
                providerOAuthStatus = authorizer.sessionState.status
                switch authorizer.sessionState.status {
                case .checking, .awaitingDeviceCode:
                    try? await Task.sleep(for: .milliseconds(600))
                case .signedIn:
                    refreshProviderOAuthModels()
                    feedback = "Sessão OAuth conectada. Escolha um modelo carregado e salve a configuração."
                    feedbackIsError = false
                    return
                case let .failed(message):
                    feedback = message
                    feedbackIsError = true
                    return
                case .idle, .signedOut:
                    return
                }
            }
        }
    }

    private func refreshProviderOAuthModels() {
        providerOAuthModelsTask?.cancel()
        providerOAuthModelsTask = Task { @MainActor in
            await loadProviderOAuthModels()
            if !Task.isCancelled {
                providerOAuthModelsTask = nil
            }
        }
    }

    private func loadProviderOAuthModels() async {
        guard draft.provider == .providerOAuth,
              isProviderOAuthSignedIn,
              let authorizer = providerOAuthAuthorizer
        else { return }

        let configuration = draft.providerOAuth
        providerOAuthModelsLoading = true
        providerOAuthModelsError = nil
        defer { providerOAuthModelsLoading = false }
        do {
            let models = try await authorizer.availableModels(
                configuration: configuration
            )
            try Task.checkCancellation()
            guard draft.provider == .providerOAuth,
                  draft.providerOAuth.kind == configuration.kind,
                  draft.providerOAuth.credentialID == configuration.credentialID
            else { return }
            guard !models.isEmpty else {
                throw AssistantProviderOAuthModelCatalogError.emptyCatalog
            }
            providerOAuthModels = models
            let savedModel = draft.providerOAuth.model
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if savedModel.isEmpty {
                draft.providerOAuth.model = models[0].id
            } else if !models.contains(where: { $0.id == savedModel }) {
                draft.providerOAuth.model = models[0].id
                feedback = "O modelo salvo anteriormente não está disponível nesta conta. Selecionamos \(models[0].displayName)."
                feedbackIsError = false
            }
            providerOAuthModelsError = nil
        } catch is CancellationError {
            return
        } catch {
            guard draft.provider == .providerOAuth,
                  draft.providerOAuth.kind == configuration.kind,
                  draft.providerOAuth.credentialID == configuration.credentialID
            else { return }
            // O catálogo pode descobrir que a sessão expirou depois do selo
            // inicial. Reaplique o estado do coordenador para nunca manter um
            // “Autenticado” verde ao lado de um erro de autenticação.
            providerOAuthStatus = authorizer.sessionState.status
            providerOAuthModelsError = error.localizedDescription
        }
    }

    private func clearProviderOAuthModels(keepingSavedSelection: Bool = true) {
        providerOAuthModelsTask?.cancel()
        providerOAuthModelsTask = nil
        providerOAuthModels = []
        providerOAuthModelsLoading = false
        providerOAuthModelsError = nil
        if !keepingSavedSelection {
            draft.providerOAuth.model = ""
        }
    }

    private func cancelProviderOAuth() {
        providerOAuthMonitor?.cancel()
        providerOAuthMonitor = nil
        Task {
            await providerOAuthAuthorizer?.cancelAuthorization()
            providerOAuthStatus = providerOAuthAuthorizer?.sessionState.status ?? .signedOut
        }
        feedback = "Login cancelado. Nenhuma sessão foi salva."
        feedbackIsError = false
    }

    private func signOutProviderOAuth() {
        guard let authorizer = providerOAuthAuthorizer else { return }
        providerOAuthMonitor?.cancel()
        providerOAuthMonitor = nil
        let configuration = draft.providerOAuth
        providerOAuthStatus = .checking
        Task {
            await authorizer.signOut(configuration: configuration)
            providerOAuthStatus = authorizer.sessionState.status
            switch authorizer.sessionState.status {
            case .signedOut:
                clearProviderOAuthModels()
                feedback = "Sessão OAuth removida deste Mac."
                feedbackIsError = false
            case let .failed(message):
                feedback = message
                feedbackIsError = true
            default:
                break
            }
        }
    }

    private func copyProviderOAuthCode(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        feedback = "Código copiado."
        feedbackIsError = false
    }

    private func openProviderOAuthPage(_ url: URL) {
        guard url.scheme?.lowercased() == "https" else {
            feedback = "O provedor devolveu uma página de login insegura."
            feedbackIsError = true
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static let assistantSelectionWidth: CGFloat = 340
}

/// Rótulo de apresentação da rota interativa. O resumo automático usa outro
/// pipeline e continua local; portanto ele não deve reutilizar esta descrição.
extension AssistantSettings {
    var interactiveProviderLabel: String {
        switch provider {
        case .foundationModels:
            return "Apple Intelligence · neste Mac"
        case .providerOAuth:
            let provider = providerOAuth.kind == .codex ? "Codex · ChatGPT" : "Grok · xAI"
            let model = providerOAuth.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "\(provider) · escolha um modelo" : "\(provider) · \(model)"
        case .openAICompatible:
            let model = openAICompatible.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "API / LiteLLM · informe o modelo" : "API / LiteLLM · \(model)"
        case .cli:
            return cli.kind.displayName
        }
    }
}

// MARK: - Gestos

/// Um ensaio deliberadamente simples: ele não simula um gesto concorrente com
/// a lista de e-mails, mas mostra em tempo real a ordem e o alcance das ações
/// persistidas. O gesto verdadeiro continua sendo responsabilidade de
/// `SwipeRow`; esta tela só edita sua configuração.
private struct SwipeRehearsalCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let configuration: SwipeConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ENSAIO AO VIVO")
                        .capsLabel(size: 8.5)
                    Text("É assim que uma mensagem responde ao seu arraste")
                        .font(theme.sans.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                }
                Spacer(minLength: 0)
                Text("A primeira ação dispara no gesto longo")
                    .font(theme.sans.font(size: 9.5))
                    .foregroundStyle(theme.ink3.color)
            }

            GeometryReader { geometry in
                let actionWidth = actionWidth(for: geometry.size.width)
                let sampleWidth = max(0, geometry.size.width - actionWidth * actionCount)
                HStack(spacing: 0) {
                    SwipeActionStrip(
                        actions: configuration.leading,
                        side: .leading,
                        itemWidth: actionWidth
                    )
                    messageSample(width: sampleWidth)
                    SwipeActionStrip(
                        actions: configuration.trailing,
                        side: .trailing,
                        itemWidth: actionWidth
                    )
                }
                .frame(width: geometry.size.width, height: 60, alignment: .leading)
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }

            HStack(spacing: 16) {
                Label("→ para a direita", systemImage: "arrow.right")
                Label("← para a esquerda", systemImage: "arrow.left")
            }
            .font(theme.mono.font(size: 9.5))
            .foregroundStyle(theme.ink4.color)
        }
        .padding(15)
        .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    /// A faixa precisa caber também na janela compacta (960pt): com três ações
    /// de cada lado, preservar 68pt por ação e um centro rígido de 260pt
    /// ultrapassaria a área útil. O centro e as células encolhem juntos, sem
    /// scroll horizontal ou recorte do gesto que a pessoa está ensaiando.
    private var actionCount: CGFloat {
        CGFloat(max(configuration.leading.count, 1) + max(configuration.trailing.count, 1))
    }

    private func actionWidth(for availableWidth: CGFloat) -> CGFloat {
        let preferredMessageWidth = min(260, max(128, availableWidth * 0.38))
        return min(68, max(20, (availableWidth - preferredMessageWidth) / actionCount))
    }

    private func messageSample(width: CGFloat) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.accentSoft.color)
                .frame(width: 31, height: 31)
                .overlay {
                    Image(systemName: "envelope")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Agenda da próxima semana")
                    .font(theme.sans.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Text("Uma mensagem da sua caixa de entrada")
                    .font(theme.sans.font(size: 9.5))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 60)
        .background(theme.surface.color)
    }
}

private struct SwipeActionStrip: View {
    @Environment(\.theme) private var theme
    let actions: [SwipeAction]
    let side: SwipeSide
    let itemWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if actions.isEmpty {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.ink4.color)
                    .frame(width: itemWidth, height: 60)
                    .background(theme.surface3.color)
                    .accessibilityLabel("Nenhuma ação configurada")
            } else {
                ForEach(actions) { action in
                    VStack(spacing: 4) {
                        Image(systemName: symbol(for: action))
                            .font(.system(size: 11, weight: .semibold))
                        if itemWidth >= 44 {
                            Text(action.settingsLabel)
                                .font(theme.sans.font(size: 8.5, weight: .medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.78)
                        }
                    }
                    .foregroundStyle(action.tint == .strong ? theme.onAccent.color : theme.ink2.color)
                    .frame(width: itemWidth, height: 60)
                    .background(action.tint == .strong ? theme.accent.color : theme.surface3.color)
                    .accessibilityLabel("\(side.label): \(action.settingsLabel)")
                }
            }
        }
    }

    private func symbol(for action: SwipeAction) -> String {
        switch action {
        case .archive: "archivebox"
        case .toggleRead: "envelope.open"
        case .later: "clock"
        case .today: "sun.max"
        case .trash: "trash"
        case .toggleFlag: "star"
        case .moveToDestination: "folder"
        }
    }
}

private struct SwipeDestinationAccount: Identifiable {
    let id: String
    let label: String
    let destinations: [SwipeMoveDestination]
}

private struct SwipeSideSettingsCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let side: SwipeSide
    let store: SwipeSettingsStore
    let moveDestinations: [SwipeMoveDestination]
    @State private var moveDestinationError: String?

    private var actions: [SwipeAction] { store.configuration.actions(on: side) }
    private var destinationAccounts: [SwipeDestinationAccount] {
        var grouped = Dictionary(grouping: moveDestinations, by: \.accountID)

        // A pasta pode ter sido removida ou ainda não ter voltado do sync. A
        // configuração existente continua visível na conta certa para que ela
        // nunca migre silenciosamente para outra conta de mesmo nome.
        for destination in store.configuration.destinations(on: side).values {
            if !(grouped[destination.accountID]?.contains(destination) ?? false) {
                grouped[destination.accountID, default: []].append(destination)
            }
        }

        return grouped.map { accountID, destinations in
            SwipeDestinationAccount(
                id: accountID,
                label: destinations.compactMap(\.accountLabel).first ?? accountID,
                destinations: destinations.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            )
        }
        .sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private var hasMoveDestination: Bool { !store.configuration.destinations(on: side).isEmpty }
    private var actionChoices: [SwipeAction] {
        SwipeAction.allCases.filter {
            $0 != .moveToDestination || hasMoveDestination
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: side == .leading ? "arrow.right" : "arrow.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 26, height: 26)
                    .background(theme.accentSoft.color, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(side == .leading ? "Para a direita" : "Para a esquerda")
                        .font(theme.sans.font(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                    Text("Selecione até \(SwipeConfiguration.maxPerSide) ações")
                        .font(theme.sans.font(size: 9.5))
                        .foregroundStyle(theme.ink3.color)
                }
                Spacer(minLength: 0)
                Text("\(actions.count)/\(SwipeConfiguration.maxPerSide)")
                    .font(theme.mono.font(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.ink4.color)
            }

            Picker("Arraste longo", selection: primaryAction) {
                ForEach(actionChoices) { action in
                    Text(action.settingsLabel).tag(action)
                }
            }
            .font(theme.sans.font(size: 10.5))
            .disabled(actions.isEmpty)
            .accessibilityHint("A primeira ação é disparada quando o arraste passa do limite")

            if !destinationAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("MOVER PARA")
                        .capsLabel(size: 8.5)
                    Text("Escolha um destino por conta. As ações acima continuam iguais em todas as caixas.")
                        .font(theme.sans.font(size: 9.5))
                        .foregroundStyle(theme.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(destinationAccounts) { account in
                        destinationPicker(for: account)
                    }
                }
            }

            if let moveDestinationError {
                Text(moveDestinationError)
                    .font(theme.sans.font(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)],
                spacing: 7
            ) {
                ForEach(SwipeAction.allCases.filter { $0 != .moveToDestination }) { action in
                    SwipeActionChoice(
                        action: action,
                        isSelected: actions.contains(action),
                        isDisabled: !actions.contains(action) && actions.count >= SwipeConfiguration.maxPerSide
                    ) {
                        toggle(action)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    private var primaryAction: Binding<SwipeAction> {
        Binding(
            get: { actions.first ?? actionChoices[0] },
            set: { chosen in
                var next = actions.filter { $0 != chosen }
                next.insert(chosen, at: 0)
                store.setActions(next, on: side)
            }
        )
    }

    private func destinationPicker(for account: SwipeDestinationAccount) -> some View {
        let pickerLabel = "Pasta ou marcador de \(account.label)"
        return VStack(alignment: .leading, spacing: 5) {
            Text(account.label)
                .font(theme.sans.font(size: 9.5, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
            Picker(pickerLabel, selection: moveDestination(for: account.id)) {
                Text("Não usar nesta conta").tag(nil as SwipeMoveDestination?)
                ForEach(account.destinations) { destination in
                    Text(destination.displayName).tag(Optional(destination))
                }
            }
            .font(theme.sans.font(size: 10.5))
            .labelsHidden()
            .accessibilityLabel(pickerLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(minHeight: 31)
            .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
        }
    }

    private func moveDestination(for accountID: String) -> Binding<SwipeMoveDestination?> {
        Binding(
            get: { store.configuration.destination(on: side, for: accountID) },
            set: { destination in
                if store.setMoveDestination(destination, on: side, for: accountID) {
                    moveDestinationError = nil
                } else {
                    moveDestinationError = "Este gesto já tem 3 ações. Remova uma para adicionar Mover."
                }
            }
        )
    }

    private func toggle(_ action: SwipeAction) {
        var next = actions
        if let index = next.firstIndex(of: action) {
            next.remove(at: index)
        } else if next.count < SwipeConfiguration.maxPerSide {
            next.append(action)
        }
        store.setActions(next, on: side)
    }
}

private struct SwipeActionChoice: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let action: SwipeAction
    let isSelected: Bool
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? theme.accent.color : theme.ink4.color)
                Text(action.settingsLabel)
                    .font(theme.sans.font(size: 9.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDisabled ? theme.ink4.color : theme.ink2.color)
            .padding(.horizontal, 8)
            .frame(minHeight: 38)
            .background(isSelected ? theme.accentSoft.color : theme.surface.color, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? theme.accentLine.color : theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusRing(cornerRadius: 7)
        .accessibilityLabel("\(action.settingsLabel), \(isSelected ? "selecionada" : "não selecionada")")
    }
}

// MARK: - Assinaturas

struct SignatureSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let model: AccountsModel
    @State private var selectedID: String?
    @State private var visualText = AttributedString()
    @State private var visualSelection = AttributedTextSelection()
    @State private var html = ""
    @State private var inlineResources: [InlineSignatureResource] = []
    @State private var editorMode: SignatureEditorMode = .visual
    @State private var canonicalSource: SignatureEditorSource = .visual
    @State private var savedSignature = EmailSignature(legacyText: "")
    @State private var visualChanged = false
    @State private var htmlChanged = false
    @State private var resourcesChanged = false
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        HStack(spacing: 0) {
            accountList
                .frame(width: 218)
                .background(theme.surface2.color)
            Rectangle()
                .fill(theme.line.color)
                .frame(width: Hairline.thickness(displayScale))
            editor
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.statuses) { _, _ in
            selectFirstIfNeeded()
            refreshSavedValueIfClean()
        }
        .onChange(of: selectedID) { _, _ in loadSelectedSignature() }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("ASSINATURAS")
                        .capsLabel(size: 8.5)
                    Text("\(model.statuses.count)")
                        .font(theme.mono.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(theme.accentSoft.color, in: Capsule())
                }
                Text("Cada conta pode ter uma assinatura própria.")
                    .font(theme.sans.font(size: 10))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.statuses) { status in
                        Button {
                            selectedID = status.accountID
                            feedback = nil
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "signature")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(
                                        selectedID == status.accountID
                                            ? theme.accent.color : theme.ink3.color
                                    )
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(status.address)
                                        .font(theme.sans.font(size: 11.5, weight: .medium))
                                        .foregroundStyle(theme.ink.color)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(signatureSummary(status.emailSignature))
                                        .font(theme.sans.font(size: 10))
                                        .foregroundStyle(theme.ink3.color)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 46)
                            .background(
                                selectedID == status.accountID ? theme.surface3.color : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .focusRing(cornerRadius: 9)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let selected {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ASSINATURA DA CONTA")
                                .capsLabel(size: 8.5)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(selected.address)
                                    .font(theme.sans.font(size: 18, weight: .semibold))
                                    .foregroundStyle(theme.ink.color)
                                if selected.emailSignature.html != nil {
                                    Text("HTML")
                                        .font(theme.mono.font(size: 9, weight: .semibold))
                                        .foregroundStyle(theme.accent.color)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 3)
                                        .background(theme.accentSoft.color, in: Capsule())
                                }
                            }
                            Text("Inserida no composer e nas respostas rápidas desta conta")
                                .font(theme.sans.font(size: 11.5))
                                .foregroundStyle(theme.ink3.color)
                        }

                        SignatureRichEditor(
                            visualText: $visualText,
                            selection: $visualSelection,
                            html: $html,
                            resources: $inlineResources,
                            mode: $editorMode,
                            canonicalSource: $canonicalSource,
                            visualDidChange: { visualChanged = true },
                            htmlDidChange: { htmlChanged = true },
                            resourcesDidChange: { resourcesChanged = true },
                            report: { text, isError in
                                feedback = text
                                feedbackIsError = isError
                            }
                        )

                        Text("A assinatura é uma parte gerenciada do rascunho: entra uma vez por mensagem. O texto alternativo continua disponível para clientes sem HTML.")
                            .font(theme.sans.font(size: 10.5))
                            .foregroundStyle(theme.ink3.color)
                            .fixedSize(horizontal: false, vertical: true)

                        if let feedback {
                            Text(feedback)
                                .font(theme.sans.font(size: 11.5, weight: .medium))
                                .foregroundStyle(feedbackIsError ? theme.danger.color : theme.ink2.color)
                        }
                    }
                    .padding(24)
                    // 600px é uma largura comum em assinaturas HTML com tabela.
                    // A área útil precisa comportá-la sem a WebView reduzir o
                    // layout para caber no antigo limite de 640px.
                    .frame(maxWidth: 820, alignment: .leading)
                }

                Rectangle()
                    .fill(theme.line.color)
                    .frame(height: Hairline.thickness(displayScale))

                HStack(spacing: 9) {
                    Button("Salvar assinatura") { saveSignature() }
                        .settingsPrimaryButton()
                        .disabled(!hasChanges || model.isBusy)
                    Button("Limpar assinatura") { clearSignature() }
                        .settingsQuietButton()
                        .disabled(!hasContent)
                    Spacer(minLength: 0)
                    Text(metadataLabel)
                        .font(theme.mono.font(size: 9.5))
                        .foregroundStyle(theme.ink4.color)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(theme.surface2.color)
            }
        } else {
            SettingsEmptyState(
                symbol: "signature",
                title: "Nenhuma conta disponível",
                text: "Adicione uma conta antes de criar uma assinatura de e-mail."
            )
        }
    }

    private var selected: AccountStatus? {
        model.statuses.first { $0.accountID == selectedID }
    }

    /// HTML importado abre na prévia para que o primeiro contato da pessoa
    /// seja o resultado renderizado, não uma caixa de código. Texto criado no
    /// app continua abrindo no editor Visual.
    static func initialEditorMode(for signature: EmailSignature) -> SignatureEditorMode {
        signature.html == nil ? .visual : .preview
    }

    static func initialCanonicalSource(for signature: EmailSignature) -> SignatureEditorSource {
        signature.html == nil ? .visual : .html
    }

    private func selectFirstIfNeeded() {
        if selectedID == nil || !model.statuses.contains(where: { $0.accountID == selectedID }) {
            selectedID = model.statuses.first?.accountID
        }
    }

    private func loadSelectedSignature() {
        let signature = selected?.emailSignature ?? EmailSignature(legacyText: "")
        savedSignature = signature
        visualText = SignatureRichDocument.visualText(from: signature, theme: theme)
        visualSelection = AttributedTextSelection()
        html = signature.html ?? ""
        inlineResources = signature.inlineResources
        canonicalSource = Self.initialCanonicalSource(for: signature)
        editorMode = Self.initialEditorMode(for: signature)
        visualChanged = false
        htmlChanged = false
        resourcesChanged = false
        feedback = nil
        feedbackIsError = false
    }

    private func refreshSavedValueIfClean() {
        guard !hasChanges, let selected else { return }
        let incoming = selected.emailSignature
        guard incoming != savedSignature else { return }
        loadSelectedSignature()
    }

    private func saveSignature() {
        guard let selectedID else { return }
        let prepared: (signature: EmailSignature, warnings: [String])
        do {
            prepared = try signatureForSaving()
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
            return
        }
        Task {
            if await model.updateEmailSignature(accountID: selectedID, signature: prepared.signature) {
                savedSignature = prepared.signature
                html = prepared.signature.html ?? ""
                inlineResources = prepared.signature.inlineResources
                visualText = SignatureRichDocument.visualText(from: prepared.signature, theme: theme)
                visualSelection = AttributedTextSelection()
                canonicalSource = Self.initialCanonicalSource(for: prepared.signature)
                editorMode = Self.initialEditorMode(for: prepared.signature)
                visualChanged = false
                htmlChanged = false
                resourcesChanged = false
                feedback = prepared.warnings.isEmpty
                    ? "Assinatura salva e disponível no composer."
                    : "Assinatura salva. \(prepared.warnings.joined(separator: " "))"
                feedbackIsError = false
            } else {
                feedback = model.lastError?.mensagem ?? "Não foi possível salvar a assinatura."
                feedbackIsError = true
            }
        }
    }

    private var hasChanges: Bool { visualChanged || htmlChanged || resourcesChanged }

    private var hasContent: Bool {
        !visualText.characters.isEmpty || !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !inlineResources.isEmpty
    }

    private var metadataLabel: String {
        let count = String(visualText.characters).count
        let images = inlineResources.count
        return images == 0 ? "\(count) caracteres" : "\(count) caracteres · \(images) imagem(ns)"
    }

    private func signatureForSaving() throws -> (signature: EmailSignature, warnings: [String]) {
        if !hasChanges { return (savedSignature, []) }

        if canonicalSource == .html, htmlChanged || resourcesChanged {
            return try Self.importedSignature(
                html: html,
                resources: inlineResources
            )
        }

        if canonicalSource == .visual, visualChanged {
            return (
                try EmailSignature(
                    plainText: String(visualText.characters),
                    html: SignatureRichDocument.html(from: visualText, resources: inlineResources, theme: theme),
                    inlineResources: inlineResources
                ),
                []
            )
        }

        // A troca de fonte é sempre explícita no `SignatureRichEditor`, mas
        // manter estes dois fallbacks preserva rascunhos de uma versão mais
        // antiga da tela que ainda só marcava o flag de alteração.
        if htmlChanged {
            return try Self.importedSignature(
                html: html,
                resources: inlineResources
            )
        }

        if visualChanged {
            return (
                try EmailSignature(
                    plainText: String(visualText.characters),
                    html: SignatureRichDocument.html(from: visualText, resources: inlineResources, theme: theme),
                    inlineResources: inlineResources
                ),
                []
            )
        }

        // Só a prateleira mudou. Preservar o documento HTML que a pessoa já
        // tinha, em vez de achatá-lo para texto ao adicionar/remover um logo.
        let baseHTML = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SignatureRichDocument.plainHTML(savedSignature.plainText)
            : html
        return (
            try EmailSignature(
                plainText: savedSignature.plainText,
                html: SignatureRichDocument.ensuringImages(baseHTML, resources: inlineResources),
                inlineResources: inlineResources
            ),
            []
        )
    }

    /// Única transformação usada por Cmd+V, arquivo importado e persistência.
    /// Assim o que aparece na prévia é o mesmo fragmento que chega ao MIME.
    static func importedSignature(
        html: String,
        resources: [InlineSignatureResource]
    ) throws -> (signature: EmailSignature, warnings: [String]) {
        let imported = SignatureHTMLImporter.normalize(
            source: html,
            existingResources: resources
        )
        return (
            try EmailSignature(
                plainText: "",
                html: imported.html,
                inlineResources: imported.inlineResources
            ),
            imported.warnings
        )
    }

    private func clearSignature() {
        visualText = AttributedString()
        visualSelection = AttributedTextSelection()
        html = ""
        inlineResources = []
        canonicalSource = .html
        visualChanged = true
        htmlChanged = true
        resourcesChanged = true
        feedback = "Assinatura limpa. Salve para aplicar a remoção."
        feedbackIsError = false
    }

    private func signatureSummary(_ signature: EmailSignature) -> String {
        guard !signature.plainText.isEmpty || signature.html != nil else { return "Sem assinatura" }
        if signature.html != nil, !signature.inlineResources.isEmpty {
            return "HTML · \(signature.inlineResources.count) imagem(ns)"
        }
        return signature.html != nil ? "Assinatura em HTML" : "Assinatura em texto"
    }
}

// MARK: - Regras

private enum RuleConditionKind: String, CaseIterable, Identifiable {
    case sender
    case subject

    var id: String { rawValue }
    var label: String { self == .sender ? "Remetente contém" : "Assunto contém" }
}

private struct RuleDraft {
    var id = UUID().uuidString
    var name = ""
    var enabled = true
    var conditionKind: RuleConditionKind = .sender
    var conditionValue = ""
    var actions: Set<EmailRuleAction> = [.archive]
    /// Nil mantém as regras antigas globais. As entregas que dependem de uma
    /// conta (encaminhar e mover) exigem uma seleção explícita antes de salvar.
    var scopeAccountID: String?
    var forwards = false
    var forwardTo = ""
    var moves = false
    var moveDestination: SwipeMoveDestination?

    init() {}

    init(_ rule: EmailRule) {
        id = rule.id
        name = rule.name
        enabled = rule.enabled
        actions = Set(rule.actions)
        scopeAccountID = rule.accountID
        forwards = rule.forwarding != nil
        forwardTo = rule.forwarding?.address ?? ""
        moves = rule.moveDestination != nil
        moveDestination = rule.moveDestination
        // Uma regra persistida por uma versão anterior pode ter as duas
        // consequências. A tela não a reapresenta como uma ordem ambígua:
        // mover substitui arquivar porque ambos alteram a localização.
        if moves { actions.remove(.archive) }
        switch rule.condition {
        case .senderContains(let value):
            conditionKind = .sender
            conditionValue = value
        case .subjectContains(let value):
            conditionKind = .subject
            conditionValue = value
        }
    }

    var rule: EmailRule {
        EmailRule(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            condition: conditionKind == .sender
                ? .senderContains(conditionValue.trimmingCharacters(in: .whitespacesAndNewlines))
                : .subjectContains(conditionValue.trimmingCharacters(in: .whitespacesAndNewlines)),
            actions: EmailRuleAction.allCases.filter(actions.contains),
            enabled: enabled,
            accountID: scopeAccountID,
            forwarding: forwards ? configuredForwarding : nil,
            moveDestination: moves ? moveDestination : nil
        )
    }

    private var configuredForwarding: EmailRuleForwarding? {
        EmailRuleForwarding(address: forwardTo)
    }

    private var needsAccount: Bool { forwards || moves }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !conditionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!actions.isEmpty || forwards || moves)
            && (!needsAccount || scopeAccountID != nil)
            && (!forwards || configuredForwarding != nil)
            && (!moves || (moveDestination != nil && moveDestination?.accountID == scopeAccountID))
    }
}

struct RulesSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: EmailRuleStore?
    let accounts: [AccountStatus]
    let moveDestinations: [SwipeMoveDestination]
    @State private var selectedID: String?
    @State private var draft = RuleDraft()
    @State private var editingNewRule = false
    @State private var deleteCandidate: String?
    @State private var forwardingConfirmation = false
    @State private var feedback: String?

    var body: some View {
        Group {
            if let store {
                HStack(spacing: 0) {
                    rulesList(store)
                        .frame(width: 238)
                        .background(theme.surface2.color)
                    Rectangle()
                        .fill(theme.line.color)
                        .frame(width: Hairline.thickness(displayScale))
                    ruleEditor(store)
                }
            } else {
                SettingsEmptyState(
                    symbol: "arrow.triangle.branch",
                    title: "Regras indisponíveis",
                    text: "O armazenamento de regras não foi conectado a esta janela."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.paper.color)
        .onAppear { selectFirstIfNeeded() }
        .confirmationDialog(
            "Apagar esta regra?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button("Apagar", role: .destructive) {
                if let id = deleteCandidate { store?.remove(id: id) }
                deleteCandidate = nil
                selectedID = nil
                editingNewRule = false
                selectFirstIfNeeded()
            }
            Button("Cancelar", role: .cancel) { deleteCandidate = nil }
        }
        .confirmationDialog(
            "Ativar encaminhamento automático?",
            isPresented: $forwardingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Salvar e ativar encaminhamento") {
                if let store { saveRule(in: store) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Mensagens novas que corresponderem a esta regra serão encaminhadas para \(draft.forwardTo), pela conta escolhida, sem anexos, Cc ou Cco.")
        }
    }

    private func rulesList(_ store: EmailRuleStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("AUTOMAÇÕES")
                            .capsLabel(size: 8.5)
                        Text("\(store.rules.count)")
                            .font(theme.mono.font(size: 9, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(theme.accentSoft.color, in: Capsule())
                    }
                    Text("Organize mensagens novas sem limpar a caixa na mão.")
                        .font(theme.sans.font(size: 10))
                        .foregroundStyle(theme.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    editingNewRule = true
                    selectedID = nil
                    draft = RuleDraft()
                    feedback = nil
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(theme.accentSoft.color, in: RoundedRectangle(cornerRadius: 7))
                .focusRing(cornerRadius: 7)
                .help("Criar regra")
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if store.rules.isEmpty && !editingNewRule {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 24, weight: .light))
                    Text("Nenhuma regra")
                        .font(theme.sans.font(size: 11.5, weight: .medium))
                    Button("Criar a primeira") {
                        editingNewRule = true
                        draft = RuleDraft()
                    }
                    .settingsQuietButton()
                }
                .foregroundStyle(theme.ink3.color)
                .frame(maxWidth: .infinity)
                .padding(.top, 50)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.rules) { rule in
                            HStack(spacing: 7) {
                                Button {
                                    editingNewRule = false
                                    selectedID = rule.id
                                    draft = RuleDraft(rule)
                                    feedback = nil
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.name)
                                            .font(theme.sans.font(size: 11.5, weight: .semibold))
                                            .foregroundStyle(theme.ink.color)
                                            .lineLimit(1)
                                        Text(ruleSummary(rule))
                                            .font(theme.sans.font(size: 9.8))
                                            .foregroundStyle(theme.ink3.color)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Toggle("", isOn: Binding(
                                    get: { store.rule(id: rule.id)?.enabled ?? false },
                                    set: { enabled in
                                        store.setEnabled(enabled, for: rule.id)
                                        if selectedID == rule.id, !editingNewRule {
                                            draft.enabled = enabled
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 50)
                            .background(
                                selectedID == rule.id && !editingNewRule
                                    ? theme.surface3.color : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func ruleEditor(_ store: EmailRuleStore) -> some View {
        if editingNewRule || selectedID != nil {
            ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                        Text(editingNewRule ? "NOVA AUTOMAÇÃO" : "AUTOMAÇÃO")
                            .capsLabel(size: 8.5)
                        Text(editingNewRule ? "Nova regra" : "Editar regra")
                            .font(theme.sans.font(size: 18, weight: .semibold))
                            .foregroundStyle(theme.ink.color)
                        Text("Vale para mensagens novas depois que a regra é salva")
                            .font(theme.sans.font(size: 11.5))
                            .foregroundStyle(theme.ink3.color)
                    }

                    Toggle("Regra ativa", isOn: $draft.enabled)
                        .toggleStyle(.switch)

                    SettingsLabeledRow(label: "Nome") {
                        TextField("Ex.: Arquivar newsletters", text: $draft.name)
                            .settingsTextField()
                    }
                    SettingsLabeledRow(label: "Conta") {
                        Picker("Conta da regra", selection: Binding(
                            get: { draft.scopeAccountID },
                            set: { accountID in
                                draft.scopeAccountID = accountID
                                if draft.moveDestination?.accountID != accountID {
                                    draft.moveDestination = nil
                                }
                            }
                        )) {
                            Text("Todas as contas").tag(nil as String?)
                            ForEach(accounts) { account in
                                Text(account.address).tag(Optional(account.accountID))
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Conta à qual a regra se aplica")
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                    SettingsLabeledRow(label: "Quando") {
                        VStack(alignment: .leading, spacing: 7) {
                            Picker("", selection: $draft.conditionKind) {
                                ForEach(RuleConditionKind.allCases) { kind in
                                    Text(kind.label).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Condição da regra")
                            TextField("Texto a procurar", text: $draft.conditionValue)
                                .settingsTextField()
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("AÇÕES NA CAIXA")
                            .capsLabel()
                        ForEach(EmailRuleAction.allCases) { action in
                            Toggle(action.label, isOn: Binding(
                                get: { draft.actions.contains(action) },
                                set: { enabled in
                                    if enabled {
                                        draft.actions.insert(action)
                                        if action == .archive {
                                            draft.moves = false
                                            draft.moveDestination = nil
                                        }
                                    } else {
                                        draft.actions.remove(action)
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("ENTREGAS ADICIONAIS")
                            .capsLabel()

                        Toggle("Encaminhar uma cópia", isOn: $draft.forwards)
                            .toggleStyle(.checkbox)

                        if draft.forwards {
                            SettingsLabeledRow(label: "Endereço") {
                                VStack(alignment: .leading, spacing: 5) {
                                    TextField("nome@empresa.com", text: $draft.forwardTo)
                                        .textContentType(.emailAddress)
                                        .settingsTextField()
                                    if EmailRuleForwarding(address: draft.forwardTo) == nil {
                                        Text("Informe um único endereço de e-mail válido.")
                                            .font(theme.sans.font(size: 10))
                                            .foregroundStyle(theme.danger.color)
                                    }
                                }
                            }
                        }

                        Toggle("Mover para pasta ou marcador", isOn: Binding(
                            get: { draft.moves },
                            set: { enabled in
                                draft.moves = enabled
                                if enabled {
                                    draft.actions.remove(.archive)
                                } else {
                                    draft.moveDestination = nil
                                }
                            }
                        ))
                            .toggleStyle(.checkbox)

                        if draft.moves {
                            Text("Mover substitui Arquivar nesta regra para não emitir duas mudanças de pasta.")
                                .font(theme.sans.font(size: 10))
                                .foregroundStyle(theme.ink3.color)
                            SettingsLabeledRow(label: "Destino") {
                                if let scopeAccountID = draft.scopeAccountID {
                                    let destinations = moveDestinations.filter {
                                        $0.accountID == scopeAccountID
                                    }
                                    if destinations.isEmpty {
                                        Text("Sincronize a conta para escolher uma pasta ou marcador real.")
                                            .font(theme.sans.font(size: 10.5))
                                            .foregroundStyle(theme.ink3.color)
                                    } else {
                                        Picker("Pasta ou marcador", selection: Binding(
                                            get: { draft.moveDestination?.id },
                                            set: { id in
                                                draft.moveDestination = destinations.first { $0.id == id }
                                            }
                                        )) {
                                            Text("Escolha um destino").tag(nil as String?)
                                            ForEach(destinations) { destination in
                                                Text(destination.displayName).tag(Optional(destination.id))
                                            }
                                        }
                                        .labelsHidden()
                                        .accessibilityLabel("Pasta ou marcador de destino")
                                        .frame(maxWidth: 320, alignment: .leading)
                                    }
                                } else {
                                    Text("Escolha uma conta antes de definir o destino.")
                                        .font(theme.sans.font(size: 10.5))
                                        .foregroundStyle(theme.ink3.color)
                                }
                            }
                        }
                    }

                    if draft.forwards || draft.moves {
                        SettingsNotice(
                            symbol: "lock.shield",
                            title: "Privacidade e entrega automática",
                            text: "Encaminhar usa a conta escolhida e envia uma cópia do conteúdo da mensagem para o endereço informado, sem anexos, Cc ou Cco. Mover usa somente a pasta ou o marcador real já sincronizado dessa conta."
                        )
                    }

                    SettingsNotice(
                        symbol: "info.circle",
                        title: "Execução idempotente",
                        text: "A regra não reprocessa o histórico da caixa e cada mensagem nova é avaliada uma vez por sessão. As ações usam a mesma fila de saída dos botões da caixa."
                    )

                    if let feedback {
                        Text(feedback)
                            .font(theme.sans.font(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.ink2.color)
                    }

                    HStack(spacing: 9) {
                        Button("Salvar regra") {
                            if draft.forwards {
                                forwardingConfirmation = true
                            } else {
                                saveRule(in: store)
                            }
                        }
                        .settingsPrimaryButton()
                        .disabled(!draft.isValid)

                        if !editingNewRule {
                            Button("Apagar regra") { deleteCandidate = draft.id }
                                .settingsDangerButton()
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
            }
        } else {
            SettingsEmptyState(
                symbol: "arrow.triangle.branch",
                title: "Selecione ou crie uma regra",
                text: "Regras podem organizar mensagens novas, encaminhar uma cópia sem anexos e movê-las para uma pasta ou marcador da conta escolhida."
            )
        }
    }

    private func selectFirstIfNeeded() {
        guard let store else { return }
        if let selectedID, store.rule(id: selectedID) != nil { return }
        guard let first = store.rules.first else { return }
        selectedID = first.id
        draft = RuleDraft(first)
    }

    private func saveRule(in store: EmailRuleStore) {
        store.upsert(draft.rule)
        selectedID = draft.id
        editingNewRule = false
        feedback = "Regra salva."
    }

    private func ruleSummary(_ rule: EmailRule) -> String {
        let condition: String
        switch rule.condition {
        case .senderContains(let value): condition = "Remetente: \(value)"
        case .subjectContains(let value): condition = "Assunto: \(value)"
        }
        var details = [condition]
        if let accountID = rule.accountID {
            let account = accounts.first(where: { $0.accountID == accountID })
            details.append(account?.address ?? accountID)
        }
        if rule.forwarding != nil { details.append("Encaminha") }
        if let destination = rule.moveDestination {
            details.append("Move: \(destination.displayName)")
        }
        return details.joined(separator: " · ")
    }
}

// MARK: - Agenda

/// Serviço padrão por conta e conexão das APIs. O editor cria uma sala nova
/// a cada compromisso — nunca um link permanente.
struct AgendaSettingsView: View {
    @Environment(\.theme) private var theme

    let rooms: MeetingRoomSettingsStore?
    let accounts: [AccountStatus]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsIntro(
                    symbol: "video.fill",
                    eyebrow: "REUNIÕES",
                    title: "Sala nova a cada compromisso",
                    text: "Meet nasce do Google já conectado. Zoom, Teams e Zoho usam a API de cada um. Um link fixo vira reunião eterna, com o título errado — por isso o OkamiUNI cria a sala na hora de adicionar."
                )

                if accounts.isEmpty {
                    SettingsEmptyState(
                        symbol: "at",
                        title: "Nenhuma conta conectada",
                        text: "Conecte uma caixa em Contas. O Meet usa o Google OAuth dessa caixa."
                    )
                    .frame(minHeight: 180)
                } else if let rooms {
                    ForEach(accounts) { account in
                        accountCard(account, rooms: rooms)
                    }
                } else {
                    SettingsNotice(
                        symbol: "exclamationmark.triangle",
                        title: "Preferências indisponíveis",
                        text: "Não foi possível abrir as preferências de reunião neste Mac."
                    )
                }

                if let rooms {
                    ForEach(MeetingService.allCases.filter(\.needsAPIConnection)) { service in
                        apiCard(service, rooms: rooms)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 840, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
    }

    private func accountCard(_ account: AccountStatus, rooms: MeetingRoomSettingsStore) -> some View {
        let profile = rooms.profile(for: account.accountID)
        let isGmail = account.hostMark.lowercased() == "gmail"
            || account.address.lowercased().hasSuffix("@gmail.com")
            || account.address.lowercased().hasSuffix("@googlemail.com")
        return SettingsCard(
            eyebrow: account.hostMark.uppercased(),
            title: account.address,
            subtitle: isGmail
                ? "Meet cria uma sala nova via Google. Reconecte a caixa se o Google pedir acesso ao Meet."
                : "O serviço padrão desta caixa. Meet exige uma conta Google conectada."
        ) {
            SettingsLabeledRow(label: "Padrão") {
                Picker("Serviço padrão", selection: Binding(
                    get: { profile.defaultService?.rawValue ?? "" },
                    set: { raw in
                        rooms.setDefault(MeetingService(rawValue: raw), for: account.accountID)
                    }
                )) {
                    Text("Nenhum").tag("")
                    ForEach(MeetingService.allCases) { service in
                        Text(service.label).tag(service.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private func apiCard(_ service: MeetingService, rooms: MeetingRoomSettingsStore) -> some View {
        let connection = rooms.connection(for: service)
        return SettingsCard(
            eyebrow: service.shortLabel.uppercased(),
            title: service.label,
            subtitle: rooms.isConnected(service)
                ? "Conectado. Cada compromisso ganha uma sala nova."
                : "Credenciais da API — não é o link de uma reunião."
        ) {
            SettingsLabeledRow(label: "Client ID") {
                TextField("Client ID", text: Binding(
                    get: { connection.clientID },
                    set: { rooms.setConnection(connection.updating(clientID: $0), for: service) }
                ))
                .settingsTextField()
            }
            SettingsLabeledRow(label: "Client secret") {
                SecureField("Client secret", text: Binding(
                    get: { connection.clientSecret },
                    set: { rooms.setConnection(connection.updating(clientSecret: $0), for: service) }
                ))
                .settingsTextField()
            }
            SettingsLabeledRow(label: service.extraFieldLabel) {
                if service == .zoho {
                    SecureField(service.extraFieldLabel, text: Binding(
                        get: { connection.extra },
                        set: { rooms.setConnection(connection.updating(extra: $0), for: service) }
                    ))
                    .settingsTextField()
                } else {
                    TextField(service.extraFieldLabel, text: Binding(
                        get: { connection.extra },
                        set: { rooms.setConnection(connection.updating(extra: $0), for: service) }
                    ))
                    .settingsTextField()
                }
            }
        }
    }
}

// MARK: - Peças comuns

private struct SettingsIntro: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let symbol: String
    let eyebrow: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent.color)
                .frame(width: 38, height: 38)
                .background(theme.accentSoft.color, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .capsLabel(size: 8.5)
                Text(title)
                    .font(theme.sans.font(size: 18, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(text)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let eyebrow: String?
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow)
                        .capsLabel(size: 8.5)
                }
                Text(title)
                    .font(theme.sans.font(size: 14.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(subtitle)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
            }
            content
        }
        .padding(18)
        .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }
}

private struct SettingsLabeledRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    @ViewBuilder let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                Text(label)
                    .font(theme.sans.font(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: 148, alignment: .trailing)
                    .padding(.top, 7)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(theme.sans.font(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.ink3.color)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SettingsNotice: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent.color)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(theme.sans.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(text)
                    .font(theme.sans.font(size: 10.8))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentSoft.color, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SettingsEmptyState: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.ink4.color)
            Text(title)
                .font(theme.sans.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(text)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

private struct SettingsBehaviorMenu<Option: Identifiable & Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let title: String
    @Binding var selection: Option
    let choices: [Option]
    let label: (Option) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(theme.sans.font(size: 10, weight: .medium))
                .foregroundStyle(theme.ink3.color)
            Picker(title, selection: $selection) {
                ForEach(choices) { choice in
                    Text(label(choice)).tag(choice)
                }
            }
            .labelsHidden()
            .accessibilityLabel(title)
            .font(theme.sans.font(size: 11.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(minHeight: 31)
            .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension View {
    func settingsTextField() -> some View {
        modifier(SettingsTextFieldStyle())
    }

    func settingsTextEditor(minHeight: CGFloat) -> some View {
        modifier(SettingsTextEditorStyle(minHeight: minHeight))
    }

    func settingsPrimaryButton() -> some View {
        modifier(SettingsButtonStyle(kind: .primary))
    }

    func settingsQuietButton() -> some View {
        modifier(SettingsButtonStyle(kind: .quiet))
    }

    func settingsDangerButton() -> some View {
        modifier(SettingsButtonStyle(kind: .danger))
    }
}

private struct SettingsTextFieldStyle: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(theme.sans.font(size: 12))
            .foregroundStyle(theme.ink.color)
            .padding(.horizontal, 10)
            .frame(minHeight: 31)
            .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
    }
}

private struct SettingsTextEditorStyle: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .font(theme.sans.font(size: 12))
            .foregroundStyle(theme.ink.color)
            .scrollContentBackground(.hidden)
            .padding(9)
            .frame(minHeight: minHeight)
            .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
    }
}

private struct SettingsButtonStyle: ViewModifier {
    enum Kind { case primary, quiet, danger }
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let kind: Kind

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(theme.sans.font(size: 11.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(minHeight: 29)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(border, lineWidth: Hairline.thickness(displayScale))
            }
            .focusRing(cornerRadius: 8)
    }

    private var foreground: Color {
        switch kind {
        case .primary: theme.onAccent.color
        case .quiet: theme.ink2.color
        case .danger: theme.danger.color
        }
    }

    private var background: Color {
        kind == .primary ? theme.accent.color : theme.surface.color
    }

    private var border: Color {
        kind == .primary ? theme.accent.color : theme.line2.color
    }
}
