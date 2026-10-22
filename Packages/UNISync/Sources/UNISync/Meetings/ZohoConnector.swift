import Foundation
import UNICore

/// O Zoho Meeting, com login **da pessoa**.
///
/// **PKCE e segredo, os dois.** É o único dos três assim, e não é escolha
/// nossa: a documentação do Zoho exige `client_secret` na troca do código
/// mesmo num fluxo com PKCE. O segredo vem de `Config/Meetings.xcconfig`,
/// fora do repositório, pelo mesmo acordo do client ID do Google — não é
/// segredo de verdade num app instalado, mas é obrigatório.
///
/// **Redirect por loopback.** O Zoho só aceita `http`/`https` no
/// `redirect_uri`, então o retorno vem em
/// `http://127.0.0.1:53720/oauth2redirect`, igual ao Zoom.
///
/// **Multi data center.** Ver `ZohoDataCenter`: o callback diz onde a conta
/// mora, e a troca do código, a renovação e a criação da sala vão **todas**
/// para lá. O accounts-server é guardado junto com o token porque sem ele a
/// próxima renovação não saberia para onde ir.
@MainActor
public final class ZohoConnector: MeetingConnector {
    public let service: MeetingService = .zoho

    /// Criar reunião e ler a organização (o `zsoid`, que entra no caminho de
    /// criar sala). Separados por vírgula: o Zoho recusa espaço.
    public static let scopes = [
        "ZohoMeeting.meeting.CREATE",
        "ZohoMeeting.manageOrg.READ",
    ]

    private let clientID: String?
    private let clientSecret: String?
    private let session: URLSession
    private let vault: MeetingTokenVault
    private let browser: any SystemBrowserOpening
    private let loopback: LoopbackEndpoint
    private let config: MeetingOAuthConfig
    private let engine: MeetingOAuthEngine
    /// O accounts-server usado quando o callback não traz um. `accounts.zoho.com`
    /// é o padrão do Zoho para quem não diz o contrário.
    private let defaultAccountsServer: String

    private var listener: LoopbackRedirectListener?

    public init(
        clientID: String? = MeetingClientIDs.clientID(for: .zoho),
        clientSecret: String? = MeetingClientIDs.clientSecret(for: .zoho),
        session: URLSession = .shared,
        vault: MeetingTokenVault,
        browser: any SystemBrowserOpening = AppKitBrowserOpener(),
        loopback: LoopbackEndpoint = .standard,
        authorizationEndpoint: URL = URL(string: "https://accounts.zoho.com/oauth/v2/auth")!,
        defaultAccountsServer: String = "https://accounts.zoho.com",
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.clientID = clientID?.nonEmptyValue
        self.clientSecret = clientSecret?.nonEmptyValue
        self.session = session
        self.vault = vault
        self.browser = browser
        self.loopback = loopback
        self.defaultAccountsServer = defaultAccountsServer
        self.config = MeetingOAuthConfig(
            service: .zoho,
            clientID: self.clientID ?? "",
            clientSecret: self.clientSecret,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: URL(string: "\(defaultAccountsServer)/oauth/v2/token")!,
            redirectURI: loopback.redirectURI,
            scopes: ZohoConnector.scopes,
            scopeSeparator: ",",
            extraAuthorizationItems: [
                // Sem `access_type=offline` o Zoho não devolve refresh token, e
                // a conexão morreria em uma hora sem nada a renovar.
                URLQueryItem(name: "access_type", value: "offline"),
                // `prompt=consent` faz o refresh token vir também quando a
                // pessoa já tinha autorizado antes — reconectar depois de um
                // erro precisa disso.
                URLQueryItem(name: "prompt", value: "consent"),
            ]
        )
        self.engine = MeetingOAuthEngine(
            config: self.config, session: session, vault: vault, now: now
        )
    }

    /// Sem client ID **ou** sem segredo não há OAuth do Zoho: aqui os dois são
    /// obrigatórios, e metade da credencial só produziria um erro do servidor.
    public var isAvailable: Bool { clientID != nil && clientSecret != nil }

    public func currentAccount() async -> String? {
        vault.load(.zoho)?.account
    }

    public func accounts() async -> [String] {
        vault.accounts(.zoho).compactMap { $0.account?.nonEmptyValue }
    }

