import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Ferramentas independentes do provedor")
struct AgentProviderCompatibilityTests {
    @Test("endpoint compatível mantém modelo e executa o mesmo rascunho", arguments: [
        "openai/gpt", "anthropic/claude", "google/gemini", "xai/grok", "ollama/local", "custom-model"
    ])
    @MainActor
    func compatibleEndpoints(model: String) async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let account = try #require(store.accounts.first)
        let plan = try createPlan(accountID: account.id)
        let replies = [plan, #"{"answer":"Rascunho salvo para revisão."}"#].map { reply in
            StubURLProtocol.Reply.json(String(decoding: try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": reply]]]
            ]), as: UTF8.self))
        }
        let session = StubURLProtocol.session(routes: ["/v1/chat/completions": replies])
        let planner = try OpenAICompatibleTextAssistant(configuration: .init(
            endpoint: "https://models.example/v1", model: model, credentialID: "", authenticationMode: .none
        ), session: session)
        _ = try await AgentToolLoop.run(question: "Prepare a resposta.", conversation: context,
                                       planner: planner, tools: MailAgentTools(store: store))
        #expect(store.messages.contains { $0.subject == "Provider fixture" && $0.bucket == .drafts })
        let requests = StubURLProtocol.requests(for: session)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.authorization == nil })
        for request in requests {
            let payload = try #require(JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
            #expect(payload["model"] as? String == model)
        }
        #expect(requests[1].body.contains("draftID"))
    }

    @Test("CLI recebe catálogo e devolve resultado sem executar ferramentas próprias", arguments: AssistantCLIKind.allCases)
    @MainActor
    func cliTransports(kind: AssistantCLIKind) async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let account = try #require(store.accounts.first)
        let executor = CompatibilityCLIExecutor(kind: kind, replies: [try createPlan(accountID: account.id), #"{"answer":"Salvo."}"#])
        let command = try AssistantCLICommand.make(kind: kind, installation: .init(kind: kind, executablePath: "/fixture/" + kind.executableNames[0]))
        let planner = AssistantCLITextAssistant(command: command, executor: executor)
        _ = try await AgentToolLoop.run(question: "Crie o rascunho.", conversation: context,
                                       planner: planner, tools: MailAgentTools(store: store))
        #expect(store.messages.contains { $0.subject == "Provider fixture" && $0.bucket == .drafts })
        let requests = await executor.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { String(decoding: $0.standardInput, as: UTF8.self).contains("drafts_create") })
        #expect(requests.allSatisfy { !$0.arguments.contains("Provider fixture") })
    }

    @Test("provedor de texto customizado participa do loop em vez de perder ferramentas")
    @MainActor
    func customTextAssistant() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let account = try #require(store.accounts.first)
        let assistant = CompatibilityTextAssistant(replies: [try createPlan(accountID: account.id), #"{"answer":"Salvo."}"#])
        let workspace = WorkspaceAgentAssistant(base: assistant, settings: { .default }, makeTools: { MailAgentTools(store: store) })
        let answer = try await workspace.answerWithProposals(question: "Prepare um rascunho.", in: context)
        #expect(answer.text == "Salvo.")
        #expect(store.messages.contains { $0.subject == "Provider fixture" && $0.bucket == .drafts })
    }

    @Test("resposta malformada é reparada uma vez, sem repetir mutação")
    @MainActor
    func repairsMalformedJSON() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let account = try #require(store.accounts.first)
        let planner = CompatibilityPlanner(replies: ["Vou preparar!", try createPlan(accountID: account.id), #"{"answer":"Salvo."}"#])
        _ = try await AgentToolLoop.run(question: "Prepare um rascunho.", conversation: context,
                                       planner: planner, tools: MailAgentTools(store: store))
        #expect(store.messages.filter { $0.subject == "Provider fixture" }.count == 1)
        #expect(await planner.prompts[1].contains("protocolError"))
    }

    @Test("modelo compacto descobre o schema completo sem incluir corpos grandes no contexto")
    @MainActor
    func compactSchemaDiscovery() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let planner = CompatibilityPlanner(replies: [#"{"toolCalls":[{"name":"tool_describe","arguments":{"name":"drafts_create"}}]}"#, #"{"answer":"Schema consultado."}"#], compact: true)
        _ = try await AgentToolLoop.run(question: "Como criar?", conversation: context,
                                       planner: planner, tools: MailAgentTools(store: store))
        let prompts = await planner.prompts
        #expect(prompts[0].contains("tool_describe"))
        #expect(!prompts[0].contains("inputSchema"))
        #expect(prompts[1].contains("inputSchema"))
        #expect(prompts[1].contains("requestID"))
    }

    @Test("erro de argumentos devolve schema e a próxima etapa recebe o progresso confirmado")
    @MainActor
    func repairsToolArguments() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let account = try #require(store.accounts.first)
        let badPlan = try createPlan(accountID: account.id).replacingOccurrences(of: "\"to\":[\"review@example.com\"]", with: "\"to\":\"review@example.com\"")
        let planner = CompatibilityPlanner(replies: [badPlan, try createPlan(accountID: account.id), #"{"answer":"Salvo."}"#], compact: true)
        _ = try await AgentToolLoop.run(question: "Crie um rascunho.", conversation: context,
                                       planner: planner, tools: MailAgentTools(store: store))
        let prompts = await planner.prompts
        #expect(prompts[1].contains("inputSchema"))
        #expect(prompts[1].contains("Invalid argument: to"))
        #expect(prompts[2].contains("Chamadas já concluídas com sucesso, em ordem: drafts_create"))
        #expect(store.messages.filter { $0.subject == "Provider fixture" }.count == 1)
    }

    private var context: AssistantConversationSnapshot {
        .init(mailContext: .email(.init(subject: "Fixture", sender: "review@example.com", body: "Dados fictícios")))
    }
    private func createPlan(accountID: String) throws -> String {
        try AgentJSONValue.object(["toolCalls": .array([.object(["name": .string("drafts_create"), "arguments": .object([
            "accountID": .string(accountID), "subject": .string("Provider fixture"), "body": .string("Texto de teste."),
            "to": .array([.string("review@example.com")]), "requestID": .string("provider-fixture-1")
        ])])])]).jsonString()
    }
}

private actor CompatibilityCLIExecutor: AssistantCLIProcessExecuting {
    let kind: AssistantCLIKind
    var replies: [String]
    var requests: [AssistantCLIProcessRequest] = []
    init(kind: AssistantCLIKind, replies: [String]) { self.kind = kind; self.replies = replies }
    func execute(_ request: AssistantCLIProcessRequest) throws -> AssistantCLIProcessResult {
        requests.append(request)
        guard !replies.isEmpty else { throw AgentToolError.unknownTool }
        let text = replies.removeFirst()
        let object: [String: Any]
        switch kind {
        case .codex: object = ["type": "item.completed", "item": ["type": "agent_message", "text": text]]
        case .claude: object = ["type": "result", "is_error": false, "result": text]
        case .openCode: object = ["type": "text", "part": ["text": text]]
        }
        return .init(exitStatus: 0, standardOutput: try JSONSerialization.data(withJSONObject: object))
    }
}

private actor CompatibilityPlanner: AgentPlanning {
    nonisolated let agentPlanningContext: AgentPlanningContext
    var replies: [String]
    var prompts: [String] = []
    init(replies: [String], compact: Bool = false) { self.replies = replies; agentPlanningContext = compact ? .compact : .standard }
    func agentPlan(prompt: String) throws -> String {
        prompts.append(prompt)
        guard !replies.isEmpty else { throw AgentToolError.unknownTool }
        return replies.removeFirst()
    }
}

private actor CompatibilityTextAssistant: TextAssisting {
    nonisolated let modelVersion = "custom/test"
    var replies: [String]
    init(replies: [String]) { self.replies = replies }
    func availability() async -> AppleIntelligenceAvailability { .available }
    func answer(question: String, in conversation: AssistantConversationSnapshot) throws -> String {
        guard !replies.isEmpty else { throw AgentToolError.unknownTool }
        return replies.removeFirst()
    }
    func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String { text }
}
