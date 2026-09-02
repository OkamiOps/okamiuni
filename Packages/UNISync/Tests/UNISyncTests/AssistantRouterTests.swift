import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("Router configurável do assistente")
struct AssistantRouterTests {
    @Test("lê um snapshot novo para cada chamada remota")
    @available(macOS 26.0, *)
    func readsSettingsPerCall() async throws {
        let suite = "okamiuni.assistant-router.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settingsStore = AssistantSettingsStore(defaults: defaults, key: "assistant")
        let credentials = InMemoryAssistantCredentialStore()
        try credentials.storeAPIKey("test-key", for: "primary")
        let session = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [
                .json("{\"choices\":[{\"message\":{\"content\":\"primeira\"}}]}"),
                .json("{\"choices\":[{\"message\":{\"content\":\"segunda\"}}]}"),
            ],
        ])
        let router = AssistantRouter(
            settingsStore: settingsStore,
            credentialStore: credentials,
            session: session
        )

        try settingsStore.save(remoteSettings(model: "model-a", instructions: "Use títulos."))
        let first = try await router.answer(question: "Qual é a prioridade?", in: conversation)

        try settingsStore.save(remoteSettings(model: "model-b", instructions: "Use uma frase."))
        let second = try await router.answer(question: "Qual é a prioridade?", in: conversation)

        #expect(first == "primeira")
        #expect(second == "segunda")
        #expect(router.modelVersion == AssistantRouter.currentModelVersion)
        let requests = StubURLProtocol.requests(for: session)
        #expect(requests.count == 2)
        #expect(requests[0].body.contains("model-a"))
        #expect(requests[0].body.contains("Use títulos."))
        #expect(requests[1].body.contains("model-b"))
        #expect(requests[1].body.contains("Use uma frase."))
    }

    @Test("endpoint remoto sem credencial aparece como indisponível")
    @available(macOS 26.0, *)
    func reportsMissingCredentialAsNotReady() async throws {
        let suite = "okamiuni.assistant-router-availability.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settingsStore = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try settingsStore.save(remoteSettings(model: "model", instructions: ""))
        let credentials = InMemoryAssistantCredentialStore()
        let router = AssistantRouter(settingsStore: settingsStore, credentialStore: credentials)

        #expect(await router.availability() == .modelNotReady)
        try credentials.storeAPIKey("test-key", for: "primary")
        #expect(await router.availability() == .available)
    }

    @Test("PKCE recebe o endpoint normalizado junto com a referência da sessão")
    @available(macOS 26.0, *)
    func scopesOAuthSessionToEndpoint() async throws {
        let suite = "okamiuni.assistant-router-oauth-endpoint.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settingsStore = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try settingsStore.save(.init(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://litellm.example/v1/",
                model: "gateway-model",
                credentialID: "litellm-team-a",
                authenticationMode: .litellmOAuthPKCE
            )
        ))
        let provider = EndpointBoundOAuthProvider()
        let session = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [.json("""
            {"choices":[{"message":{"content":"OK"}}]}
            """)],
        ])
        let router = AssistantRouter(
            settingsStore: settingsStore,
            credentialStore: InMemoryAssistantCredentialStore(),
            session: session,
            oauthTokenProvider: provider
        )

        #expect(await router.availability() == .available)
        #expect(try await router.answer(question: "Status?", in: conversation) == "OK")

        let requests = await provider.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.credentialID == "litellm-team-a" })
        #expect(requests.allSatisfy {
            $0.endpoint.absoluteString == "https://litellm.example/v1/chat/completions"
        })
    }

    @Test("aplica opções globais e o prompt específico de cada finalidade")
    @available(macOS 26.0, *)
    func routesPurposeSpecificPreferences() async throws {
        let suite = "okamiuni.assistant-router-purpose.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settingsStore = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try settingsStore.save(.init(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://litellm.example",
                model: "dynamic-model",
                credentialID: "primary"
            ),
            behavior: .init(
                tone: .formal,
                detail: .concise,
                questionsInstructions: "Destaque somente riscos financeiros.",
                writingInstructions: "Use uma saudação curta."
            ),
            additionalInstructions: "Não abrevie nomes de empresas."
        ))
        let credentials = InMemoryAssistantCredentialStore()
        try credentials.storeAPIKey("test-key", for: "primary")
        let session = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [
                .json("{\"choices\":[{\"message\":{\"content\":\"análise\"}}]}"),
                .json("{\"choices\":[{\"message\":{\"content\":\"resposta\"}}]}"),
            ],
        ])
        let router = AssistantRouter(
            settingsStore: settingsStore,
            credentialStore: credentials,
            session: session
        )

        _ = try await router.answer(question: "Quais são os riscos?", in: conversation)
        _ = try await router.transform(
            "Confirmo o recebimento.",
            using: .rewriteForClarity,
            context: nil
        )

        let requests = StubURLProtocol.requests(for: session)
        #expect(requests.count == 2)
        #expect(requests[0].body.contains("linguagem formal"))
        #expect(requests[0].body.contains("riscos financeiros"))
        #expect(!requests[0].body.contains("saudação curta"))
        #expect(requests[1].body.contains("saudação curta"))
        #expect(!requests[1].body.contains("riscos financeiros"))
        #expect(requests.allSatisfy { $0.body.contains("Não abrevie nomes") })
    }

    private func remoteSettings(model: String, instructions: String) -> AssistantSettings {
        AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://litellm.example",
                model: model,
                credentialID: "primary"
            ),
            additionalInstructions: instructions
        )
    }

    private var conversation: AssistantConversationSnapshot {
        .init(mailContext: .email(.init(
            subject: "Planejamento",
            sender: "Marina <marina@example.com>",
            body: "A entrega é sexta-feira."
        )))
    }
}

private actor EndpointBoundOAuthProvider: OpenAICompatibleOAuthTokenProviding {
    struct Request: Sendable {
        let credentialID: String
        let endpoint: URL
    }

    private var captured: [Request] = []

    func hasAccessToken(for credentialID: String, endpoint: URL) async -> Bool {
        captured.append(.init(credentialID: credentialID, endpoint: endpoint))
        return true
    }

    func accessToken(for credentialID: String, endpoint: URL) async throws -> String? {
        captured.append(.init(credentialID: credentialID, endpoint: endpoint))
        return "oauth-test-token"
    }

    func requests() -> [Request] { captured }
}
