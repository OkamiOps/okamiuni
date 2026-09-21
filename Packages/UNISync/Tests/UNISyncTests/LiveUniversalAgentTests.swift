import Foundation
import Testing
import UNICore
@testable import UNISync

/// Real models receive fixtures only. Nothing can send mail or reach the
/// user's mailbox database. No provider credential is printed or copied.
@Suite("Agentes reais além do Codex", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OKAMIUNI_LIVE_UNIVERSAL"] == "1"))
struct LiveUniversalAgentTests {
    @Test("Claude autenticado salva e consulta um rascunho", .timeLimit(.minutes(3)))
    @MainActor
    func claudeDraftWorkflow() async throws {
        let installation = try #require(AssistantCLIDiscovery().scan().first { $0.kind == .claude && $0.isDetected })
        let command = try AssistantCLICommand.make(kind: .claude, installation: installation)
        try await workflow(planner: AssistantCLITextAssistant(command: command), label: "Claude")
    }

    @Test("Apple Intelligence usa o catálogo compacto e salva um rascunho", .timeLimit(.minutes(3)),
          .enabled(if: FoundationModelsTextAssistant.systemAvailability == .available))
    @MainActor
    func foundationModelsDraftWorkflow() async throws {
        try await workflow(planner: LiveTracePlanner(base: FoundationModelsTextAssistant()), label: "Apple")
    }

    @MainActor
    private func workflow(planner: any AgentPlanning, label: String) async throws {
        let database = try SyncDatabase.temporary()
        let store = MailStore(source: InMemoryMailSource.fixtures, draftPort: DatabaseCommandPort(database: database))
        await store.load()
        let account = try #require(store.accounts.first)
        try await database.pool.write { db in try AccountRecord(account, createdAt: Date()).save(db) }
        let tools = MailAgentTools(store: store, accountIDs: [account.id])
        let context = AssistantConversationSnapshot(mailContext: .email(.init(subject: "Teste", sender: "review@example.com", body: "Dados fictícios")))
        let result = try await AgentToolLoop.run(
            question: "Salve um rascunho para revisão na conta \(account.id), para review@example.com. Copie exatamente o assunto ‘Universal fixture \(label)’ e o corpo ‘Texto de validação.’, incluindo o ponto final. Use exatamente o identificador requestID universal-\(label.lowercased())-1. Depois confira o rascunho salvo e confirme. Não envie email.",
            conversation: context, planner: planner, tools: tools, maximumRounds: 10
        )
        #expect(!result.isEmpty)
        let saved = try #require(store.messages.first { $0.subject == "Universal fixture \(label)" && $0.bucket == .drafts })
        #expect(saved.to.map(\.address) == ["review@example.com"])
        #expect(saved.body == ["Texto de validação."])
        let reopened = try await DatabaseMailSource(database: database).snapshot()
        #expect(reopened.messages.contains { $0.id == saved.id })
    }
}

private struct LiveTracePlanner: AgentPlanning {
    let base: any AgentPlanning
    var agentPlanningContext: AgentPlanningContext { base.agentPlanningContext }
    func agentPlan(prompt: String) async throws -> String {
        try await record(prompt: prompt) { try await base.agentPlan(prompt: prompt) }
    }
    func agentPlan(prompt: String, tools: [AgentToolDefinition]) async throws -> String {
        try await record(prompt: prompt) { try await base.agentPlan(prompt: prompt, tools: tools) }
    }
    private func record(prompt: String, operation: () async throws -> String) async throws -> String {
        let result = try await operation()
        if ProcessInfo.processInfo.environment["OKAMIUNI_LIVE_TRACE"] == "1" {
            print("FIXTURE PLANNER INPUT: \(prompt)\nFIXTURE PLANNER OUTPUT: \(result)")
        }
        return result
    }
}
