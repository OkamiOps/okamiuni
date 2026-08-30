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
public actor AssistantRouter: OnDeviceTextAssisting {
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
        requestTimeout: TimeInterval = 30,
        oauthTokenProvider: (any OpenAICompatibleOAuthTokenProviding)? = nil,
        providerOAuthTokenProvider: (any AssistantProviderOAuthTokenProviding)? = nil,
        cliInstallationProvider: @escaping @Sendable () -> [AssistantCLIInstallation] = {
            AssistantCLIDiscovery().scan()
        },
        cliExecutor: any AssistantCLIProcessExecuting = SystemAssistantCLIProcessExecutor(),
        cliRequestTimeout: TimeInterval = 60
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.session = session
        self.requestTimeout = max(1, requestTimeout)
        self.oauthTokenProvider = oauthTokenProvider
        self.providerOAuthTokenProvider = providerOAuthTokenProvider
        self.cliInstallationProvider = cliInstallationProvider
        self.cliExecutor = cliExecutor
        self.cliRequestTimeout = min(max(cliRequestTimeout, 5), 120)
    }

    public func availability() async -> OnDeviceMessageAnalysisAvailability {
        let settings = settingsStore.snapshot()
        switch settings.provider {
        case .foundationModels:
            return FoundationModelsTextAssistant.systemAvailability
        case .openAICompatible:
            guard let configuration = try? settings.openAICompatible.validated(),
                  let endpoint = try? configuration.chatCompletionsURL()
            else {
                return .modelNotReady
            }
            switch configuration.authenticationMode {
            case .none:
                return .available
            case .apiKey:
                guard (try? credentialStore.credentialPresence(for: configuration.credentialID)) == .present else {
                    return .modelNotReady
                }
                return .available
            case .litellmOAuthPKCE:
                guard let oauthTokenProvider,
                      await oauthTokenProvider.hasAccessToken(
                          for: configuration.credentialID,
                          endpoint: endpoint
                      )
                else {
                    return .modelNotReady
                }
                return .available
            }
        case .providerOAuth:
            guard let configuration = try? settings.providerOAuth.validated(),
                  let providerOAuthTokenProvider,
                  await providerOAuthTokenProvider.hasAccessToken(for: configuration)
            else {
                return .modelNotReady
            }
            return .available
        case .cli:
            guard let installation = cliInstallationProvider().first(where: {
                $0.kind == settings.cli.kind && $0.isDetected
            }), (try? AssistantCLICommand.make(kind: settings.cli.kind, installation: installation)) != nil
            else {
                return .modelNotReady
            }
            return .available
        }
    }

    public func answer(
        question: String,
        in conversation: OnDeviceAssistantConversation
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

    public func transform(
        _ text: String,
        using action: OnDeviceWritingAction,
        context: OnDeviceAssistantMailContext?
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
    ) async throws -> any OnDeviceTextAssisting {
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
            requestTimeout: requestTimeout
        )
    }
}
