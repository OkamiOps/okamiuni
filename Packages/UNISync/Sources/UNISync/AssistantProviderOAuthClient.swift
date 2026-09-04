import UNICore
import Foundation

/// Erros estáveis do OAuth. Nenhum caso incorpora tokens, device codes,
/// respostas remotas ou conteúdo de e-mail em uma mensagem exibível.
public enum AssistantProviderOAuthError: Error, Sendable, Equatable, LocalizedError {
    case invalidDiscovery, redirectRefused, deviceAuthorizationUnavailable
    case invalidDeviceAuthorization, authorizationExpired, authorizationDenied
    case invalidTokenResponse, missingSession, sessionProviderMismatch
    case rateLimited, timedOut, server(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDiscovery: L10n.tr("O provedor publicou uma rota OAuth inesperada; o login foi interrompido por segurança.")
        case .redirectRefused: L10n.tr("Uma rota OAuth tentou redirecionar a requisição; o login foi interrompido.")
        case .deviceAuthorizationUnavailable: L10n.tr("Não foi possível iniciar o login OAuth da assinatura. Tente novamente em instantes.")
        case .invalidDeviceAuthorization: L10n.tr("O provedor devolveu um código de login inválido. Tente novamente.")
        case .authorizationExpired: L10n.tr("O código de login expirou. Gere um novo código e tente novamente.")
        case .authorizationDenied: L10n.tr("O login OAuth foi recusado ou a assinatura não é elegível para este acesso.")
        case .invalidTokenResponse: L10n.tr("O provedor devolveu uma sessão OAuth incompleta. Tente entrar novamente.")
        case .missingSession: L10n.tr("Conecte a assinatura do provedor antes de usar esta IA.")
        case .sessionProviderMismatch: L10n.tr("A sessão OAuth guardada pertence a outro provedor e não será reutilizada.")
        case .rateLimited: L10n.tr("O provedor pediu para desacelerar. Tente entrar novamente em instantes.")
        case .timedOut: L10n.tr("O login OAuth demorou demais. Gere um novo código e tente novamente.")
        case let .server(statusCode): L10n.tr("O provedor respondeu com erro \(statusCode) durante o login OAuth.")
        }
    }
}

/// O único estado seguro levado à interface durante device auth. O segredo de
/// polling fica exclusivamente na estrutura efêmera abaixo.
public struct AssistantProviderOAuthDeviceAuthorization: Sendable, Hashable {
    public let kind: AssistantProviderOAuthKind
    public let verificationURL: URL
    public let userCode: String
    public let expiresAt: Date
    public let pollInterval: TimeInterval

    public init(kind: AssistantProviderOAuthKind, verificationURL: URL, userCode: String, expiresAt: Date, pollInterval: TimeInterval) {
        self.kind = kind
        self.verificationURL = verificationURL
        self.userCode = userCode
        self.expiresAt = expiresAt
        self.pollInterval = pollInterval
    }
}

public protocol AssistantProviderOAuthHTTPTransport: Sendable {
    func data(for request: URLRequest, rejectingRedirects: Bool) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAssistantProviderOAuthHTTPTransport: AssistantProviderOAuthHTTPTransport, Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest, rejectingRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let active: URLSession
        if rejectingRedirects {
            // Preserve the caller's protocol classes and additional headers.
            // Besides keeping injected test sessions isolated, this avoids
            // changing the caller's network configuration just to refuse a
            // redirect that could otherwise receive the bearer credential.
            let configuration = session.configuration
            active = URLSession(configuration: configuration, delegate: AssistantProviderOAuthNoRedirectDelegate.shared, delegateQueue: nil)
        } else {
            active = session
        }
        defer { if rejectingRedirects { active.finishTasksAndInvalidate() } }
        let (data, raw) = try await active.data(for: request)
        guard let response = raw as? HTTPURLResponse else { throw AssistantProviderOAuthError.deviceAuthorizationUnavailable }
        return (data, response)
    }
}

private final class AssistantProviderOAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = AssistantProviderOAuthNoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Contexto interno do device grant xAI. Codex não aparece aqui: o runtime
/// oficial retém seu próprio segredo e persiste sua própria sessão.
struct AssistantProviderOAuthPendingAuthorization: Sendable {
    let presentation: AssistantProviderOAuthDeviceAuthorization
    let deviceCode: String
    let tokenEndpoint: URL
}

enum AssistantProviderOAuthPollResult: Sendable {
    case pending(nextInterval: TimeInterval)
    case completed(AssistantProviderOAuthSession)
}

