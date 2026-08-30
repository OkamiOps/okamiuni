import Testing
@testable import UNISync

@Suite("Descoberta segura de CLIs de IA")
struct AssistantCLIDiscoveryTests {
    @Test("usa allowlist e PATH sem executar nem ler credenciais")
    func findsKnownExecutables() {
        let executables: Set<String> = [
            "/custom/bin/claude",
            "/Users/test/.bun/bin/opencode",
        ]
        let result = AssistantCLIDiscovery(
            environment: ["PATH": "/custom/bin:/usr/bin"],
            homeDirectory: "/Users/test",
            isExecutable: { executables.contains($0) }
        ).scan()

        #expect(result.first { $0.kind == .claude }?.executablePath == "/custom/bin/claude")
        #expect(result.first { $0.kind == .openCode }?.executablePath == "/Users/test/.bun/bin/opencode")
        #expect(result.first { $0.kind == .codex }?.executablePath == nil)
    }

    @Test("prioriza runtime Codex distribuído pelo bundle do app")
    func prioritizesBundledCodexRuntime() {
        let bundled = "/Applications/OkamiUNI.app/Contents/Resources/codex"
        let fromPath = "/usr/local/bin/codex"
        let result = AssistantCLIDiscovery(
            environment: ["PATH": "/usr/local/bin"],
            homeDirectory: "/Users/test",
            bundleResourceDirectory: "/Applications/OkamiUNI.app/Contents/Resources",
            isExecutable: { $0 == bundled || $0 == fromPath }
        ).scan()

        #expect(result.first { $0.kind == .codex }?.executablePath == bundled)
    }

    @Test("não transforma um arquivo desconhecido em provedor")
    func ignoresUnknownExecutables() {
        let result = AssistantCLIDiscovery(
            environment: ["PATH": "/custom/bin"],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/custom/bin/qualquer-ia" }
        ).scan()

        #expect(result.allSatisfy { !$0.isDetected })
    }
}
