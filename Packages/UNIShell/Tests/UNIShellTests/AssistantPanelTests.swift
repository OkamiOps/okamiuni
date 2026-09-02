import SwiftUI
import Testing
import UNIDesign
@testable import UNIShell

@Suite("Painel do assistente")
@MainActor
struct AssistantPanelTests {
    private let context = AssistantContext(
        subject: "Reunião de produto na terça-feira",
        sender: "Fernanda Lima",
        conversationLabel: "Conversa com 3 mensagens"
    )

    @Test("ações do email têm nomes claros e executam sem segundo clique")
    func emailQuickActionsRunImmediately() async throws {
        let actions = AssistantSuggestion.emailDefaults
        #expect(actions.map(\.title) == [
            "Resumo", "Pontos-chave", "Insights", "Pendências", "Gerar resposta"
        ])

        var received: AssistantRequest?
        let conversation = AssistantConversation(context: context) { request in
            received = request
            return "Resposta pronta"
        }
        await conversation.run(try #require(actions.first))

        #expect(received?.question == actions.first?.question)
        #expect(conversation.messages.map(\.speaker) == [.user, .assistant])
        #expect(conversation.messages.last?.text == "Resposta pronta")
        #expect(conversation.draft.isEmpty)
    }

    @Test("clicar em Gerar resposta atravessa o botão e chega ao motor")
    func generateReplyButtonRunsOffscreen() async throws {
        let action = try #require(
            AssistantSuggestion.emailDefaults.first { $0.title == "Gerar resposta" }
        )
        var received: AssistantRequest?

        CliqueDeEnsaio.em(
            AssistantPanel(
                context: context,
                suggestions: [action],
                onAsk: { request in
                    received = request
                    return "Resposta completa pronta para revisão"
                },
                onClose: {}
            ),
            size: CGSize(width: AssistantPanel.defaultWidth, height: 620),
            aY: 245,
            x: AssistantPanel.defaultWidth / 2
        )
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        #expect(received?.question == action.question)
    }

    @Test("assistente global oferece ações de caixas e agenda")
    func workspaceQuickActionsAreGlobal() {
        let actions = AssistantSuggestion.workspaceDefaults
        #expect(actions.map(\.title) == [
            "Resumo geral", "Prioridades", "Não lidos", "Agenda", "Riscos e pendências"
        ])
        #expect(actions.allSatisfy { !$0.question.localizedCaseInsensitiveContains("este email") })
    }

    @Test("pergunta faz a transição para resposta pela closure injetada")
    func questionTransitionsToAnswer() async {
        var received: AssistantRequest?
        let conversation = AssistantConversation(context: context) { request in
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

    @Test("pergunta seguinte recebe a conversa anterior e mantém a instrução atual")
    func followUpCarriesConversationHistory() async throws {
        var requests: [AssistantRequest] = []
        let conversation = AssistantConversation(context: context) { request in
            requests.append(request)
            return requests.count == 1
                ? "- Confirmar a pauta\n- Responder até segunda-feira"
                : "- Confirmar a pauta com Produto\n- Responder até segunda-feira"
        }

        conversation.draft = "Gere em lista."
        await conversation.submit()
        conversation.draft = "Agora detalhe o primeiro item, mantendo a lista."
        await conversation.submit()

        let followUp = try #require(requests.last)
        #expect(followUp.question == "Agora detalhe o primeiro item, mantendo a lista.")
        #expect(followUp.conversation.map(\.speaker) == [.user, .assistant, .user])
        #expect(followUp.conversation.map(\.text) == [
            "Gere em lista.",
            "- Confirmar a pauta\n- Responder até segunda-feira",
            "Agora detalhe o primeiro item, mantendo a lista.",
        ])
        #expect(conversation.messages.count == 4)
    }

    @Test("erro mantém a pergunta e tentar de novo usa a mesma closure")
    func failedQuestionCanRetry() async {
        var attempts = 0
        let conversation = AssistantConversation(context: context) { _ in
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
        let response = AssistantPanelDebugState(messages: [
            .init(speaker: .user, text: "Quais são os próximos passos?"),
            .init(speaker: .assistant, text: "Confirme a pauta e responda até segunda-feira."),
        ])
        let error = AssistantPanelDebugState(
            messages: [.init(speaker: .user, text: "Há algum prazo?")],
            errorMessage: "Não foi possível responder agora.",
            lastQuestion: "Há algum prazo?"
        )

        let states: [(String, AssistantPanelDebugState)] = [
            ("empty", .empty),
            ("response", response),
            ("error", error),
        ]
        var snapshots: [NSBitmapImageRep] = []

        for (name, state) in states {
            let bitmap = try #require(Render.snapshot(
                AssistantPanel(
                    context: context,
                    debugState: state,
                    onAsk: { _ in "Resposta de ensaio" },
                    onClose: {}
                ),
                named: "m5-local-assistant-\(name)",
                size: CGSize(width: AssistantPanel.defaultWidth, height: 620),
                theme: .tinta
            ))
            snapshots.append(bitmap)
        }

        let empty = try #require(snapshots.first)
        for bitmap in snapshots.dropFirst() {
            #expect(empty.pixelsDiffering(from: bitmap) > 0)
        }
    }

    @Test("painel global identifica o ambiente e renderiza as ações")
    func workspacePanelRenders() throws {
        let bitmap = try #require(Render.snapshot(
            AssistantPanel(
                mode: .workspace,
                context: AssistantContext(
                    subject: "Todo o OkamiUNI",
                    sender: "4 contas · 7 emails",
                    conversationLabel: "38 compromissos"
                ),
                onAsk: { _ in "Resposta de ensaio" },
                onClose: {}
            ),
            named: "m5-local-assistant-workspace",
            size: CGSize(width: AssistantPanel.defaultWidth, height: 620),
            theme: .tinta
        ))
        #expect(bitmap.pixelsWide == Int(AssistantPanel.defaultWidth))
    }
}

private enum AssistantTestError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "A Apple Intelligence ainda está sendo preparada."
    }
}