/// OAuth direto é mantido somente para xAI. A ramificação Codex utiliza o
/// app-server/CLI oficial; por isso não há endpoint ou client ID Codex neste
/// módulo e o OkamiUNI nunca recebe as credenciais ChatGPT.
public struct AssistantProviderOAuthClient: Sendable {
    static let xAIClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let xAIScope = "openid profile email offline_access grok-cli:access api:access"
    static let xAIResponsesURL = URL(string: "https://api.x.ai/v1/responses")!

    private static let xAIAuthority = URL(string: "https://auth.x.ai")!
    private static let xAIDiscoveryURL = URL(string: "https://auth.x.ai/.well-known/openid-configuration")!
    private let transport: any AssistantProviderOAuthHTTPTransport
    private let now: @Sendable () -> Date

    public init(transport: any AssistantProviderOAuthHTTPTransport = URLSessionAssistantProviderOAuthHTTPTransport(), now: @Sendable @escaping () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    func begin(configuration: AssistantProviderOAuthConfiguration) async throws -> AssistantProviderOAuthPendingAuthorization {
        guard try configuration.validatedForAuthorization().kind == .xAI else { throw AssistantProviderOAuthError.missingSession }
        let discovery = try await xAIDiscovery()
        let endpoint = discovery.deviceAuthorizationEndpoint ?? Self.xAIAuthority.appending(path: "/oauth2/device/code")
        guard Self.isAllowed(endpoint, host: "auth.x.ai") else { throw AssistantProviderOAuthError.invalidDiscovery }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["client_id": Self.xAIClientID, "scope": Self.xAIScope])
        let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
        if (300..<400).contains(response.statusCode) { throw AssistantProviderOAuthError.redirectRefused }
        if response.statusCode == 429 { throw AssistantProviderOAuthError.rateLimited }
        guard (200..<300).contains(response.statusCode), data.count <= 65_536,
              let wire = try? JSONDecoder().decode(XAIDeviceCodeResponse.self, from: data),
              let deviceCode = Self.nonEmpty(wire.deviceCode), let userCode = Self.nonEmpty(wire.userCode),
              let verificationURL = wire.verificationURL, Self.isAllowedXAIVerificationURL(verificationURL)
        else { throw AssistantProviderOAuthError.deviceAuthorizationUnavailable }
        return .init(
            presentation: .init(kind: .xAI, verificationURL: wire.verificationURLComplete.flatMap { Self.isAllowedXAIVerificationURL($0) ? $0 : nil } ?? verificationURL, userCode: userCode, expiresAt: Self.expiry(expiresAt: wire.expiresAt, expiresIn: wire.expiresIn, now: now), pollInterval: max(1, TimeInterval(wire.interval?.value ?? 5))),
            deviceCode: deviceCode,
            tokenEndpoint: discovery.tokenEndpoint
        )
    }

