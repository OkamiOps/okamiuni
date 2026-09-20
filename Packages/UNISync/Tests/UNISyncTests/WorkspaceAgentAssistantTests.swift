import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("Loop de ferramentas do assistente de espaço")
struct WorkspaceAgentAssistantTests {
    private let conversation = AssistantConversationSnapshot(
        mailContext: .email(.init(subject: "Status", sender: "ana@example.com", body: "A atualização chegou."))
    )

    @Test("executa duas rodadas e devolve o resultado observado à próxima")
    func executesTwoRoundsBeforeFinalAnswer() async throws {
        let plannerState = PlannerState(responses: [
            .value(toolCall(name: "mail.search", arguments: .object(["query": .string("atualização")]))),
            .value(answer("Encontrei a atualização.")),
        ])
        let toolState = ToolState(replies: [
            .value(.object(["matches": .array([.object(["id": .string("mail-1")])])])),
        ])
        let tools = ScriptedTools(definitions: [definition("mail.search")], state: toolState)

        let result = try await AgentToolLoop.run(
            question: "A atualização chegou?",
            conversation: conversation,
            planner: ScriptedPlanner(state: plannerState),
            tools: tools
        )

        #expect(result == "Encontrei a atualização.")
        #expect(await toolState.calls() == [
            ToolInvocation(name: "mail.search", arguments: .object(["query": .string("atualização")]))
        ])
        let prompts = await plannerState.prompts()
        #expect(prompts.count == 2)
        #expect(prompts[1].contains("mail-1"))
        #expect(prompts[1].contains("\"isError\":false") == false)
    }

    @Test("materializa falha da ferramenta para o planejador, sem abortar a rodada")
    func returnsToolErrorsToPlanner() async throws {
        let plannerState = PlannerState(responses: [
            .value(toolCall(name: "mail.search", arguments: .object([:]))),
            .value(answer("A busca falhou; tente de novo depois.")),
        ])
        let toolState = ToolState(replies: [.failure(.unavailable("Banco indisponível."))])
        let tools = ScriptedTools(definitions: [definition("mail.search")], state: toolState)

        let result = try await AgentToolLoop.run(
            question: "Busque a mensagem.",
            conversation: conversation,
            planner: ScriptedPlanner(state: plannerState),
            tools: tools
        )

        #expect(result == "A busca falhou; tente de novo depois.")
        let secondPrompt = try #require(await plannerState.prompts().dropFirst().first)
        #expect(secondPrompt.contains("\"isError\":true"))
        #expect(secondPrompt.contains("Banco indisponível."))
    }

    @Test("propaga cancelamento em vez de transformar em resposta ou erro de ferramenta")
    func propagatesCancellation() async throws {
        let planner = BlockingPlanner()
        let tools = ScriptedTools(definitions: [definition("mail.search")], state: ToolState(replies: []))
        let task = Task {
            try await AgentToolLoop.run(
                question: "Busque a mensagem.",
                conversation: conversation,
                planner: planner,
                tools: tools
            )
        }

        try await planner.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("interrompe um plano que continua chamando ferramentas após o limite")
    func enforcesRoundLimit() async throws {
        let plannerState = PlannerState(responses: [
            .value(toolCall(name: "mail.search", arguments: .object([:]))),
            .value(toolCall(name: "mail.search", arguments: .object([:]))),
        ])
        let tools = ScriptedTools(
            definitions: [definition("mail.search")],
            state: ToolState(replies: [.value(.object([:])), .value(.object([:]))])
        )

        do {
            _ = try await AgentToolLoop.run(
                question: "Continue procurando.",
                conversation: conversation,
                planner: ScriptedPlanner(state: plannerState),
                tools: tools,
                maximumRounds: 2
            )
            Issue.record("O loop aceitou mais rodadas que o limite.")
        } catch let error as AgentToolError {
            guard case .unavailable = error else {
                Issue.record("Erro inesperado: \(error)")
                return
            }
        }
    }

    @Test("recusa resposta do planejador que não é o JSON estruturado do protocolo")
    func rejectsMalformedPlannerResponse() async throws {
        let plannerState = PlannerState(responses: [.value("uma resposta em prosa, sem JSON")])
        let tools = ScriptedTools(definitions: [definition("mail.search")], state: ToolState(replies: []))

        do {
            _ = try await AgentToolLoop.run(
                question: "Busque a mensagem.",
                conversation: conversation,
                planner: ScriptedPlanner(state: plannerState),
                tools: tools
            )
            Issue.record("O loop aceitou uma resposta malformada.")
        } catch let error as AgentToolError {
            guard case .unavailable = error else {
                Issue.record("Erro inesperado: \(error)")
                return
            }
        }
    }

    @Test("preserva o catálogo inteiro, inclusive ferramenta além do orçamento de 2 KiB da pergunta")
    func preservesLargeToolCatalog() async throws {
        let definitions = (0..<48).map { index in
            definition(
                index == 47 ? "catalog.last.sentinel" : "catalog.tool.\(index)",
                description: String(repeating: "descrição \(index) ", count: 18)
            )
        }
        let plannerState = PlannerState(responses: [.value(answer("Catálogo recebido."))])
        let tools = ScriptedTools(definitions: definitions, state: ToolState(replies: []))

        let result = try await AgentToolLoop.run(
            question: "O que você pode consultar?",
            conversation: conversation,
            planner: ScriptedPlanner(state: plannerState),
            tools: tools
        )

        #expect(result == "Catálogo recebido.")
        let prompt = try #require(await plannerState.prompts().first)
        #expect(prompt.utf8.count > 2_000)
        #expect(prompt.contains("catalog.last.sentinel"))
    }

    private func definition(_ name: String, description: String = "Consulta segura no OkamiUNI.") -> AgentToolDefinition {
        AgentToolDefinition(
            name: name,
            description: description,
            inputSchema: .object(["type": .string("object")]),
            readOnly: true
        )
    }

    private func toolCall(name: String, arguments: AgentJSONValue) -> String {
        try! AgentJSONValue.object([
            "toolCalls": .array([.object([
                "name": .string(name),
                "arguments": arguments,
            ])]),
        ]).jsonString()
    }

    private func answer(_ value: String) -> String {
        try! AgentJSONValue.object(["answer": .string(value)]).jsonString()
    }
}

