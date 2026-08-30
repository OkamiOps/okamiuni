import Foundation
import Testing
@testable import UNISync

@Suite("Estado de autenticação seguro dos CLIs")
struct AssistantCLIAuthenticationProbeTests {
    @Test("Codex consulta apenas login status sem prompt e confirma sessão")
    func codexUsesAllowlistedStatusCommand() async throws {
        let executor = RecordingAuthenticationProbeExecutor(result: .init(
            exitStatus: 0,
            standardOutput: Data("Logged in using ChatGPT".utf8)
        ))
        let probe = AssistantCLIAuthenticationProbe(executor: executor, requestTimeout: 3)

        let status = await probe.status(for: .init(
            kind: .codex,
            executablePath: "/usr/local/bin/codex"
        ))

        #expect(status.state == .authenticated)
        let request = try #require(await executor.firstRequest())
        #expect(request.executableURL.path == "/usr/local/bin/codex")
        #expect(request.arguments == ["login", "status"])
        #expect(request.standardInput.isEmpty)
        #expect(request.timeout == 3)
        #expect(request.maximumOutputBytes == AssistantCLIAuthenticationProbe.maximumStatusOutputBytes)
    }

    @Test("Claude usa JSON de status e respeita logout mesmo com erro de processo")
    func claudeParsesExplicitLoggedOutState() async throws {
        let executor = RecordingAuthenticationProbeExecutor(result: .init(
            exitStatus: 1,
            standardOutput: Data("{\"loggedIn\":false}".utf8)
        ))
        let probe = AssistantCLIAuthenticationProbe(executor: executor)

        let status = await probe.status(for: .init(
            kind: .claude,
            executablePath: "/opt/homebrew/bin/claude"
        ))

        #expect(status.state == .unauthenticated)
        let request = try #require(await executor.firstRequest())
        #expect(request.arguments == ["auth", "status", "--json"])
        #expect(request.standardInput.isEmpty)
    }

    @Test("OpenCode só aceita booleano explícito e não presume sessão pela lista")
    func openCodeRequiresExplicitAuthenticationEvidence() async throws {
        let executor = RecordingAuthenticationProbeExecutor(result: .init(
            exitStatus: 0,
            standardOutput: Data("[{\"provider\":\"openai\",\"authenticated\":true}]".utf8)
        ))
        let probe = AssistantCLIAuthenticationProbe(executor: executor)

        let status = await probe.status(for: .init(
            kind: .openCode,
            executablePath: "/usr/local/bin/opencode"
        ))

        #expect(status.state == .authenticated)
        let request = try #require(await executor.firstRequest())
        #expect(request.arguments == ["auth", "list"])
        #expect(request.standardInput.isEmpty)
    }

    @Test("Binário ausente é unavailable e falha de execução continua unknown")
    func distinguishesUnavailableFromInconclusiveStatus() async {
        let executor = RecordingAuthenticationProbeExecutor(result: .init(
            exitStatus: 0,
            standardOutput: Data("Logged in using ChatGPT".utf8)
        ))
        let probe = AssistantCLIAuthenticationProbe(executor: executor)

        let missing = await probe.status(for: .init(kind: .codex, executablePath: nil))
        #expect(missing.state == .unavailable)
        let unexpected = await probe.status(for: .init(
            kind: .codex,
            executablePath: "/tmp/nao-e-codex"
        ))
        #expect(unexpected.state == .unavailable)
        #expect(await executor.requestCount() == 0)

        let blocked = AssistantCLIAuthenticationProbe(executor: FailingAuthenticationProbeExecutor())
        let unknown = await blocked.status(for: .init(
            kind: .codex,
            executablePath: "/usr/local/bin/codex"
        ))
        #expect(unknown.state == .unknown)
    }

    @Test("Saída grande ou sem evidência nunca vira sessão autenticada")
    func refusesOversizedAndAmbiguousOutput() async {
        let oversized = RecordingAuthenticationProbeExecutor(result: .init(
            exitStatus: 0,
            standardOutput: Data(repeating: 65, count: AssistantCLIAuthenticationProbe.maximumStatusOutputBytes + 1)
        ))
        let probe = AssistantCLIAuthenticationProbe(executor: oversized)
        let status = await probe.status(for: .init(
            kind: .openCode,
            executablePath: "/usr/local/bin/opencode"
        ))
        #expect(status.state == .unknown)
    }
}

private actor RecordingAuthenticationProbeExecutor: AssistantCLIProcessExecuting {
    private let result: AssistantCLIProcessResult
    private var requests: [AssistantCLIProcessRequest] = []

    init(result: AssistantCLIProcessResult) {
        self.result = result
    }

    func execute(_ request: AssistantCLIProcessRequest) async throws -> AssistantCLIProcessResult {
        requests.append(request)
        return result
    }

    func firstRequest() -> AssistantCLIProcessRequest? {
        requests.first
    }

    func requestCount() -> Int {
        requests.count
    }
}

private struct FailingAuthenticationProbeExecutor: AssistantCLIProcessExecuting {
    func execute(_ request: AssistantCLIProcessRequest) async throws -> AssistantCLIProcessResult {
        throw AssistantCLIProcessError.failedToStart
    }
}
