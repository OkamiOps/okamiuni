import Foundation
import Testing
@testable import UNISync

@Suite("OAuth PKCE nativo do LiteLLM")
struct LiteLLMOAuthTests {
    @Test("login valida discovery, state e guarda a sessão sem expor tokens à UI")
    @MainActor
    func connectsAndScopesSessionToProxy() async throws {
        let transport = OAuthStubTransport { request in
            switch request.url?.path {
            case "/.well-known/litellm-cli-auth":
                return Self.response(request, status: 200, json: Self.discovery())
            case "/register":
                return Self.response(request, status: 201, json: [
                    "client_id": "llm_dcrc_okami",
                    "token_endpoint_auth_method": "none",
                    "redirect_uris": ["http://127.0.0.1:53187/callback"],
                ])
            case "/token":
                return Self.response(request, status: 200, json: [
                    "access_token": "access-value",
                    "token_type": "Bearer",
                    "expires_in": 3_600,
                    "refresh_token": "refresh-value",
                    "user_id": "person@example.com",
                    "team_id": "team-a",
                ])
            default:
                return Self.response(request, status: 404, json: [:])
            }
        }
        let store = InMemoryLiteLLMOAuthSessionStore()
        let coordinator = LiteLLMOAuthCoordinator(
            client: LiteLLMOAuthClient(transport: transport),
            sessions: store,
            browserSessions: OAuthStubBrowserFactory()
        )
        let endpoint = URL(string: "https://proxy.example/v1")!

        try await coordinator.start(endpoint: endpoint, credentialID: "proxy-a")

        #expect(coordinator.sessionState.status == .signedIn)
        #expect(await coordinator.hasAccessToken(for: "proxy-a", endpoint: endpoint))
        #expect(try await coordinator.accessToken(for: "proxy-a", endpoint: endpoint) == "access-value")
        #expect(try store.session(for: "proxy-a")?.refreshToken == "refresh-value")

        let anotherProxy = URL(string: "https://other.example/v1")!
        #expect(await coordinator.hasAccessToken(for: "proxy-a", endpoint: anotherProxy) == false)
        await #expect(throws: LiteLLMOAuthError.crossOriginEndpoint) {
            _ = try await coordinator.accessToken(for: "proxy-a", endpoint: anotherProxy)
        }

