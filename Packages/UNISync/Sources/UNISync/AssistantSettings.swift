import Foundation

/// O motor que atende perguntas e transformações de texto no OkamiUNI.
///
/// A configuração do provedor não carrega segredo: a chave correspondente vive
/// no `AssistantCredentialStore`, identificada por `credentialID`.
public enum AssistantProvider: String, Codable, Sendable, Hashable {
    case foundationModels
    case openAICompatible
    /// Login direto da assinatura do provedor, sem depender de uma chave de
    /// API, de um proxy LiteLLM ou de um CLI instalado neste Mac.
    case providerOAuth
    /// Executa um dos CLIs explicitamente permitidos em um processo isolado.
    /// A sessão (OAuth ou device auth) continua pertencendo ao próprio CLI;
    /// o OkamiUNI nunca importa nem serializa seus tokens.
    case cli
}

/// Como o endpoint OpenAI-compatible recebe autenticação. O fluxo PKCE não é
/// um bearer colado pela pessoa: o token é obtido por um provedor específico
/// do LiteLLM, fora desta configuração persistida.
public enum OpenAICompatibleAuthenticationMode: String, Codable, Sendable, Hashable {
    case none
    case apiKey
    case litellmOAuthPKCE
}

/// Falhas de configuração que a interface pode explicar sem revelar chaves ou
/// conteúdo de e-mail.
public enum AssistantSettingsError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidEndpoint
    case endpointMustUseHTTPS
    case endpointContainsCredentials
    case missingModel
    case missingCredentialID
    case additionalInstructionsTooLong

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Esta configuração de IA foi criada por uma versão mais nova do OkamiUNI (schema \(version))."
        case .invalidEndpoint:
            "Informe um endpoint OpenAI-compatible válido."
        case .endpointMustUseHTTPS:
            "O endpoint de IA deve usar HTTPS; HTTP é aceito somente em localhost."
        case .endpointContainsCredentials:
            "Não coloque usuário, senha ou chave na URL do endpoint."
        case .missingModel:
            "Informe o modelo que o endpoint deve usar."
        case .missingCredentialID:
            "A referência da credencial de IA está vazia."
        case .additionalInstructionsTooLong:
            "As instruções adicionais do assistente são longas demais."
        }
    }
}

/// A parte não secreta de um endpoint compatível com OpenAI, como um proxy
/// LiteLLM. A pessoa pode informar tanto a base do proxy quanto a rota completa
/// de `chat/completions`; `chatCompletionsURL()` normaliza os dois casos.
public struct OpenAICompatibleAssistantConfiguration: Codable, Sendable, Hashable {
    public static let defaultCredentialID = "openai-compatible-default"

    public var endpoint: String
    public var model: String
    public var credentialID: String
    public var authenticationMode: OpenAICompatibleAuthenticationMode

    public init(
        endpoint: String = "",
        model: String = "",
        credentialID: String = Self.defaultCredentialID,
        authenticationMode: OpenAICompatibleAuthenticationMode = .apiKey
    ) {
        self.endpoint = endpoint
        self.model = model
        self.credentialID = credentialID
        self.authenticationMode = authenticationMode
    }

    /// Retorna uma cópia limpa e validada. Não valida a chave: ela nunca vem
    /// junto desta estrutura e só é lida do Keychain quando uma chamada começa.
    public func validated() throws -> OpenAICompatibleAssistantConfiguration {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialID = credentialID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !model.isEmpty, model.count <= 256 else {
            throw AssistantSettingsError.missingModel
        }
        if authenticationMode != .none {
            guard !credentialID.isEmpty, credentialID.count <= 128 else {
                throw AssistantSettingsError.missingCredentialID
            }
        }
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            throw AssistantSettingsError.invalidEndpoint
        }