private struct ScriptedPlanner: AgentPlanning {
    let state: PlannerState

    func agentPlan(prompt: String) async throws -> String {
        try await state.next(prompt: prompt)
    }
}

private actor PlannerState {
    enum Reply: Sendable {
        case value(String)
    }

    private var responses: [Reply]
    private var recordedPrompts: [String] = []

    init(responses: [Reply]) { self.responses = responses }

    func next(prompt: String) throws -> String {
        recordedPrompts.append(prompt)
        guard !responses.isEmpty else { throw AgentToolError.unavailable("Plano sem resposta.") }
        let response = responses.removeFirst()
        switch response {
        case let .value(value): return value
        }
    }

    func prompts() -> [String] { recordedPrompts }
}

private struct ScriptedTools: AgentToolExecuting {
    let definitions: [AgentToolDefinition]
    let state: ToolState

    func execute(name: String, arguments: AgentJSONValue) async throws -> AgentJSONValue {
        try await state.execute(name: name, arguments: arguments)
    }
}

private struct ToolInvocation: Sendable, Equatable {
    let name: String
    let arguments: AgentJSONValue
}

private actor ToolState {
    enum Reply: Sendable {
        case value(AgentJSONValue)
        case failure(AgentToolError)
    }

    private var replies: [Reply]
    private var recordedCalls: [ToolInvocation] = []

    init(replies: [Reply]) { self.replies = replies }

    func execute(name: String, arguments: AgentJSONValue) throws -> AgentJSONValue {
        recordedCalls.append(.init(name: name, arguments: arguments))
        guard !replies.isEmpty else { throw AgentToolError.unavailable("Ferramenta sem resposta.") }
        switch replies.removeFirst() {
        case let .value(value): return value
        case let .failure(error): throw error
        }
    }

    func calls() -> [ToolInvocation] { recordedCalls }
}

private actor BlockingPlanner: AgentPlanning {
    private var started = false

    func agentPlan(prompt: String) async throws -> String {
        started = true
        try await Task.sleep(for: .seconds(30))
        return ""
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !started {
            guard ContinuousClock.now < deadline else { throw WorkspaceAgentAssistantTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum WorkspaceAgentAssistantTestError: Error {
    case timedOut
}
