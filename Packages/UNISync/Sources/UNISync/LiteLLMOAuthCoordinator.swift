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
public protocol LiteLLMOAuthAuthorizing: AnyObject, Sendable {
    nonisolated var sessionState: LiteLLMOAuthSessionState { get }
    func refreshStatus(endpoint: URL, credentialID: String) async
    func start(endpoint: URL, credentialID: String) async throws
    func signOut(endpoint: URL, credentialID: String) async
}

/// O que Ajustes desenha. Só status — nunca token, nunca endpoint com
/// credencial. O ator publica; a tela observa.
@MainActor
@Observable
public final class LiteLLMOAuthSessionState {
    public private(set) var status: LiteLLMOAuthStatus = .idle
    /// A transição mais recente já aplicada — ver
    /// `AssistantProviderOAuthSessionState`: a entrega até aqui é um salto
    /// para o ator principal e nada garante a ordem de chegada.
    @ObservationIgnored private var appliedSequence: UInt64 = 0

    public nonisolated init() {}

    public func apply(_ status: LiteLLMOAuthStatus, sequence: UInt64) {
        guard sequence > appliedSequence else { return }
        appliedSequence = sequence
        self.status = status
    }
}

/// Coordena consentimento, renovação single-flight e revogação. É um ator:
/// ler ou renovar token acontece no executor dele, nunca na thread que
/// desenha a interface. A apresentação do navegador — o único ponto que
/// precisa da tela — salta para o ator principal onde ela acontece.
public actor LiteLLMOAuthCoordinator:
    LiteLLMOAuthAuthorizing, OpenAICompatibleOAuthTokenProviding {

    public nonisolated let sessionState: LiteLLMOAuthSessionState

    private let client: LiteLLMOAuthClient
    private let sessions: any LiteLLMOAuthSessionStoring
    private let browserSessions: any LiteLLMOAuthBrowserSessionMaking
    private let now: @Sendable () -> Date
    private var refreshTasks: [String: Task<LiteLLMOAuthSession, any Error>] = [:]
    /// Só cresce. Dá ordem a transições que atravessam o ator principal por
    /// caminhos diferentes.
    private var publishSequence: UInt64 = 0

    public init(
        sessionState: LiteLLMOAuthSessionState = .init(),
        client: LiteLLMOAuthClient = LiteLLMOAuthClient(),
        sessions: any LiteLLMOAuthSessionStoring = KeychainLiteLLMOAuthSessionStore(),
        browserSessions: any LiteLLMOAuthBrowserSessionMaking = SystemLiteLLMOAuthBrowserSessionFactory(),
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.sessionState = sessionState
        self.client = client
        self.sessions = sessions
        self.browserSessions = browserSessions
        self.now = now
    }

    public func refreshStatus(endpoint: URL, credentialID: String) async {
        publish(.checking)
        do {
            let session = try sessions.session(for: credentialID)
            publish(session.map { LiteLLMOAuthClient.session($0, belongsTo: endpoint) } == true
                ? .signedIn
                : .signedOut)
        } catch {
            publish(.failed(error.localizedDescription))
        }
    }

    /// Publica o estado na tela. Só status atravessa esta fronteira, e
    /// **sem suspender**: a transição vai carimbada com a ordem em que foi
    /// decidida aqui, para um `.signedIn` de renovação em voo não pousar
    /// depois — e por cima — do `.signedOut` de um logout.
    @discardableResult
    private func publish(_ status: LiteLLMOAuthStatus) -> UInt64 {
        publishSequence &+= 1
        let sequence = publishSequence
        let state = sessionState
        Task { @MainActor in state.apply(status, sequence: sequence) }
        return sequence
    }

    /// Ainda somos a última palavra sobre o estado?
    private func stillCurrent(_ sequence: UInt64) -> Bool {
        publishSequence == sequence
    }

    public func start(endpoint: URL, credentialID: String) async throws {
        let marca = publish(.authorizing)
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
            // O consentimento demora: um `signOut` decidido enquanto o
            // navegador estava aberto é mais novo do que esta autorização, e
            // a tela fica com a decisão dele. A limpeza abaixo acontece de
            // qualquer jeito — ela não é sobre o que a tela mostra.
            if stillCurrent(marca) { publish(.signedIn) }
            if let oldSession, oldSession.refreshToken != newSession.refreshToken {
                try? await client.revoke(oldSession)
            }
        } catch {
            publish(.failed(error.localizedDescription))
            throw error
        }
    }

    public func signOut(endpoint: URL, credentialID: String) async {
        let marca = publish(.checking)
        do {
            guard let session = try sessions.session(for: credentialID) else {
                publish(.signedOut)
                return
            }
            guard LiteLLMOAuthClient.session(session, belongsTo: session.issuer) else {
                // Registro adulterado ou legado sem vínculo interno coerente:
                // não envia o refresh token a lugar nenhum.
                try sessions.removeSession(for: credentialID)
                publish(.signedOut)
                return
            }
            // Mesmo que a pessoa tenha acabado de editar o endpoint, revoga a
            // sessão no emissor que a criou; simplesmente apagá-la localmente
            // deixaria um refresh token ativo e sem caminho para revogação.
            try await client.revoke(session)
            try sessions.removeSession(for: credentialID)
            if stillCurrent(marca) { publish(.signedOut) }
        } catch {
            // Mantém o refresh token para que a pessoa possa tentar revogar de
            // novo; limpar localmente agora deixaria uma autorização viva e
            // sem controle no proxy.
            publish(.failed(error.localizedDescription))
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
            // O caminho do pedido não espera pela interface: o token volta
            // agora e a tela recebe a transição quando o ator principal puder.
            publish(.signedIn)
            return renewed.accessToken
        } catch {
            publish(.failed(error.localizedDescription))
            throw error
        }
    }
}
