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
    /// A transição mais recente já aplicada. Cada `publish` do ator carrega um
    /// número que só cresce; a entrega até aqui é um salto para o ator
    /// principal e nada garante a ordem de chegada. Sem este descarte, o
    /// `.signedIn` de uma renovação em voo podia pousar **depois** do
    /// `.signedOut` de um logout e a tela mostraria uma sessão que não existe.
    @ObservationIgnored private var appliedSequence: UInt64 = 0

    public nonisolated init() {}

    public func apply(_ status: AssistantProviderOAuthStatus, sequence: UInt64) {
        guard sequence > appliedSequence else { return }
        appliedSequence = sequence
        self.status = status
    }
}

public extension AssistantProviderOAuthAuthorizing {
    func availableModels(configuration: AssistantProviderOAuthConfiguration) async throws -> [AssistantProviderModel] { [] }
}

/// Credenciais da conexão direta de assinatura, independentes de qualquer CLI.
public protocol AssistantProviderOAuthTokenProviding: Sendable {
    func hasAccessToken(for configuration: AssistantProviderOAuthConfiguration) async -> Bool
    func accessToken(for configuration: AssistantProviderOAuthConfiguration) async throws -> String?
    func accountID(for configuration: AssistantProviderOAuthConfiguration) async throws -> String?
}

public extension AssistantProviderOAuthTokenProviding {
    func accountID(for configuration: AssistantProviderOAuthConfiguration) async throws -> String? { nil }
}

