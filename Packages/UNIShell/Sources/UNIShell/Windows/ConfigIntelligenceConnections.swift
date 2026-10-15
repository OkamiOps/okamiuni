import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Em que pé uma conexão está. São três estados porque são três coisas
/// diferentes: a que está ligada agora, a que está aqui e pode ser usada a
/// qualquer momento, e a que pede um minuto da pessoa.
enum ConfigAIConnectionState: Hashable {
    case connected
    case available
    case needsYou

    func label(_ palette: ConfigPalette) -> (text: String, color: TokenColor) {
        switch self {
        case .connected: (L10n.tr("Conectada"), palette.green)
        case .available: (L10n.tr("Disponível"), palette.ink3)
        case .needsYou: (L10n.tr("Pede atenção"), palette.orange)
        }
    }
}

/// Uma conexão que **existe de verdade** neste Mac agora.
///
/// A lista não é um catálogo: ela é derivada das preferências gravadas, da
/// sessão OAuth publicada pelo coordenador e da varredura de CLIs. Uma linha
/// aqui significa "isto responde se você pedir" — nunca "isto poderia ser
/// configurado". O catálogo do que *poderia* é a folha "Conectar uma IA".
struct ConfigAIConnection: Identifiable, Hashable {
    enum Kind: Hashable {
        case appleIntelligence
        case login(AssistantProviderOAuthKind)
        /// Um endpoint compatível com OpenAI — chave de API, LiteLLM ou um
        /// servidor local.
        case endpoint
        case cli(AssistantCLIKind)
        case acpAgent
        case a2aAgent
    }

    let id: String
    let kind: Kind
    let name: String
    let detail: String
    /// O que o botão do papel mostra em fonte mono: o modelo escolhido.
    let model: String
    let monogram: String
    let hue: Double
    let state: ConfigAIConnectionState
    /// Os papéis que esta conexão serve agora. É a etiqueta ao lado do nome.
    var roles: [String]

    /// Esta conexão roda sem sair do Mac?
    var isLocal: Bool {
        switch kind {
        case .appleIntelligence: true
        case .endpoint: LocalModelCatalog.loopbackHost(of: endpointForLocality ?? "") != nil
        default: false
        }
    }

    /// Só para `isLocal`: o endereço que decide se o endpoint é de loopback.
    var endpointForLocality: String?
}

/// Os dois papéis que o desenho põe no cartão "Quem faz o quê".
///
/// Eles não são rótulos: cada um corresponde a um caminho real do roteador.
/// `escrita` é `transform` e a análise de mensagem; `conversas` é `answer`, que
/// é o caminho que o agente ACP intercepta quando está ligado (ver
/// `WorkspaceAgentAssistant`). É por isso que só estes dois existem aqui —
/// inventar um terceiro papel sem um caminho que o honre seria uma etiqueta
/// bonita mentindo sobre para onde o texto vai.
enum ConfigAIRole: String, CaseIterable, Identifiable, Hashable {
    case escrita
    case conversas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .escrita: L10n.tr("Escrita e análise")
        case .conversas: L10n.tr("Conversas")
        }
    }

    var subtitle: String {
        switch self {
        case .escrita: L10n.tr("resumos, rascunhos, tarefas e datas tiradas do e-mail")
        case .conversas: L10n.tr("a Mesa e o assistente, quando você pergunta alguma coisa")
        }
    }

    var symbol: String {
        switch self {
        case .escrita: "pencil"
        case .conversas: "bubble.left"
        }
    }

    /// A etiqueta curta que aparece ao lado do nome da conexão na lista.
    var badge: String {
        switch self {
        case .escrita: L10n.tr("Escrita")
        case .conversas: L10n.tr("Conversas")
        }
    }
}

/// Monta a lista de conexões a partir dos fatos, e só dos fatos.
struct ConfigAIInventory {
    let draft: AssistantSettings
    let oauthStatus: AssistantProviderOAuthStatus
    let models: [AssistantProviderModel]
    let cliInstallations: [AssistantCLIInstallation]
    let cliAuthentication: [AssistantCLIKind: AssistantCLIAuthenticationState]
    let apiKeyPresent: Bool

    /// A conexão que serve um papel agora.
    ///
    /// `escrita` é sempre o provedor configurado. `conversas` é o mesmo
    /// provedor, **exceto** quando o agente ACP está ligado — aí as perguntas
    /// passam por ele de verdade, e é isso que a linha diz.
    func connection(for role: ConfigAIRole) -> ConfigAIConnection {
        if role == .conversas, draft.agent.enabled {
            return acpConnection(state: .connected)
        }
        return configuredConnection()
    }

