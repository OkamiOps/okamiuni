import Foundation

public enum LiteLLMOAuthError: Error, Sendable, Equatable, LocalizedError {
    case invalidEndpoint
    case insecureEndpoint
    case discoveryUnavailable
    case unsupportedContract
    case issuerMismatch
    case crossOriginEndpoint
    case redirectRefused
    case registrationFailed
    case authorizationDenied(String?)
    case stateMismatch
    case missingAuthorizationCode
    case invalidTokenResponse
    case missingSession
    case browserUnavailable
    case callbackUnavailable
    case timedOut
    case server(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "O endereço do LiteLLM é inválido."
        case .insecureEndpoint:
            "OAuth do LiteLLM exige HTTPS; HTTP é aceito somente em localhost."
        case .discoveryUnavailable:
            "Este LiteLLM não publicou o contrato de login OAuth para clientes nativos."
        case .unsupportedContract:
            "Este LiteLLM usa uma versão ou modalidade de OAuth que o OkamiUNI não suporta."
        case .issuerMismatch:
            "O emissor OAuth não corresponde ao endereço do LiteLLM informado."
        case .crossOriginEndpoint:
            "O LiteLLM anunciou uma rota OAuth em outro domínio; o login foi interrompido."
        case .redirectRefused:
            "Uma rota sensível do OAuth tentou redirecionar a requisição; o login foi interrompido."
        case .registrationFailed:
            "O LiteLLM não registrou o OkamiUNI como cliente OAuth público."
        case let .authorizationDenied(detail):
            detail?.isEmpty == false ? "O login foi recusado: \(detail!)." : "O login foi recusado."
        case .stateMismatch:
            "A resposta OAuth não pertence a este login. Tente novamente."
        case .missingAuthorizationCode:
            "O LiteLLM voltou do navegador sem o código de autorização."
        case .invalidTokenResponse:
            "O LiteLLM devolveu uma sessão OAuth incompleta ou inválida."
        case .missingSession:
            "Entre com OAuth no LiteLLM antes de usar este provedor."
        case .browserUnavailable:
            "Não foi possível abrir o navegador do sistema para o login."
        case .callbackUnavailable:
            "Não foi possível abrir o retorno local seguro do OAuth."
        case .timedOut:
            "O login OAuth demorou demais. Tente novamente."
        case let .server(statusCode):
            "O LiteLLM respondeu com erro \(statusCode) durante o login."
        }
    }
}

public struct LiteLLMOAuthDiscovery: Decodable, Sendable, Hashable {
    public let contractVersion: Int
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL
    public let revocationEndpoint: URL
    public let resource: URL
    public let responseTypesSupported: [String]
    public let grantTypesSupported: [String]
    public let codeChallengeMethodsSupported: [String]
    public let tokenEndpointAuthMethodsSupported: [String]
    public let revocationEndpointAuthMethodsSupported: [String]

    private enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case resource
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case revocationEndpointAuthMethodsSupported = "revocation_endpoint_auth_methods_supported"
    }
}

public protocol LiteLLMOAuthHTTPTransport: Sendable {
    func data(for request: URLRequest, rejectingRedirects: Bool) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionLiteLLMOAuthHTTPTransport: LiteLLMOAuthHTTPTransport, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(
        for request: URLRequest,
        rejectingRedirects: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let activeSession: URLSession
        if rejectingRedirects {
            activeSession = URLSession(
                configuration: .ephemeral,
                delegate: LiteLLMNoRedirectDelegate.shared,
                delegateQueue: nil
            )
        } else {
            activeSession = session
        }
        defer { if rejectingRedirects { activeSession.finishTasksAndInvalidate() } }

        let (data, response) = try await activeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LiteLLMOAuthError.discoveryUnavailable
        }
        return (data, http)
    }
}

private final class LiteLLMNoRedirectDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    static let shared = LiteLLMNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Cliente estrito do contrato nativo publicado em
/// `/.well-known/litellm-cli-auth`. Ele nunca segue redirect nas rotas que
/// recebem código, verifier ou refresh token e só aceita endpoints na mesma
/// origem do proxy informado pela pessoa.
public struct LiteLLMOAuthClient: Sendable {
    private let transport: any LiteLLMOAuthHTTPTransport
    private let now: @Sendable () -> Date

