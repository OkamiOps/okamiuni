import Foundation
import Testing
@testable import UNISync

@Suite("Preferências do agente ACP")
struct AgentConnectionConfigurationTests {
    @Test("preferências antigas mantêm ACP desligado e o provedor escolhido")
    func legacySettings() throws {
        let old = Data(#"{"schemaVersion":5,"provider":"cli","cli":{"kind":"codex"}}"#.utf8)
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: old).migrated()
        #expect(settings.provider == .cli)
        #expect(!settings.agent.enabled)
    }

    @Test("runtime ausente não apaga preferências; só a conexão falha")
    func missingRuntimeRetainsSettings() throws {
        let config = AgentConnectionConfiguration(enabled: true, executablePath: "/missing/okamiuni-acp-agent", arguments: ["agent.js"])
        let settings = AssistantSettings(provider: .cli, agent: config, additionalInstructions: "Preserve meu tom")
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: encoded).migrated()
        #expect(decoded.agent == config)
        #expect(decoded.additionalInstructions == "Preserve meu tom")
        #expect(decoded.provider == .cli)
        #expect(throws: (any Error).self) { try decoded.agent.validated() }
    }

    @Test("argumentos são valores literais; caminho relativo é recusado")
    func literalArguments() throws {
        let config = AgentConnectionConfiguration(enabled: true, executablePath: "/bin/echo", arguments: ["$(touch /tmp/never)", "two words"])
        #expect(try config.validated().arguments == config.arguments)
        #expect(throws: (any Error).self) {
            try AgentConnectionConfiguration(enabled: true, executablePath: "codex-acp").validated()
        }
    }
}