    /// A conexão do provedor ativo, do jeito que ele está gravado.
    func configuredConnection() -> ConfigAIConnection {
        switch draft.provider {
        case .foundationModels:
            return appleIntelligence(state: .connected)
        case .providerOAuth:
            return login(draft.providerOAuth.kind, state: loginState)
        case .openAICompatible:
            return endpoint(state: endpointState)
        case .cli:
            return cli(draft.cli.kind, state: cliState(draft.cli.kind))
        }
    }

    /// Tudo o que responde hoje, na ordem do desenho: o que está em uso
    /// primeiro, o que está aqui depois.
    func connections() -> [ConfigAIConnection] {
        var list: [ConfigAIConnection] = []
        var roles: [ConfigAIConnection.Kind: [String]] = [:]
        for role in ConfigAIRole.allCases {
            roles[connection(for: role).kind, default: []].append(role.badge)
        }

        func append(_ connection: ConfigAIConnection) {
            guard !list.contains(where: { $0.kind == connection.kind }) else { return }
            var copy = connection
            copy.roles = roles[connection.kind] ?? []
            list.append(copy)
        }

        // Em uso primeiro — é o que a pessoa veio conferir.
        for role in ConfigAIRole.allCases { append(connection(for: role)) }

        // Apple Intelligence está sempre aqui: é o motor do próprio Mac, e
        // listá-lo só quando escolhido esconderia a única rota que não precisa
        // de conta nem de chave.
        append(appleIntelligence(state: .available))

        // Um endpoint gravado continua existindo mesmo quando o provedor ativo
        // é outro: a pessoa colou aquela chave, e ela não sumiu.
        if !draft.openAICompatible.endpoint.isEmpty {
            append(endpoint(state: endpointState == .needsYou ? .needsYou : .available))
        }

        // A assinatura que já tem sessão viva, ainda que não esteja servindo
        // papel nenhum.
        if oauthStatus == .signedIn {
            append(login(draft.providerOAuth.kind, state: .available))
        }

        // Cada CLI encontrado e logado nesta máquina.
        for installation in cliInstallations where installation.isDetected {
            guard cliAuthentication[installation.kind] == .authenticated else { continue }
            append(cli(installation.kind, state: .available))
        }

        if draft.agent.enabled { append(acpConnection(state: .available)) }
        if draft.a2a.enabled, !draft.a2a.peers.isEmpty { append(a2aConnection()) }

        return list
    }

    /// As opções que o menu de um papel oferece: as conexões que podem servir
    /// aquele papel. O agente só aparece em Conversas, porque é o único papel
    /// que ele realmente intercepta.
    func options(for role: ConfigAIRole) -> [ConfigAIConnection] {
        connections().filter { connection in
            switch connection.kind {
            case .acpAgent, .a2aAgent: role == .conversas
            default: true
            }
        }
    }

    /// A frase que o desenho põe ao lado de "Conectadas".
    func countLine() -> String {
        let total = connections().count
        return total == 1
            ? L10n.tr("uma, e ela não roda sem você pedir")
            : L10n.tr("\(total), e nenhuma roda sem você pedir")
    }

    // MARK: Cada conexão

    private func appleIntelligence(state: ConfigAIConnectionState) -> ConfigAIConnection {
        ConfigAIConnection(
            id: "apple-intelligence",
            kind: .appleIntelligence,
            name: L10n.tr("Apple Intelligence"),
            detail: L10n.tr("Neste Mac · sem conta e sem chave · nada sai daqui"),
            model: L10n.tr("no chip"),
            monogram: "A",
            hue: 268,
            state: state,
            roles: [],
            endpointForLocality: nil
        )
    }

    private func login(
        _ kind: AssistantProviderOAuthKind, state: ConfigAIConnectionState
    ) -> ConfigAIConnection {
        let modelCount = models.count
        let conta = switch kind {
        case .codex: L10n.tr("Sua conta ChatGPT, por código no navegador")
        case .xAI: L10n.tr("Sua conta xAI, por código no navegador")
        }
        let detail = modelCount > 0
            ? "\(conta) · \(L10n.tr("\(modelCount) modelos"))"
            : conta
        return ConfigAIConnection(
            id: "login-\(kind.rawValue)",
            kind: .login(kind),
            name: kind == .codex ? L10n.tr("ChatGPT · Codex") : L10n.tr("Grok · xAI"),
            detail: detail,
            model: draft.providerOAuth.model.isEmpty
                ? L10n.tr("sem modelo")
                : draft.providerOAuth.model,
            monogram: kind == .codex ? "C" : "G",
            hue: kind == .codex ? 165 : 222,
            state: state,
            roles: [],
            endpointForLocality: nil
        )
    }

