import Foundation

/// Estado seguro para a tela: apenas link e código de dispositivo atravessam
/// essa fronteira. Access/refresh tokens nunca fazem parte dele.
public enum AssistantProviderOAuthStatus: Sendable, Hashable {
    case idle
    case checking
    case signedOut
    case awaitingDeviceCode(AssistantProviderOAuthDeviceAuthorization)
    case signedIn
    case failed(String)
}

/// Contrato consumido por Ajustes. A tela lê o estado publicado e chama as
/// ações; nada aqui devolve token.
public protocol AssistantProviderOAuthAuthorizing: AnyObject, Sendable {
    nonisolated var sessionState: AssistantProviderOAuthSessionState { get }
    func refreshStatus(configuration: AssistantProviderOAuthConfiguration) async
    func start(configuration: AssistantProviderOAuthConfiguration) async throws
    func availableModels(configuration: AssistantProviderOAuthConfiguration) async throws -> [AssistantProviderModel]
    func cancelAuthorization() async
    func signOut(configuration: AssistantProviderOAuthConfiguration) async
}

/// O que Ajustes desenha. Só status — nunca token, nunca endpoint com
/// credencial. O ator publica; a tela observa.
@MainActor
@Observable
public final class AssistantProviderOAuthSessionState {
    public private(set) var status: AssistantProviderOAuthStatus = .idle
    public nonisolated init() {}
    public func apply(_ status: AssistantProviderOAuthStatus) { self.status = status }
}

public extension AssistantProviderOAuthAuthorizing {
    func availableModels(configuration: AssistantProviderOAuthConfiguration) async throws -> [AssistantProviderModel] { [] }
}

/// Legado de integração do roteador: para Codex, `true` significa que o
/// runtime oficial tem sessão, nunca que o OkamiUNI possui um token.
public protocol AssistantProviderOAuthTokenProviding: Sendable {
    func hasAccessToken(for configuration: AssistantProviderOAuthConfiguration) async -> Bool
    func accessToken(for configuration: AssistantProviderOAuthConfiguration) async throws -> String?
}

