import Foundation

public struct GoogleAuthConfig: Sendable, Hashable {
    public let clientID: String
    /// O "segredo" do client de app desktop, exigido pelo Google na troca do
    /// código e na renovação — sem ele o token endpoint responde
    /// `400 client_secret is missing` mesmo com PKCE correto. Não é segredo
    /// de verdade (o RFC 8252 e a própria doc do Google assumem que app
    /// instalado não guarda confidência), mas é obrigatório. `nil` é legítimo:
    /// clients antigos do tipo certo podem não tê-lo.
    public let clientSecret: String?
    /// Esquema próprio de app desktop. O `Info.plist` registra o esquema em
    /// `CFBundleURLTypes`; sem esse registro o macOS não devolve o redirect.
    public let redirectURI: String
    /// Só o esquema, que é o que `ASWebAuthenticationSession` quer.
    public let callbackScheme: String
    public let scopes: [String]
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL

    /// Os dois pedidos **juntos**, no primeiro consentimento.
    ///
    /// **`mail.google.com`, e não `gmail.modify` + `gmail.send`.** O par
    /// anterior não cobria o Marco 3 inteiro: `messages.batchDelete` — o
    /// apagamento definitivo, que "apagar de vez" e "esvaziar a lixeira"
    /// pedem — exige o escopo total, e recusa `gmail.modify` com 403. Uma
    /// conta autorizada com o par antigo veria a fila parar na primeira
    /// operação de apagar definitivo, sem nada que a pessoa pudesse fazer
    /// além de adivinhar.
    ///
    /// `mail.google.com` é superconjunto de `modify` + `send`, então um
    /// escopo só cobre ler, triar, apagar e enviar — o marco todo, uma tela
    /// de consentimento só. Quem já autorizou com o par antigo **reconecta
    /// uma vez**; é o preço, e a mensagem do 403 diz exatamente isso em vez
    /// de falar em revogação (ver `SyncError.autorizacaoRevogada`).
    public static let defaultScopes = [
        "https://mail.google.com/",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    /// O esquema que o Google de fato aceita para client de app desktop.
    ///
    /// O `redirect_uri_mismatch` do mundo real ensinou: um client *Desktop* do
    /// Google **não** aceita esquema custom arbitrário (o nosso
    /// `com.okamiops.okamiuni:/oauth` era recusado na tela de consentimento).
    /// O que ele aceita é o esquema derivado do próprio client ID — o
    /// "reverso": `com.googleusercontent.apps.<id-sem-sufixo>`. Derivar aqui
    /// significa que funciona para o client de QUALQUER pessoa, sem registrar
    /// nada além do próprio client: o esquema nasce do ID.
    public static func reversedScheme(forClientID clientID: String) -> String {
        let semSufixo = clientID.hasSuffix(".apps.googleusercontent.com")
            ? String(clientID.dropLast(".apps.googleusercontent.com".count))
            : clientID
        return "com.googleusercontent.apps.\(semSufixo)"
    }

    public init(
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: String? = nil,
        callbackScheme: String? = nil,
        scopes: [String] = GoogleAuthConfig.defaultScopes,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        revocationEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        let esquema = callbackScheme ?? Self.reversedScheme(forClientID: clientID)
        self.redirectURI = redirectURI ?? "\(esquema):/oauth"
        self.callbackScheme = esquema
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
        let segredoBruto = bundle.object(forInfoDictionaryKey: "OkamiUNIGoogleClientSecret") as? String
        let segredo = (segredoBruto ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let segredoValido = (segredo.isEmpty || segredo.hasPrefix("$(")) ? nil : segredo
        return GoogleAuthConfig(clientID: limpo, clientSecret: segredoValido)
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