    public init(
        transport: any LiteLLMOAuthHTTPTransport = URLSessionLiteLLMOAuthHTTPTransport(),
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    public func discover(endpoint: URL) async throws -> LiteLLMOAuthDiscovery {
        let base = try Self.proxyBaseURL(from: endpoint)
        let discoveryURL = try Self.discoveryURL(for: base)
        var request = URLRequest(url: discoveryURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
        if (300..<400).contains(response.statusCode) { throw LiteLLMOAuthError.redirectRefused }
        guard (200..<300).contains(response.statusCode), data.count <= 1_048_576 else {
            throw LiteLLMOAuthError.discoveryUnavailable
        }
        guard let discovery = try? JSONDecoder().decode(LiteLLMOAuthDiscovery.self, from: data) else {
            throw LiteLLMOAuthError.discoveryUnavailable
        }
        try Self.validate(discovery: discovery, base: base)
        return discovery
    }

    public func register(
        discovery: LiteLLMOAuthDiscovery,
        redirectURI: URL
    ) async throws -> String {
        guard Self.isLoopbackCallback(redirectURI) else {
            throw LiteLLMOAuthError.callbackUnavailable
        }
        struct Body: Encodable {
            let client_name = "OkamiUNI"
            let redirect_uris: [String]
            let token_endpoint_auth_method = "none"
            let grant_types = ["authorization_code", "refresh_token"]
            let response_types = ["code"]
        }
        struct Wire: Decodable {
            let client_id: String
            let token_endpoint_auth_method: String?
            let redirect_uris: [String]?
        }

        var request = URLRequest(url: discovery.registrationEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(redirect_uris: [redirectURI.absoluteString]))

        let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
        try Self.requireSuccess(response)
        guard data.count <= 1_048_576,
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              !wire.client_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              wire.token_endpoint_auth_method == nil || wire.token_endpoint_auth_method == "none",
              wire.redirect_uris == nil || wire.redirect_uris?.contains(redirectURI.absoluteString) == true
        else {
            throw LiteLLMOAuthError.registrationFailed
        }
        return wire.client_id
    }

    public func authorizationURL(
        discovery: LiteLLMOAuthDiscovery,
        clientID: String,
        redirectURI: URL,
        pkce: PKCEPair,
        state: String
    ) throws -> URL {
        guard Self.isLoopbackCallback(redirectURI),
              var components = URLComponents(
                url: discovery.authorizationEndpoint,
                resolvingAgainstBaseURL: false
              )
        else {
            throw LiteLLMOAuthError.callbackUnavailable
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: discovery.resource.absoluteString),
        ]
        guard let url = components.url else { throw LiteLLMOAuthError.invalidEndpoint }
        return url
    }

    public func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw LiteLLMOAuthError.missingAuthorizationCode
        }
        let values = Dictionary(
            components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        guard values["state"] == expectedState else { throw LiteLLMOAuthError.stateMismatch }
        if let error = values["error"] {
            throw LiteLLMOAuthError.authorizationDenied(values["error_description"] ?? error)
        }
        guard let code = values["code"], !code.isEmpty else {
            throw LiteLLMOAuthError.missingAuthorizationCode
        }
        return code
    }