        if components.user != nil || components.password != nil {
            throw AssistantSettingsError.endpointContainsCredentials
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw AssistantSettingsError.endpointMustUseHTTPS
        }
        return .init(
            endpoint: endpoint,
            model: model,
            credentialID: credentialID,
            authenticationMode: authenticationMode
        )
    }

    /// A URL exata do POST. LiteLLM e outros gateways aceitam uma base como
    /// `https://proxy.example` ou `https://proxy.example/v1`; aceitar a rota
    /// inteira torna a configuração interoperável sem duplicar `/v1`.
    public func chatCompletionsURL() throws -> URL {
        let configuration = try validated()
        guard var components = URLComponents(string: configuration.endpoint) else {
            throw AssistantSettingsError.invalidEndpoint
        }

        var path = components.path
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            components.path = path
        } else if path.hasSuffix("/v1") {
            components.path = path + "/chat/completions"
        } else {
            components.path = (path == "/" ? "" : path) + "/v1/chat/completions"
        }

        guard let url = components.url else { throw AssistantSettingsError.invalidEndpoint }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case model
        case credentialID
        case authenticationMode
    }

    /// O modo foi adicionado depois do primeiro documento de preferências;
    /// configurações existentes continuam sendo chaves de API até a pessoa
    /// escolher explicitamente outra modalidade.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        credentialID = try values.decodeIfPresent(String.self, forKey: .credentialID)
            ?? Self.defaultCredentialID
        authenticationMode = try values.decodeIfPresent(
            OpenAICompatibleAuthenticationMode.self,
            forKey: .authenticationMode
        ) ?? .apiKey
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(endpoint, forKey: .endpoint)
        try values.encode(model, forKey: .model)
        try values.encode(credentialID, forKey: .credentialID)
        try values.encode(authenticationMode, forKey: .authenticationMode)
    }
}

/// Preferência não secreta para o transporte que delega a autenticação a um
/// CLI já configurado pela pessoa. Não há caminho, argumento livre, modelo ou
/// token configurável aqui: o roteador constrói uma invocação fixa a partir de
/// `kind` e da descoberta por allowlist.
public struct AssistantCLIConfiguration: Codable, Sendable, Hashable {
    public var kind: AssistantCLIKind

    public init(kind: AssistantCLIKind = .codex) {
        self.kind = kind
    }
}

/// Provedores que publicam uma sessão OAuth de assinatura para uso no
/// assistente. Esta opção é propositalmente separada de `openAICompatible`:
/// um bearer obtido do ChatGPT ou da xAI nunca pode ser enviado a um endpoint
/// arbitrário informado pela pessoa.
public enum AssistantProviderOAuthKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Assinatura ChatGPT que habilita o Codex. Usa o backend Codex do ChatGPT.
    case codex
    /// Assinatura Grok/xAI elegível. O contrato ainda pode mudar pelo provedor.
    case xAI

    public var defaultCredentialID: String {
        switch self {
        case .codex: "provider-oauth-codex"
        case .xAI: "provider-oauth-xai"
        }
    }
}

/// Preferência não secreta da rota OAuth direta. Access e refresh token ficam
/// exclusivamente no Keychain, vinculados a `credentialID` e ao provedor.
public struct AssistantProviderOAuthConfiguration: Codable, Sendable, Hashable {
    public var kind: AssistantProviderOAuthKind
    public var model: String
    public var credentialID: String

    public init(
        kind: AssistantProviderOAuthKind = .codex,
        model: String? = nil,
        credentialID: String? = nil
    ) {
        self.kind = kind
        // O modelo pertence ao catálogo vivo da conta autenticada. Um valor
        // padrão compilado no app fica obsoleto e pode até apontar para um
        // modelo que a assinatura atual não oferece.
        self.model = model ?? ""
        self.credentialID = credentialID ?? kind.defaultCredentialID
    }

    public func validated() throws -> AssistantProviderOAuthConfiguration {
        let authorization = try validatedForAuthorization()
        let model = authorization.model
        guard !model.isEmpty, model.count <= 256 else {
            throw AssistantSettingsError.missingModel
        }
        return authorization
    }

    /// Login, logout e carregamento do catálogo não dependem de um modelo já
    /// escolhido. Separar esta validação permite autenticar primeiro e só
    /// então preencher o seletor com a lista real da conta.
    public func validatedForAuthorization() throws -> AssistantProviderOAuthConfiguration {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialID = credentialID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.count <= 256 else {
            throw AssistantSettingsError.missingModel
        }
        guard !credentialID.isEmpty, credentialID.count <= 128 else {
            throw AssistantSettingsError.missingCredentialID
        }
        return .init(kind: kind, model: model, credentialID: credentialID)
    }
}

