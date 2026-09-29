import Foundation
import Testing
@testable import UNISync

@Suite("Catálogo vivo dos provedores OAuth")
struct AssistantProviderOAuthModelCatalogTests {
    @Test("Codex exige a conta vinculada ao token antes de consultar a API")
    func requiresCodexAccountID() async {
        let transport = ModelCatalogTransport { request in
            (Data(), Self.response(for: request, status: 500))
        }
        let catalog = AssistantProviderOAuthModelCatalog(transport: transport)

        await #expect(throws: AssistantProviderOAuthModelCatalogError.missingAuthorization) {
            _ = try await catalog.models(
                configuration: .init(kind: .codex),
                accessToken: "never-sent-to-okamiuni"
            )
        }
        #expect(transport.requests().isEmpty)
    }

    @Test("Codex mostra somente os modelos retornados pela API autenticada")
    func loadsRemoteCodexCatalogWithoutFallback() async throws {
        let transport = ModelCatalogTransport { request in
            let data = Data(#"{"models":[{"slug":"remote-account-new","display_name":"Modelo novo da conta","visibility":"list"},{"slug":"hidden-account-model","visibility":"hide"},{"slug":"remote-account-new","visibility":"list"}]}"#.utf8)
            return (data, Self.response(for: request, status: 200))
        }
        let catalog = AssistantProviderOAuthModelCatalog(transport: transport)
        let models = try await catalog.models(
            configuration: .init(kind: .codex), accessToken: "test-access-token", accountID: "test-account"
        )
        #expect(models == [.init(id: "remote-account-new", displayName: "Modelo novo da conta")])
        let request = try #require(transport.requests().first)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/models?client_version=\(AssistantProviderOAuthClient.codexProtocolVersion)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "test-account")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(transport.redirectPolicies() == [true])
    }

    @Test("401 e 403 Codex são falhas de sessão e elegibilidade, sem lista substituta", arguments: [401, 403])
    func rejectsCodexAuthorizationFailure(status: Int) async {
        let transport = ModelCatalogTransport { request in
            (Data(#"{"models":[{"slug":"must-not-appear"}]}"#.utf8), Self.response(for: request, status: status))
        }
        let catalog = AssistantProviderOAuthModelCatalog(transport: transport)
        let expected: AssistantProviderOAuthModelCatalogError = status == 401 ? .authenticationFailed : .subscriptionNotEligible
        await #expect(throws: expected) {
            _ = try await catalog.models(configuration: .init(kind: .codex), accessToken: "test-token", accountID: "test-account")
        }
        #expect(transport.requests().count == 1)
    }

    @Test("Catálogo Codex vazio não inventa modelos")
    func refusesEmptyCodexCatalog() async {
        let transport = ModelCatalogTransport { request in
            (Data(#"{"models":[]}"#.utf8), Self.response(for: request, status: 200))
        }
        let catalog = AssistantProviderOAuthModelCatalog(transport: transport)
        await #expect(throws: AssistantProviderOAuthModelCatalogError.emptyCatalog) {
            _ = try await catalog.models(configuration: .init(kind: .codex), accessToken: "test-token", accountID: "test-account")
        }
    }

    @Test("xAI usa a API direta e preserva somente headers verdadeiros do OkamiUNI")
    func loadsXAISubscriptionCatalogFromDirectAPI() async throws {
        let transport = ModelCatalogTransport { request in
            let data = Data(#"""
            {
              "models": [
                {"id":" grok-account-default ","name":"Grok da conta"},
                {"id":"grok-account-default","name":"Duplicado"},
                {"id":"grok-interno","visibility":"hidden"},
                {"id":"grok-oculto","visibility":"hide"},
                {"id":"grok-reasoning","display_name":"Grok Raciocínio"},
                {"id":"   "}
              ]
            }
            """#.utf8)
            return (data, Self.response(for: request, status: 200))
        }
        let catalog = AssistantProviderOAuthModelCatalog(
            transport: transport,
            clientVersion: "1.2.3"
        )

        let models = try await catalog.models(
            configuration: .init(kind: .xAI),
            accessToken: "xai-oauth-session"
        )

        #expect(models.map(\.id) == ["grok-account-default", "grok-reasoning"])
        #expect(models[0].displayName == "Grok da conta")
        #expect(models[1].displayName == "Grok Raciocínio")
        let request = try #require(transport.requests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/language-models")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xai-oauth-session")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "OkamiUNI/1.2.3")
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(headerNames == Set(["accept", "authorization", "user-agent"]))
        #expect(transport.redirectPolicies() == [true])
    }

    @Test("Catálogo nunca segue redirect com o bearer")
    func refusesCatalogRedirect() async {
        let transport = ModelCatalogTransport { request in
            (Data(), Self.response(for: request, status: 302))
        }
        let catalog = AssistantProviderOAuthModelCatalog(transport: transport)

        await #expect(throws: AssistantProviderOAuthModelCatalogError.redirectRefused) {
            _ = try await catalog.models(
                configuration: .init(kind: .xAI),
                accessToken: "xai-oauth-session"
            )
        }
        #expect(transport.redirectPolicies() == [true])
    }

    @Test("426 explica que o OkamiUNI precisa ser atualizado")
    func reportsActionableUpgradeRequirement() async {
        let transport = ModelCatalogTransport { request in
            (Data(), Self.response(for: request, status: 426))
        }
        let catalog = AssistantProviderOAuthModelCatalog(transport: transport)

        await #expect(throws: AssistantProviderOAuthModelCatalogError.upgradeRequired) {
            _ = try await catalog.models(
                configuration: .init(kind: .xAI),
                accessToken: "xai-oauth-session"
            )
        }
        #expect(
            AssistantProviderOAuthModelCatalogError.upgradeRequired.errorDescription
                == "O provedor exige uma atualização do protocolo/cliente. Atualize o OkamiUNI e tente novamente."
        )
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private final class ModelCatalogTransport:
    AssistantProviderOAuthHTTPTransport, @unchecked Sendable {

    typealias Handler = @Sendable (URLRequest) -> (Data, HTTPURLResponse)

    private let lock = NSLock()
    private let handler: Handler
    private var captured: [URLRequest] = []
    private var policies: [Bool] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(
        for request: URLRequest,
        rejectingRedirects: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            captured.append(request)
            policies.append(rejectingRedirects)
        }
        return handler(request)
    }

    func requests() -> [URLRequest] { lock.withLock { captured } }
    func redirectPolicies() -> [Bool] { lock.withLock { policies } }
}
