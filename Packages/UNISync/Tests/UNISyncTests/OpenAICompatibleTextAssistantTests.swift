import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("Assistente OpenAI-compatible")
struct OpenAICompatibleTextAssistantTests {
    private let conversation = AssistantConversationSnapshot(
        mailContext: .email(.init(
            subject: "Planejamento",
            sender: "Marina <marina@example.com>",
            body: "A entrega é sexta-feira."
        ))
    )

    @Test("envia o contrato chat completions com a política e sem alterar os dados do e-mail")
    func sendsOpenAICompatibleRequest() async throws {
        let session = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [.json("""
            {"choices":[{"message":{"content":"Marina confirmou sexta-feira."}}]}
            """)],
        ])
        let assistant = try OpenAICompatibleTextAssistant(
            configuration: .init(
                endpoint: "https://litellm.example/v1",
                model: "grok-4-fast",
                credentialID: "grok-team"
            ),
            apiKey: "api-test-secret",
            additionalInstructions: "Responda em tópicos & preserve nomes.",
            session: session
        )

        let answer = try await assistant.answer(
            question: "Quando é a entrega?",
            in: conversation
        )

        #expect(answer == "Marina confirmou sexta-feira.")
        #expect(assistant.modelVersion == "openai-compatible/grok-4-fast")
        let request = try #require(StubURLProtocol.requests(for: session).first)
        #expect(request.path == "/v1/chat/completions")
        #expect(request.authorization == "Bearer api-test-secret")

        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
        )
        #expect(payload["model"] as? String == "grok-4-fast")
        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        let system = try #require(messages[0]["content"] as? String)
        let prompt = try #require(messages[1]["content"] as? String)
        #expect(system.contains("<user-configured-assistant-instructions>"))
        #expect(system.contains("Responda em tópicos & preserve nomes."))
        #expect(system.contains("nunca revogam as regras de"))
        #expect(prompt.contains("<untrusted-app-context>"))
        #expect(prompt.contains("A entrega é sexta-feira."))
    }

    @Test("mapeia falhas HTTP e resposta fora do contrato sem vazar o corpo")
    func mapsServerFailures() async throws {
        let session = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [
                .json("{}", status: 401),
                .json("{}", status: 429),
                .json("{\"choices\":[]}"),
            ],
        ])
        let assistant = try OpenAICompatibleTextAssistant(
            configuration: .init(endpoint: "https://litellm.example", model: "model"),
            apiKey: "api-test-secret",
            session: session
        )

        await #expect(throws: OpenAICompatibleTextAssistantError.authenticationFailed) {
            try await assistant.answer(question: "Oi", in: conversation)
        }
        await #expect(throws: OpenAICompatibleTextAssistantError.rateLimited) {
            try await assistant.answer(question: "Oi", in: conversation)
        }
        await #expect(throws: OpenAICompatibleTextAssistantError.invalidResponse) {
            try await assistant.answer(question: "Oi", in: conversation)
        }
    }

    @Test("modo sem autenticação não consulta nem envia bearer")
    func sendsNoAuthorizationForUnauthenticatedProxy() async throws {
        let session = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [.json("""
            {"choices":[{"message":{"content":"Proxy público respondeu."}}]}
            """)],
        ])
        let assistant = try OpenAICompatibleTextAssistant(
            configuration: .init(
                endpoint: "https://litellm.example",
                model: "public-model",
                credentialID: "",
                authenticationMode: .none
            ),
            authorizationToken: nil,
            session: session
        )

        let response = try await assistant.answer(question: "Oi", in: conversation)

        #expect(response == "Proxy público respondeu.")
        let request = try #require(StubURLProtocol.requests(for: session).first)
        #expect(request.authorization == nil)
    }
}