// MARK: - Comportamento do assistente

/// Preferências humanas de escrita. Elas viram instruções secundárias do
/// prompt; a política de segurança do app continua fixa e vem antes delas.
public enum AssistantTonePreference: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case natural
    case direct
    case warm
    case formal
    case technical

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .natural: "Natural"
        case .direct: "Direto"
        case .warm: "Cordial"
        case .formal: "Formal"
        case .technical: "Técnico"
        }
    }

    var promptInstruction: String {
        switch self {
        case .natural: "Use um tom natural, profissional e sem frases artificiais."
        case .direct: "Vá direto ao ponto e corte introduções, desculpas e repetições desnecessárias."
        case .warm: "Use um tom cordial, próximo e respeitoso, sem exagerar na informalidade."
        case .formal: "Use linguagem formal, precisa e apropriada para comunicação institucional."
        case .technical: "Use vocabulário técnico preciso e preserve termos, siglas e detalhes relevantes."
        }
    }
}

public enum AssistantDetailPreference: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case adaptive
    case concise
    case balanced
    case detailed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .adaptive: "Adaptar ao pedido"
        case .concise: "Curto"
        case .balanced: "Equilibrado"
        case .detailed: "Detalhado"
        }
    }

    var promptInstruction: String {
        switch self {
        case .adaptive: "Ajuste o nível de detalhe à complexidade e à intenção do pedido."
        case .concise: "Responda de forma curta; mantenha somente fatos e ações essenciais."
        case .balanced: "Use detalhe suficiente para ser útil, com parágrafos curtos e sem prolixidade."
        case .detailed: "Explique contexto, implicações, riscos e próximos passos quando forem relevantes."
        }
    }
}

public enum AssistantLanguagePreference: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case followConversation
    case portugueseBrazil
    case english
    case spanish
    case german

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .followConversation: "Idioma da conversa"
        case .portugueseBrazil: "Português (Brasil)"
        case .english: "English"
        case .spanish: "Español"
        case .german: "Deutsch"
        }
    }

    var promptInstruction: String {
        switch self {
        case .followConversation: "Responda no idioma usado pela pessoa ou pelo texto que está sendo respondido."
        case .portugueseBrazil: "Responda em português do Brasil."
        case .english: "Respond in English."
        case .spanish: "Responde en español."
        case .german: "Antworte auf Deutsch."
        }
    }
}

public enum AssistantFormatPreference: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case adaptive
    case paragraphs
    case bullets
    case executive

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .adaptive: "Automático"
        case .paragraphs: "Parágrafos"
        case .bullets: "Tópicos"
        case .executive: "Resumo executivo"
        }
    }

    var promptInstruction: String {
        switch self {
        case .adaptive: "Escolha a estrutura mais legível para o conteúdo."
        case .paragraphs: "Prefira parágrafos curtos e texto corrido; use listas somente quando indispensáveis."
        case .bullets: "Organize vários pontos em listas curtas, com uma ideia acionável por item."
        case .executive: "Comece pela conclusão e organize depois decisões, riscos, responsáveis e próximos passos."
        }
    }
}

/// Ajustes que valem para todos os motores (local, API, assinatura ou CLI).
/// Instruções por finalidade evitam obrigar a pessoa a usar a mesma voz para
/// analisar uma caixa e para redigir uma resposta ao cliente.
public struct AssistantBehaviorPreferences: Codable, Sendable, Hashable {
    public var tone: AssistantTonePreference
    public var detail: AssistantDetailPreference
    public var language: AssistantLanguagePreference
    public var format: AssistantFormatPreference
    public var suggestNextSteps: Bool
    public var questionsInstructions: String
    public var writingInstructions: String

    public init(
        tone: AssistantTonePreference = .natural,
        detail: AssistantDetailPreference = .adaptive,
        language: AssistantLanguagePreference = .portugueseBrazil,
        format: AssistantFormatPreference = .adaptive,
        suggestNextSteps: Bool = true,
        questionsInstructions: String = "",
        writingInstructions: String = ""
    ) {
        self.tone = tone
        self.detail = detail
        self.language = language
        self.format = format
        self.suggestNextSteps = suggestNextSteps
        self.questionsInstructions = questionsInstructions
        self.writingInstructions = writingInstructions
    }

