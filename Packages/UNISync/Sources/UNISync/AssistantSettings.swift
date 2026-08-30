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
        if language != .portugueseBrazil { instructions.append(language.promptInstruction) }
        if format != .adaptive { instructions.append(format.promptInstruction) }
        if !suggestNextSteps {
            instructions.append("Não acrescente próximos passos que não tenham sido pedidos.")
        }
        return instructions.joined(separator: "\n")
    }
}

/// Preferências persistidas da IA. É um único documento Codable para que uma
/// troca de provedor, endpoint e instruções seja atômica para quem o lê.
public struct AssistantSettings: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 4
    public static let maximumAdditionalInstructionsCharacters = 6_000
    public static let maximumPurposeInstructionsCharacters = 3_000

    public var schemaVersion: Int
    public var provider: AssistantProvider
    public var openAICompatible: OpenAICompatibleAssistantConfiguration
    public var providerOAuth: AssistantProviderOAuthConfiguration
    public var cli: AssistantCLIConfiguration
    public var behavior: AssistantBehaviorPreferences
    public var additionalInstructions: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        provider: AssistantProvider = .foundationModels,
        openAICompatible: OpenAICompatibleAssistantConfiguration = .init(),
        providerOAuth: AssistantProviderOAuthConfiguration = .init(),
        cli: AssistantCLIConfiguration = .init(),
        behavior: AssistantBehaviorPreferences = .default,
        additionalInstructions: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.openAICompatible = openAICompatible
        self.providerOAuth = providerOAuth
        self.cli = cli
        self.behavior = behavior
        self.additionalInstructions = additionalInstructions
    }

    public static let `default` = AssistantSettings()

    /// Migra versões que este binário conhece e valida o resultado antes de ele
    /// entrar no cache do app. Por enquanto v0 representa o arquivo sem versão
    /// explícita da primeira prévia desta infraestrutura.
    public func migrated() throws -> AssistantSettings {
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
    }
}