/// OAuth de assinatura via HTTP. O app mantém sua própria sessão no Keychain;
/// login, catálogo e respostas nunca iniciam processos ou consultam sessões CLI.
public actor AssistantProviderOAuthCoordinator: AssistantProviderOAuthAuthorizing, AssistantProviderOAuthTokenProviding {
    private var status: AssistantProviderOAuthStatus = .idle
    private var publishSequence: UInt64 = 0
    public nonisolated let sessionState: AssistantProviderOAuthSessionState
    private let client: AssistantProviderOAuthClient
    private let modelCatalog: AssistantProviderOAuthModelCatalog
    private let sessions: any AssistantProviderOAuthSessionStoring
    private let now: @Sendable () -> Date
    private var authorizationTask: Task<Void, Never>?
    private var refreshTasks: [String: Task<AssistantProviderOAuthSession, any Error>] = [:]

    public init(
        sessionState: AssistantProviderOAuthSessionState = .init(),
        client: AssistantProviderOAuthClient = .init(),
        modelCatalog: AssistantProviderOAuthModelCatalog = .init(),
        sessions: any AssistantProviderOAuthSessionStoring = KeychainAssistantProviderOAuthSessionStore(),
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.sessionState = sessionState
        self.client = client
        self.modelCatalog = modelCatalog
        self.sessions = sessions
        self.now = now
    }

    deinit {
        authorizationTask?.cancel()
        for task in refreshTasks.values { task.cancel() }
    }

    public func refreshStatus(configuration: AssistantProviderOAuthConfiguration) async {
        if case .awaitingDeviceCode = status { return }
        let sequence = publish(.checking)
        var attemptedToken: String?
        do {
            let configuration = try configuration.validatedForAuthorization()
            guard let stored = try sessions.session(for: configuration.credentialID),
                  stored.kind == configuration.kind,
                  !stored.accessToken.isEmpty, !stored.refreshToken.isEmpty,
                  configuration.kind != .codex || stored.accountID?.isEmpty == false
            else {
                if stillCurrent(sequence) { publish(.signedOut) }
                await synchronizeState()
                return
            }
            if configuration.kind == .codex {
                // Uma credencial local não comprova uma conexão ativa: o selo
                // só aparece depois da consulta autenticada ao catálogo oficial.
                guard let token = try await accessToken(for: configuration) else {
                    throw AssistantProviderOAuthError.missingSession
                }
                attemptedToken = token
                _ = try await modelCatalog.models(
                    configuration: configuration, accessToken: token,
                    accountID: try await accountID(for: configuration)
                )
            }
            if stillCurrent(sequence) { publish(.signedIn) }
        } catch {
            if error as? AssistantProviderOAuthModelCatalogError == .authenticationFailed {
                removeRejectedSession(configuration: configuration, token: attemptedToken)
            }
            if stillCurrent(sequence) { publish(.failed(error.localizedDescription)) }
        }
        await synchronizeState()
    }

    public func start(configuration: AssistantProviderOAuthConfiguration) async throws {
        authorizationTask?.cancel()
        authorizationTask = nil
        let sequence = publish(.checking)
        do {
            let configuration = try configuration.validatedForAuthorization()
            let pending = try await client.begin(configuration: configuration)
            guard stillCurrent(sequence) else { throw CancellationError() }
            let presentationSequence = publish(.awaitingDeviceCode(pending.presentation))
            let state = sessionState
            await MainActor.run { state.apply(.awaitingDeviceCode(pending.presentation), sequence: presentationSequence) }
            guard stillCurrent(presentationSequence) else { throw CancellationError() }
            authorizationTask = Task { [weak self, pending, configuration] in
                await self?.completeAuthorization(pending, configuration: configuration)
            }
        } catch {
            if stillCurrent(sequence) { publish(.failed(error.localizedDescription)) }
            throw error
        }
    }

    public func cancelAuthorization() async {
        authorizationTask?.cancel()
        authorizationTask = nil
        switch status {
        case .checking, .awaitingDeviceCode: publish(.signedOut)
        default: break
        }
        await synchronizeState()
    }

    public func availableModels(configuration: AssistantProviderOAuthConfiguration) async throws -> [AssistantProviderModel] {
        let configuration = try configuration.validatedForAuthorization()
        let sequence = publishSequence
        var attemptedToken: String?
        do {
            guard let token = try await accessToken(for: configuration) else {
                throw AssistantProviderOAuthModelCatalogError.missingAuthorization
            }
            attemptedToken = token
            let models = try await modelCatalog.models(
                configuration: configuration, accessToken: token,
                accountID: try await accountID(for: configuration)
            )
            if stillCurrent(sequence) { publish(.signedIn) }
            await synchronizeState()
            return models
        } catch {
            if error as? AssistantProviderOAuthModelCatalogError == .authenticationFailed {
                removeRejectedSession(configuration: configuration, token: attemptedToken)
            }
            if stillCurrent(sequence) {
                if let error = error as? AssistantProviderOAuthModelCatalogError,
                   error == .authenticationFailed || error == .missingAuthorization {
                    publish(.signedOut)
                } else {
                    publish(.failed(error.localizedDescription))
                }
            }
            await synchronizeState()
            throw error
        }
    }

    public func signOut(configuration: AssistantProviderOAuthConfiguration) async {
        await cancelAuthorization()
        let sequence = publish(.checking)
        do {
            let configuration = try configuration.validatedForAuthorization()
            let refreshID = "\(configuration.kind.rawValue):\(configuration.credentialID)"
            refreshTasks.removeValue(forKey: refreshID)?.cancel()
            if let stored = try sessions.session(for: configuration.credentialID),
               stored.kind == configuration.kind {
                try sessions.removeSession(for: configuration.credentialID)
            }
            if stillCurrent(sequence) { publish(.signedOut) }
        } catch {
            if stillCurrent(sequence) { publish(.failed(error.localizedDescription)) }
        }
        await synchronizeState()
    }

    public func hasAccessToken(for configuration: AssistantProviderOAuthConfiguration) async -> Bool {
        guard let configuration = try? configuration.validatedForAuthorization(),
              let session = try? sessions.session(for: configuration.credentialID),
              session.kind == configuration.kind,
              !session.accessToken.isEmpty, !session.refreshToken.isEmpty
        else { return false }
        return configuration.kind != .codex || session.accountID?.isEmpty == false
    }

    public func accountID(for configuration: AssistantProviderOAuthConfiguration) async throws -> String? {
        let configuration = try configuration.validatedForAuthorization()
        guard let session = try sessions.session(for: configuration.credentialID) else { return nil }
        guard session.kind == configuration.kind else { throw AssistantProviderOAuthError.sessionProviderMismatch }
        return session.accountID
    }

    public func accessToken(for configuration: AssistantProviderOAuthConfiguration) async throws -> String? {
        let configuration = try configuration.validatedForAuthorization()
        guard let session = try sessions.session(for: configuration.credentialID) else { return nil }
        guard session.kind == configuration.kind else { throw AssistantProviderOAuthError.sessionProviderMismatch }
        guard session.needsRefresh(at: now()) else { return session.accessToken }
        let refreshID = "\(configuration.kind.rawValue):\(configuration.credentialID)"
        if let existing = refreshTasks[refreshID] { return try await existing.value.accessToken }
        let sequence = publishSequence
        let task = Task { try await client.refresh(session) }
        refreshTasks[refreshID] = task
        defer { refreshTasks[refreshID] = nil }
        do {
            let renewed = try await task.value
            // Uma saída ou um login novo não pode ser desfeito por uma
            // renovação que já estava em voo.
            guard !task.isCancelled,
                  try sessions.session(for: configuration.credentialID)?.refreshToken == session.refreshToken
            else { throw CancellationError() }
            try sessions.store(renewed, for: configuration.credentialID)
            if configuration.kind == .xAI, stillCurrent(sequence) { publish(.signedIn) }
            return renewed.accessToken
        } catch {
            if !(error is CancellationError), stillCurrent(sequence) {
                publish(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    @discardableResult
    private func publish(_ status: AssistantProviderOAuthStatus) -> UInt64 {
        publishSequence &+= 1
        let sequence = publishSequence
        self.status = status
        let state = sessionState
        Task { @MainActor in state.apply(status, sequence: sequence) }
        return sequence
    }

    private func stillCurrent(_ sequence: UInt64) -> Bool { publishSequence == sequence }

    private func synchronizeState() async {
        let sequence = publishSequence
        let status = status
        let state = sessionState
        await MainActor.run { state.apply(status, sequence: sequence) }
    }

    private func removeRejectedSession(configuration: AssistantProviderOAuthConfiguration, token: String?) {
        // A rejection of an older request must not delete a newer login.
        guard let token, let stored = try? sessions.session(for: configuration.credentialID),
              stored.kind == configuration.kind, stored.accessToken == token else { return }
        try? sessions.removeSession(for: configuration.credentialID)
    }

    private func completeAuthorization(
        _ pending: AssistantProviderOAuthPendingAuthorization,
        configuration: AssistantProviderOAuthConfiguration
    ) async {
        var interval = pending.presentation.pollInterval
        do {
            while pending.presentation.expiresAt > now() {
                try await Task.sleep(for: .seconds(interval))
                try Task.checkCancellation()
                switch try await client.poll(pending, interval: interval) {
                case let .pending(nextInterval): interval = nextInterval
                case let .completed(session):
                    try Task.checkCancellation()
                    guard session.kind == configuration.kind else {
                        throw AssistantProviderOAuthError.sessionProviderMismatch
                    }
                    if configuration.kind == .codex {
                        _ = try await modelCatalog.models(
                            configuration: configuration, accessToken: session.accessToken,
                            accountID: session.accountID
                        )
                    }
                    try Task.checkCancellation()
                    try sessions.store(session, for: configuration.credentialID)
                    authorizationTask = nil
                    publish(.signedIn)
                    return
                }
            }
            throw AssistantProviderOAuthError.authorizationExpired
        } catch {
            guard !Task.isCancelled else { return }
            authorizationTask = nil
            publish(.failed(error.localizedDescription))
        }
    }
}