    public static let `default` = AssistantBehaviorPreferences()

    func validated() throws -> AssistantBehaviorPreferences {
        var value = self
        value.questionsInstructions = questionsInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        value.writingInstructions = writingInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.questionsInstructions.count <= AssistantSettings.maximumPurposeInstructionsCharacters,
              value.writingInstructions.count <= AssistantSettings.maximumPurposeInstructionsCharacters
        else {
            throw AssistantSettingsError.additionalInstructionsTooLong
        }
        return value
    }

    func generatedInstructions() -> String {
        var instructions: [String] = []
        if tone != .natural { instructions.append(tone.promptInstruction) }
        if detail != .adaptive { instructions.append(detail.promptInstruction) }
        // Sem condição: enquanto pt-BR era o silêncio, a preferência da pessoa
        // perdia para a linha fixa do prompt, que dizia português sempre.
        instructions.append(language.promptInstruction)
        if format != .adaptive { instructions.append(format.promptInstruction) }
        if !suggestNextSteps {
            instructions.append("Não acrescente próximos passos que não tenham sido pedidos.")
        }
        return instructions.joined(separator: "\n")
    }
}

/// Para onde vai a análise que roda **sem** a pessoa pedir.
///
/// Separada do provedor interativo de propósito: escolher Grok para
/// responder perguntas não pode significar mandar cada mensagem recebida
/// para a xAI em segundo plano.
public enum AutomaticAnalysisRoute: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case onDeviceOnly
    case configuredProvider

    public var id: String { rawValue }

    /// O padrão segue o provedor ativo.
    ///
    /// Ruling 2026-09-03: conectar um provedor remoto de propósito **é** o
    /// consentimento. Pedir de novo, num interruptor separado, é burocracia —
    /// e deixava a tela dizendo "precisa da análise automática · Ativar" para
    /// quem já tinha ligado o Codex. O interruptor continua existindo, agora
    /// para restringir a este Mac.
    public static func `default`(for provider: AssistantProvider) -> AutomaticAnalysisRoute {
        provider == .foundationModels ? .onDeviceOnly : .configuredProvider
    }
}

