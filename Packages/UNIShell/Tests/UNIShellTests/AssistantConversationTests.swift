import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// Espião do contrato puro. Guarda o que foi pedido e devolve o que o
/// teste mandar, sem tocar em FoundationModels nem em rede.
final class SpyTextAssistant: TextAssisting, @unchecked Sendable {
    struct TransformCall: Equatable {
        let text: String
        let action: WritingAction
    }

    let modelVersion = "spy/v1"
    var answerResult: Result<String, any Error> = .success("resposta")
    var transformResult: Result<String, any Error> = .success("Oi Marina,\n\nFechado.")
    private(set) var answers: [AssistantConversationSnapshot] = []
    private(set) var transforms: [TransformCall] = []
    var beforeAnswer: (@Sendable () async -> Void)?

    func availability() async -> AppleIntelligenceAvailability { .available }

    func answer(question: String, in conversation: AssistantConversationSnapshot) async throws -> String {
        answers.append(conversation)
        await beforeAnswer?()
        return try answerResult.get()
    }

    func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String {
        transforms.append(.init(text: text, action: action))
        return try transformResult.get()
    }
}

@Suite("Máquina de estado do assistente")
@MainActor
struct AssistantConversationTests {
    private let emailContext = AssistantMailContext.email(
        AssistantEmailContext(subject: "Revisão", sender: "marina@example.com", body: "Podemos amanhã?")
    )
    private let destination = AssistantDestination(
        label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false
    )

    private func conversation(
        _ spy: SpyTextAssistant,
        scope: AssistantScope = .email
    ) -> AssistantConversation {
        AssistantConversation(
            scope: scope,
            context: .init(subject: "Revisão", sender: "Marina"),
            destination: destination,
            engine: AssistantBridge.engine(
                using: spy,
                supportsDraftReply: scope == .email,
                mailContext: { self.emailContext }
            )
        )
    }

    @Test("draftReply usa transform(.draftReply), nunca answer")
    func draftReplyUsesTransform() async {
        let spy = SpyTextAssistant()
        let conversation = conversation(spy)
        conversation.draftReply()
        await conversation.waitForIdle()

        #expect(spy.transforms == [.init(text: "", action: .draftReply)])
        #expect(spy.answers.isEmpty)
        #expect(conversation.messages.count == 1)
        #expect(conversation.messages[0].speaker == .assistant)
        #expect(conversation.messages[0].kind == .draft)
        #expect(conversation.messages[0].text == "Oi Marina,\n\nFechado.")
        #expect(conversation.failure == nil)
    }

    @Test("no ambiente inteiro não existe rascunho")
    func workspaceHasNoDraftReply() {
        let conversation = conversation(SpyTextAssistant(), scope: .workspace)
        #expect(!conversation.canDraftReply)
    }

    @Test("cancelar durante uma pergunta deixa o estado ocioso e sem erro")
    func cancelLeavesIdle() async {
        let spy = SpyTextAssistant()
        let started = AsyncGate()
        spy.beforeAnswer = { await started.openAndWaitForever() }
        let conversation = conversation(spy)
        conversation.ask("O que é urgente?")
        await started.waitUntilOpen()
        #expect(conversation.isLoading)

        conversation.cancel()
        await conversation.waitForIdle()
        #expect(!conversation.isLoading)
        #expect(conversation.failure == nil)
    }

    @Test("o histórico enviado ao motor tem 16 turnos com 20 acumulados")
    func historyIsCappedAtSixteen() async {
        let spy = SpyTextAssistant()
        let conversation = conversation(spy)
        for index in 1...10 {
            conversation.ask("pergunta \(index)")
            await conversation.waitForIdle()
        }
        #expect(conversation.messages.count == 20)

        conversation.ask("pergunta 11")
        await conversation.waitForIdle()
        let sent = try! #require(spy.answers.last)
        // Prender o teto ao literal: sem isto a comparação abaixo seria uma
        // tautologia e mudar a constante não quebraria teste nenhum.
        #expect(AssistantConversation.maximumHistoryTurns == 16)
        // A pergunta atual tem campo próprio no contrato e é retirada do
        // histórico pela ponte; sobram 16 turnos anteriores.
        #expect(sent.turns.count == 16)
        #expect(sent.turns.last?.text == "resposta")
    }

    @Test("resposta vazia vira emptyResponse, e é a única cópia")
    func emptyResponseHasOneCopy() async {
        let spy = SpyTextAssistant()
        spy.answerResult = .success("   \n ")
        let conversation = conversation(spy)
        conversation.ask("O que é urgente?")
        await conversation.waitForIdle()

        #expect(conversation.failure?.message == TextAssistantError.emptyResponse.errorDescription)
        #expect(conversation.failure?.recovery == .retry)
        #expect(conversation.messages.count == 1)
    }

    @Test("briefing vive fora do transcript e só dispara por chamada")
    func briefingIsSeparate() async {
        let spy = SpyTextAssistant()
        spy.answerResult = .success("Hoje: responder Marina às 9h42.")
        let conversation = conversation(spy, scope: .workspace)
        #expect(conversation.briefingText == nil)

        conversation.briefing()
        await conversation.waitForIdle()
        #expect(conversation.briefingText == "Hoje: responder Marina às 9h42.")
        #expect(conversation.messages.isEmpty)
        #expect(spy.answers.count == 1)
    }

    @Test("retry repete a última ação, inclusive o rascunho")
    func retryRepeatsLastAction() async {
        let spy = SpyTextAssistant()
        spy.transformResult = .failure(OpenAICompatibleTextAssistantError.timedOut)
        let conversation = conversation(spy)
        conversation.draftReply()
        await conversation.waitForIdle()
        #expect(conversation.failure?.recovery == .retry)

        spy.transformResult = .success("Oi Marina,")
        conversation.retry()
        await conversation.waitForIdle()
        #expect(spy.transforms.count == 2)
        #expect(conversation.failure == nil)
        #expect(conversation.messages.last?.kind == .draft)
    }

    @Test("limpar apaga transcript, rascunho, erro e briefing")
    func clearResetsEverything() async {
        let spy = SpyTextAssistant()
        let conversation = conversation(spy, scope: .workspace)
        conversation.briefing()
        await conversation.waitForIdle()
        conversation.ask("e depois?")
        await conversation.waitForIdle()

        conversation.clear()
        #expect(conversation.messages.isEmpty)
        #expect(conversation.briefingText == nil)
        #expect(conversation.failure == nil)
        #expect(conversation.draft.isEmpty)
    }
}

/// Portão determinístico: nada de `Task.sleep` para sincronizar teste.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func openAndWaitForever() async {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    func waitUntilOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