    public func exchange(
        code: String,
        discovery: LiteLLMOAuthDiscovery,
        clientID: String,
        redirectURI: URL,
        verifier: String
    ) async throws -> LiteLLMOAuthSession {
        try await token(
            discovery: discovery,
            clientID: clientID,
            fields: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI.absoluteString,
                "client_id": clientID,
                "code_verifier": verifier,
                "resource": discovery.resource.absoluteString,
            ]
        )
    }

    public func refresh(_ session: LiteLLMOAuthSession) async throws -> LiteLLMOAuthSession {
        let discovery = LiteLLMOAuthDiscovery(
            contractVersion: 1,
            issuer: session.issuer,
            authorizationEndpoint: session.issuer,
            tokenEndpoint: session.tokenEndpoint,
            registrationEndpoint: session.issuer,
            revocationEndpoint: session.revocationEndpoint,
            resource: session.resource,
            responseTypesSupported: ["code"],
            grantTypesSupported: ["authorization_code", "refresh_token"],
            codeChallengeMethodsSupported: ["S256"],
            tokenEndpointAuthMethodsSupported: ["none"],
            revocationEndpointAuthMethodsSupported: ["none"]
        )
        return try await token(
            discovery: discovery,
            clientID: session.clientID,
            fields: [
                "grant_type": "refresh_token",
                "refresh_token": session.refreshToken,
                "client_id": session.clientID,
                "resource": session.resource.absoluteString,
            ]
        )
    }

    public func revoke(_ session: LiteLLMOAuthSession) async throws {
        var request = URLRequest(url: session.revocationEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form([
            "token": session.refreshToken,
            "client_id": session.clientID,
        ]).utf8)
        let (_, response) = try await transport.data(for: request, rejectingRedirects: true)
        try Self.requireSuccess(response)
    }

    private func token(
        discovery: LiteLLMOAuthDiscovery,
        clientID: String,
        fields: [String: String]
    ) async throws -> LiteLLMOAuthSession {
        struct Wire: Decodable {
            let access_token: String
            let token_type: String?
            let expires_in: Double
            let refresh_token: String
            let user_id: String?
            let team_id: String?
        }

        var request = URLRequest(url: discovery.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(fields).utf8)

        let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
        try Self.requireSuccess(response)
        guard data.count <= 1_048_576,
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              !wire.access_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !wire.refresh_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              wire.expires_in > 0,
              wire.token_type?.lowercased() ?? "bearer" == "bearer"
        else {
            throw LiteLLMOAuthError.invalidTokenResponse
        }
        return LiteLLMOAuthSession(
            accessToken: wire.access_token,
            refreshToken: wire.refresh_token,
            expiresAt: now().addingTimeInterval(wire.expires_in),
            clientID: clientID,
            issuer: discovery.issuer,
            tokenEndpoint: discovery.tokenEndpoint,
            revocationEndpoint: discovery.revocationEndpoint,
            resource: discovery.resource,
            userID: wire.user_id,
            teamID: wire.team_id
        )
    }

    public static func proxyBaseURL(from endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw LiteLLMOAuthError.invalidEndpoint
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw LiteLLMOAuthError.insecureEndpoint
        }
        var parts = components.path.split(separator: "/").map(String.init)
        if parts.suffix(3).map({ $0.lowercased() }) == ["v1", "chat", "completions"] {
            parts.removeLast(3)
        } else if parts.last?.lowercased() == "v1" {
            parts.removeLast()
        }
        components.scheme = scheme
        components.host = host
        components.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        guard let url = components.url else { throw LiteLLMOAuthError.invalidEndpoint }
        return url
    }

    /// Vincula a sessão ao proxy que a emitiu antes que o bearer seja
    /// devolvido ao roteador. Um `credentialID` reaproveitado para outro host
    /// não pode fazer o token atravessar essa fronteira.
    public static func session(
        _ session: LiteLLMOAuthSession,
        belongsTo endpoint: URL
    ) -> Bool {
        guard let base = try? proxyBaseURL(from: endpoint) else { return false }
        return normalizedIdentity(session.issuer) == normalizedIdentity(base)
            && sameOrigin(session.tokenEndpoint, base)
            && sameOrigin(session.revocationEndpoint, base)
            && sameOrigin(session.resource, base)
    }

    private static func discoveryURL(for base: URL) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw LiteLLMOAuthError.invalidEndpoint
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/.well-known/litellm-cli-auth"
        guard let url = components.url else { throw LiteLLMOAuthError.invalidEndpoint }
        return url
    }

    private static func validate(discovery: LiteLLMOAuthDiscovery, base: URL) throws {
        guard discovery.contractVersion == 1,
              discovery.responseTypesSupported.contains("code"),
              discovery.grantTypesSupported.contains("authorization_code"),
              discovery.grantTypesSupported.contains("refresh_token"),
              discovery.codeChallengeMethodsSupported.contains("S256"),
              discovery.tokenEndpointAuthMethodsSupported.contains("none"),
              discovery.revocationEndpointAuthMethodsSupported.contains("none")
        else {
            throw LiteLLMOAuthError.unsupportedContract
        }
        guard normalizedIdentity(discovery.issuer) == normalizedIdentity(base) else {
            throw LiteLLMOAuthError.issuerMismatch
        }
        for url in [
            discovery.authorizationEndpoint,
            discovery.tokenEndpoint,
            discovery.registrationEndpoint,
            discovery.revocationEndpoint,
            discovery.resource,
        ] {
            guard sameOrigin(url, base),
                  url.user == nil,
                  url.password == nil,
                  url.fragment == nil
            else {
                throw LiteLLMOAuthError.crossOriginEndpoint
            }
        }
    }

    private static func requireSuccess(_ response: HTTPURLResponse) throws {
        if (300..<400).contains(response.statusCode) { throw LiteLLMOAuthError.redirectRefused }
        guard (200..<300).contains(response.statusCode) else {
            throw LiteLLMOAuthError.server(statusCode: response.statusCode)
        }
    }

    private static func normalizedIdentity(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ""
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return (components.string ?? "").lowercased()
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private static func isLoopbackCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              url.port != nil,
              url.path == "/callback",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return false }
        return true
    }

    private static let formCharacters: CharacterSet = {
        var result = CharacterSet.alphanumerics
        result.insert(charactersIn: "-._~")
        return result
    }()

    private static func form(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: formCharacters) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: formCharacters) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}