    public func connect() async throws -> String {
        guard clientID != nil, clientSecret != nil else {
            throw MeetingConnectorError.missingClientID(.zoho)
        }

        let escuta = loopback.make()
        try escuta.start()
        listener = escuta
        defer {
            escuta.cancel()
            if listener === escuta { listener = nil }
        }

        let pkce = PKCEPair.random()
        let state = PKCEPair.randomToken()
        guard await browser.open(config.authorizationURL(pkce: pkce, state: state)) else {
            throw MeetingConnectorError.refused(
                L10n.tr("Não foi possível abrir o navegador para o login do Zoho Meeting.")
            )
        }

        let retorno = try await escuta.wait()
        let callback = try MeetingOAuthCallback.read(
            retorno, expectedState: state, service: .zoho
        )

        // O data center da conta. O callback manda `accounts-server`; se o
        // domínio não for um que conhecemos, falhar aqui é melhor que postar
        // a sala num host inventado.
        let bruto = callback.accountsServer ?? defaultAccountsServer
        guard let servidor = ZohoDataCenter.canonicalAccountsServer(bruto) else {
            throw MeetingConnectorError.refused(
                L10n.tr("O Zoho Meeting voltou de um data center que não conhecemos: \(bruto)")
            )
        }

        var tokens = try await engine.exchange(
            code: callback.code,
            verifier: pkce.verifier,
            tokenEndpoint: URL(string: "\(servidor)/oauth/v2/token")!
        )
        tokens.accountsServer = servidor
        if let usuario = await fetchUser(accessToken: tokens.accessToken, accountsServer: servidor) {
            tokens.account = usuario.email
            tokens.zsoid = usuario.zsoid
        }
        try await engine.store(tokens)
        return tokens.account ?? L10n.tr("conta Zoho")
    }

    public func cancel() {
        listener?.cancel()
        listener = nil
    }

    public func disconnect() async {
        vault.clear(.zoho)
    }

    public func disconnect(account: String) async {
        vault.remove(.zoho, account: account)
    }

    public var tokenSource: MeetingTokenSource {
        MeetingTokenSource(service: .zoho, vault: vault, engine: engine)
    }

    private func fetchUser(
        accessToken: String, accountsServer: String
    ) async -> ZohoUser? {
        guard let base = ZohoDataCenter.meetingAPIBase(accountsServer: accountsServer) else {
            return nil
        }
        return try? await ZohoUserClient(session: session, apiBase: base)
            .me(accessToken: accessToken)
    }
}

/// Quem é a pessoa e qual é a organização dela.
///
/// O `zsoid` entra no **caminho** de criar sala
/// (`/api/v2/{zsoid}/sessions.json`), então sem esta chamada não há URL para
/// onde postar. O e-mail é só a linha que a aba Agendas mostra.
struct ZohoUser: Sendable, Hashable {
    let zsoid: String
    let email: String?
}

struct ZohoUserClient: Sendable {
    let session: URLSession
    let apiBase: URL

    func me(accessToken: String) async throws -> ZohoUser {
        var request = URLRequest(url: URL(string: "user.json", relativeTo: apiBase)!)
        request.setValue("Zoho-oauthtoken \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Wire: Decodable {
            struct User: Decodable {
                let zsoid: ZohoLooseID?
                let zuid: ZohoLooseID?
                let emailId: String?
                let primaryEmail: String?
            }
            let userDetails: User?
            let user: User?
        }
        let fio = try await MeetingHTTP.decode(
            request, session: session, as: Wire.self, service: .zoho
        )
        let detalhe = fio.userDetails ?? fio.user
        guard let zsoid = (detalhe?.zsoid ?? detalhe?.zuid)?.text else {
            throw MeetingRoomError.failed(
                L10n.tr("O Zoho Meeting não disse qual é a organização da conta (zsoid).")
            )
        }
        return ZohoUser(
            zsoid: zsoid,
            email: detalhe?.emailId?.nonEmptyValue ?? detalhe?.primaryEmail?.nonEmptyValue
        )
    }
}

/// O `zsoid` chega como número em algumas respostas e como texto em outras.
/// Decodificar os dois é mais honesto que escolher um e falhar no outro.
struct ZohoLooseID: Decodable, Sendable, Hashable {
    let text: String

    init(from decoder: Decoder) throws {
        let valor = try decoder.singleValueContainer()
        if let texto = try? valor.decode(String.self) {
            text = texto
        } else if let numero = try? valor.decode(Int64.self) {
            text = String(numero)
        } else {
            text = String(try valor.decode(Double.self))
        }
    }
}