/// Preferências persistidas da IA. É um único documento Codable para que uma
/// troca de provedor, endpoint e instruções seja atômica para quem o lê.
public struct AssistantSettings: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 5
    public static let maximumAdditionalInstructionsCharacters = 6_000
    public static let maximumPurposeInstructionsCharacters = 3_000

    public var schemaVersion: Int
    public var provider: AssistantProvider
    public var openAICompatible: OpenAICompatibleAssistantConfiguration
    public var providerOAuth: AssistantProviderOAuthConfiguration
    public var cli: AssistantCLIConfiguration
    public var behavior: AssistantBehaviorPreferences
    public var additionalInstructions: String
    /// A rota da análise automática. Nunca herda o provedor interativo.
    public var automaticAnalysis: AutomaticAnalysisRoute
    /// O instante em que a pessoa ligou o opt-in.
    ///
    /// O consentimento é sobre "mensagens novas", e é este carimbo que o
    /// torna verdade: sem ele, ligar o toggle mandaria a caixa inteira já
    /// guardada para o provedor. `nil` sempre que a rota é `onDeviceOnly`.
    public var automaticAnalysisSince: Date?
    /// A pessoa já mexeu no interruptor da análise automática?
    ///
    /// Enquanto for `false`, a rota é derivada do provedor ativo; quem
    /// escolheu à mão nunca é sobrescrito por um padrão novo.
    public var automaticAnalysisTouchedByUser: Bool

    /// Quanto do acervo a migração aceita como "novo".
    ///
    /// Ligar a rota com `since` em `nil` mandaria a caixa inteira já guardada
    /// ao provedor de uma vez. O acervo tem porta própria — "Analisar o
    /// acervo", com contagem e confirmação —, e esta janela curta só evita que
    /// o dashboard nasça vazio no dia da atualização.
    public static let migrationRetroactiveWindow: TimeInterval = 7 * 24 * 60 * 60

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        provider: AssistantProvider = .foundationModels,
        openAICompatible: OpenAICompatibleAssistantConfiguration = .init(),
        providerOAuth: AssistantProviderOAuthConfiguration = .init(),
        cli: AssistantCLIConfiguration = .init(),
        behavior: AssistantBehaviorPreferences = .default,
        additionalInstructions: String = "",
        automaticAnalysis: AutomaticAnalysisRoute? = nil,
        automaticAnalysisSince: Date? = nil,
        automaticAnalysisTouchedByUser: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.openAICompatible = openAICompatible
        self.providerOAuth = providerOAuth
        self.cli = cli
        self.behavior = behavior
        self.additionalInstructions = additionalInstructions
        self.automaticAnalysis = automaticAnalysis ?? .default(for: provider)
        self.automaticAnalysisSince = automaticAnalysisSince
        self.automaticAnalysisTouchedByUser = automaticAnalysisTouchedByUser
    }

    public static let `default` = AssistantSettings()

    /// Migra versões que este binário conhece e valida o resultado antes de ele
    /// entrar no cache do app. Por enquanto v0 representa o arquivo sem versão
    /// explícita da primeira prévia desta infraestrutura.
    public func migrated(now: Date = Date()) throws -> AssistantSettings {
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw AssistantSettingsError.unsupportedSchemaVersion(schemaVersion)
        }

        var migrated = self
        migrated.schemaVersion = Self.currentSchemaVersion
        migrated.additionalInstructions = additionalInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        migrated.behavior = try behavior.validated()
        guard migrated.additionalInstructions.count <= Self.maximumAdditionalInstructionsCharacters else {
            throw AssistantSettingsError.additionalInstructionsTooLong
        }
        if migrated.provider == .openAICompatible {
            migrated.openAICompatible = try openAICompatible.validated()
        }
        if migrated.provider == .providerOAuth {
            migrated.providerOAuth = try providerOAuth.validated()
        }
        // Ruling 2026-09-03: quem nunca mexeu no interruptor segue o padrão do
        // provedor. É isto que migra quem já tinha o Codex conectado e ainda
        // via "Ativar" na tela — e quem escolheu à mão fica exatamente onde
        // escolheu ficar.
        if !migrated.automaticAnalysisTouchedByUser {
            let padrao = AutomaticAnalysisRoute.default(for: migrated.provider)
            if padrao == .configuredProvider, migrated.automaticAnalysis == .onDeviceOnly {
                migrated.automaticAnalysisSince = now - Self.migrationRetroactiveWindow
            }
            migrated.automaticAnalysis = padrao
        }

        // O carimbo do opt-in nasce aqui, no mesmo save que liga a rota, e
        // morre quando ela é desligada: religar depois vale a partir do novo
        // instante, nunca do antigo.
        switch migrated.automaticAnalysis {
        case .onDeviceOnly:
            migrated.automaticAnalysisSince = nil
        case .configuredProvider:
            // `migrated`, e não `self`: a janela retroativa da migração acima
            // é um carimbo já escrito, e relê-lo do original o apagaria.
            migrated.automaticAnalysisSince = migrated.automaticAnalysisSince ?? now
        }
        return migrated
    }

    /// Preferências efetivas para uma chamada. A camada fixa de segurança é
    /// montada depois pelo adaptador; aqui entram apenas escolhas da pessoa.
    public func configuredInstructions(for kind: AssistantPromptKind) -> String {
        let purpose = switch kind {
        case .questions: behavior.questionsInstructions
        case .writing: behavior.writingInstructions
        }
        return [
            behavior.generatedInstructions(),
            additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines),
            purpose.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case provider
        case openAICompatible
        case providerOAuth
        case cli
        case behavior
        case additionalInstructions
        case automaticAnalysis
        case automaticAnalysisSince
        case automaticAnalysisTouchedByUser
    }

    /// `cli` e `authenticationMode` foram acrescentados depois do primeiro
    /// documento persistido. Decodificar ambos como opcionais mantém uma
    /// preferência v1 existente utilizável e a migração a regrava de forma
    /// atômica como v2, sem nunca tocar no Keychain.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        provider = try values.decodeIfPresent(AssistantProvider.self, forKey: .provider) ?? .foundationModels
        openAICompatible = try values.decodeIfPresent(
            OpenAICompatibleAssistantConfiguration.self,
            forKey: .openAICompatible
        ) ?? .init()
        providerOAuth = try values.decodeIfPresent(
            AssistantProviderOAuthConfiguration.self,
            forKey: .providerOAuth
        ) ?? .init()
        cli = try values.decodeIfPresent(AssistantCLIConfiguration.self, forKey: .cli) ?? .init()
        behavior = try values.decodeIfPresent(
            AssistantBehaviorPreferences.self,
            forKey: .behavior
        ) ?? .default
        additionalInstructions = try values.decodeIfPresent(String.self, forKey: .additionalInstructions) ?? ""
        // Documento sem a rota gravada nasce no padrão do provedor; a decisão
        // de quem já mexeu no interruptor vem do campo ao lado.
        automaticAnalysis = try values.decodeIfPresent(
            AutomaticAnalysisRoute.self, forKey: .automaticAnalysis
        ) ?? .default(for: provider)
        // Documento anterior a esta versão não registrava o toque. `false` é o
        // que faz a migração da rota valer uma vez para quem nunca escolheu.
        automaticAnalysisTouchedByUser = try values.decodeIfPresent(
            Bool.self, forKey: .automaticAnalysisTouchedByUser
        ) ?? false
        // Decodificação tolerante: o esquema continua sendo o v5. Um documento
        // v5 do binário anterior não tinha o carimbo, e `migrated()` o preenche
        // com o instante da carga — conservador, porque o histórico já guardado
        // fica de fora da rota remota.
        automaticAnalysisSince = try values.decodeIfPresent(
            Date.self, forKey: .automaticAnalysisSince
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(provider, forKey: .provider)
        try values.encode(openAICompatible, forKey: .openAICompatible)
        try values.encode(providerOAuth, forKey: .providerOAuth)
        try values.encode(cli, forKey: .cli)
        try values.encode(behavior, forKey: .behavior)
        try values.encode(additionalInstructions, forKey: .additionalInstructions)
        try values.encode(automaticAnalysis, forKey: .automaticAnalysis)
        try values.encodeIfPresent(automaticAnalysisSince, forKey: .automaticAnalysisSince)
        try values.encode(automaticAnalysisTouchedByUser, forKey: .automaticAnalysisTouchedByUser)
    }
}

