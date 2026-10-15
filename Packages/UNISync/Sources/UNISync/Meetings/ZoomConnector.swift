import Foundation
import UNICore

/// O Zoom, com login **da pessoa** — não credencial de servidor.
///
/// **Public Client OAuth, sem segredo.** No App Marketplace isto é um
/// "General App" user-managed marcado como Public Client: a troca do código
/// leva `client_id`, `code`, `redirect_uri`, `code_verifier` e
/// `grant_type=authorization_code` **no corpo**, sem cabeçalho
/// `Authorization`. É o que um aplicativo instalado pode fazer com
/// honestidade — qualquer pessoa abre o `.app` e lê um segredo embutido, então
/// embutir um segredo seria só fingir que há confidência. O PKCE S256 ocupa o
/// lugar dele.
///
/// **Redirect por loopback.** O Zoom não aceita esquema próprio fora do
/// Meeting SDK, então o retorno vem em `http://127.0.0.1:53720/oauth2redirect`
/// e quem escuta é o `LoopbackRedirectListener`. Esse endereço tem de estar
/// cadastrado como OAuth Redirect URL **e** na allow list do aplicativo no
/// Marketplace, caractere por caractere.
@MainActor
public final class ZoomConnector: MeetingConnector {
    public let service: MeetingService = .zoom

    /// Um escopo só: criar reunião. Pedir mais do que se usa é pedir à pessoa
    /// que confie no app para algo que ele não faz.
    public static let scopes = ["meeting:write:meeting"]

    private let clientID: String?
    private let session: URLSession
    private let vault: MeetingTokenVault
    private let browser: any SystemBrowserOpening
    private let loopback: LoopbackEndpoint
    private let apiBase: URL
    private let engine: MeetingOAuthEngine
    private let config: MeetingOAuthConfig

    private var listener: LoopbackRedirectListener?

    public init(
        clientID: String? = MeetingClientIDs.clientID(for: .zoom),
        session: URLSession = .shared,
        vault: MeetingTokenVault,
        browser: any SystemBrowserOpening = AppKitBrowserOpener(),
        loopback: LoopbackEndpoint = .standard,
        apiBase: URL = URL(string: "https://api.zoom.us/v2/")!,
        authorizationEndpoint: URL = URL(string: "https://zoom.us/oauth/authorize")!,
        tokenEndpoint: URL = URL(string: "https://zoom.us/oauth/token")!,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.clientID = clientID?.nonEmptyValue
        self.session = session
        self.vault = vault
        self.browser = browser
        self.loopback = loopback
        self.apiBase = apiBase
        self.config = MeetingOAuthConfig(
            service: .zoom,
            clientID: self.clientID ?? "",
            clientSecret: nil,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            redirectURI: loopback.redirectURI,
            scopes: ZoomConnector.scopes
        )
        self.engine = MeetingOAuthEngine(
            config: self.config, session: session, vault: vault, now: now
        )
    }

    /// Sem client ID no build não há OAuth nenhum, e a linha diz isso em vez
    /// de oferecer um botão que só pode falhar. Segredo **não** entra na
    /// conta: cliente público não tem.
    public var isAvailable: Bool { clientID != nil }

    public func currentAccount() async -> String? {
        vault.load(.zoom)?.account
    }

    public func connect() async throws -> String {
        guard clientID != nil else { throw MeetingConnectorError.missingClientID(.zoom) }

        let escuta = loopback.make()
        // Subir a escuta **antes** de abrir o navegador: se a porta estiver
        // ocupada, é melhor a pessoa ler o erro sem uma aba aberta à toa.
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
                L10n.tr("Não foi possível abrir o navegador para o login do Zoom.")
            )
        }

        let retorno = try await escuta.wait()
        let callback = try MeetingOAuthCallback.read(
            retorno, expectedState: state, service: .zoom
        )
        var tokens = try await engine.exchange(code: callback.code, verifier: pkce.verifier)
        tokens.account = await fetchAccount(accessToken: tokens.accessToken)
        try await engine.store(tokens)
        return tokens.account ?? L10n.tr("conta Zoom")
    }

    public func cancel() {
        listener?.cancel()
        listener = nil
    }

    public func disconnect() async {
        vault.clear(.zoom)
    }

    /// O que a fábrica de salas usa para mintar. Vale mesmo depois de a janela
    /// de Ajustes fechar: o motor nasce do cofre, não da sessão de login.
    public var tokenSource: MeetingTokenSource {
        MeetingTokenSource(service: .zoom, vault: vault, engine: engine)
    }

    /// O e-mail da conta, quando o escopo concedido permite ler. Quando não
    /// permite, o chamador cai para "conta Zoom": a linha da aba Agendas só
    /// precisa dizer que está conectado.
    private func fetchAccount(accessToken: String) async -> String? {
        var request = URLRequest(url: URL(string: "users/me", relativeTo: apiBase)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (dados, resposta) = try? await session.data(for: request),
              let http = resposta as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        struct Wire: Decodable { let email: String? }
        return (try? JSONDecoder().decode(Wire.self, from: dados))?.email?.nonEmptyValue
    }
}

/// Onde o redirect do loopback é escutado, e como abrir essa escuta.
///
/// Um tipo, e não dois parâmetros soltos, porque `redirectURI` e a escuta
/// **têm** de concordar: o serviço compara o `redirect_uri` da autorização com
/// o da troca do código, e um desencontro de porta dá
/// `redirect_uri_mismatch`, que é o erro mais difícil de ler do OAuth. Aqui os
/// dois nascem do mesmo par porta/caminho.
public struct LoopbackEndpoint: Sendable {
    public let port: UInt16
    public let path: String
    private let factory: @Sendable (UInt16, String) -> LoopbackRedirectListener

    public init(
        port: UInt16 = LoopbackRedirectListener.defaultPort,
        path: String = LoopbackRedirectListener.defaultPath,
        factory: @Sendable @escaping (UInt16, String) -> LoopbackRedirectListener = {
            LoopbackRedirectListener(port: $0, path: $1)
        }
    ) {
        self.port = port
        self.path = path
        self.factory = factory
    }

    public static let standard = LoopbackEndpoint()

    public var redirectURI: String { "http://127.0.0.1:\(port)\(path)" }

    public func make() -> LoopbackRedirectListener { factory(port, path) }
}

extension String {
    /// Vazio e `$(VAR)` não substituído contam como ausente — é o que um
    /// `xcconfig` sem valor deixa no `Info.plist`.
    var nonEmptyValue: String? {
        let limpo = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty, !limpo.hasPrefix("$(") else { return nil }
        return limpo
    }
}
