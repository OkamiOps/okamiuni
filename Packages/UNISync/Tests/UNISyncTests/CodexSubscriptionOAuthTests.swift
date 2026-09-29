import Foundation
import Testing
@testable import UNISync

@Suite("OAuth HTTP direto da assinatura ChatGPT")
struct CodexSubscriptionOAuthTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("device grant usa JSON, preserva pending e troca o código por tokens sem processo")
    func completesDeviceGrantOverHTTP() async throws {
        let idToken = try token(accountID: "account-from-provider")
        let tokens = try JSONSerialization.data(withJSONObject: [
            "access_token": "test-access", "refresh_token": "test-refresh", "expires_in": 3_600,
            "id_token": idToken
        ])
        let transport = CodexHTTPStub(replies: [
            .init(status: 200, body: Data(#"{"device_auth_id":"test-device","usercode":"TEST-1234","interval":"7"}"#.utf8)),
            .init(status: 403), .init(status: 404),
            .init(status: 200, body: Data(#"{"authorization_code":"test-code","code_verifier":"test-verifier","code_challenge":"test-challenge"}"#.utf8)),
            .init(status: 200, body: tokens)
        ])
        let client = AssistantProviderOAuthClient(transport: transport, now: { now })
        let pending = try await client.begin(configuration: .init(kind: .codex))
        #expect(pending.presentation.verificationURL.absoluteString == "https://auth.openai.com/codex/device")
        #expect(pending.presentation.userCode == "TEST-1234")
        #expect(pending.presentation.expiresAt == now.addingTimeInterval(900))
        #expect(pending.presentation.pollInterval == 7)
        for _ in 0..<2 {
            guard case let .pending(nextInterval) = try await client.poll(pending, interval: 7) else {
                Issue.record("Autorização ainda deveria estar pendente")
                return
            }
            #expect(nextInterval == 7)
        }
        guard case let .completed(session) = try await client.poll(pending, interval: 7) else {
            Issue.record("Autorização deveria devolver uma sessão")
            return
        }
        #expect(session.kind == .codex)
        #expect(session.accountID == "account-from-provider")
        #expect(session.accessToken == "test-access")
        #expect(session.refreshToken == "test-refresh")
        #expect(session.expiresAt == now.addingTimeInterval(3_600))

        let requests = transport.requests
        #expect(requests.count == 5)
        #expect(requests[0].url?.absoluteString == "https://auth.openai.com/api/accounts/deviceauth/usercode")
        #expect(try jsonBody(requests[0]) == ["client_id": AssistantProviderOAuthClient.codexClientID])
        for request in requests[1...3] {
            #expect(request.url?.absoluteString == "https://auth.openai.com/api/accounts/deviceauth/token")
            #expect(try jsonBody(request) == ["device_auth_id": "test-device", "user_code": "TEST-1234"])
        }
        #expect(requests[4].url == AssistantProviderOAuthClient.codexTokenURL)
        #expect(requests[4].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
        #expect(formBody(requests[4]) == [
            "grant_type": "authorization_code", "client_id": AssistantProviderOAuthClient.codexClientID,
            "redirect_uri": "https://auth.openai.com/deviceauth/callback",
            "code": "test-code", "code_verifier": "test-verifier"
        ])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(transport.redirectPolicies == [true, true, true, true, true])
    }

    @Test("refresh JSON preserva refresh/accountID ausentes e usa exp do access token")
    func refreshesCodexSessionDirectly() async throws {
        let access = try token(accountID: "test-account", expiration: now.addingTimeInterval(600))
        let transport = CodexHTTPStub(replies: [.init(status: 200, body: try JSONSerialization.data(withJSONObject: ["access_token": access]))])
        let client = AssistantProviderOAuthClient(transport: transport, now: { now })
        let previous = AssistantProviderOAuthSession(kind: .codex, accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now, tokenEndpoint: AssistantProviderOAuthClient.codexTokenURL, accountID: "test-account")
        let updated = try await client.refresh(previous)
        #expect(updated.accountID == "test-account")
        #expect(updated.refreshToken == "old-refresh")
        #expect(updated.expiresAt == now.addingTimeInterval(600))
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try jsonBody(request) == ["grant_type": "refresh_token", "client_id": AssistantProviderOAuthClient.codexClientID, "refresh_token": "old-refresh"])
    }

    @Test("refresh recusado não conserva sucesso aparente", arguments: [401, 403])
    func rejectsRefreshFailure(status: Int) async {
        let transport = CodexHTTPStub(replies: [.init(status: status)])
        let client = AssistantProviderOAuthClient(transport: transport, now: { now })
        let session = AssistantProviderOAuthSession(kind: .codex, accessToken: "old", refreshToken: "refresh", expiresAt: now, tokenEndpoint: AssistantProviderOAuthClient.codexTokenURL, accountID: "test-account")
        await #expect(throws: AssistantProviderOAuthError.authorizationDenied) { _ = try await client.refresh(session) }
    }

    @Test("device code expirado não faz polling nem troca tokens")
    func stopsExpiredAuthorization() async throws {
        let transport = CodexHTTPStub(replies: [.init(status: 200, body: Data(#"{"device_auth_id":"test-device","user_code":"TEST-1234","interval":5}"#.utf8))])
        let client = AssistantProviderOAuthClient(transport: transport, now: { now })
        let pending = try await client.begin(configuration: .init(kind: .codex))
        let expiredClient = AssistantProviderOAuthClient(transport: transport, now: { now.addingTimeInterval(901) })
        await #expect(throws: AssistantProviderOAuthError.authorizationExpired) { _ = try await expiredClient.poll(pending, interval: 5) }
        #expect(transport.requests.count == 1)
    }

    @Test("token endpoint inesperado é recusado antes de enviar refresh")
    func refusesUnexpectedTokenEndpoint() async {
        let transport = CodexHTTPStub(replies: [])
        let client = AssistantProviderOAuthClient(transport: transport)
        let session = AssistantProviderOAuthSession(kind: .codex, accessToken: "old", refreshToken: "refresh", expiresAt: now, tokenEndpoint: URL(string: "https://elsewhere.example/token")!, accountID: "test-account")
        await #expect(throws: AssistantProviderOAuthError.sessionProviderMismatch) { _ = try await client.refresh(session) }
        #expect(transport.requests.isEmpty)
    }

    @Test("Responses SSE concatena deltas somente após conclusão")
    func acceptsCompletedEventStream() throws {
        let stream = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Olá "}

        data: {"type":"response.output_text.delta","delta":"mundo"}

        event: response.completed
        data: {"type":"response.completed","response":{"output":[]}}

        """
        #expect(try CodexResponsesEventStream.text(from: Data(stream.utf8)) == "Olá mundo")
    }

    @Test("SSE interrompido ou failed não entrega texto parcial", arguments: ["", "data: {\"type\":\"response.failed\"}\n\n"])
    func rejectsPartialEventStream(terminal: String) {
        let stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"parcial\"}\n\n" + terminal
        #expect(throws: AssistantProviderOAuthTextAssistantError.invalidResponse) { _ = try CodexResponsesEventStream.text(from: Data(stream.utf8)) }
    }

    private func token(accountID: String, expiration: Date? = nil) throws -> String {
        var payload: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": accountID]]
        if let expiration { payload["exp"] = Int(expiration.timeIntervalSince1970) }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let base64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "test.\(base64).test"
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: String] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func formBody(_ request: URLRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private final class CodexHTTPStub: AssistantProviderOAuthHTTPTransport, @unchecked Sendable {
    struct Reply { let status: Int; var body = Data() }
    private let lock = NSLock()
    private var replies: [Reply]
    private var captured: [URLRequest] = []
    private var policies: [Bool] = []
    init(replies: [Reply]) { self.replies = replies }
    var requests: [URLRequest] { lock.withLock { captured } }
    var redirectPolicies: [Bool] { lock.withLock { policies } }
    func data(for request: URLRequest, rejectingRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let reply = lock.withLock {
            captured.append(request)
            policies.append(rejectingRedirects)
            return replies.isEmpty ? Reply(status: 500) : replies.removeFirst()
        }
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