public extension AssistantSettings {
    /// De onde **este** resumo veio, pela versão do motor que o gravou.
    ///
    /// A rota atual não serve para isto: depois do opt-in o histórico continua
    /// tendo sido resumido aqui, e nomear o provedor em cima dele seria a mesma
    /// mentira de antes, só que ao contrário. A proveniência é um fato gravado
    /// com o resumo — `Message.summaryModelVersion` —, não uma preferência.
    ///
    /// A decisão é por **prefixo**, e não por igualdade com a constante da
    /// versão de hoje: subir o analisador para `-v2` faria todo resumo `-v1`
    /// se apresentar como "neste Mac", que é exatamente a mentira que a
    /// Task 13 tirou da tela. E um resumo remoto cujo provedor não dá mais
    /// para determinar recebe uma legenda neutra — nunca a promessa de que
    /// ficou aqui.
    func automaticAnalysisDestination(forSummaryModelVersion version: String?) -> AssistantDestination {
        guard let version, TextAssistantMessageAnalyzer.isRemoteModelVersion(version) else {
            return .onThisMac
        }
        let destination = AssistantDestination(settings: self)
        // O provedor de agora só pode ser nomeado quando ele ainda é o destino
        // remoto configurado. Se a pessoa voltou para o Foundation Models, o
        // resumo continua tendo saído daqui, mas o app não sabe mais para
        // quem — e inventar um nome é pior do que não dar nenhum.
        return destination.isLocal ? .configuredProviderUnknown : destination
    }

    /// Esta mensagem entra no consentimento que a pessoa deu?
    ///
    /// "Mensagens novas" é o que a cópia promete, e é literalmente isto: só o
    /// que chegou **depois** do clique. Sem carimbo, ninguém sai daqui.
    func automaticAnalysisCoversMessage(receivedAt: Date) -> Bool {
        guard automaticAnalysis == .configuredProvider,
              provider != .foundationModels,
              let since = automaticAnalysisSince
        else { return false }
        return receivedAt >= since
    }
}
