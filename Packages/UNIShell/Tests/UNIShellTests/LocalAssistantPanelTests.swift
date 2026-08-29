import SwiftUI
import Testing
import UNIDesign
@testable import UNIShell

@Suite("Painel de perguntas locais")
@MainActor
struct LocalAssistantPanelTests {
    private let context = LocalAssistantContext(
        subject: "Reunião de produto na terça-feira",
        sender: "Fernanda Lima",
        conversationLabel: "Conversa com 3 mensagens"
    )

    @Test("pergunta faz a transição para resposta pela closure injetada")
    func questionTransitionsToAnswer() async {
        var received: LocalAssistantRequest?
        let conversation = LocalAssistantConversation(context: context) { request in
            received = request
            return "A reunião é terça-feira, às 10h."
        }
        conversation.draft = "Quando é a reunião?"

        await conversation.submit()

        #expect(received?.context == context)
        #expect(received?.question == "Quando é a reunião?")
        #expect(received?.conversation.map(\.speaker) == [.user])
        #expect(conversation.messages.map(\.speaker) == [.user, .assistant])
        #expect(conversation.messages.last?.text == "A reunião é terça-feira, às 10h.")
        #expect(conversation.isLoading == false)
        #expect(conversation.errorMessage == nil)
    }

    @Test("erro mantém a pergunta e tentar de novo usa a mesma closure")
    func failedQuestionCanRetry() async {
        var attempts = 0
        let conversation = LocalAssistantConversation(context: context) { _ in
            attempts += 1
            if attempts == 1 { throw AssistantTestError.unavailable }
            return "Tentei novamente e encontrei o prazo."
        }
        conversation.draft = "Qual é o prazo?"

        await conversation.submit()
        #expect(conversation.messages.map(\.speaker) == [.user])
        #expect(conversation.errorMessage == "A Apple Intelligence ainda está sendo preparada.")
        #expect(conversation.canRetry)

        await conversation.retry()
        #expect(attempts == 2)
        #expect(conversation.messages.map(\.speaker) == [.user, .assistant])
        #expect(conversation.errorMessage == nil)

        conversation.clear()
        #expect(conversation.messages.isEmpty)
        #expect(conversation.canRetry == false)
    }

    @Test("painel vazio, resposta e erro renderizam fora da tela")
    func panelStatesRender() throws {
        let response = LocalAssistantPanelDebugState(messages: [
            .init(speaker: .user, text: "Quais são os próximos passos?"),
            .init(speaker: .assistant, text: "Confirme a pauta e responda até segunda-feira."),
        ])
        let error = LocalAssistantPanelDebugState(
            messages: [.init(speaker: .user, text: "Há algum prazo?")],
            errorMessage: "Não foi possível responder agora.",
            lastQuestion: "Há algum prazo?"
        )

        let states: [(String, LocalAssistantPanelDebugState)] = [
            ("empty", .empty),
            ("response", response),
            ("error", error),
        ]
        var snapshots: [NSBitmapImageRep] = []

        for (name, state) in states {
            let bitmap = try #require(Render.snapshot(
                LocalAssistantPanel(
                    context: context,
                    debugState: state,
                    onAsk: { _ in "Resposta de ensaio" },
                    onClose: {}
                ),
                named: "m5-local-assistant-\(name)",
                size: CGSize(width: LocalAssistantPanel.defaultWidth, height: 620),
                theme: .tinta
            ))
            snapshots.append(bitmap)
        }

        let empty = try #require(snapshots.first)
        for bitmap in snapshots.dropFirst() {
            #expect(empty.pixelsDiffering(from: bitmap) > 0)
        }
    }
}

private enum AssistantTestError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "A Apple Intelligence ainda está sendo preparada."
    }
}