        let requests = transport.capturedRequests()
        #expect(requests.map({ $0.url?.path }) == [
            "/.well-known/litellm-cli-auth", "/register", "/token",
        ])
        let tokenBody = requests.last?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(tokenBody.contains("grant_type=authorization_code"))
        #expect(tokenBody.contains("code_verifier="))
        #expect(tokenBody.contains("resource=https%3A%2F%2Fproxy.example"))
    }

    @Test("refresh token gira antes do vencimento e o novo par substitui o anterior")
    @MainActor
    func refreshesAtomically() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let transport = OAuthStubTransport { request in
            Self.response(request, status: 200, json: [
                "access_token": "new-access",
                "token_type": "Bearer",
                "expires_in": 7_200,
                "refresh_token": "new-refresh",
            ])
        }
        let store = InMemoryLiteLLMOAuthSessionStore()
        try store.store(
            .init(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expiresAt: now.addingTimeInterval(10),
                clientID: "client",
                issuer: URL(string: "https://proxy.example")!,
                tokenEndpoint: URL(string: "https://proxy.example/token")!,
                revocationEndpoint: URL(string: "https://proxy.example/revoke")!,
                resource: URL(string: "https://proxy.example")!
            ),
            for: "proxy"
        )
        let coordinator = LiteLLMOAuthCoordinator(
            client: LiteLLMOAuthClient(transport: transport, now: { now }),
            sessions: store,
            browserSessions: OAuthStubBrowserFactory(),
            now: { now }
        )
        let endpoint = URL(string: "https://proxy.example/v1")!

        #expect(try await coordinator.accessToken(for: "proxy", endpoint: endpoint) == "new-access")
        #expect(try await coordinator.accessToken(for: "proxy", endpoint: endpoint) == "new-access")
        #expect(try store.session(for: "proxy")?.refreshToken == "new-refresh")
        #expect(transport.capturedRequests().count == 1)
        let body = transport.capturedRequests()[0].httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=old-refresh"))
    }

    @Test("discovery recusa endpoint sensível em outra origem")
    func rejectsCrossOriginDiscovery() async {
        let transport = OAuthStubTransport { request in
            var discovery = Self.discovery()
            discovery["token_endpoint"] = "https://attacker.example/token"
            return Self.response(request, status: 200, json: discovery)
        }
        let client = LiteLLMOAuthClient(transport: transport)

        await #expect(throws: LiteLLMOAuthError.crossOriginEndpoint) {
            _ = try await client.discover(endpoint: URL(string: "https://proxy.example/v1")!)
        }
    }

    @Test("callback exige state exato antes de aceitar o código")
    func rejectsWrongState() {
        let client = LiteLLMOAuthClient(transport: OAuthStubTransport { request in
            Self.response(request, status: 404, json: [:])
        })
        let callback = URL(string: "http://127.0.0.1:53187/callback?code=secret&state=other")!

        #expect(throws: LiteLLMOAuthError.stateMismatch) {
            _ = try client.authorizationCode(from: callback, expectedState: "expected")
        }
    }

    @Test("receptor real usa loopback efêmero e encerra após o callback")
    func receivesLoopbackCallback() async throws {
        let factory = SystemLiteLLMOAuthBrowserSessionFactory(
            opener: OAuthLoopbackTestOpener(), timeout: 30
        )
        let session = try await factory.makeSession()
        #expect(session.redirectURI.host == "127.0.0.1")
        #expect(session.redirectURI.port != nil)
        #expect(session.redirectURI.path == "/callback")

        var authorization = URLComponents(string: "https://proxy.example/authorize")!
        authorization.queryItems = [
            URLQueryItem(name: "redirect_uri", value: session.redirectURI.absoluteString),
            URLQueryItem(name: "state", value: "expected-state"),
        ]
        let callback = try await session.authorize(at: authorization.url!)
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(values.first(where: { $0.name == "code" })?.value == "loopback-code")
        #expect(values.first(where: { $0.name == "state" })?.value == "expected-state")
    }

    private static func discovery() -> [String: Any] {
        [
            "contract_version": 1,
            "issuer": "https://proxy.example",
            "authorization_endpoint": "https://proxy.example/authorize",
            "token_endpoint": "https://proxy.example/token",
            "registration_endpoint": "https://proxy.example/register",
            "revocation_endpoint": "https://proxy.example/revoke",
            "resource": "https://proxy.example",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "revocation_endpoint_auth_methods_supported": ["none"],
        ]
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        json: [String: Any]
    ) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private final class OAuthStubTransport: LiteLLMOAuthHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let responder: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    init(responder: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.responder = responder
    }

    func data(
        for request: URLRequest,
        rejectingRedirects: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        return try responder(request)
    }

    func capturedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }
}

private struct OAuthStubBrowserFactory: LiteLLMOAuthBrowserSessionMaking, Sendable {
    func makeSession() async throws -> any LiteLLMOAuthBrowserSession {
        OAuthStubBrowserSession()
    }
}

private struct OAuthStubBrowserSession: LiteLLMOAuthBrowserSession, Sendable {
    let redirectURI = URL(string: "http://127.0.0.1:53187/callback")!

    func authorize(at url: URL) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value
        var callback = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "state", value: state),
        ]
        return callback.url!
    }
}

private struct OAuthLoopbackTestOpener: LiteLLMSystemBrowserOpening, Sendable {
    func open(_ url: URL) async -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let redirectValue = items.first(where: { $0.name == "redirect_uri" })?.value,
              let redirect = URL(string: redirectValue),
              let state = items.first(where: { $0.name == "state" })?.value,
              var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)
        else { return false }
        var spurious = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        spurious.path = "/not-a-callback"
        guard let spuriousURL = spurious.url else { return false }
        callback.queryItems = [
            URLQueryItem(name: "code", value: "loopback-code"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let callbackURL = callback.url else { return false }
        do {
            let (_, spuriousResponse) = try await URLSession.shared.data(from: spuriousURL)
            guard (spuriousResponse as? HTTPURLResponse)?.statusCode == 400 else {
                return false
            }
            let (_, response) = try await URLSession.shared.data(from: callbackURL)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
