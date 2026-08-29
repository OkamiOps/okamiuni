import Foundation
import Testing
@testable import UNICore

@Suite("Contrato do assistente textual no dispositivo")
struct OnDeviceTextAssistantTests {
    @Test("O contexto preserva e-mail, conversa e turnos")
    func contextPreservesMailAndTurns() {
        let email = OnDeviceAssistantEmailContext(
            subject: "Reunião de produto",
            sender: "Marina <marina@example.com>",
            recipients: ["equipe@example.com"],
            sentAt: Date(timeIntervalSince1970: 1_788_000_000),
            body: "A reunião será na terça às 15h."
        )
        let conversation = OnDeviceAssistantConversation(
            mailContext: .conversation([email]),
            turns: [
                OnDeviceAssistantTurn(role: .user, text: "Quem marcou a reunião?"),
                OnDeviceAssistantTurn(role: .assistant, text: "Marina marcou a reunião.")
            ]
        )

        #expect(conversation.mailContext == .conversation([email]))
        #expect(conversation.turns.map(\.role) == [.user, .assistant])
        #expect(conversation.turns.map(\.text).joined(separator: " ").contains("Marina"))
    }

    @Test("As ações de escrita cobrem as transformações locais")
    func writingActionsAreExplicit() {
        let actions: [OnDeviceWritingAction] = [
            .summarize,
            .rewriteForClarity,
            .shorten,
            .formalize,
            .makeFriendly,
            .correctPortuguese,
            .draftReply,
            .customInstruction("Use frases curtas.")
        ]

        #expect(actions.count == 8)
        #expect(actions.contains(.customInstruction("Use frases curtas.")))
    }

    @Test("A porta assíncrona expõe pergunta contextual e transformação")
    func asynchronousPort() async throws {
        let assistant = TextAssistantDouble()
        let email = OnDeviceAssistantEmailContext(
            subject: "Recibo",
            sender: "Loja <vendas@example.com>",
            body: "Sua compra foi confirmada."
        )
        let conversation = OnDeviceAssistantConversation(mailContext: .email(email))

        #expect(await assistant.availability() == .available)
        #expect(try await assistant.answer(question: "O que aconteceu?", in: conversation) == email.body)
        #expect(try await assistant.transform("oi", using: .formalize) == "OI")
        #expect(try await assistant.transform("", using: .draftReply, context: .email(email)) == "RESPOSTA")
    }

    @Test("A resposta vazia tem erro claro")
    func emptyResponseErrorIsClear() {
        #expect(OnDeviceTextAssistantError.emptyResponse.errorDescription == "O assistente local devolveu uma resposta vazia.")
    }
}

private struct TextAssistantDouble: OnDeviceTextAssisting {
    let modelVersion = "double-v1"

    func availability() async -> OnDeviceMessageAnalysisAvailability { .available }

    func answer(
        question: String,
        in conversation: OnDeviceAssistantConversation
    ) async throws -> String {
        guard case let .email(email) = conversation.mailContext else {
            throw OnDeviceTextAssistantError.invalidRequest("O double espera um e-mail.")
        }
        return email.body
    }

    func transform(
        _ text: String,
        using action: OnDeviceWritingAction,
        context: OnDeviceAssistantMailContext?
    ) async throws -> String {
        if case .draftReply = action {
            guard context != nil else {
                throw OnDeviceTextAssistantError.invalidRequest("Criar uma resposta requer contexto de e-mail.")
            }
            return "RESPOSTA"
        }
        return text.uppercased()
    }
}
