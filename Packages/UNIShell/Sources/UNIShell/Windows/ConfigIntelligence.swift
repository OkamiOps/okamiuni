import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Qual página da Inteligência está aberta dentro do painel.
///
/// A folha de escolher e a de entrar numa conta **não** estão aqui: elas são
/// modais sobre a janela inteira, e por isso vivem em `AccountsWindow` (ver
/// `ConfigIntelligenceSheet`). Aqui ficam só as páginas que substituem o
/// conteúdo do painel e ganham o "‹ Inteligência" no cabeçalho.
enum ConfigIntelligencePage: Hashable {
    case main
    /// O formulário de chave de API de um preset do catálogo.
    case apiKey(presetID: String)
    /// "Neste Mac": Apple Intelligence e os servidores de loopback.
    case local
}

/// As duas abas do cabeçalho.
enum ConfigIntelligenceTab: Hashable {
    case connections
    case writing
}

/// Inteligência: quem faz o quê, as conexões que existem, e o interruptor da
/// análise automática.
///
/// A tela não tem catálogo: tudo o que ela lista **responde agora** neste Mac
/// (ver `ConfigAIInventory`). O catálogo do que poderia ser conectado é a folha
/// "Conectar uma IA", que abre por cima da janela.
struct ConfigIntelligence: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    @Binding var draft: AssistantSettings
    /// A folha aberta sobre a janela. Mora fora desta view porque o véu do
    /// desenho cobre a navegação também.
    @Binding var sheet: ConfigIntelligenceSheet?
    /// A página que a folha pediu ao se fechar. Também mora fora porque é a
    /// folha, que é de lá, quem a escolhe.
    @Binding var requestedPage: ConfigIntelligencePage?

    let oauthStatus: AssistantProviderOAuthStatus
    let availableModels: [AssistantProviderModel]
    let cliInstallations: [AssistantCLIInstallation]
    let cliAuthentication: [AssistantCLIKind: AssistantCLIAuthenticationState]
    let apiKeyPresent: Bool
    let lastTest: String?
    let lastTestFailed: Bool
    let testing: Bool

    let save: () -> Void
    let test: () -> Void
    let storeAPIKey: (String) -> Void
    let removeAPIKey: () -> Void
    /// Abre o painel de conexão antigo — é lá que moram o OAuth do LiteLLM e
    /// os formulários de agente (pasta autorizada, bookmark, teste de ACP e
    /// Agent Card do A2A). Esta tela não os reimplementa: eles funcionam.
    let openAdvancedPanel: () -> Void
    /// Pergunta a um servidor de loopback quais modelos ele tem. É injetável
    /// para o retrato poder desenhar "não está rodando" sem depender de haver
    /// ou não um Ollama ligado na máquina que roda a suíte.
    var probeLocal: @Sendable (String) async -> LocalServerState = { endpoint in
        await LocalModelCatalog().probe(endpoint: endpoint)
    }

    @State private var page: ConfigIntelligencePage = .main
    @State private var tab: ConfigIntelligenceTab = .connections

    private var inventory: ConfigAIInventory {
        ConfigAIInventory(
            draft: draft,
            oauthStatus: oauthStatus,
            models: availableModels,
            cliInstallations: cliInstallations,
            cliAuthentication: cliAuthentication,
            apiKeyPresent: apiKeyPresent
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch page {
            case .main:
                if tab == .writing {
                    ConfigIntelligenceWriting(draft: $draft, save: save)
                } else {
                    mainPage
                }
            case .apiKey(let presetID):
                ConfigIntelligenceAPIKeyForm(
                    draft: $draft,
                    preset: ConfigAICatalog.preset(presetID),
                    apiKeyPresent: apiKeyPresent,
                    lastTest: lastTest,
                    lastTestFailed: lastTestFailed,
                    testing: testing,
                    save: save,
                    test: test,
                    storeAPIKey: storeAPIKey,
                    removeAPIKey: { removeAPIKey(); page = .main },
                    openAdvancedPanel: openAdvancedPanel,
                    probeLocal: probeLocal
                )
            case .local:
                ConfigIntelligenceLocalPage(
                    draft: $draft,
                    save: save,
                    probe: probeLocal
                )
            }
        }
        // A folha de escolher pede uma página pelo caminho de volta: ela some e
        // a página nasce embaixo dela, no mesmo painel.
        .onChange(of: requestedPage) { _, pedida in
            guard let pedida else { return }
            page = pedida
            requestedPage = nil
        }
    }

    // MARK: O cabeçalho

    /// `header`: `align-items: flex-end; gap: 16px; padding-bottom: 16px`, com
    /// o voltar opcional em cima do título e as abas à direita.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                if page != .main {
                    Button {
                        page = .main
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text(L10n.tr("Inteligência"))
                        }
                        .font(theme.sans.font(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.ink3.color)
                        .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)
                }
                Text(title)
                    .font(theme.sans.font(size: 27, weight: .bold))
                    .tracking(-0.025 * 27)
                    .foregroundStyle(palette.ink.color)
                    .lineLimit(1)
                Text(subtitle)
                    .font(theme.sans.font(size: 14))
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if page == .main { tabs }
        }
        .padding(.bottom, 16)
    }

    private var title: String {
        switch page {
        case .main: L10n.tr("Inteligência")
        case .apiKey(let presetID): ConfigAICatalog.preset(presetID)?.name ?? L10n.tr("Chave de API")
        case .local: L10n.tr("Neste Mac")
        }
    }

    private var subtitle: String {
        switch page {
        case .main:
            let escrita = inventory.connection(for: .escrita)
            let conversas = inventory.connection(for: .conversas)
            if escrita.kind == conversas.kind {
                return L10n.tr("Pronta — \(escrita.name) escreve e conversa, e só quando você pede")
            }
            return L10n.tr("Pronta — \(escrita.name) escreve, \(conversas.name) conversa, e só quando você pede")
        case .apiKey:
            return L10n.tr("Chave de API · endpoint compatível com OpenAI")
        case .local:
            return L10n.tr("As IAs que rodam no seu computador, sem passar pela internet")
        }
    }

    /// `role="tablist"`: calha de `field`, `padding: 3px`, e cada aba em
    /// `padding: 6px 14px`.
    private var tabs: some View {
        HStack(spacing: 2) {
            tabButton(L10n.tr("Conexões"), value: .connections)
            tabButton(L10n.tr("Como ela escreve"), value: .writing)
        }
        .padding(3)
        .background(palette.field.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Abas da Inteligência"))
    }

    private func tabButton(_ label: String, value: ConfigIntelligenceTab) -> some View {
        let on = tab == value
        return Button { tab = value } label: {
            Text(label)
                .font(theme.sans.font(size: 13, weight: on ? .semibold : .medium))
                .foregroundStyle((on ? palette.ink : palette.ink3).color)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(palette.segOn.color)
                            .modifier(ConditionalShadow(layers: palette.segShadow))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: A tela principal

    /// `max-width: 820px; gap: 20px`.
    private var mainPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                rolesSection
                connectionsSection
                if !loggedCLIs.isEmpty { cliStrip }
                automaticAnalysis
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Quem faz o quê

    private var rolesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(
                L10n.tr("Quem faz o quê"),
                note: L10n.tr("duas funções, uma IA em cada")
            )
            VStack(spacing: 0) {
                ForEach(Array(ConfigAIRole.allCases.enumerated()), id: \.element) { index, role in
                    roleRow(role, first: index == 0)
                }
            }
            .configCard(palette, radius: 14)
        }
    }

    /// `grid-template-columns: 34px minmax(0, 1fr) auto; padding: 14px 18px`.
    private func roleRow(_ role: ConfigAIRole, first: Bool) -> some View {
        let current = inventory.connection(for: role)
        return HStack(spacing: 14) {
            Image(systemName: role.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.accentInk.color)
                .frame(width: 34, height: 34)
                .background(
                    palette.accentSoft.color,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                    .font(theme.sans.font(size: 14.5, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Text(role.subtitle)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            roleSwitcher(role, current: current)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(palette.line.color)
                    .frame(height: Hairline.thickness(displayScale))
            }
        }
    }

    /// O botão que troca a IA de um papel **num clique**: ele abre o menu com
    /// as conexões que existem, e a última linha leva à folha de conectar.
    private func roleSwitcher(_ role: ConfigAIRole, current: ConfigAIConnection) -> some View {
        Menu {
            ForEach(inventory.options(for: role)) { option in
                Button {
                    assign(option, to: role)
                } label: {
                    Text(option.name)
                }
            }
            Divider()
            Button(L10n.tr("Conectar outra IA…")) { sheet = .choose }
        } label: {
            HStack(spacing: 9) {
                ConfigAIMonogram(
                    letter: current.monogram, hue: current.hue,
                    side: 22, radius: 7, fontSize: 11
                )
                Text(current.name)
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                    .lineLimit(1)
                Text(current.model)
                    .font(theme.mono.font(size: 11.5))
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.ink3.color)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(palette.btn2.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.tr("Trocar a IA de \(role.title)"))
    }

    /// Põe uma conexão num papel — e grava.
    ///
    /// Conversas é o único papel que aceita um agente, porque é o único que o
    /// agente realmente atende (`WorkspaceAgentAssistant` desvia `answer`).
    /// Escolher qualquer outra coisa para Conversas desliga o agente, senão a
    /// linha diria uma coisa e o roteador faria outra.
    private func assign(_ connection: ConfigAIConnection, to role: ConfigAIRole) {
        switch connection.kind {
        case .acpAgent:
            draft.agent.enabled = true
        case .a2aAgent:
            draft.a2a.enabled = true
        case .appleIntelligence:
            if role == .conversas { draft.agent.enabled = false }
            draft.provider = .foundationModels
        case .login(let kind):
            if role == .conversas { draft.agent.enabled = false }
            draft.provider = .providerOAuth
            draft.providerOAuth.kind = kind
            draft.providerOAuth.credentialID = kind.defaultCredentialID
        case .endpoint:
            if role == .conversas { draft.agent.enabled = false }
            draft.provider = .openAICompatible
        case .cli(let kind):
            if role == .conversas { draft.agent.enabled = false }
            draft.provider = .cli
            draft.cli.kind = kind
        }
        save()
    }

    // MARK: Conectadas

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(L10n.tr("Conectadas"), note: inventory.countLine())
            VStack(spacing: 0) {
                let list = inventory.connections()
                ForEach(Array(list.enumerated()), id: \.element.id) { index, connection in
                    connectionRow(connection, first: index == 0)
                }
                connectButton
            }
            .configCard(palette, radius: 14)
        }
    }

    /// `grid-template-columns: 34px minmax(0, 1fr) auto 14px; padding: 13px 18px`.
    private func connectionRow(_ connection: ConfigAIConnection, first: Bool) -> some View {
        let estado = connection.state.label(palette)
        return Button {
            open(connection)
        } label: {
            HStack(spacing: 14) {
                ConfigAIMonogram(letter: connection.monogram, hue: connection.hue)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(connection.name)
                            .font(theme.sans.font(size: 14.5, weight: .semibold))
                            .foregroundStyle(palette.ink.color)
                            .lineLimit(1)
                        ForEach(connection.roles, id: \.self) { role in
                            Text(role)
                                .font(theme.sans.font(size: 11, weight: .semibold))
                                .foregroundStyle(palette.accentInk.color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    palette.accentSoft.color,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                        }
                    }
                    Text(connection.detail)
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle(palette.ink3.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    Circle()
                        .fill(estado.color.color)
                        .frame(width: 7, height: 7)
                    Text(estado.text)
                        .font(theme.sans.font(size: 12.5, weight: .medium))
                        .foregroundStyle(estado.color.color)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink3.color)
                    .frame(width: 14)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(palette.line.color)
                    .frame(height: Hairline.thickness(displayScale))
            }
        }
    }

    /// A última linha do cartão: o convite, com a contagem real do catálogo.
    private var connectButton: some View {
        Button { sheet = .choose } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accentInk.color)
                    .frame(width: 34, height: 34)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                palette.line.color,
                                style: StrokeStyle(
                                    lineWidth: Hairline.thickness(displayScale), dash: [3, 3]
                                )
                            )
                    }
                Text(L10n.tr("Conectar outra IA"))
                    .font(theme.sans.font(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accentInk.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.tr("\(ConfigAICatalog.all.count) opções — no seu Mac, na sua conta, por chave ou por agente"))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
        }
    }

    /// Abrir uma conexão leva para onde ela se conserta: o formulário da chave,
    /// a página do Mac, a folha do login, os formulários de agente.
    private func open(_ connection: ConfigAIConnection) {
        switch connection.kind {
        case .appleIntelligence:
            page = .local
        case .endpoint:
            if connection.isLocal {
                page = .local
            } else {
                let preset = ConfigAICatalog.all.first {
                    $0.baseURL?.caseInsensitiveCompare(draft.openAICompatible.endpoint) == .orderedSame
                }
                page = .apiKey(presetID: preset?.id ?? "custom")
            }
        case .login(let kind):
            sheet = .login(kind)
        case .cli:
            sheet = .choose
        case .acpAgent, .a2aAgent:
            openAdvancedPanel()
        }
    }

    // MARK: Já logados neste Mac

    private var loggedCLIs: [AssistantCLIInstallation] {
        cliInstallations.filter { $0.isDetected }
    }

    /// O azulejo raso do desenho: o app só vê que o CLI está logado.
    private var cliStrip: some View {
        HStack(spacing: 16) {
            Text(L10n.tr("Já logados neste Mac"))
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.ink2.color)
                .fixedSize()
            HStack(spacing: 14) {
                ForEach(loggedCLIs) { installation in
                    let state = cliAuthentication[installation.kind] ?? .unknown
                    HStack(spacing: 6) {
                        Circle()
                            .fill(cliDotColor(state).color)
                            .frame(width: 6, height: 6)
                        Text(installation.kind.rawValue)
                            .font(theme.mono.font(size: 12.5))
                            .foregroundStyle(palette.ink2.color)
                        Text(cliStateLabel(state))
                            .font(theme.sans.font(size: 12.5))
                            .foregroundStyle(palette.ink3.color)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.tr("o app só vê que estão logados — nunca lê os tokens deles"))
                .font(theme.sans.font(size: 12))
                .foregroundStyle(palette.ink3.color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .configTile(palette, radius: 14)
    }

    private func cliDotColor(_ state: AssistantCLIAuthenticationState) -> TokenColor {
        switch state {
        case .authenticated: palette.green
        case .unauthenticated: palette.orange
        case .unavailable: palette.red
        case .unknown: palette.ink3
        }
    }

    private func cliStateLabel(_ state: AssistantCLIAuthenticationState) -> String {
        switch state {
        case .authenticated: L10n.tr("logado")
        case .unauthenticated: L10n.tr("sem sessão")
        case .unavailable: L10n.tr("não respondeu")
        case .unknown: L10n.tr("conferindo")
        }
    }

    // MARK: Analisar e-mails novos sozinha

    /// O interruptor do opt-in, com a frase que nomeia **para onde** o texto
    /// vai. A frase vem de `AssistantDestination`, que é a única fonte dessa
    /// promessa no app.
    private var automaticAnalysis: some View {
        let destino = AssistantDestination(settings: draft)
        let ligada = draft.automaticAnalysis == .configuredProvider
        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Analisar e-mails novos sozinha"))
                    .font(theme.sans.font(size: 14.5, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Text(automaticAnalysisDetail(ligada: ligada, destino: destino))
                    .font(theme.sans.font(size: 12.5))
                    .lineSpacing(12.5 * 0.45)
                    .foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ConfigSwitch(
                isOn: Binding(
                    get: { ligada },
                    set: { on in
                        draft.automaticAnalysis = on ? .configuredProvider : .onDeviceOnly
                        draft.automaticAnalysisTouchedByUser = true
                        save()
                    }
                ),
                label: L10n.tr("Analisar e-mails novos sozinha")
            )
            .disabled(destino.isLocal)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity)
        .configCard(palette, radius: 14)
    }

    private func automaticAnalysisDetail(
        ligada: Bool, destino: AssistantDestination
    ) -> String {
        if destino.isLocal {
            return L10n.tr("A IA escolhida roda neste Mac, então a análise nunca sai daqui — nem assunto, nem texto, nem anexo.")
        }
        if ligada {
            return L10n.tr("Ligada. O assunto e o texto de cada e-mail novo saem deste Mac para \(destino.label). Anexos e endereços não saem.")
        }
        return L10n.tr("Desligada. Se você ligar, o assunto e o texto de cada e-mail novo saem deste Mac para \(destino.label). Anexos e endereços não saem.")
    }

    // MARK: Peças

    /// `h2` de 15/600 com a nota de 13 ao lado, na mesma linha de base.
    private func sectionTitle(_ text: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(text)
                .font(theme.sans.font(size: 15, weight: .semibold))
                .tracking(-0.01 * 15)
                .foregroundStyle(palette.ink.color)
            Text(note)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(palette.ink3.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
