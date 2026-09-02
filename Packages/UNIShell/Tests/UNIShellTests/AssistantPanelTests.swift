import Foundation
import SwiftUI
import Testing
import UNIDesign
import UNISync
@testable import UNIShell

@Suite("Painel do assistente")
@MainActor
struct AssistantPanelTests {
    private let context = AssistantContext(
        subject: "Reunião de produto na terça-feira",
        sender: "Fernanda Lima",
        conversationLabel: "Conversa com 3 mensagens"
    )

    /// O painel não cria mais a conversa: ele recebe uma. O teste monta a
    /// dona do estado com um motor de mentira e observa as duas pontas.
    @MainActor
    private final class Recorder {
        var requests: [AssistantRequest] = []
        /// As duas rotas são contadas separadamente: é o que prova que
        /// "Gerar resposta" nunca cai no `answer`.
        var drafts: [AssistantRequest] = []
        var reply: (Int) throws -> String = { _ in "Resposta pronta" }
        var draft: () throws -> String = { "Oi Fernanda,\n\nFechado." }
    }

    private func makeConversation(
        scope: AssistantScope = .email,
        recorder: Recorder,
        supportsDraftReply: Bool = false,
        debugState: AssistantPanelDebugState = .empty
    ) -> AssistantConversation {
        AssistantConversation(
            scope: scope,
            context: context,
            destination: AssistantDestination(
                label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true
            ),
            engine: AssistantEngine(
                supportsDraftReply: supportsDraftReply,
                answer: { request in
                    recorder.requests.append(request)
                    return try recorder.reply(recorder.requests.count)
                },
                draftReply: { request in
                    recorder.drafts.append(request)
                    return try recorder.draft()
                }
            ),
            debugState: debugState
        )
    }