    func poll(_ pending: AssistantProviderOAuthPendingAuthorization, interval: TimeInterval) async throws -> AssistantProviderOAuthPollResult {
        guard pending.presentation.expiresAt > now() else { throw AssistantProviderOAuthError.authorizationExpired }
        let endpoint = try Self.validatedXAITokenEndpoint(pending.tokenEndpoint)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "client_id": Self.xAIClientID, "device_code": pending.deviceCode])
        let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
        if (300..<400).contains(response.statusCode) { throw AssistantProviderOAuthError.redirectRefused }
        if response.statusCode == 429 { throw AssistantProviderOAuthError.rateLimited }
        if (200..<300).contains(response.statusCode) {
            guard data.count <= 65_536, let token = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data) else { throw AssistantProviderOAuthError.invalidTokenResponse }
            return .completed(try Self.session(response: token, tokenEndpoint: endpoint, fallbackRefreshToken: nil, now: now))
        }
        switch (try? JSONDecoder().decode(OAuthErrorResponse.self, from: data))?.error {
        case "authorization_pending": return .pending(nextInterval: max(1, interval))
        case "slow_down": return .pending(nextInterval: min(max(1, interval) + 1, 30))
        case "expired_token": throw AssistantProviderOAuthError.authorizationExpired
        case "access_denied": throw AssistantProviderOAuthError.authorizationDenied
        default: throw AssistantProviderOAuthError.server(statusCode: response.statusCode)
        }
    }

    public func refresh(_ session: AssistantProviderOAuthSession) async throws -> AssistantProviderOAuthSession {
        guard session.kind == .xAI else { throw AssistantProviderOAuthError.sessionProviderMismatch }
        let endpoint = try Self.validatedXAITokenEndpoint(session.tokenEndpoint)
        let token = try await requestToken(at: endpoint, body: Self.formBody(["grant_type": "refresh_token", "client_id": Self.xAIClientID, "refresh_token": session.refreshToken]))
        return try Self.session(response: token, tokenEndpoint: endpoint, fallbackRefreshToken: session.refreshToken, now: now)
    }

    private func xAIDiscovery() async throws -> XAIProviderDiscovery {
        var request = URLRequest(url: Self.xAIDiscoveryURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
        if (300..<400).contains(response.statusCode) { throw AssistantProviderOAuthError.redirectRefused }
        guard (200..<300).contains(response.statusCode), data.count <= 1_048_576,
              let discovery = try? JSONDecoder().decode(XAIProviderDiscovery.self, from: data),
              Self.isAllowed(discovery.issuer, host: "auth.x.ai"), Self.isAllowed(discovery.tokenEndpoint, host: "auth.x.ai"),
              discovery.deviceAuthorizationEndpoint.map({ Self.isAllowed($0, host: "auth.x.ai") }) ?? true
        else { throw AssistantProviderOAuthError.invalidDiscovery }
        return discovery
    }

    private func requestToken(at endpoint: URL, body: Data) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
        if (300..<400).contains(response.statusCode) { throw AssistantProviderOAuthError.redirectRefused }
        if response.statusCode == 429 { throw AssistantProviderOAuthError.rateLimited }
        guard (200..<300).contains(response.statusCode), data.count <= 65_536,
              let decoded = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        else { throw AssistantProviderOAuthError.server(statusCode: response.statusCode) }
        return decoded
    }

    private static func session(response: OAuthTokenResponse, tokenEndpoint: URL, fallbackRefreshToken: String?, now: @Sendable () -> Date) throws -> AssistantProviderOAuthSession {
        guard let access = nonEmpty(response.accessToken), let refresh = nonEmpty(response.refreshToken) ?? fallbackRefreshToken else { throw AssistantProviderOAuthError.invalidTokenResponse }
        return .init(kind: .xAI, accessToken: access, refreshToken: refresh, expiresAt: now().addingTimeInterval(max(60, TimeInterval(response.expiresIn ?? 3_600))), tokenEndpoint: tokenEndpoint)
    }

    private static func validatedXAITokenEndpoint(_ endpoint: URL) throws -> URL {
        guard isAllowed(endpoint, host: "auth.x.ai") else { throw AssistantProviderOAuthError.sessionProviderMismatch }
        return endpoint
    }

    private static func isAllowed(_ url: URL, host: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == "https", components.host?.lowercased() == host, components.user == nil, components.password == nil, components.fragment == nil, components.query == nil else { return false }
        return true
    }

    private static func isAllowedXAIVerificationURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == "https", components.host?.lowercased() == "accounts.x.ai", components.user == nil, components.password == nil, components.fragment == nil else { return false }
        return true
    }

    private static func expiry(expiresAt: FlexibleEpochSeconds?, expiresIn: FlexibleInteger?, now: @Sendable () -> Date) -> Date {
        expiresAt?.date ?? now().addingTimeInterval(max(60, TimeInterval(expiresIn?.value ?? 900)))
    }

    private static func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let value = values.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(value.utf8)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct XAIProviderDiscovery: Decodable {
    let issuer: URL
    let tokenEndpoint: URL
    let deviceAuthorizationEndpoint: URL?
    enum CodingKeys: String, CodingKey { case issuer; case tokenEndpoint = "token_endpoint"; case deviceAuthorizationEndpoint = "device_authorization_endpoint" }
}

private struct XAIDeviceCodeResponse: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationURL: URL?
    let verificationURLComplete: URL?
    let expiresIn: FlexibleInteger?
    let expiresAt: FlexibleEpochSeconds?
    let interval: FlexibleInteger?
    enum CodingKeys: String, CodingKey { case deviceCode = "device_code"; case userCode = "user_code"; case verificationURL = "verification_uri"; case verificationURLComplete = "verification_uri_complete"; case expiresIn = "expires_in"; case expiresAt = "expires_at"; case interval }
}

private struct FlexibleInteger: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self.value = value; return }
        guard let value = Int(try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected integer") }
        self.value = value
    }
}

private struct FlexibleEpochSeconds: Decodable {
    let date: Date
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(TimeInterval.self), seconds.isFinite { date = Date(timeIntervalSince1970: seconds); return }
        let string = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(string), seconds.isFinite { date = Date(timeIntervalSince1970: seconds); return }
        if let parsed = ISO8601DateFormatter().date(from: string) { date = parsed; return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected timestamp")
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token"; case expiresIn = "expires_in" }
}

private struct OAuthErrorResponse: Decodable { let error: String? }
