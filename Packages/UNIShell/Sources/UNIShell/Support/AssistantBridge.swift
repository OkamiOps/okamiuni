import Foundation
import UNICore

/// Liga as intenções das superfícies do shell ao contrato local do UNICore.
/// Foundation Models continua fora daqui; o app injeta a implementação.
public enum AssistantBridge {
    public static func composerGenerator(
        using assistant: any TextAssisting
    ) -> ComposerIntelligenceGenerator {
        { request in
            let context = request.sourceContext
                ?? request.sourceMessage.map(AssistantMailContext.init(message:))
            return try await assistant.transform(
                request.source,
                using: writingAction(for: request),
                context: context
            )
        }
    }

    static func answer(
        _ request: AssistantRequest,
        mailContext: AssistantMailContext,
        using assistant: any TextAssisting
    ) async throws -> String {
        try await assistant.answer(
            question: request.question,
            in: snapshot(request, mailContext: mailContext)
        )
    }

    /// O histórico como o motor o recebe. Um lugar só: a rota com cartões e a
    /// rota de prosa têm de ver a mesma conversa.
    static func snapshot(
        _ request: AssistantRequest, mailContext: AssistantMailContext
    ) -> AssistantConversationSnapshot {
        var history = request.conversation
        // O painel inclui a pergunta atual antes de chamar a closure. Ela já
        // tem campo próprio no contrato do motor, portanto não vai duplicada.
        if let last = history.last,
           last.speaker == .user,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines)
               == request.question.trimmingCharacters(in: .whitespacesAndNewlines) {
            history.removeLast()
        }

        let turns = history.suffix(AssistantConversation.maximumHistoryTurns).map { message in
            AssistantTurn(
                role: message.speaker == .user ? .user : .assistant,
                text: message.text
            )
        }
        return AssistantConversationSnapshot(mailContext: mailContext, turns: turns)
    }

    /// A mesma pergunta pela rota que traz cartões. O histórico é montado
    /// pela **mesma** função — duas montagens divergiriam no primeiro
    /// conserto, e o que o modelo vê é justamente o que decide a proposta.
    static func answerWithProposals(
        _ request: AssistantRequest,
        mailContext: AssistantMailContext,
        using assistant: any TextAssisting
    ) async throws -> AssistantAnswer {
        try await assistant.answerWithProposals(
            question: request.question,
            in: snapshot(request, mailContext: mailContext)
        )
    }

    private static func writingAction(
        for request: ComposerIntelligenceRequest
    ) -> WritingAction {
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

public extension AssistantBridge {
    /// O contexto é resolvido **no momento da chamada**: a mensagem aberta
    /// pode ter mudado desde que a superfície abriu, e o corpo pode ter
    /// acabado de chegar da rede.
    @MainActor
    static func engine(
        using assistant: any TextAssisting,
        supportsDraftReply: Bool,
        mailContext: @escaping @MainActor () async throws -> AssistantMailContext,
        currentDraft: @escaping @MainActor () -> String = { "" }
    ) -> AssistantEngine {
        AssistantEngine(
            supportsDraftReply: supportsDraftReply,
            answer: { request in
                try await AssistantBridge.answer(
                    request,
                    mailContext: try await mailContext(),
                    using: assistant
                )
            },
            draftReply: { _ in
                let context = try await mailContext()
                if case .workspace = context {
                    throw TextAssistantError.invalidRequest(
                        "Criar uma resposta requer contexto de e-mail."
                    )
                }
                return try await assistant.transform(
                    currentDraft(),
                    using: .draftReply,
                    context: context
                )
            },
            answerWithProposals: { request in
                try await AssistantBridge.answerWithProposals(
                    request,
                    mailContext: try await mailContext(),
                    using: assistant
                )
            }
        )
    }
}