    @Test("ações do email têm nomes claros e executam sem segundo clique")
    func emailQuickActionsRunImmediately() async throws {
        let actions = AssistantSuggestion.emailDefaults
        #expect(actions.map(\.title) == [
            "Resumo", "Pontos-chave", "Insights", "Pendências", "Gerar resposta"
        ])

        let recorder = Recorder()
        let conversation = makeConversation(recorder: recorder)
        conversation.run(try #require(actions.first))
        await conversation.waitForIdle()

        #expect(recorder.requests.first?.question == actions.first?.question)
        #expect(conversation.messages.map(\.speaker) == [.user, .assistant])
        #expect(conversation.messages.last?.text == "Resposta pronta")
        #expect(conversation.draft.isEmpty)
    }

    @Test("clicar em Gerar resposta chega ao rascunho, nunca ao answer")
    func generateReplyButtonRunsOffscreen() async throws {
        let action = try #require(
            AssistantSuggestion.emailDefaults.first { $0.title == "Gerar resposta" }
        )
        #expect(action.kind == .draftReply)
        let recorder = Recorder()
        recorder.draft = { "Resposta completa pronta para revisão" }
        let conversation = makeConversation(recorder: recorder, supportsDraftReply: true)

        CliqueDeEnsaio.em(
            AssistantPanel(
                conversation: conversation,
                suggestions: [action],
                onClose: {}
            ),
            size: CGSize(width: AssistantPanel.defaultWidth, height: 620),
            aY: 245,
            x: AssistantPanel.defaultWidth / 2
        )
        await Task.yield()
        await conversation.waitForIdle()

        // Só as duas contagens: fechar a janela do ensaio cancela o pedido
        // em voo, então o turno pode não chegar a ser publicado. Que o
        // rascunho vira turno `.draft` é o que `AssistantConversationTests`
        // prova.
        #expect(recorder.drafts.count == 1)
        #expect(recorder.requests.isEmpty)
    }

    @Test("sem motor de rascunho a sugestão de resposta não aparece")
    func draftSuggestionIsHiddenWithoutDraftEngine() {
        let recorder = Recorder()
        let panel = AssistantPanel(
            conversation: makeConversation(recorder: recorder),
            onClose: {}
        )
        #expect(!panel.visibleSuggestions.contains { $0.kind == .draftReply })

        let withDraft = AssistantPanel(
            conversation: makeConversation(recorder: recorder, supportsDraftReply: true),
            onClose: {}
        )
        #expect(withDraft.visibleSuggestions.contains { $0.kind == .draftReply })
    }

    @Test("assistente global oferece ações de caixas e agenda")
    func workspaceQuickActionsAreGlobal() {
        let actions = AssistantSuggestion.workspaceDefaults
        #expect(actions.map(\.title) == [
            "Resumo geral", "Prioridades", "Não lidos", "Agenda", "Riscos e pendências"
        ])
        #expect(actions.allSatisfy { !$0.question.localizedCaseInsensitiveContains("este email") })
    }

    @Test("pergunta faz a transição para resposta pelo motor injetado")
    func questionTransitionsToAnswer() async {
        let recorder = Recorder()
        recorder.reply = { _ in "A reunião é terça-feira, às 10h." }
        let conversation = makeConversation(recorder: recorder)
        conversation.draft = "Quando é a reunião?"

        conversation.submit()
        await conversation.waitForIdle()

        #expect(recorder.requests.first?.context == context)
        #expect(recorder.requests.first?.question == "Quando é a reunião?")
        #expect(recorder.requests.first?.conversation.map(\.speaker) == [.user])
        #expect(conversation.messages.map(\.speaker) == [.user, .assistant])
        #expect(conversation.messages.last?.text == "A reunião é terça-feira, às 10h.")
        #expect(conversation.isLoading == false)
        #expect(conversation.failure == nil)
    }

    @Test("pergunta seguinte recebe a conversa anterior e mantém a instrução atual")
    func followUpCarriesConversationHistory() async throws {
        let recorder = Recorder()
        recorder.reply = { attempt in
            attempt == 1
                ? "- Confirmar a pauta\n- Responder até segunda-feira"
                : "- Confirmar a pauta com Produto\n- Responder até segunda-feira"
        }
        let conversation = makeConversation(recorder: recorder)

        conversation.draft = "Gere em lista."
        conversation.submit()
        await conversation.waitForIdle()
        conversation.draft = "Agora detalhe o primeiro item, mantendo a lista."
        conversation.submit()
        await conversation.waitForIdle()

        let followUp = try #require(recorder.requests.last)
        #expect(followUp.question == "Agora detalhe o primeiro item, mantendo a lista.")
        #expect(followUp.conversation.map(\.speaker) == [.user, .assistant, .user])
        #expect(followUp.conversation.map(\.text) == [
            "Gere em lista.",
            "- Confirmar a pauta\n- Responder até segunda-feira",
            "Agora detalhe o primeiro item, mantendo a lista.",
        ])
        #expect(conversation.messages.count == 4)
    }

    @Test("erro mantém a pergunta e tentar de novo usa o mesmo motor")
    func failedQuestionCanRetry() async {
        let recorder = Recorder()
        recorder.reply = { attempt in
            if attempt == 1 { throw AssistantTestError.unavailable }
            return "Tentei novamente e encontrei o prazo."
        }
        let conversation = makeConversation(recorder: recorder)
        conversation.draft = "Qual é o prazo?"

        conversation.submit()
        await conversation.waitForIdle()
        #expect(conversation.messages.map(\.speaker) == [.user])
        #expect(conversation.failure?.message == "A Apple Intelligence ainda está sendo preparada.")
        #expect(conversation.canRetry)

        conversation.retry()
        await conversation.waitForIdle()
        #expect(recorder.requests.count == 2)
        #expect(conversation.messages.map(\.speaker) == [.user, .assistant])
        #expect(conversation.failure == nil)

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
            failure: AssistantFailure(
                message: "Não foi possível responder agora.", recovery: .retry
            )
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
                    conversation: makeConversation(
                        recorder: Recorder(), debugState: state
                    ),
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
        let conversation = AssistantConversation(
            scope: .workspace,
            context: AssistantContext(
                subject: "Todo o OkamiUNI",
                sender: "4 contas · 7 emails",
                conversationLabel: "38 compromissos"
            ),
            destination: .unconfigured,
            engine: AssistantEngine(supportsDraftReply: false) { _ in "Resposta de ensaio" }
        )
        let bitmap = try #require(Render.snapshot(
            AssistantPanel(conversation: conversation, onClose: {}),
            named: "m5-local-assistant-workspace",
            size: CGSize(width: AssistantPanel.defaultWidth, height: 620),
            theme: .tinta
        ))
        #expect(bitmap.pixelsWide == Int(AssistantPanel.defaultWidth))
    }

    @Test("com provedor remoto, nenhuma superfície promete processamento local")
    func remoteDestinationNeverPromisesLocal() async throws {
        let destination = AssistantDestination(
            label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false
        )
        let conversation = AssistantConversation(
            scope: .workspace,
            context: .init(subject: "Todo o OkamiUNI", sender: "2 contas"),
            destination: destination,
            engine: AssistantEngine(supportsDraftReply: false) { _ in "ok" }
        )
        let panel = AssistantPanel(conversation: conversation, onClose: {})
        let image = try #require(Render.snapshot(
            panel,
            named: "assistant-panel-remote",
            size: CGSize(width: 360, height: 640),
            theme: .okami
        ))
        #expect(image.pixelsWide == 360)

        // A cópia é lógica pura e mora fora da View: o rodapé é o `detail` do
        // destino, e a espera é `AssistantScope.loadingLabel(for:)`. Nenhum
        // dos dois é um texto fixo por escopo.
        #expect(conversation.destination.detail == "Sai deste Mac para a xAI.")
        #expect(!conversation.destination.detail.localizedCaseInsensitiveContains("neste Mac"))
        #expect(!conversation.destination.detail.localizedCaseInsensitiveContains("local"))
        #expect(AssistantScope.workspace.loadingLabel(for: destination) == "Falando com Grok · xAI…")
        #expect(!AssistantScope.workspace.loadingLabel(for: destination).localizedCaseInsensitiveContains("local"))
        #expect(AssistantScope.email.loadingLabel(for: destination) == "Falando com Grok · xAI…")

        let local = AssistantDestination(
            label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true
        )
        #expect(local.detail == "Nada sai deste Mac.")
        #expect(AssistantScope.workspace.loadingLabel(for: local) == "Lendo o contexto neste Mac…")
    }

    /// O dashboard guarda a conversa em `@State` pela sessão inteira e Ajustes
    /// é outra janela: um destino congelado na construção fazia o rodapé e a
    /// espera prometerem "neste Mac" com o pedido saindo para a xAI.
    @Test("trocar de provedor muda o que a conversa imprime, sem refazer a view")
    func destinationIsReadAtRenderTime() {
        let escolha = Escolha()
        let conversation = AssistantConversation(
            scope: .workspace,
            context: AssistantContext(subject: "Ambiente"),
            destination: { escolha.destino },
            engine: .unavailable,
            provider: { escolha.provedor }
        )

        #expect(conversation.destination.isLocal)
        #expect(
            AssistantScope.workspace.loadingLabel(for: conversation.destination)
                == "Lendo o contexto neste Mac…"
        )

        // A mesma instância de conversa, sem reconstrução nenhuma.
        escolha.trocarParaXAI()
        #expect(!conversation.destination.isLocal)
        #expect(conversation.destination.label == "Grok · xAI")
        #expect(
            AssistantScope.workspace.loadingLabel(for: conversation.destination)
                == "Falando com Grok · xAI…"
        )
    }

    @Test("um turno de rascunho não passa pelo renderizador de Markdown")
    func draftTurnRendersLiterally() throws {
        let draft = AssistantPanelDebugState(messages: [
            .init(speaker: .assistant, text: "Oi Marina,\n\n**Fechado** para amanhã.", kind: .draft),
        ])
        let message = AssistantPanelDebugState(messages: [
            .init(speaker: .assistant, text: "Oi Marina,\n\n**Fechado** para amanhã."),
        ])

        let asDraft = try #require(Render.snapshot(
            AssistantPanel(
                conversation: makeConversation(recorder: Recorder(), debugState: draft),
                onClose: {}
            ),
            named: "m5-local-assistant-draft",
            size: CGSize(width: AssistantPanel.defaultWidth, height: 620),
            theme: .tinta
        ))
        let asMessage = try #require(Render.snapshot(
            AssistantPanel(
                conversation: makeConversation(recorder: Recorder(), debugState: message),
                onClose: {}
            ),
            named: "m5-local-assistant-draft-markdown",
            size: CGSize(width: AssistantPanel.defaultWidth, height: 620),
            theme: .tinta
        ))
        #expect(asDraft.pixelsDiffering(from: asMessage) > 0)
    }
}

private enum AssistantTestError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "A Apple Intelligence ainda está sendo preparada."
    }
}

/// O provedor escolhido em Ajustes, do ponto de vista de outra janela.
private final class Escolha: @unchecked Sendable {
    private let lock = NSLock()
    private var settings = AssistantSettings.default

    var destino: AssistantDestination {
        lock.withLock { AssistantDestination(settings: settings) }
    }

    var provedor: AssistantProviderOAuthKind? {
        lock.withLock {
            settings.provider == .providerOAuth ? settings.providerOAuth.kind : nil
        }
    }

    func trocarParaXAI() {
        lock.withLock {
            settings.provider = .providerOAuth
            settings.providerOAuth.kind = .xAI
            settings.providerOAuth.model = "grok-4"
        }
    }
}
