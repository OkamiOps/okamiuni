import Foundation
import UNICore

/// Liga as intenções das superfícies do shell ao contrato local do UNICore.
/// Foundation Models continua fora daqui; o app injeta a implementação.
public enum OnDeviceAssistantBridge {
    public static func composerGenerator(
        using assistant: any OnDeviceTextAssisting
    ) -> ComposerIntelligenceGenerator {
        { request in
            let context = request.sourceContext
                ?? request.sourceMessage.map(OnDeviceAssistantMailContext.init(message:))
            return try await assistant.transform(
                request.source,
                using: writingAction(for: request),
                context: context
            )
        }
    }

    static func answer(
        _ request: LocalAssistantRequest,
        mailContext: OnDeviceAssistantMailContext,
        using assistant: any OnDeviceTextAssisting
    ) async throws -> String {
        var history = request.conversation
        // O painel inclui a pergunta atual antes de chamar a closure. Ela já
        // tem campo próprio no contrato do motor, portanto não vai duplicada.
        if let last = history.last,
           last.speaker == .user,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines)
               == request.question.trimmingCharacters(in: .whitespacesAndNewlines) {
            history.removeLast()
        }

        let turns = history.map { message in
            OnDeviceAssistantTurn(
                role: message.speaker == .user ? .user : .assistant,
                text: message.text
            )
        }
        return try await assistant.answer(
            question: request.question,
            in: OnDeviceAssistantConversation(mailContext: mailContext, turns: turns)
        )
    }

    private static func writingAction(
        for request: ComposerIntelligenceRequest
    ) -> OnDeviceWritingAction {
        switch request.action {
        case .summarize: .summarize
        case .clarify: .rewriteForClarity
        case .shorten: .shorten
        case .formal: .formalize
        case .cordial: .makeFriendly
        case .correctPortuguese: .correctPortuguese
        case .createReply: .draftReply
        case .custom: .customInstruction(request.instruction ?? "")
        }
    }
}