    private func endpoint(state: ConfigAIConnectionState) -> ConfigAIConnection {
        let configuration = draft.openAICompatible
        let host = AssistantDestination.host(of: configuration.endpoint)
        let preset = ConfigAICatalog.all.first {
            $0.baseURL?.caseInsensitiveCompare(configuration.endpoint) == .orderedSame
        }
        let name = preset?.name ?? host ?? L10n.tr("Endereço seu")
        let detalhe = switch configuration.authenticationMode {
        case .apiKey:
            apiKeyPresent
                ? L10n.tr("Chave de API no Keychain deste Mac")
                : L10n.tr("Falta a chave de API")
        case .litellmOAuthPKCE:
            L10n.tr("LiteLLM, por OAuth no navegador")
        case .none:
            L10n.tr("Sem autenticação")
        }
        return ConfigAIConnection(
            id: "endpoint",
            kind: .endpoint,
            name: name,
            detail: "\(detalhe) · \(host ?? L10n.tr("sem endereço"))",
            model: configuration.model.isEmpty ? L10n.tr("sem modelo") : configuration.model,
            monogram: preset?.monogram ?? "E",
            hue: preset?.hue ?? 210,
            state: state,
            roles: [],
            endpointForLocality: configuration.endpoint
        )
    }

    private func cli(
        _ kind: AssistantCLIKind, state: ConfigAIConnectionState
    ) -> ConfigAIConnection {
        ConfigAIConnection(
            id: "cli-\(kind.rawValue)",
            kind: .cli(kind),
            name: L10n.tr("\(kind.displayName) · CLI"),
            detail: L10n.tr("Já logado neste Mac · o app nunca lê o token dele"),
            model: kind.rawValue,
            monogram: String(kind.displayName.prefix(1)),
            hue: cliHue(kind),
            state: state,
            roles: [],
            endpointForLocality: nil
        )
    }

    private func cliHue(_ kind: AssistantCLIKind) -> Double {
        switch kind {
        case .codex: 165
        case .claude: 24
        case .openCode: 120
        }
    }

    private func acpConnection(state: ConfigAIConnectionState) -> ConfigAIConnection {
        ConfigAIConnection(
            id: "agent-acp",
            kind: .acpAgent,
            name: draft.agent.destination.label,
            detail: L10n.tr("Agente ACP, numa pasta que você autorizou"),
            model: L10n.tr("agente"),
            monogram: "P",
            hue: 285,
            state: state,
            roles: [],
            endpointForLocality: nil
        )
    }

    private func a2aConnection() -> ConfigAIConnection {
        ConfigAIConnection(
            id: "agent-a2a",
            kind: .a2aAgent,
            name: L10n.tr("Agentes A2A"),
            detail: draft.a2a.peers.count == 1
                ? L10n.tr("1 agente pelo Agent Card dele")
                : L10n.tr("\(draft.a2a.peers.count) agentes pelo Agent Card deles"),
            model: L10n.tr("delegação"),
            monogram: "2",
            hue: 320,
            state: .available,
            roles: [],
            endpointForLocality: nil
        )
    }

    // MARK: Os estados

    private var loginState: ConfigAIConnectionState {
        switch oauthStatus {
        case .signedIn: .connected
        case .failed, .signedOut: .needsYou
        case .awaitingDeviceCode: .needsYou
        case .idle, .checking: .available
        }
    }

    private var endpointState: ConfigAIConnectionState {
        guard (try? draft.openAICompatible.validated()) != nil else { return .needsYou }
        if draft.openAICompatible.authenticationMode == .apiKey, !apiKeyPresent {
            return .needsYou
        }
        return .connected
    }

    private func cliState(_ kind: AssistantCLIKind) -> ConfigAIConnectionState {
        switch cliAuthentication[kind] {
        case .authenticated: .connected
        case .unauthenticated, .unavailable: .needsYou
        case .unknown, nil: .available
        }
    }
}
