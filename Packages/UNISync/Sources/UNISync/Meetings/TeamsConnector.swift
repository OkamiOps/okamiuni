import Foundation
import UNICore

/// O Microsoft Teams, com login **da pessoa**.
///
/// **Cliente público, PKCE S256, sem segredo.** No Entra ID isto é um registro
/// de aplicativo com plataforma "Mobile and desktop applications" e
/// `allowPublicClient` ligado. Um aplicativo instalado não guarda confidência,
/// e o próprio Entra recusa `client_secret` de cliente público.
///
/// **Tenant `common`.** Não `organizations` nem um GUID: `common` aceita conta
/// de trabalho ou escola **e** conta pessoal Microsoft, e é a única que
/// atende as duas. Qual das duas entrou se descobre na hora de criar a sala —
/// ver `TeamsMeetingClient`.
///
/// **Redirect por esquema próprio.** Aqui, diferente do Zoom e do Zoho, o
/// `ASWebAuthenticationSession` serve: o Entra aceita
/// `com.okamiops.okamiuni:/oauth2redirect`, o esquema já está registrado em
/// `CFBundleURLTypes`, e a sessão do sistema mostra o domínio real na barra —
/// que é o que impede o app de ver a senha digitada.
@MainActor
public final class TeamsConnector: MeetingConnector {
    public let service: MeetingService = .teams

    /// `offline_access` é o que faz o Entra devolver refresh token; sem ele a
    /// conexão morreria em uma hora. `Calendars.ReadWrite` cobre o caminho
    /// alternativo (`/me/events`) da conta pessoal, `OnlineMeetings.ReadWrite`
    /// o caminho normal, e `User.Read` só o e-mail que a linha mostra.
    public static let scopes = [
        "offline_access",
        "Calendars.ReadWrite",
        "OnlineMeetings.ReadWrite",
        "User.Read",
    ]

    /// `com.okamiops.okamiuni:/oauth2redirect`. Um só `/` depois dos dois
    /// pontos, como o redirect do Google deste mesmo app.
    public static let redirectURI = "com.okamiops.okamiuni:/oauth2redirect"
    public static let callbackScheme = "com.okamiops.okamiuni"

    private let clientID: String?
    private let session: URLSession
    private let vault: MeetingTokenVault
    private let presenter: any AuthorizationPresenter
    private let graphBase: URL
    private let config: MeetingOAuthConfig
    private let engine: MeetingOAuthEngine

    public init(
        clientID: String? = MeetingClientIDs.clientID(for: .teams),
        session: URLSession = .shared,
        vault: MeetingTokenVault,
        presenter: any AuthorizationPresenter = WebAuthorizationPresenter(),
        graphBase: URL = URL(string: "https://graph.microsoft.com/v1.0/")!,
        authorizationEndpoint: URL = URL(
            string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        )!,
        tokenEndpoint: URL = URL(
            string: "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        )!,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.clientID = clientID?.nonEmptyValue
        self.session = session
        self.vault = vault
        self.presenter = presenter
        self.graphBase = graphBase
        self.config = MeetingOAuthConfig(
            service: .teams,
            clientID: self.clientID ?? "",
            clientSecret: nil,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            redirectURI: TeamsConnector.redirectURI,
            scopes: TeamsConnector.scopes
        )
        self.engine = MeetingOAuthEngine(
            config: self.config, session: session, vault: vault, now: now
        )
    }

    public var isAvailable: Bool { clientID != nil }

    public func currentAccount() async -> String? {
        vault.load(.teams)?.account
    }

    public func connect() async throws -> String {
        guard clientID != nil else { throw MeetingConnectorError.missingClientID(.teams) }

        let pkce = PKCEPair.random()
        let state = PKCEPair.randomToken()
        let url = config.authorizationURL(pkce: pkce, state: state)

        let retorno: URL
        do {
            retorno = try await presenter.authorize(
                url: url, callbackScheme: TeamsConnector.callbackScheme
            )
        } catch SyncError.autorizacaoRevogada {
            // A pessoa fechou a janela do sistema. Desistir não é falha.
            throw CancellationError()
        }
        let callback = try MeetingOAuthCallback.read(
            retorno, expectedState: state, service: .teams
        )
        var tokens = try await engine.exchange(code: callback.code, verifier: pkce.verifier)
        tokens.account = await fetchAccount(accessToken: tokens.accessToken)
        try await engine.store(tokens)
        guard let conta = tokens.account else {
            throw MeetingConnectorError.refused(
                L10n.tr("O Microsoft Graph não disse de quem é a conta que entrou.")
            )
        }
        return conta
    }

    /// O consentimento acontece numa sessão do sistema que o apresentador
    /// controla; cancelar aqui é desistir da espera, e a tarefa cancelada já
    /// derruba a sessão. Mesma conta do `GoogleMeetConnector`.
    public func cancel() {}

    public func disconnect() async {
        vault.clear(.teams)
    }

    public var tokenSource: MeetingTokenSource {
        MeetingTokenSource(service: .teams, vault: vault, engine: engine)
    }

    /// `mail` quando a conta tem caixa; `userPrincipalName` quando não (conta
    /// pessoal MSA costuma vir só com ele).
    private func fetchAccount(accessToken: String) async -> String? {
        var request = URLRequest(url: URL(string: "me", relativeTo: graphBase)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (dados, resposta) = try? await session.data(for: request),
              let http = resposta as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        struct Wire: Decodable {
            let mail: String?
            let userPrincipalName: String?
        }
        let fio = try? JSONDecoder().decode(Wire.self, from: dados)
        return fio?.mail?.nonEmptyValue ?? fio?.userPrincipalName?.nonEmptyValue
    }
}
