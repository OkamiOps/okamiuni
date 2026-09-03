import Foundation
import UNICore

/// A sessão OAuth PKCE do LiteLLM pertence a um serviço específico do proxy.
/// O roteador só pede presença ou um access token efêmero quando uma ação foi
/// explicitamente iniciada; ele não sabe iniciar device flow, importar tokens
/// de CLIs nem persistir segredos desse serviço.
public protocol OpenAICompatibleOAuthTokenProviding: Sendable {
    /// O endpoint faz parte da chave de autorização: uma sessão configurada
    /// para um proxy nunca pode reutilizar seu bearer em outro host.
    func hasAccessToken(for credentialID: String, endpoint: URL) async -> Bool
    func accessToken(for credentialID: String, endpoint: URL) async throws -> String?
}

/// Porta estável para a interface. Ela escolhe o adaptador no início de cada
/// ação a partir de um snapshot atômico das configurações; portanto salvar uma
/// mudança afeta a próxima chamada, sem desmontar telas ou cancelar uma
/// resposta que já estava em voo.
@available(macOS 26.0, *)
public actor AssistantRouter: TextAssisting {
    public static let currentModelVersion = "assistant-router/v3"
    public nonisolated let modelVersion = AssistantRouter.currentModelVersion

    private let settingsStore: AssistantSettingsStore
    private let credentialStore: any AssistantCredentialStore
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let oauthTokenProvider: (any OpenAICompatibleOAuthTokenProviding)?
    private let providerOAuthTokenProvider: (any AssistantProviderOAuthTokenProviding)?
    private let cliInstallationProvider: @Sendable () -> [AssistantCLIInstallation]
    private let cliExecutor: any AssistantCLIProcessExecuting
    private let cliRequestTimeout: TimeInterval

    public init(
        settingsStore: AssistantSettingsStore,
        credentialStore: any AssistantCredentialStore,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 120,
        oauthTokenProvider: (any OpenAICompatibleOAuthTokenProviding)? = nil,
        providerOAuthTokenProvider: (any AssistantProviderOAuthTokenProviding)? = nil,
        cliInstallationProvider: @escaping @Sendable () -> [AssistantCLIInstallation] = {
            AssistantCLIDiscovery().scan()
        },
        cliExecutor: any AssistantCLIProcessExecuting = SystemAssistantCLIProcessExecutor(),
        cliRequestTimeout: TimeInterval = 120
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.requestTimeout = max(1, requestTimeout)
        self.session = AssistantURLSessionFactory.timed(
            basedOn: session,
            timeout: max(self.requestTimeout, 120)
        )
        self.oauthTokenProvider = oauthTokenProvider
        self.providerOAuthTokenProvider = providerOAuthTokenProvider
        self.cliInstallationProvider = cliInstallationProvider
        self.cliExecutor = cliExecutor
        // Faixa da spec 1.4: nunca menos de 30 s (um CLI frio demora a subir),
        // nunca mais de 300 s (o botão precisa devolver a mão da pessoa).
        self.cliRequestTimeout = min(max(cliRequestTimeout, 30), 300)
    }

    /// Os dois tempos realmente gravados na sessão HTTP deste roteador.
    /// Interno de propósito: o `URLRequest` sozinho não mostra o tempo de
    /// **recurso**, que é justamente o que matava o Grok em prompt longo, e
    /// sem isto nenhum teste consegue provar que a fábrica de sessão foi
    /// aplicada.
    func httpTimeouts() -> (request: TimeInterval, resource: TimeInterval) {
        (
            session.configuration.timeoutIntervalForRequest,
            session.configuration.timeoutIntervalForResource
        )
    }

    /// Para onde o conteúdo vai agora, sem perguntar nada a ninguém. É o que
    /// a interface usa para não prometer processamento local com um provedor
    /// remoto escolhido.
    public nonisolated func destination() -> AssistantDestination {
        AssistantDestination(settings: settingsStore.snapshot())
    }

    /// Barata de propósito: nenhuma chamada de rede, nenhuma leitura de
    /// segredo, nenhuma renovação de token. É consultada a cada abertura de
    /// tela e a cada `save` das preferências.
    public func assistantAvailability() async -> AssistantAvailability {
        let settings = settingsStore.snapshot()
        let destination = AssistantDestination(settings: settings)
        switch settings.provider {
        case .foundationModels:
            let state = FoundationModelsTextAssistant.systemAvailability
            return state == .available ? .ready(destination) : .appleIntelligence(state)
        case .openAICompatible:
            guard let configuration = try? settings.openAICompatible.validated(),
                  let endpoint = try? configuration.chatCompletionsURL()
            else {
                return .needsSetup(destination, reason: "Confira o endpoint e o modelo deste provedor.")
            }
            switch configuration.authenticationMode {
            case .none:
                return .ready(destination)
            case .apiKey:
                guard (try? credentialStore.credentialPresence(for: configuration.credentialID)) == .present else {
                    return .needsSetup(destination, reason: "Adicione a chave de API deste provedor.")
                }
                return .ready(destination)
            case .litellmOAuthPKCE:
                guard let oauthTokenProvider,
                      await oauthTokenProvider.hasAccessToken(
                          for: configuration.credentialID, endpoint: endpoint
                      )
                else {
                    return .needsSignIn(destination, provider: nil)
                }
                return .ready(destination)
            }
        case .providerOAuth:
            guard let configuration = try? settings.providerOAuth.validated() else {
                return .needsSetup(destination, reason: "Escolha um modelo para esta assinatura.")
            }
            guard let providerOAuthTokenProvider,
                  await providerOAuthTokenProvider.hasAccessToken(for: configuration)
            else {
                return .needsSignIn(destination, provider: configuration.kind)
            }
            if configuration.kind == .codex,
               cliInstallationProvider().first(where: { $0.kind == .codex && $0.isDetected }) == nil {
                return .needsSetup(destination, reason: "O runtime do Codex não foi encontrado neste Mac.")
            }
            return .ready(destination)
        case .cli:
            guard let installation = cliInstallationProvider().first(where: {
                $0.kind == settings.cli.kind && $0.isDetected
            }), (try? AssistantCLICommand.make(kind: settings.cli.kind, installation: installation)) != nil
            else {
                return .needsSetup(
                    destination,
                    reason: "O \(settings.cli.kind.displayName) não foi encontrado neste Mac."
                )
            }
            return .ready(destination)
        }
    }

    /// O requisito do protocolo continua existindo — é ele que a fila de
    /// análise consulta. Agora é derivado, e não uma segunda regra.
    public func availability() async -> AppleIntelligenceAvailability {
        switch await assistantAvailability() {
        case .ready: .available
        case let .appleIntelligence(state): state
        case .needsSetup, .needsSignIn: .modelNotReady
        }
    }

    public func answer(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> String {
        let settings = settingsStore.snapshot()
        switch settings.provider {
        case .foundationModels:
            return try await FoundationModelsTextAssistant(
                additionalInstructions: settings.configuredInstructions(for: .questions)
            ).answer(question: question, in: conversation)
        case .openAICompatible:
            return try await remoteAssistant(settings: settings, promptKind: .questions).answer(
                question: question,
                in: conversation
            )
        case .providerOAuth:
            return try await providerOAuthAssistant(settings: settings, promptKind: .questions).answer(
                question: question,
                in: conversation
            )
        case .cli:
            return try await cliAssistant(settings: settings, promptKind: .questions).answer(
                question: question,
                in: conversation
            )
        }
    }

    /// A mesma pergunta, com propostas de ação quando houver ação a propor.
    ///
    /// Duas rotas para a mesma coisa, e a diferença é só de forma: o
    /// Foundation Models devolve estrutura por `@Generable`; endpoint,
    /// assinatura e CLI devolvem texto, e a estrutura vem num bloco
    /// ```` ```okami-actions ```` que o parser tira da resposta antes de ela
    /// chegar à tela.
    ///
    /// **O validador roda aqui, nas duas.** A alternativa — deixá-lo para a
    /// superfície — repetiria a conferência em cada tela, e bastaria uma
    /// esquecer para uma proposta agir sobre uma mensagem que não estava no
    /// contexto. Nada é executado nesta função: propostas são texto tipado até
    /// alguém clicar.
    public func answerWithProposals(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> AssistantAnswer {
        let settings = settingsStore.snapshot()
        let bruta: AssistantAnswer
        switch settings.provider {
        case .foundationModels:
            bruta = try await FoundationModelsTextAssistant(
                additionalInstructions: settings.configuredInstructions(for: .questions)
            ).answerWithProposals(question: question, in: conversation)
        case .openAICompatible:
            bruta = AssistantActionsBlock.answer(
                try await remoteAssistant(settings: settings, promptKind: .questions).answer(
                    question: AssistantPrompt.questionRequestingProposals(question),
                    in: conversation
                )
            )
        case .providerOAuth:
            bruta = AssistantActionsBlock.answer(
                try await providerOAuthAssistant(settings: settings, promptKind: .questions).answer(
                    question: AssistantPrompt.questionRequestingProposals(question),
                    in: conversation
                )
            )
        case .cli:
            bruta = AssistantActionsBlock.answer(
                try await cliAssistant(settings: settings, promptKind: .questions).answer(
                    question: AssistantPrompt.questionRequestingProposals(question),
                    in: conversation
                )
            )
        }
        return AssistantAnswer(
            text: bruta.text,
            proposals: AssistantProposalValidator.validate(
                bruta.proposals,
                messageIDs: conversation.mailContext.messageIDs,
                messageIDsWithEvent: conversation.mailContext.messageIDsWithEvent
            )
        )
    }

    public func transform(
        _ text: String,
        using action: WritingAction,
        context: AssistantMailContext?
    ) async throws -> String {
        let settings = settingsStore.snapshot()
        switch settings.provider {
        case .foundationModels:
            return try await FoundationModelsTextAssistant(
                additionalInstructions: settings.configuredInstructions(for: .writing)
            ).transform(text, using: action, context: context)
        case .openAICompatible:
            return try await remoteAssistant(settings: settings, promptKind: .writing).transform(
                text,
                using: action,
                context: context
            )
        case .providerOAuth:
            return try await providerOAuthAssistant(settings: settings, promptKind: .writing).transform(
                text,
                using: action,
                context: context
            )
        case .cli:
            return try await cliAssistant(settings: settings, promptKind: .writing).transform(
                text,
                using: action,
                context: context
            )
        }
    }

    private func remoteAssistant(
        settings: AssistantSettings,
        promptKind: AssistantPromptKind
    ) async throws -> OpenAICompatibleTextAssistant {
        let configuration = try settings.openAICompatible.validated()
        let authorizationToken: String?
        switch configuration.authenticationMode {
        case .none:
            authorizationToken = nil
        case .apiKey:
            guard let apiKey = try credentialStore.apiKey(for: configuration.credentialID) else {
                throw OpenAICompatibleTextAssistantError.missingAPIKey
            }
            authorizationToken = apiKey
        case .litellmOAuthPKCE:
            guard let oauthTokenProvider else {
                throw OpenAICompatibleTextAssistantError.oauthProviderUnavailable
            }
            let endpoint = try configuration.chatCompletionsURL()
            guard let token = try await oauthTokenProvider.accessToken(
                for: configuration.credentialID,
                endpoint: endpoint
            ) else {
                throw OpenAICompatibleTextAssistantError.missingOAuthAuthorization
            }
            authorizationToken = token
        }
        return try OpenAICompatibleTextAssistant(
            configuration: configuration,
            authorizationToken: authorizationToken,
            additionalInstructions: settings.configuredInstructions(for: promptKind),
            session: session,
            requestTimeout: requestTimeout
        )
    }

    private func cliAssistant(
        settings: AssistantSettings,
        promptKind: AssistantPromptKind
    ) throws -> AssistantCLITextAssistant {
        guard let installation = cliInstallationProvider().first(where: {
            $0.kind == settings.cli.kind && $0.isDetected
        }) else {
            throw AssistantCLITextAssistantError.executableNotFound(settings.cli.kind)
        }
        let command = try AssistantCLICommand.make(
            kind: settings.cli.kind,
            installation: installation
        )
        return .init(
            command: command,
            executor: cliExecutor,
            additionalInstructions: settings.configuredInstructions(for: promptKind),
            requestTimeout: cliRequestTimeout
        )
    }

    private func providerOAuthAssistant(
        settings: AssistantSettings,
        promptKind: AssistantPromptKind
    ) async throws -> any TextAssisting {
        let configuration = try settings.providerOAuth.validated()
        guard let providerOAuthTokenProvider else {
            throw AssistantProviderOAuthError.missingSession
        }
        if configuration.kind == .codex {
            guard await providerOAuthTokenProvider.hasAccessToken(for: configuration) else {
                throw AssistantProviderOAuthError.missingSession
            }
            guard let installation = cliInstallationProvider().first(where: {
                $0.kind == .codex && $0.isDetected
            }) else {
                throw AssistantCLITextAssistantError.executableNotFound(.codex)
            }
            let command = try AssistantCLICommand.makeCodexSubscription(
                configuration: configuration,
                installation: installation
            )
            return AssistantCLITextAssistant(
                command: command,
                executor: cliExecutor,
                additionalInstructions: settings.configuredInstructions(for: promptKind),
                requestTimeout: cliRequestTimeout
            )
        }
        guard let token = try await providerOAuthTokenProvider.accessToken(for: configuration) else {
            throw AssistantProviderOAuthError.missingSession
        }
        return try AssistantProviderOAuthTextAssistant(
            configuration: configuration,
            accessToken: token,
            additionalInstructions: settings.configuredInstructions(for: promptKind),
            session: session,
            requestTimeout: max(requestTimeout, 120)
        )
    }
}