/// Coordena dois limites diferentes: xAI mantém sessão no Keychain do app;
/// ChatGPT/Codex fica integralmente dentro do app-server e cofre do Codex.
public actor AssistantProviderOAuthCoordinator: AssistantProviderOAuthAuthorizing, AssistantProviderOAuthTokenProviding {
    /// A cópia do ator: quem decide dentro dele lê daqui, sem atravessar a
    /// interface. `publish` mantém as duas em passo.
    private var status: AssistantProviderOAuthStatus = .idle
    public nonisolated let sessionState: AssistantProviderOAuthSessionState

    private let client: AssistantProviderOAuthClient
    private let modelCatalog: AssistantProviderOAuthModelCatalog
    private let sessions: any AssistantProviderOAuthSessionStoring
    private let codexRuntime: any CodexDeviceLoginRuntime
    private let now: @Sendable () -> Date
    private var authorizationTask: Task<Void, Never>?
    private var refreshTasks: [String: Task<AssistantProviderOAuthSession, any Error>] = [:]
    /// A última resposta do runtime do Codex e quando ela chegou.
    ///
    /// Perguntar "há sessão?" ao Codex é subir o `codex app-server --stdio` e
    /// falar JSON-RPC com ele. A sonda de disponibilidade faz essa pergunta a
    /// cada `save` das preferências; sem esta janela curta, mexer no modelo
    /// três vezes seguidas subia três processos. Trinta segundos respondem à
    /// rajada sem esconder um login: `start` e `signOut` limpam na hora, e
    /// `refreshStatus` — o botão explícito de "verificar" — nunca lê daqui,
    /// só escreve.
    private var codexSession: (signedIn: Bool, measuredAt: Date)?
    private static let codexSessionTTL: TimeInterval = 30

    public init(
        sessionState: AssistantProviderOAuthSessionState = .init(),
        client: AssistantProviderOAuthClient = .init(),
        modelCatalog: AssistantProviderOAuthModelCatalog = .init(),
        sessions: any AssistantProviderOAuthSessionStoring = KeychainAssistantProviderOAuthSessionStore(),
        codexRuntime: any CodexDeviceLoginRuntime = SystemCodexDeviceLoginRuntime(),
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.sessionState = sessionState
        self.client = client
        self.modelCatalog = modelCatalog
        self.sessions = sessions
        self.codexRuntime = codexRuntime
        self.now = now
    }

    deinit {
        authorizationTask?.cancel()
        for task in refreshTasks.values { task.cancel() }
    }

    public func refreshStatus(configuration: AssistantProviderOAuthConfiguration) async {
        if case .awaitingDeviceCode = status { return }
        await publish(.checking)
        do {
            let configuration = try configuration.validatedForAuthorization()
            switch configuration.kind {
            case .codex:
                await publish(await measuredCodexSignedIn() ? .signedIn : .signedOut)
            case .xAI:
                guard let session = try sessions.session(for: configuration.credentialID),
                      session.kind == .xAI,
                      !session.accessToken.isEmpty,
                      !session.refreshToken.isEmpty
                else {
                    await publish(.signedOut)
                    return
                }
                await publish(.signedIn)
            }
        } catch {
            await publish(.failed(error.localizedDescription))
        }
    }

    public func start(configuration: AssistantProviderOAuthConfiguration) async throws {
        authorizationTask?.cancel()
        authorizationTask = nil
        codexSession = nil
        // A nova tentativa só começa depois que o runtime confirmou o
        // fechamento do login anterior; disparar isto em uma Task criaria uma
        // corrida que poderia cancelar o código recém-gerado.
        await codexRuntime.cancelDeviceLogin()
        await publish(.checking)
        do {
            let configuration = try configuration.validatedForAuthorization()
            switch configuration.kind {
            case .codex:
                let login = try await codexRuntime.startDeviceLogin()
                let presentation = AssistantProviderOAuthDeviceAuthorization(
                    kind: .codex,
                    verificationURL: login.verificationURL,
                    userCode: login.userCode,
                    // O protocolo oficial não publica expiração. A conclusão é
                    // a notificação `account/login/completed`, não um timeout
                    // inventado pelo app.
                    expiresAt: .distantFuture,
                    pollInterval: 0
                )
                await publish(.awaitingDeviceCode(presentation))
                authorizationTask = Task { [weak self, codexRuntime, loginID = login.loginID] in
                    do {
                        try await codexRuntime.waitForDeviceLogin(loginID: loginID)
                        guard !Task.isCancelled else { return }
                        await self?.finishCodexAuthorization()
                    } catch is CancellationError {
                        // Cancelar é decisão da pessoa, não um erro do login.
                    } catch {
                        await self?.failAuthorization(error)
                    }
                }
            case .xAI:
                let pending = try await client.begin(configuration: configuration)
                await publish(.awaitingDeviceCode(pending.presentation))
                authorizationTask = Task { [weak self, pending, configuration] in
                    await self?.completeXAIAuthorization(pending, configuration: configuration)
                }
            }
        } catch {
            await publish(.failed(error.localizedDescription))
            throw error
        }
    }

    public func cancelAuthorization() async {
        authorizationTask?.cancel()
        authorizationTask = nil
        Task { [codexRuntime] in await codexRuntime.cancelDeviceLogin() }
        if case .awaitingDeviceCode = status { await publish(.signedOut) }
    }

    public func availableModels(configuration: AssistantProviderOAuthConfiguration) async throws -> [AssistantProviderModel] {
        let configuration = try configuration.validatedForAuthorization()
        switch configuration.kind {
        case .codex:
            do {
                let models = try await codexRuntime.availableModels()
                await publish(.signedIn)
                return models
            } catch CodexDeviceLoginRuntimeError.notAuthenticated {
                await publish(.signedOut)
                throw CodexDeviceLoginRuntimeError.notAuthenticated
            }
        case .xAI:
            guard let token = try await accessToken(for: configuration) else {
                throw AssistantProviderOAuthModelCatalogError.missingAuthorization
            }
            return try await modelCatalog.models(configuration: configuration, accessToken: token)
        }
    }

    public func signOut(configuration: AssistantProviderOAuthConfiguration) async {
        await cancelAuthorization()
        codexSession = nil
        await publish(.checking)
        do {
            let configuration = try configuration.validatedForAuthorization()
            switch configuration.kind {
            case .codex:
                try await codexRuntime.signOut()
                // Limpa somente um eventual resíduo da implementação antiga;
                // a nova nunca grava uma credencial Codex neste Keychain.
                try sessions.removeSession(for: configuration.credentialID)
            case .xAI:
                if let stored = try sessions.session(for: configuration.credentialID), stored.kind != .xAI {
                    await publish(.signedOut)
                    return
                }
                try sessions.removeSession(for: configuration.credentialID)
            }
            await publish(.signedOut)
        } catch {
            await publish(.failed(error.localizedDescription))
        }
    }

    public func hasAccessToken(for configuration: AssistantProviderOAuthConfiguration) async -> Bool {
        guard let configuration = try? configuration.validatedForAuthorization() else { return false }
        switch configuration.kind {
        case .codex:
            return await cachedCodexSignedIn()
        case .xAI:
            guard let session = try? sessions.session(for: configuration.credentialID),
                  session.kind == .xAI,
                  !session.accessToken.isEmpty,
                  !session.refreshToken.isEmpty
            else { return false }
            return true
        }
    }

    public func accessToken(for configuration: AssistantProviderOAuthConfiguration) async throws -> String? {
        let configuration = try configuration.validatedForAuthorization()
        guard configuration.kind == .xAI else {
            // A sessão Codex permanece no runtime oficial. O roteador a usa
            // pelo adaptador de CLI, portanto não existe bearer para devolver.
            return nil
        }
        guard let session = try sessions.session(for: configuration.credentialID) else { return nil }
        guard session.kind == .xAI else { throw AssistantProviderOAuthError.sessionProviderMismatch }
        guard session.needsRefresh(at: now()) else { return session.accessToken }

        let refreshID = "xai:\(configuration.credentialID)"
        if let existing = refreshTasks[refreshID] { return try await existing.value.accessToken }
        let task = Task { try await client.refresh(session) }
        refreshTasks[refreshID] = task
        defer { refreshTasks[refreshID] = nil }
        do {
            let renewed = try await task.value
            try sessions.store(renewed, for: configuration.credentialID)
            // O caminho do pedido não espera pela interface: o token volta
            // agora e a tela recebe a transição quando o ator principal puder.
            publishWithoutWaiting(.signedIn)
            return renewed.accessToken
        } catch {
            publishWithoutWaiting(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Publica o estado na tela. O ator guarda sua própria cópia — quem decide
    /// aqui dentro nunca precisa perguntar à interface o que ela está
    /// desenhando.
    private func publish(_ status: AssistantProviderOAuthStatus) async {
        self.status = status
        await MainActor.run { self.sessionState.apply(status) }
    }

    /// A variante do caminho do pedido: atualiza a cópia do ator na hora e
    /// entrega a transição à interface sem suspender quem espera pelo token.
    private func publishWithoutWaiting(_ status: AssistantProviderOAuthStatus) {
        self.status = status
        let state = sessionState
        Task { @MainActor in state.apply(status) }
    }

    /// A resposta fresca do runtime, guardada para a sonda barata.
    private func measuredCodexSignedIn() async -> Bool {
        let signedIn = await codexRuntime.isSignedIn()
        codexSession = (signedIn, now())
        return signedIn
    }

    /// A leitura da sonda: usa a janela curta quando ela ainda vale.
    private func cachedCodexSignedIn() async -> Bool {
        if let codexSession, now().timeIntervalSince(codexSession.measuredAt) < Self.codexSessionTTL {
            return codexSession.signedIn
        }
        return await measuredCodexSignedIn()
    }

    private func finishCodexAuthorization() async {
        authorizationTask = nil
        codexSession = nil
        if await measuredCodexSignedIn() {
            await publish(.signedIn)
        } else {
            await publish(.failed(CodexDeviceLoginRuntimeError.notAuthenticated.localizedDescription))
        }
    }

    private func failAuthorization(_ error: Error) async {
        authorizationTask = nil
        await publish(.failed(error.localizedDescription))
    }

    private func completeXAIAuthorization(_ pending: AssistantProviderOAuthPendingAuthorization, configuration: AssistantProviderOAuthConfiguration) async {
        var interval = pending.presentation.pollInterval
        do {
            while pending.presentation.expiresAt > now() {
                try await Task.sleep(for: .seconds(interval))
                try Task.checkCancellation()
                switch try await client.poll(pending, interval: interval) {
                case let .pending(nextInterval): interval = nextInterval
                case let .completed(session):
                    try sessions.store(session, for: configuration.credentialID)
                    authorizationTask = nil
                    await publish(.signedIn)
                    return
                }
            }
            throw AssistantProviderOAuthError.authorizationExpired
        } catch is CancellationError {
            // Cancelamento voluntário não vira erro visual.
        } catch {
            authorizationTask = nil
            await publish(.failed(error.localizedDescription))
        }
    }
}
