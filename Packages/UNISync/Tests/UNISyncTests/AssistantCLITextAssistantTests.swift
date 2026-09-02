import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("Transporte seguro pelos CLIs de IA")
struct AssistantCLITextAssistantTests {
    private let conversation = AssistantConversationSnapshot(
        mailContext: .email(.init(
            subject: "Planejamento",
            sender: "Marina <marina@example.com>",
            body: "A entrega é sexta-feira."
        ))
    )

    @Test("Codex recebe prompt somente por stdin e ignora eventos de ferramenta")
    func codexUsesStaticArgumentsAndStdin() async throws {
        let executor = RecordingCLIExecutor(result: .init(
            exitStatus: 0,
            standardOutput: Data("""
            {"type":"item.completed","item":{"type":"command_execution","text":"não é resposta"}}
            {"type":"item.completed","item":{"type":"agent_message","text":"A entrega é sexta-feira."}}
            """.utf8)
        ))
        let command = try AssistantCLICommand.make(
            kind: .codex,
            installation: .init(kind: .codex, executablePath: "/opt/homebrew/bin/codex")
        )
        let assistant = AssistantCLITextAssistant(command: command, executor: executor)

        let response = try await assistant.answer(
            question: "Quando é a entrega?",
            in: conversation
        )

        #expect(response == "A entrega é sexta-feira.")
        let request = try #require(await executor.firstRequest())
        #expect(request.executableURL.path == "/opt/homebrew/bin/codex")
        #expect(request.arguments == [
            "exec", "--sandbox", "read-only", "--skip-git-repo-check",
            "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--color", "never", "--json", "-",
        ])
        #expect(!request.arguments.joined(separator: " ").contains("Quando é a entrega?"))
        let prompt = try #require(String(data: request.standardInput, encoding: .utf8))
        #expect(prompt.contains("<okamiuni-cli-policy>"))
        #expect(prompt.contains("Quando é a entrega?"))
        #expect(prompt.contains("A entrega é sexta-feira."))
    }

    @Test("assinatura Codex passa o modelo escolhido sem mudar o CLI genérico")
    func codexSubscriptionUsesSelectedModel() throws {
        let generic = try AssistantCLICommand.make(
            kind: .codex,
            installation: .init(kind: .codex, executablePath: "/opt/homebrew/bin/codex")
        )
        let subscription = try AssistantCLICommand.makeCodexSubscription(
            configuration: .init(kind: .codex, model: "gpt-da-conta"),
            installation: .init(kind: .codex, executablePath: "/opt/homebrew/bin/codex")
        )

        #expect(generic.arguments == [
            "exec", "--sandbox", "read-only", "--skip-git-repo-check",
            "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--color", "never", "--json", "-",
        ])
        #expect(subscription.arguments.suffix(3) == ["--model", "gpt-da-conta", "-"])
        #expect(Set(subscription.environment.keys) == Set(["CODEX_HOME"]))
    }

    @Test("parsers aceitam somente o evento final conhecido de cada CLI")
    func parsesKnownJSONShapes() throws {
        let claude = try AssistantCLIResponseParser.parse(
            Data("""
            {"type":"assistant","message":"ignorar"}
            {"type":"result","is_error":false,"result":"Resposta Claude"}
            """.utf8),
            format: .claudeJSON
        )
        let openCode = try AssistantCLIResponseParser.parse(
            Data("""
            {"type":"tool","part":{"text":"ignorar"}}
            {"type":"text","part":{"text":"Resposta "}}
            {"type":"text","part":{"text":"OpenCode"}}
            """.utf8),
            format: .openCodeJSONLines
        )

        #expect(claude == "Resposta Claude")
        #expect(openCode == "Resposta OpenCode")
        #expect(throws: AssistantCLITextAssistantError.invalidResponse) {
            try AssistantCLIResponseParser.parse(
                Data("{\"type\":\"tool\",\"text\":\"não usar\"}".utf8),
                format: .openCodeJSONLines
            )
        }
    }

    @Test("O adaptador do CLI aceita de 30 a 300 s")
    func clampsRequestTimeoutToSpecRange() async throws {
        #expect(try await cliTimeout(requestTimeout: nil) == 120)
        #expect(try await cliTimeout(requestTimeout: 10) == 30)
        #expect(try await cliTimeout(requestTimeout: 500) == 300)
    }

    private func cliTimeout(requestTimeout: TimeInterval?) async throws -> TimeInterval {
        let executor = RecordingCLIExecutor(result: .init(
            exitStatus: 0,
            standardOutput: Data("""
            {"type":"item.completed","item":{"type":"agent_message","text":"Pronto."}}
            """.utf8)
        ))
        let command = try AssistantCLICommand.make(
            kind: .codex,
            installation: .init(kind: .codex, executablePath: "/opt/homebrew/bin/codex")
        )
        let assistant: AssistantCLITextAssistant
        if let requestTimeout {
            assistant = AssistantCLITextAssistant(
                command: command,
                executor: executor,
                requestTimeout: requestTimeout
            )
        } else {
            assistant = AssistantCLITextAssistant(command: command, executor: executor)
        }
        _ = try await assistant.answer(question: "Quando é a entrega?", in: conversation)
        return try #require(await executor.firstRequest()).timeout
    }

    @Test("Router escolhe CLI detectado sem tocar no cofre de credenciais")
    @available(macOS 26.0, *)
    func routerUsesCLITransport() async throws {
        let suite = "okamiuni.assistant-cli-router.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try settings.save(.init(provider: .cli, cli: .init(kind: .claude)))
        let executor = RecordingCLIExecutor(result: .init(
            exitStatus: 0,
            standardOutput: Data("""
            {"type":"result","is_error":false,"result":"Resposta via sessão Claude."}
            """.utf8)
        ))
        let router = AssistantRouter(
            settingsStore: settings,
            credentialStore: InMemoryAssistantCredentialStore(),
            cliInstallationProvider: {
                [.init(kind: .claude, executablePath: "/usr/local/bin/claude")]
            },
            cliExecutor: executor
        )

        #expect(await router.availability() == .available)
        let response = try await router.answer(question: "Qual é o status?", in: conversation)

        #expect(response == "Resposta via sessão Claude.")
        let request = try #require(await executor.firstRequest())
        #expect(request.arguments.contains("--tools"))
        #expect(request.arguments.contains(""))
        #expect(request.arguments.contains("--safe-mode"))
    }

    @Test("CLI não permitido falha antes de executar")
    func rejectsUnexpectedExecutableName() {
        #expect(throws: AssistantCLITextAssistantError.executableNotAllowed) {
            try AssistantCLICommand.make(
                kind: .codex,
                installation: .init(kind: .codex, executablePath: "/tmp/qualquer-coisa")
            )
        }
    }

    @Test("timeout do executor não expõe a saída do CLI")
    func mapsProcessTimeout() async throws {
        let command = try AssistantCLICommand.make(
            kind: .codex,
            installation: .init(kind: .codex, executablePath: "/usr/local/bin/codex")
        )
        let assistant = AssistantCLITextAssistant(
            command: command,
            executor: TimedOutCLIExecutor()
        )

        await #expect(throws: AssistantCLITextAssistantError.timedOut) {
            try await assistant.answer(question: "Qual é a prioridade?", in: conversation)
        }
    }

    @Test("o CLI que morreu entrega o stderr, não um silêncio")
    func processFailureCarriesStderr() async throws {
        let executor = RecordingCLIExecutor(result: .init(
            exitStatus: 1,
            standardOutput: Data(),
            standardError: Data("error: not logged in\n".utf8)
        ))
        let assistant = AssistantCLITextAssistant(
            command: try AssistantCLICommand.make(
                kind: .codex,
                installation: .init(kind: .codex, executablePath: "/usr/local/bin/codex")
            ),
            executor: executor
        )
        await #expect(throws: AssistantCLITextAssistantError.processFailed(
            exitCode: 1,
            stderrTail: "error: not logged in"
        )) {
            try await assistant.answer(question: "oi", in: conversation)
        }
    }

    @Test("do stderr guardamos a cauda de 4 KiB, não a cabeça")
    func standardErrorKeepsTailWithinCap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-stderr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stderr")

        let banner = String(repeating: "b", count: 8 * 1_024)
        try Data((banner + "\nerror: not logged in\n").utf8).write(to: url)

        let tail = SystemAssistantCLIProcessExecutor.standardErrorTail(at: url)
        #expect(tail.count <= SystemAssistantCLIProcessExecutor.maximumStandardErrorBytes)
        let text = String(decoding: tail, as: UTF8.self)
        #expect(text.contains("error: not logged in"))
        #expect(!text.contains(banner))
    }
}

private actor RecordingCLIExecutor: AssistantCLIProcessExecuting {
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
}

private struct TimedOutCLIExecutor: AssistantCLIProcessExecuting {
    func execute(_ request: AssistantCLIProcessRequest) async throws -> AssistantCLIProcessResult {
        throw AssistantCLIProcessError.timedOut
    }
}
