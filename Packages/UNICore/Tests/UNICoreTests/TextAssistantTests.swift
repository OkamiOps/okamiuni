import Foundation
import Testing
@testable import UNICore

@Suite("Contrato do assistente textual no dispositivo")
struct TextAssistantTests {
    @Test("O contexto preserva e-mail, conversa e turnos")
    func contextPreservesMailAndTurns() {
        let email = AssistantEmailContext(
            subject: "Reunião de produto",
            sender: "Marina <marina@example.com>",
            recipients: ["equipe@example.com"],
            sentAt: Date(timeIntervalSince1970: 1_788_000_000),
            body: "A reunião será na terça às 15h."
        )
        let conversation = AssistantConversationSnapshot(
            mailContext: .conversation([email]),
            turns: [
                AssistantTurn(role: .user, text: "Quem marcou a reunião?"),
                AssistantTurn(role: .assistant, text: "Marina marcou a reunião.")
            ]
        )

        #expect(conversation.mailContext == .conversation([email]))
        #expect(conversation.turns.map(\.role) == [.user, .assistant])
        #expect(conversation.turns.map(\.text).joined(separator: " ").contains("Marina"))
    }

    @Test("As ações de escrita cobrem as transformações locais")
    func writingActionsAreExplicit() {
        let actions: [WritingAction] = [
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
        let email = AssistantEmailContext(
            subject: "Recibo",
            sender: "Loja <vendas@example.com>",
            body: "Sua compra foi confirmada."
        )
        let conversation = AssistantConversationSnapshot(mailContext: .email(email))

        #expect(await assistant.availability() == .available)
        #expect(try await assistant.answer(question: "O que aconteceu?", in: conversation) == email.body)
        #expect(try await assistant.transform("oi", using: .formalize) == "OI")
        #expect(try await assistant.transform("", using: .draftReply, context: .email(email)) == "RESPOSTA")
    }

    @Test("A resposta vazia tem erro claro")
    func emptyResponseErrorIsClear() {
        #expect(TextAssistantError.emptyResponse.errorDescription == "O assistente devolveu uma resposta vazia.")
    }
}

private struct TextAssistantDouble: TextAssisting {
    let modelVersion = "double-v1"

    func availability() async -> OnDeviceMessageAnalysisAvailability { .available }

    func answer(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> String {
        guard case let .email(email) = conversation.mailContext else {
            throw TextAssistantError.invalidRequest("O double espera um e-mail.")
        }
        return email.body
    }

    func transform(
        _ text: String,
        using action: WritingAction,
        context: AssistantMailContext?
    ) async throws -> String {
        if case .draftReply = action {
            guard context != nil else {
                throw TextAssistantError.invalidRequest("Criar uma resposta requer contexto de e-mail.")
            }
            return "RESPOSTA"
        }
        return text.uppercased()
    }
}
