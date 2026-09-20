import Foundation
import Testing
import GRDB
@testable import UNISync
import UNICore

/// Explicit opt-in integration gate. Uses a temporary SQLite store containing
/// fixtures only, and never exposes a sending port or the user's mail database.
@Suite("Agente ACP real", .enabled(if: ProcessInfo.processInfo.environment["OKAMIUNI_LIVE_ACP_NODE"] != nil))
struct LiveAgentTests {
    @Test("Codex via ACP usa MCP e salva um rascunho que reabre do SQLite")
    @MainActor
    func realAdapterSavesDraft() async throws {
        let environment = ProcessInfo.processInfo.environment
        let node = try #require(environment["OKAMIUNI_LIVE_ACP_NODE"])
        let script = try #require(environment["OKAMIUNI_LIVE_ACP_SCRIPT"])
        let database = try SyncDatabase.temporary()
        let store = MailStore(source: InMemoryMailSource.fixtures, draftPort: DatabaseCommandPort(database: database))
        await store.load()
        let account = try #require(store.accounts.first)
        try await database.pool.write { db in
            try AccountRecord(account, createdAt: Date()).save(db)
        }
        let tools = MailAgentTools(store: store, accountIDs: [account.id])
        let server = LocalMCPServer(tools: tools.definitions) { name, arguments in
            print("LIVE MCP TOOL: " + name)
            return try await tools.execute(name: name, arguments: arguments)
        }
        let endpoint = try await server.start()
        do {
            let client = ACPAgentClient(configuration: .init(
                executableURL: URL(fileURLWithPath: node), arguments: [script],
                environment: ["INITIAL_AGENT_MODE": "read-only", "NO_BROWSER": "1"], timeout: 180,
                safeMCPToolNames: Set(tools.definitions.map(\.name))
            ))
            let answer = try await client.answer(prompt: """
                Teste de integração com dados fictícios. Use SOMENTE o servidor MCP okamiuni.
                Não use terminal, arquivos, outros servidores, plugins ou rede externa.
                Chame accounts_list. Em seguida chame drafts_create na primeira conta:
                to=["review@example.com"], subject="ACP integration fixture",
                body="Rascunho criado pelo agente para validação.", requestID="live-acp-fixture-1".
                Consulte drafts_get com o draftID retornado. Responda brevemente que foi salvo.
                Não envie email. Não peça confirmação: este rascunho de teste está autorizado.
                """, mcpURL: endpoint.url, bearerToken: endpoint.bearerToken)
            print("LIVE FIXTURE ANSWER: " + answer)
            #expect(!answer.isEmpty)
            let draft = try #require(store.messages.first { $0.subject == "ACP integration fixture" && $0.bucket == .drafts })
            #expect(draft.body == ["Rascunho criado pelo agente para validação."])
            #expect(draft.to.map(\.address) == ["review@example.com"])
            let reopened = try await DatabaseMailSource(database: database).snapshot()
            #expect(reopened.messages.contains { $0.id == draft.id && $0.bucket == .drafts })
            await server.stop()
        } catch { await server.stop(); throw error }
    }
    @Test("Codex no ciclo nativo salva e confirma o rascunho")
    @MainActor
    func nativePlannerSavesDraft() async throws {
        let installation = try #require(AssistantCLIDiscovery().scan().first { $0.kind == .codex && $0.isDetected })
        let command = try AssistantCLICommand.make(kind: .codex, installation: installation)
        let planner = AssistantCLITextAssistant(command: command)
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let tools = MailAgentTools(store: store)
        let account = try #require(store.accounts.first)
        let context = AssistantConversationSnapshot(mailContext: .email(.init(subject: "Teste", sender: "review@example.com", body: "Dados fictícios")))
        let result = try await AgentToolLoop.run(
            question: "Crie um rascunho na conta \(account.id), para review@example.com, assunto Native agent fixture, texto Teste do agente nativo. Não envie. Salve usando requestID native-live-1 e depois confirme com drafts_get.",
            conversation: context, planner: planner, tools: tools
        )
        #expect(!result.isEmpty)
        #expect(store.messages.contains { $0.subject == "Native agent fixture" && $0.bucket == .drafts && $0.body == ["Teste do agente nativo."] })
    }
}
