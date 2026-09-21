import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Preferências e composição de agentes")
struct AssistantAgentSettingsTests {
    @Test("um documento anterior ao A2A migra para integração desativada")
    func legacySettingsDefaultToDisabledA2A() throws {
        let legacy = Data(#"{"schemaVersion":5,"provider":"foundationModels"}"#.utf8)

        let settings = try JSONDecoder().decode(AssistantSettings.self, from: legacy).migrated()

        #expect(!settings.a2a.enabled)
        #expect(settings.a2a.peers.isEmpty)
    }

    @Test("persiste pares A2A e somente a referência de credencial")
    func persistsA2APeerCredentialReferenceWithoutSecret() throws {
        let suite = "okamiuni.assistant-agent-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let peer = A2APeerConfiguration(
            id: "research",
            name: "Research",
            cardURL: "https://research.example/.well-known/agent-card.json",
            credentialID: "a2a-research-keychain-item",
            enabled: true
        )
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        let saved = try store.save(AssistantSettings(a2a: .init(enabled: true, peers: [peer])))

        #expect(saved.a2a == .init(enabled: true, peers: [peer]))
        let document = try #require(defaults.data(forKey: "assistant"))
        let object = try #require(JSONSerialization.jsonObject(with: document) as? [String: Any])
        let a2a = try #require(object["a2a"] as? [String: Any])
        let peers = try #require(a2a["peers"] as? [[String: Any]])
        let storedPeer = try #require(peers.first)
        #expect(storedPeer["credentialID"] as? String == "a2a-research-keychain-item")
        #expect(storedPeer["token"] == nil)
        #expect(!String(decoding: document, as: UTF8.self).contains("Bearer actually-secret"))
    }

    @Test("rejeita IDs A2A duplicados durante a migração")
    func rejectsDuplicateA2APeers() {
        let peer = A2APeerConfiguration(
            id: "duplicate",
            name: "Duplicate",
            cardURL: "https://agent.example/card",
            enabled: true
        )
        let settings = AssistantSettings(a2a: .init(enabled: true, peers: [peer, peer]))

        #expect(throws: A2AClientError.invalidConfiguration) {
            try settings.migrated()
        }
    }

    @Test("despacha cada ferramenta para seu grupo e recusa duplicatas")
    func workspaceToolSetDispatchesAndRejectsDuplicates() async throws {
        let native = AgentToolFixture(name: "native_tool", value: "native")
        let delegated = AgentToolFixture(name: "delegated_tool", value: "delegated")
        let tools = try WorkspaceAgentToolSet([native, delegated])

        #expect(tools.definitions.map(\.name) == ["native_tool", "delegated_tool"])
        #expect(try await tools.execute(name: "native_tool", arguments: .object([:])) == .string("native"))
        #expect(try await tools.execute(name: "delegated_tool", arguments: .object([:])) == .string("delegated"))
        await #expect(throws: (any Error).self) {
            try await tools.execute(name: "missing", arguments: .object([:]))
        }

        let duplicate = AgentToolFixture(name: "native_tool", value: "duplicate")
        #expect(throws: (any Error).self) {
            try WorkspaceAgentToolSet([native, duplicate])
        }
    }
}

private struct AgentToolFixture: AgentToolExecuting {
    let definitions: [AgentToolDefinition]
    let value: String

    init(name: String, value: String) {
        definitions = [.init(
            name: name,
            description: "Fixture tool",
            inputSchema: .object(["type": .string("object")]),
            readOnly: true
        )]
        self.value = value
    }

    func execute(name: String, arguments: AgentJSONValue) async throws -> AgentJSONValue {
        guard definitions.contains(where: { $0.name == name }), arguments.objectValue != nil else {
            throw AgentToolError.unknownTool
        }
        return .string(value)
    }
}
