import Foundation
import Testing
import UNICore
@testable import UNIShell

@Suite("Ponte do assistente local")
struct OnDeviceAssistantBridgeTests {
    @Test("Composer traduz cada intenção e preserva contexto")
    func composerMapping() async throws {
        let spy = AssistantSpy()
        let generator = OnDeviceAssistantBridge.composerGenerator(using: spy)
        let message = Fixtures.messages[0]
        let conversationContext = OnDeviceAssistantMailContext.conversation([
            OnDeviceAssistantEmailContext(
                subject: "Pergunta original", sender: "Cliente", body: "Pode enviar até sexta?"
            ),
            OnDeviceAssistantEmailContext(message: message),
        ])

        _ = try await generator(.init(
            action: .createReply,
            target: .draft,
            source: "",
            sourceMessage: message,
            sourceContext: conversationContext
        ))

        let call = try #require(await spy.lastTransform)
        #expect(call.text.isEmpty)
        #expect(call.action == .draftReply)
        #expect(call.context == conversationContext)
    }

    @Test("Pergunta atual não é duplicada no histórico")
    func currentQuestionIsNotDuplicated() async throws {
        let spy = AssistantSpy()
        let request = LocalAssistantRequest(
            context: .init(subject: "Assunto"),
            question: "Qual é o prazo?",
            conversation: [
                .init(speaker: .user, text: "Resuma"),
                .init(speaker: .assistant, text: "Resumo"),
                .init(speaker: .user, text: "Qual é o prazo?"),
            ]
        )

        _ = try await OnDeviceAssistantBridge.answer(
            request,
            mailContext: .email(OnDeviceAssistantEmailContext(message: Fixtures.messages[0])),
            using: spy
        )

        let call = try #require(await spy.lastAnswer)
        #expect(call.question == "Qual é o prazo?")
        #expect(call.conversation.turns.map(\.text) == ["Resuma", "Resumo"])
    }

    @Test("Contexto global atravessa a ponte sem virar email selecionado")
    func workspaceContextIsPreserved() async throws {
        let spy = AssistantSpy()
        let workspace = OnDeviceAssistantWorkspaceContext(
            accounts: ["Marcos · eu@example.com · example"],
            emailCount: 8,
            unreadCount: 3,
            mailboxes: [.init(name: "Hoje", totalCount: 4, unreadCount: 2)],
            emails: [],
            agenda: [.init(
                title: "Planejamento", date: Date(timeIntervalSince1970: 1_788_000_000),
                startMinute: 600, endMinute: 660, account: "eu@example.com"
            )]
        )
        let request = LocalAssistantRequest(
            context: .init(subject: "Todo o OkamiUNI"),
            question: "Como está meu dia?",
            conversation: []
        )

        _ = try await OnDeviceAssistantBridge.answer(
            request,
            mailContext: .workspace(workspace),
            using: spy
        )

        let call = try #require(await spy.lastAnswer)
        #expect(call.conversation.mailContext == .workspace(workspace))
    }
}

private actor AssistantSpy: OnDeviceTextAssisting {
    struct TransformCall: Sendable {
        let text: String
        let action: OnDeviceWritingAction
        let context: OnDeviceAssistantMailContext?
    }
    struct AnswerCall: Sendable {
        let question: String
        let conversation: OnDeviceAssistantConversation
    }

    nonisolated let modelVersion = "spy"
    private(set) var lastTransform: TransformCall?
    private(set) var lastAnswer: AnswerCall?

    func availability() async -> OnDeviceMessageAnalysisAvailability { .available }

    func answer(
        question: String,
        in conversation: OnDeviceAssistantConversation
    ) async throws -> String {
        lastAnswer = .init(question: question, conversation: conversation)
        return "Resposta"
    }

    func transform(
        _ text: String,
        using action: OnDeviceWritingAction,
        context: OnDeviceAssistantMailContext?
    ) async throws -> String {
        lastTransform = .init(text: text, action: action, context: context)
        return "Texto"
    }
}
