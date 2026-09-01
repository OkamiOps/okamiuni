import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("OAuth direto de assinatura do assistente")
struct AssistantProviderOAuthTests {
    @Test("migra preferências v2 sem criar segredo no documento")
    func migratesV2Configuration() throws {
        let data = Data("""
        {
          "schemaVersion": 2,
          "provider": "foundationModels",
          "openAICompatible": { "endpoint": "", "model": "", "credentialID": "openai-compatible-default", "authenticationMode": "apiKey" },
          "cli": { "kind": "codex" },
          "additionalInstructions": "  preserve os fatos.  "
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: data)
        let migrated = try decoded.migrated()

        #expect(migrated.schemaVersion == AssistantSettings.currentSchemaVersion)
        #expect(migrated.providerOAuth.kind == .codex)
        #expect(migrated.providerOAuth.credentialID == "provider-oauth-codex")
        #expect(migrated.additionalInstructions == "preserve os fatos.")
        let document = String(data: try JSONEncoder().encode(migrated), encoding: .utf8) ?? ""
        #expect(!document.contains("access_token"))
        #expect(!document.contains("refresh_token"))
    }

    @Test("completion do Codex sem loginId conclui a conexão dedicada")
    func acceptsNullLoginIDCompletion() {
        let completion = CodexDeviceLoginCompletion(loginID: nil, success: true)
        #expect(completion.matches("login-do-runtime"))
        #expect(!CodexDeviceLoginCompletion(loginID: "outro-login", success: true).matches("login-do-runtime"))
    }

    @Test("CODEX_HOME fica em espaço privado compartilhado pelo runtime")
    func createsManagedCodexHome() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-codex-home-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let environment = try CodexManagedRuntimeEnvironment.environment(
            applicationSupportDirectory: base
        )
        let path = try #require(environment["CODEX_HOME"])
        #expect(path == base.appendingPathComponent("OkamiUNI/Codex", isDirectory: true).path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Codex expõe somente link e código do runtime, persiste nada e carrega catálogo após concluir")
    @MainActor
    func usesManagedCodexDeviceRuntime() async throws {
        let runtime = CodexRuntimeStub()
        let store = InMemoryAssistantProviderOAuthSessionStore()
        let coordinator = AssistantProviderOAuthCoordinator(
            sessions: store,
            codexRuntime: runtime
        )
        let configuration = AssistantProviderOAuthConfiguration(
            kind: .codex,
            model: "gpt-da-conta",
            credentialID: "codex-runtime"
        )

        try await coordinator.start(configuration: configuration)
        let presentation = try #require(coordinator.status.deviceAuthorization)
        #expect(presentation.kind == .codex)
        #expect(presentation.verificationURL.absoluteString == "https://auth.openai.com/device")
        #expect(presentation.userCode == "OKAMI-4242")
        #expect(presentation.expiresAt == .distantFuture)
        #expect(try store.session(for: configuration.credentialID) == nil)
        await coordinator.refreshStatus(configuration: configuration)
        #expect(coordinator.status == .awaitingDeviceCode(presentation))

        await runtime.completeLogin()
        for _ in 0..<20 where coordinator.status != .signedIn { await Task.yield() }
        #expect(coordinator.status == .signedIn)
        #expect(try await coordinator.availableModels(configuration: configuration).map(\.id) == ["gpt-da-conta", "gpt-raciocinio"])
    }

    @Test("account/read reconhece somente uma sessão ChatGPT estruturada")
    func parsesStructuredCodexAccountState() {
        let chatGPT = Data(#"{"account":{"type":"chatgpt","email":"pessoa@example.com","planType":"plus"}}"#.utf8)
        let signedOut = Data(#"{"account":null}"#.utf8)
        let apiKey = Data(#"{"account":{"type":"apiKey"}}"#.utf8)

        #expect(CodexAccountReadParser.isChatGPTSignedIn(chatGPT))
        #expect(!CodexAccountReadParser.isChatGPTSignedIn(signedOut))
        #expect(!CodexAccountReadParser.isChatGPTSignedIn(apiKey))
        #expect(!CodexAccountReadParser.isChatGPTSignedIn(Data("não é JSON".utf8)))
        #expect(!CodexAccountReadParser.isChatGPTSignedIn(Data(repeating: 0, count: 1_048_577)))
    }

    @Test("falha de autenticação do catálogo remove o estado verde anterior")
    @MainActor
    func clearsStaleSignedInStateWhenCatalogRejectsSession() async {
        let runtime = CatalogCodexRuntimeStub(reportedSignedIn: true, models: nil)
        let coordinator = AssistantProviderOAuthCoordinator(codexRuntime: runtime)
        let configuration = AssistantProviderOAuthConfiguration(kind: .codex)

        await coordinator.refreshStatus(configuration: configuration)
        #expect(coordinator.status == .signedIn)
        await #expect(throws: CodexDeviceLoginRuntimeError.notAuthenticated) {
            _ = try await coordinator.availableModels(configuration: configuration)
        }

        #expect(coordinator.status == .signedOut)
        #expect(await runtime.signedInCheckCount() == 1)
    }

    @Test("catálogo Codex é a fonte única e não sofre uma segunda sondagem textual")
    @MainActor
    func loadsCodexCatalogWithoutDuplicatePreflight() async throws {
        let expected = [AssistantProviderModel(id: "gpt-da-conta", displayName: "GPT da conta")]
        let runtime = CatalogCodexRuntimeStub(reportedSignedIn: false, models: expected)
        let coordinator = AssistantProviderOAuthCoordinator(codexRuntime: runtime)

        let models = try await coordinator.availableModels(configuration: .init(kind: .codex))

        #expect(models == expected)
        #expect(coordinator.status == .signedIn)
        #expect(await runtime.signedInCheckCount() == 0)
    }

    @Test("xAI usa discovery estrito, respeita pending e slow_down, e conclui via token endpoint")
    func handlesXAIDeviceFlowStates() async throws {
        let counter = NSLockingCounter()
        let transport = ProviderOAuthStubTransport { request in
            switch request.url?.path {
            case "/.well-known/openid-configuration":
                Self.json(request, [
                    "issuer": "https://auth.x.ai",
                    "token_endpoint": "https://auth.x.ai/oauth2/token",
                    "device_authorization_endpoint": "https://auth.x.ai/oauth2/device/code",
                ])
            case "/oauth2/device/code":
                Self.json(request, [
                    "device_code": "transient-device-code",
                    "user_code": "XAI-1234",
                    "verification_uri": "https://accounts.x.ai/activate",
                    "verification_uri_complete": "https://accounts.x.ai/activate?code=XAI-1234",
                    "expires_at": "2023-11-14T22:28:20Z",
                    "interval": 4,
                ])
            case "/oauth2/token":
                switch counter.next() {
                case 1:
                    Self.json(request, ["error": "authorization_pending"], status: 400)
                case 2:
                    Self.json(request, ["error": "slow_down"], status: 400)
                default:
                    Self.json(request, ["access_token": "xai-access", "refresh_token": "xai-refresh", "expires_in": 3600])
                }
            default:
                Self.json(request, [:], status: 404)
            }
        }
        let client = AssistantProviderOAuthClient(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let pending = try await client.begin(configuration: .init(kind: .xAI, model: "grok-4"))
        #expect(pending.presentation.verificationURL.absoluteString == "https://accounts.x.ai/activate?code=XAI-1234")
        #expect(pending.presentation.userCode == "XAI-1234")
        #expect(pending.presentation.expiresAt == Date(timeIntervalSince1970: 1_700_000_900))

        let first = try await client.poll(pending, interval: 4)
        #expect(first.nextInterval == 4)
        let second = try await client.poll(pending, interval: first.nextInterval ?? 4)
        #expect(second.nextInterval == 5)
        let third = try await client.poll(pending, interval: second.nextInterval ?? 5)
        let session = try #require(third.session)
        #expect(session.kind == .xAI)
        #expect(session.accessToken == "xai-access")
        #expect(session.tokenEndpoint.absoluteString == "https://auth.x.ai/oauth2/token")

        let firstTokenBody = transport.capturedRequests().first(where: { $0.url?.path == "/oauth2/token" })?
            .httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(firstTokenBody.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
        #expect(firstTokenBody.contains("device_code=transient-device-code"))
        #expect(transport.capturedRequests().allSatisfy { $0.url?.host == "auth.x.ai" })
    }

    @Test("recusa discovery xAI que tenta mover o token para outro host")
    func rejectsCrossOriginXAIDiscovery() async {
        let transport = ProviderOAuthStubTransport { request in
            Self.json(request, [
                "issuer": "https://auth.x.ai",
                "token_endpoint": "https://attacker.example/token",
            ])
        }
        let client = AssistantProviderOAuthClient(transport: transport)
        await #expect(throws: AssistantProviderOAuthError.invalidDiscovery) {
            _ = try await client.begin(configuration: .init(kind: .xAI, model: "grok-4"))
        }
    }

    @Test("refresh rotativo preserva o refresh antigo se o provedor não devolvê-lo")
    @MainActor
    func refreshesSingleFlightAndPersistsRotatedSession() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let transport = DelayedProviderOAuthTransport(delay: .milliseconds(30)) { request in
            Self.json(request, ["access_token": "new-access", "expires_in": 7200])
        }
        let store = InMemoryAssistantProviderOAuthSessionStore()
        let configuration = AssistantProviderOAuthConfiguration(kind: .xAI, credentialID: "xai-personal")
        try store.store(.init(
            kind: .xAI,
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: now.addingTimeInterval(10),
            tokenEndpoint: URL(string: "https://auth.x.ai/oauth2/token")!
        ), for: configuration.credentialID)
        let coordinator = AssistantProviderOAuthCoordinator(
            client: .init(transport: transport, now: { now }),
            sessions: store,
            now: { now }
        )

        async let first = coordinator.accessToken(for: configuration)
        async let second = coordinator.accessToken(for: configuration)
        #expect(try await first == "new-access")
        #expect(try await second == "new-access")
        #expect(try store.session(for: configuration.credentialID)?.refreshToken == "old-refresh")
        #expect(transport.capturedRequests().count == 1)
        let body = transport.capturedRequests()[0].httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=old-refresh"))
    }

    @Test("router usa Responses OAuth sem CLI ou API key")
    @available(macOS 26.0, *)
    func routesOAuthSubscriptionWithoutCLI() async throws {
        let suite = "okamiuni.provider-oauth-router.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AssistantSettingsStore(defaults: defaults, key: "assistant")
        let configuration = AssistantProviderOAuthConfiguration(
            kind: .xAI,
            model: "grok-4",
            credentialID: "xai-personal"
        )
        try settings.save(.init(provider: .providerOAuth, providerOAuth: configuration))
        let http = StubURLProtocol.session(routes: [
            "/v1/responses": [.json("{\"output_text\":\"Resumo da assinatura.\"}")],
        ])
        let tokenProvider = OAuthTokenProviderStub()
        let router = AssistantRouter(
            settingsStore: settings,
            credentialStore: InMemoryAssistantCredentialStore(),
            session: http,
            providerOAuthTokenProvider: tokenProvider,
            cliInstallationProvider: { [] }
        )

        #expect(await router.availability() == .available)
        let answer = try await router.answer(question: "Resuma", in: .init(mailContext: .email(.init(
            subject: "Contrato", sender: "Lia <lia@example.com>", body: "Assinatura ativa."
        ))))
        #expect(answer == "Resumo da assinatura.")
        let request = try #require(StubURLProtocol.requests(for: http).first)
        #expect(request.path == "/v1/responses")
        #expect(request.authorization == "Bearer subscription-token")
        #expect(request.body.contains("grok-4"))
    }

    @Test("xAI usa Responses direto com bearer, payload e redirects recusados")
    func sendsDirectXAIResponsesWithoutCLIHeaders() async throws {
        let transport = TextAssistantTransportStub { request in
            Self.json(request, ["output_text": "Resumo direto."])
        }
        let assistant = try AssistantProviderOAuthTextAssistant(
            configuration: .init(kind: .xAI, model: "grok-4"),
            accessToken: "subscription-token",
            additionalInstructions: "Preserve os fatos.",
            transport: transport
        )

        let answer = try await assistant.answer(question: "Resuma", in: .init(mailContext: .email(.init(
            subject: "Contrato", sender: "Lia <lia@example.com>", body: "Assinatura ativa."
        ))))

        #expect(answer == "Resumo direto.")
        let call = try #require(transport.capturedCalls().first)
        #expect(call.request.url?.absoluteString == "https://api.x.ai/v1/responses")
        #expect(call.request.url?.host == "api.x.ai")
        #expect(call.rejectingRedirects)
        #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-token")
        #expect(call.request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
        #expect(call.request.timeoutInterval >= 90)

        let body = try #require(call.request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let payload = try #require(object as? [String: Any])
        #expect(payload["model"] as? String == "grok-4")
        #expect(payload["store"] as? Bool == false)
        #expect((payload["instructions"] as? String)?.contains("Preserve os fatos.") == true)
        #expect((payload["input"] as? String)?.contains("Resuma") == true)

        let headerNames = Set((call.request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(headerNames.isSubset(of: ["accept", "authorization", "content-type"]))
    }

    @Test("xAI recebe o HTML completo quando o text/plain é só a abertura")
    func configuredXAIReceivesHTMLWhenPlainIsAStub() async throws {
        let transport = TextAssistantTransportStub { request in
            Self.json(request, ["output_text": "Tradução completa."])
        }
        let assistant = try AssistantProviderOAuthTextAssistant(
            configuration: .init(kind: .xAI, model: "grok-4"),
            accessToken: "subscription-token",
            transport: transport
        )
        let html = """
        <p>Hi Marcos,</p>
        <p>1. What is/was your role with IGEL OS, UMS, or Stratodesk?</p>
        <p>2. What is IGEL's product portfolio?</p>
        """

        _ = try await assistant.answer(
            question: "traduz e resume",
            in: .init(mailContext: .email(.init(
                subject: "Paid Consultation",
                sender: "Jayden Sutherland",
                body: "Hi Marcos, I'm reaching out to gauge your interest.",
                html: html
            )))
        )

        let body = try #require(transport.capturedCalls().first?.request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let payload = try #require(object as? [String: Any])
        let input = try #require(payload["input"] as? String)
        #expect(input.contains("IGEL OS"))
        #expect(input.contains("Stratodesk"))
        #expect(input.contains("product portfolio"))
        #expect(!input.contains(FoundationModelsTextAssistantPrompt.omittedMiddleMarker))
    }

    @Test("xAI interrompe redirects antes de reutilizar o bearer")
    func refusesRedirectsForAuthenticatedResponses() async throws {
        let transport = TextAssistantTransportStub { request in
            Self.json(request, [:], status: 302)
        }
        let assistant = try AssistantProviderOAuthTextAssistant(
            configuration: .init(kind: .xAI, model: "grok-4"),
            accessToken: "subscription-token",
            transport: transport
        )

        await #expect(throws: AssistantProviderOAuthTextAssistantError.redirectRefused) {
            _ = try await assistant.answer(question: "Resuma", in: .init(mailContext: .email(.init(
                subject: "Contrato", sender: "Lia <lia@example.com>", body: "Assinatura ativa."
            ))))
        }
        #expect(transport.capturedCalls().first?.rejectingRedirects == true)
    }

    @Test("xAI traduz HTTP 426 em atualização acionável do cliente")
    func mapsUpgradeRequiredResponse() async throws {
        let transport = TextAssistantTransportStub { request in
            Self.json(request, [:], status: 426)
        }
        let assistant = try AssistantProviderOAuthTextAssistant(
            configuration: .init(kind: .xAI, model: "grok-4"),
            accessToken: "subscription-token",
            transport: transport
        )

        await #expect(throws: AssistantProviderOAuthTextAssistantError.upgradeRequired) {
            _ = try await assistant.answer(question: "Resuma", in: .init(mailContext: .email(.init(
                subject: "Contrato", sender: "Lia <lia@example.com>", body: "Assinatura ativa."
            ))))
        }
        let description = try #require(AssistantProviderOAuthTextAssistantError.upgradeRequired.errorDescription)
        #expect(description.contains("protocolo/cliente"))
        #expect(description.contains("Atualize o OkamiUNI"))
        #expect(!description.localizedCaseInsensitiveContains("prompt"))
    }

    @Test("Codex recusa o adaptador HTTP que receberia bearer")
    func refusesCodexBearerAdapter() {
        #expect(throws: AssistantProviderOAuthTextAssistantError.managedByCodexRuntime) {
            _ = try AssistantProviderOAuthTextAssistant(
                configuration: .init(kind: .codex, model: "gpt-da-conta"),
                accessToken: "never-exported"
            )
        }
    }

    private static func json(
        _ request: URLRequest,
        _ object: [String: Any],
        status: Int = 200
    ) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private extension StubURLProtocol.Recorded {
    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private extension AssistantProviderOAuthPollResult {
    var session: AssistantProviderOAuthSession? {
        guard case let .completed(session) = self else { return nil }
        return session
    }

    var nextInterval: TimeInterval? {
        guard case let .pending(nextInterval) = self else { return nil }
        return nextInterval
    }
}

private extension AssistantProviderOAuthStatus {
    var deviceAuthorization: AssistantProviderOAuthDeviceAuthorization? {
        guard case let .awaitingDeviceCode(value) = self else { return nil }
        return value
    }
}

private final class ProviderOAuthStubTransport:
    AssistantProviderOAuthHTTPTransport, @unchecked Sendable {

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

private final class TextAssistantTransportStub:
    AssistantProviderOAuthHTTPTransport, @unchecked Sendable {

    struct Call: Sendable {
        let request: URLRequest
        let rejectingRedirects: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private let responder: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    init(responder: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.responder = responder
    }

    func data(
        for request: URLRequest,
        rejectingRedirects: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { calls.append(.init(request: request, rejectingRedirects: rejectingRedirects)) }
        return try responder(request)
    }

    func capturedCalls() -> [Call] {
        lock.withLock { calls }
    }
}

private final class NSLockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class DelayedProviderOAuthTransport:
    AssistantProviderOAuthHTTPTransport, @unchecked Sendable {

    private let delay: Duration
    private let responder: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    init(
        delay: Duration,
        responder: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    ) {
        self.delay = delay
        self.responder = responder
    }

    func data(
        for request: URLRequest,
        rejectingRedirects: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        try await Task.sleep(for: delay)
        return try responder(request)
    }

    func capturedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }
}

private actor OAuthTokenProviderStub: AssistantProviderOAuthTokenProviding {
    func hasAccessToken(for configuration: AssistantProviderOAuthConfiguration) async -> Bool {
        configuration.kind == .xAI && configuration.credentialID == "xai-personal"
    }

    func accessToken(for configuration: AssistantProviderOAuthConfiguration) async throws -> String? {
        guard configuration.kind == .xAI, configuration.credentialID == "xai-personal" else { return nil }
        return "subscription-token"
    }
}

private actor CodexRuntimeStub: CodexDeviceLoginRuntime {
    private var signedIn = false
    private var completion: CheckedContinuation<Void, Error>?

    func startDeviceLogin() async throws -> CodexDeviceLogin {
        .init(
            loginID: "login-do-runtime",
            verificationURL: URL(string: "https://auth.openai.com/device")!,
            userCode: "OKAMI-4242"
        )
    }

    func waitForDeviceLogin(loginID: String) async throws {
        guard loginID == "login-do-runtime" else { throw CodexDeviceLoginRuntimeError.loginFailed }
        if signedIn { return }
        try await withCheckedThrowingContinuation { completion = $0 }
    }

    func cancelDeviceLogin() async {
        completion?.resume(throwing: CancellationError())
        completion = nil
    }

    func isSignedIn() async -> Bool { signedIn }

    func availableModels() async throws -> [AssistantProviderModel] {
        guard signedIn else { throw CodexDeviceLoginRuntimeError.notAuthenticated }
        return [
            .init(id: "gpt-da-conta", displayName: "GPT da conta"),
            .init(id: "gpt-raciocinio", displayName: "GPT Raciocínio"),
        ]
    }

    func signOut() async throws { signedIn = false }

    func completeLogin() {
        signedIn = true
        completion?.resume()
        completion = nil
    }
}

private actor CatalogCodexRuntimeStub: CodexDeviceLoginRuntime {
    private let reportedSignedIn: Bool
    private let models: [AssistantProviderModel]?
    private var signedInChecks = 0

    init(reportedSignedIn: Bool, models: [AssistantProviderModel]?) {
        self.reportedSignedIn = reportedSignedIn
        self.models = models
    }

    func startDeviceLogin() async throws -> CodexDeviceLogin {
        throw CodexDeviceLoginRuntimeError.protocolUnavailable
    }

    func waitForDeviceLogin(loginID: String) async throws {
        throw CodexDeviceLoginRuntimeError.protocolUnavailable
    }

    func cancelDeviceLogin() async {}

    func isSignedIn() async -> Bool {
        signedInChecks += 1
        return reportedSignedIn
    }

    func availableModels() async throws -> [AssistantProviderModel] {
        guard let models else { throw CodexDeviceLoginRuntimeError.notAuthenticated }
        return models
    }

    func signOut() async throws {}

    func signedInCheckCount() -> Int { signedInChecks }
}
