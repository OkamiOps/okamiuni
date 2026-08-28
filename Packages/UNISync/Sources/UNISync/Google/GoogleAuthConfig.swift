import Foundation

public struct GoogleAuthConfig: Sendable, Hashable {
    public let clientID: String
    /// Esquema próprio de app desktop. O `Info.plist` registra o esquema em
    /// `CFBundleURLTypes`; sem esse registro o macOS não devolve o redirect.
    public let redirectURI: String
    /// Só o esquema, que é o que `ASWebAuthenticationSession` quer.
    public let callbackScheme: String
    public let scopes: [String]
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL

    /// Os três pedidos **juntos**, no primeiro consentimento.
    ///
    /// `gmail.send` só é usado no Marco 3 e mesmo assim entra aqui: pedi-lo
    /// depois obrigaria o usuário a passar pela tela de consentimento uma
    /// segunda vez, para um app que ele já autorizou.
    public static let defaultScopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    public init(
        clientID: String,
        redirectURI: String = "com.okamiops.okamiuni:/oauth",
        callbackScheme: String = "com.okamiops.okamiuni",
        scopes: [String] = GoogleAuthConfig.defaultScopes,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        revocationEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.callbackScheme = callbackScheme
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
    }

    /// O client ID vem do `Info.plist`, alimentado por `Config/Google.xcconfig`.
    ///
    /// **Nunca hardcoded**: o valor é de quem publica o app, não do código, e
    /// deixar um no repositório amarraria toda instalação a um projeto do
    /// Google Cloud que não é dela.
    ///
    /// Ausente ou vazio lança `.semClientID`, que a janela de Contas mostra
    /// apontando `docs/oauth-google.md`. Falha explicada, não silêncio.
    public static func fromBundle(_ bundle: Bundle) throws -> GoogleAuthConfig {
        let bruto = bundle.object(forInfoDictionaryKey: "OkamiUNIGoogleClientID") as? String
        let limpo = (bruto ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty, !limpo.hasPrefix("$(") else { throw SyncError.semClientID }
        return GoogleAuthConfig(clientID: limpo)
    }

    public func authorizationURL(pkce: PKCEPair, state: String, loginHint: String?) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var itens = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Sem `access_type=offline` o Google não devolve refresh token, e a
            // conta pararia de funcionar uma hora depois sem nada a renovar.
            URLQueryItem(name: "access_type", value: "offline"),
            // `prompt=consent` força o refresh token a vir também quando o
            // usuário já tinha autorizado o app antes — reconectar depois de um
            // erro precisa disso para não voltar sem refresh token.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint { itens.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = itens
        return components.url!
    }
}
