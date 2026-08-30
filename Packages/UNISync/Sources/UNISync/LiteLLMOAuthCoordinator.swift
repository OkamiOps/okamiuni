import Foundation

public enum LiteLLMOAuthStatus: Sendable, Hashable {
    case idle
    case checking
    case signedOut
    case authorizing
    case signedIn
    case failed(String)
}

/// Contrato consumido pela tela de configurações. A tela recebe estado e
/// ações, nunca access/refresh token.
@MainActor
public protocol LiteLLMOAuthAuthorizing: AnyObject, Sendable {
    var status: LiteLLMOAuthStatus { get }
    func refreshStatus(endpoint: URL, credentialID: String) async
    func start(endpoint: URL, credentialID: String) async throws
    func signOut(endpoint: URL, credentialID: String) async
}

/// Coordena consentimento, renovação single-flight e revogação. É MainActor
/// para que as transições lidas pela UI sejam determinísticas; todas as
/// esperas de rede e navegador são assíncronas.
@MainActor
public final class LiteLLMOAuthCoordinator:
    LiteLLMOAuthAuthorizing, OpenAICompatibleOAuthTokenProviding {

    public private(set) var status: LiteLLMOAuthStatus = .idle

    private let client: LiteLLMOAuthClient
    private let sessions: any LiteLLMOAuthSessionStoring
    private let browserSessions: any LiteLLMOAuthBrowserSessionMaking
    private let now: @Sendable () -> Date
    private var refreshTasks: [String: Task<LiteLLMOAuthSession, any Error>] = [:]

    public init(
        client: LiteLLMOAuthClient = LiteLLMOAuthClient(),
        sessions: any LiteLLMOAuthSessionStoring = KeychainLiteLLMOAuthSessionStore(),
        browserSessions: any LiteLLMOAuthBrowserSessionMaking = SystemLiteLLMOAuthBrowserSessionFactory(),
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.sessions = sessions
        self.browserSessions = browserSessions
        self.now = now
    }

    public func refreshStatus(endpoint: URL, credentialID: String) async {
        status = .checking
        do {
            let session = try sessions.session(for: credentialID)
            status = session.map { LiteLLMOAuthClient.session($0, belongsTo: endpoint) } == true
                ? .signedIn
                : .signedOut
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    public func start(endpoint: URL, credentialID: String) async throws {
        status = .authorizing
        do {
            let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
            let oldSession = try sessions.session(for: credentialID)
            let discovery = try await client.discover(endpoint: endpoint)
            let browserSession = try await browserSessions.makeSession()
            let clientID = try await client.register(
                discovery: discovery,
                redirectURI: browserSession.redirectURI
            )
            let pkce = PKCEPair.random()
            let state = PKCEPair.randomToken(byteCount: 32)
            let authorizationURL = try client.authorizationURL(
                discovery: discovery,
                clientID: clientID,
                redirectURI: browserSession.redirectURI,
                pkce: pkce,
                state: state
            )
            let callback = try await browserSession.authorize(at: authorizationURL)
            let code = try client.authorizationCode(from: callback, expectedState: state)
            let newSession = try await client.exchange(
                code: code,
                discovery: discovery,
                clientID: clientID,
                redirectURI: browserSession.redirectURI,
                verifier: pkce.verifier
            )

            // Primeiro persiste o novo par. Só depois revoga a sessão antiga:
            // falha de rede na limpeza não pode jogar fora um login concluído.
            try sessions.store(newSession, for: credentialID)
            status = .signedIn
            if let oldSession, oldSession.refreshToken != newSession.refreshToken {
                try? await client.revoke(oldSession)
            }
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    public func signOut(endpoint: URL, credentialID: String) async {
        status = .checking
        do {
            guard let session = try sessions.session(for: credentialID) else {
                status = .signedOut
                return
            }
            guard LiteLLMOAuthClient.session(session, belongsTo: session.issuer) else {
                // Registro adulterado ou legado sem vínculo interno coerente:
                // não envia o refresh token a lugar nenhum.
                try sessions.removeSession(for: credentialID)
                status = .signedOut
                return
            }
            // Mesmo que a pessoa tenha acabado de editar o endpoint, revoga a
            // sessão no emissor que a criou; simplesmente apagá-la localmente
            // deixaria um refresh token ativo e sem caminho para revogação.
            try await client.revoke(session)
            try sessions.removeSession(for: credentialID)
            status = .signedOut
        } catch {
            // Mantém o refresh token para que a pessoa possa tentar revogar de
            // novo; limpar localmente agora deixaria uma autorização viva e
            // sem controle no proxy.
            status = .failed(error.localizedDescription)
        }
    }

    public func hasAccessToken(for credentialID: String, endpoint: URL) async -> Bool {
        guard let session = try? sessions.session(for: credentialID),
              LiteLLMOAuthClient.session(session, belongsTo: endpoint)
        else { return false }
        return !session.accessToken.isEmpty && !session.refreshToken.isEmpty
    }

    public func accessToken(for credentialID: String, endpoint: URL) async throws -> String? {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        guard let stored = try sessions.session(for: credentialID) else { return nil }
        guard LiteLLMOAuthClient.session(stored, belongsTo: endpoint) else {
            throw LiteLLMOAuthError.crossOriginEndpoint
        }
        guard stored.needsRefresh(at: now()) else { return stored.accessToken }

        if let inFlight = refreshTasks[credentialID] {
            return try await inFlight.value.accessToken
        }
        let task = Task { try await client.refresh(stored) }
        refreshTasks[credentialID] = task
        defer { refreshTasks[credentialID] = nil }
        do {
            let renewed = try await task.value
            // A troca é atômica no Keychain. O refresh token anterior é de uso
            // único e deixa de ser válido assim que o servidor responde.
            try sessions.store(renewed, for: credentialID)
            status = .signedIn
            return renewed.accessToken
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }
}
