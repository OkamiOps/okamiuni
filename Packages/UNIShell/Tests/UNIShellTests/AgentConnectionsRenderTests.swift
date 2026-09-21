import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

@Suite("Conexões de agentes", .serialized)
@MainActor
struct AgentConnectionsRenderTests {
    @Test("configuração ACP e parceiro A2A cabem na área de ajustes", arguments: [680.0, 920.0])
    func connections(width: Double) throws {
        let configuration = AgentConnectionConfiguration(enabled: true, executablePath: "/runtime/bin/agent", arguments: ["--acp"])
        let delegation = A2AConfiguration(enabled: true, peers: [
            .init(name: "Agente de revisão", cardURL: "https://agent.example/.well-known/agent-card.json")
        ])
        let image = try #require(Render.snapshot(
            ScrollView {
                AgentConnectionsSettings(configuration: .constant(configuration), delegation: .constant(delegation), credentials: nil)
                    .padding(24)
            }.background(Theme.grafite.surface.color).foregroundStyle(Theme.grafite.ink.color),
            named: "agent-connections-\(Int(width))", size: CGSize(width: width, height: 1_220), theme: .grafite
        ))
        #expect(image.pixelsWide == Int(width))
        #expect(image.pixelsHigh == 1_220)
    }
}
