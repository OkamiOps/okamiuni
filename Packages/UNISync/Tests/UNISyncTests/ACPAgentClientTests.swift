import Foundation
import Darwin
import GRDB
import Testing
@testable import UNISync
import UNICore

@Suite("Cliente ACP v1")
struct ACPAgentClientTests {
    @Test("negocia HTTP MCP, usa cwd temporário e acumula os chunks")
    func streamsAnswerFromPersistentChild() async throws {
        let fixture = try ACPFixture(mode: "stream")
        defer { fixture.remove() }
        let updates = ACPUpdates()

        let answer = try await fixture.client.answer(
            prompt: "Resuma o e-mail.",
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token",
            onUpdate: { text in Task { await updates.append(text) } }
        )

        #expect(answer == "Olá, mundo.")
        try await updates.waitForCount(2)
        #expect(await updates.values() == ["Olá, ", "mundo."])
    }

    @Test("testa o handshake sem enviar prompt ao agente")
    func checksConnectionWithoutPrompt() async throws {
        let fixture = try ACPFixture(mode: "stream")
        defer { fixture.remove() }

        let name = try await fixture.client.checkConnection(
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token"
        )

        #expect(name == "ACP v1")
        #expect(!FileManager.default.fileExists(atPath: fixture.markerURL.path))
    }

    @Test("o filho ACP chama tools/list e tools/call no MCP local autenticado")
    func bridgesACPChildToLocalMCPServer() async throws {
        let calls = ACPBridgeCallRecorder()
        let server = LocalMCPServer(
            tools: [
                .init(
                    name: "okamiuni.lookup",
                    description: "Consulta segura.",
                    inputSchema: .object(["type": .string("object")]),
                    readOnly: true
                ),
            ],
            handler: { name, arguments in
                await calls.append(name: name, arguments: arguments)
                return .object(["ok": .bool(true)])
            }
        )
        let endpoint = try await server.start()
        defer { Task { await server.stop() } }
        let fixture = try ACPFixture(mode: "mcp-bridge")
        defer { fixture.remove() }

        // Exercita a mesma fronteira HTTP por URLSession antes de entregar o
        // endpoint ao filho ACP. O processo falso então faz a segunda chamada
        // real, depois de `tools/list`, usando as credenciais injetadas em
        // `session/new`.
        let preflight = try await mcpCall(
            endpoint: endpoint,
            name: "okamiuni.lookup",
            arguments: .object(["source": .string("URLSession")])
        )
        #expect(preflight["result"]?["isError"]?.boolValue == false)

        let answer = try await fixture.client.answer(
            prompt: "Consulte os dados.",
            mcpURL: endpoint.url,
            bearerToken: endpoint.bearerToken
        )

        #expect(answer == "Ferramenta MCP chamada.")
        #expect(await calls.values() == [
            ACPBridgeCall(name: "okamiuni.lookup", arguments: .object(["source": .string("URLSession")])),
            ACPBridgeCall(name: "okamiuni.lookup", arguments: .object([:]))
        ])
    }

    @Test("o filho ACP salva um rascunho pelo MCP e ele sobrevive a uma nova carga")
    @MainActor
    func bridgeCreatesDurableMailDraft() async throws {
        let database = try SyncDatabase.temporary()
        let account = Account(
            id: "account-1", address: "me@example.com", displayName: "Me",
            provider: .imap, host: "mail.example.com",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7",
            imap: ImapEndpoint(host: "imap.example.com", port: 993, security: .tls),
            state: .ativa
        )
        try await database.pool.write { db in
            try AccountRecord(account, createdAt: Date(timeIntervalSince1970: 1)).insert(db)
        }

        let port = DatabaseCommandPort(database: database)
        let store = MailStore(
            source: DatabaseMailSource(database: database),
            draftPort: port
        )
        await store.load()
        let tools = MailAgentTools(store: store, accountIDs: [account.id])
        let server = LocalMCPServer(
            tools: tools.definitions,
            handler: { name, arguments in
                try await tools.execute(name: name, arguments: arguments)
            }
        )
        let endpoint = try await server.start()
        defer { Task { await server.stop() } }
        let fixture = try ACPFixture(mode: "mcp-draft")
        defer { fixture.remove() }

        let answer = try await fixture.client.answer(
            prompt: "Crie um rascunho para revisão.",
            mcpURL: endpoint.url,
            bearerToken: endpoint.bearerToken
        )
        #expect(answer == "Rascunho salvo pelo MCP.")

        let reloaded = MailStore(
            source: DatabaseMailSource(database: database),
            draftPort: port
        )
        await reloaded.load()
        let saved = try #require(reloaded.messages.first { $0.subject == "Rascunho via ACP" })
        #expect(saved.bucket == .drafts)
        #expect(saved.to.map(\.address) == ["dest@example.com"])
        #expect(saved.accountID == account.id)
        let persisted = try await DatabaseMailSource(database: database).messages()
        let durable = try #require(persisted.first { $0.id == saved.id })
        #expect(durable.body == ["Texto persistido"])
    }

    @Test("recusa o agente sem transporte MCP HTTP antes de criar a sessão")
    func rejectsUnsupportedHTTPTransport() async throws {
        let fixture = try ACPFixture(mode: "unsupported-http")
        defer { fixture.remove() }

        await #expect(throws: ACPAgentClientError.unsupportedHTTPTransport) {
            try await fixture.client.answer(
                prompt: "oi",
                mcpURL: URL(string: "https://mcp.example.test/rpc")!,
                bearerToken: "test-token"
            )
        }
    }

    @Test("não expõe o erro JSON-RPC retornado pelo filho")
    func hidesRemoteErrorDetails() async throws {
        let fixture = try ACPFixture(mode: "error")
        defer { fixture.remove() }

        await #expect(throws: ACPAgentClientError.remoteFailure) {
            try await fixture.client.answer(
                prompt: "oi",
                mcpURL: URL(string: "https://mcp.example.test/rpc")!,
                bearerToken: "test-token"
            )
        }
    }

    @Test("cancelar o turno envia session/cancel ao filho")
    func cancellationSendsSessionCancel() async throws {
        let fixture = try ACPFixture(mode: "cancel")
        defer { fixture.remove() }
        let updates = ACPUpdates()
        let task = Task {
            try await fixture.client.answer(
                prompt: "oi",
                mcpURL: URL(string: "https://mcp.example.test/rpc")!,
                bearerToken: "test-token",
                onUpdate: { text in Task { await updates.append(text) } }
            )
        }

        try await updates.waitForValue("aguardando")
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        try await fixture.waitForMarker()
        #expect(try String(contentsOf: fixture.markerURL, encoding: .utf8) == "cancelled")
    }

    @Test("timeout encerra filho que não lê um prompt maior que o pipe")
    func largeBlockedPromptTimesOutAndExitsChild() async throws {
        let fixture = try ACPFixture(mode: "blocked-prompt", timeout: 1)
        defer { fixture.remove() }

        await #expect(throws: ACPAgentClientError.timedOut) {
            try await fixture.client.answer(
                prompt: String(repeating: "x", count: 256 * 1_024),
                mcpURL: URL(string: "https://mcp.example.test/rpc")!,
                bearerToken: "test-token"
            )
        }

        try await fixture.waitForMarker()
        let rawPID = try String(contentsOf: fixture.markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(rawPID))
        try await fixture.waitForExit(pid: pid)
    }

    @Test("recusa permissão de terminal mesmo quando o agente oferece allow")
    func rejectsGenericTerminalPermission() async throws {
        let fixture = try ACPFixture(mode: "terminal-permission")
        defer { fixture.remove() }

        let answer = try await fixture.client.answer(
            prompt: "oi",
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token"
        )

        #expect(answer == "Recusado.")
        #expect(try String(contentsOf: fixture.markerURL, encoding: .utf8) == "reject-once")
    }

    @Test("só libera uma ferramenta MCP anunciada pelo adaptador oficial")
    func permitsLinkedSafeMCPToolOnce() async throws {
        let fixture = try ACPFixture(
            mode: "linked-safe",
            safeMCPToolNames: ["okamiuni.lookup"]
        )
        defer { fixture.remove() }

        let answer = try await fixture.client.answer(
            prompt: "oi",
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token"
        )

        #expect(answer == "Autorizado.")
        #expect(try String(contentsOf: fixture.markerURL, encoding: .utf8) == "allow-once")
    }

    @Test("autoriza MCP estrutural de adaptador genérico sem metadados Codex")
    func permitsStructuredMCPFromGenericProvider() async throws {
        let fixture = try ACPFixture(
            mode: "generic-structured-mcp",
            safeMCPToolNames: ["okamiuni.lookup"]
        )
        defer { fixture.remove() }

        let answer = try await fixture.client.answer(
            prompt: "oi",
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token"
        )

        #expect(answer == "Autorizado.")
        #expect(try String(contentsOf: fixture.markerURL, encoding: .utf8) == "allow-once")
    }

    @Test("autoriza nome MCP padrão de segundo adaptador sem metadados privados")
    func permitsStandardNamedMCPFromGenericProvider() async throws {
        let fixture = try ACPFixture(
            mode: "generic-standard-mcp",
            safeMCPToolNames: ["okamiuni.lookup"]
        )
        defer { fixture.remove() }

        let answer = try await fixture.client.answer(
            prompt: "oi",
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token"
        )

        #expect(answer == "Autorizado.")
        #expect(try String(contentsOf: fixture.markerURL, encoding: .utf8) == "allow-once")
    }

    @Test("recusa prompt MCP que contradiz o servidor observado")
    func rejectsMismatchedStandardMCPPermission() async throws {
        let fixture = try ACPFixture(
            mode: "generic-mismatched-mcp",
            safeMCPToolNames: ["okamiuni.lookup"]
        )
        defer { fixture.remove() }

        let answer = try await fixture.client.answer(
            prompt: "oi",
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token"
        )

        #expect(answer == "Recusado.")
        #expect(try String(contentsOf: fixture.markerURL, encoding: .utf8) == "reject-once")
    }

    @Test("recusa aprovação MCP cujo ID não corresponde à chamada anunciada")
    func rejectsUnknownMCPPermissionID() async throws {
        let fixture = try ACPFixture(
            mode: "unknown-tool-call",
            safeMCPToolNames: ["okamiuni.lookup"]
        )
        defer { fixture.remove() }

        let answer = try await fixture.client.answer(
            prompt: "oi",
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token"
        )

        #expect(answer == "Recusado.")
        #expect(try String(contentsOf: fixture.markerURL, encoding: .utf8) == "reject-once")
    }

    @Test("recusa aprovação MCP anunciada por servidor diferente")
    func rejectsMCPPermissionFromWrongServer() async throws {
        let fixture = try ACPFixture(
            mode: "wrong-mcp-server",
            safeMCPToolNames: ["okamiuni.lookup"]
        )
        defer { fixture.remove() }

        let answer = try await fixture.client.answer(
            prompt: "oi",
            mcpURL: URL(string: "https://mcp.example.test/rpc")!,
            bearerToken: "test-token"
        )

        #expect(answer == "Recusado.")
        #expect(try String(contentsOf: fixture.markerURL, encoding: .utf8) == "reject-once")
    }
}

private actor ACPUpdates {
    private var stored: [String] = []

    func append(_ value: String) { stored.append(value) }
    func values() -> [String] { stored }

    func waitForValue(_ expected: String) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !stored.contains(expected) {
            guard ContinuousClock.now < deadline else { throw ACPFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForCount(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while stored.count < expected {
            guard ContinuousClock.now < deadline else { throw ACPFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum ACPFixtureError: Error {
    case timedOut
}

private struct ACPBridgeCall: Sendable, Equatable {
    let name: String
    let arguments: AgentJSONValue
}

private actor ACPBridgeCallRecorder {
    private var calls: [ACPBridgeCall] = []

    func append(name: String, arguments: AgentJSONValue) {
        calls.append(.init(name: name, arguments: arguments))
    }

    func values() -> [ACPBridgeCall] { calls }
}

private func mcpCall(
    endpoint: LocalMCPServer.Endpoint,
    name: String,
    arguments: AgentJSONValue
) async throws -> AgentJSONValue {
    let message: AgentJSONValue = .object([
        "jsonrpc": .string("2.0"),
        "id": .number(99),
        "method": .string("tools/call"),
        "params": .object(["name": .string(name), "arguments": arguments]),
    ])
    var request = URLRequest(url: endpoint.url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(endpoint.bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
    request.httpBody = try JSONEncoder().encode(message)
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    return try JSONDecoder().decode(AgentJSONValue.self, from: data)
}

private struct ACPFixture {
    let directory: URL
    let markerURL: URL
    let client: ACPAgentClient

    init(
        mode: String,
        timeout: TimeInterval = 5,
        safeMCPToolNames: Set<String> = [],
        permissionHandler: ACPAgentPermissionHandler? = nil
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-acp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        markerURL = directory.appendingPathComponent("marker")
        let scriptURL = directory.appendingPathComponent("fake-agent.sh")
        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
        client = ACPAgentClient(configuration: .init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [scriptURL.path, mode, markerURL.path],
            timeout: timeout,
            safeMCPToolNames: safeMCPToolNames,
            permissionHandler: permissionHandler
        ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForMarker() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while (try? Data(contentsOf: markerURL).isEmpty) != false {
            guard ContinuousClock.now < deadline else { throw ACPFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForExit(pid: pid_t) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while Darwin.kill(pid, 0) == 0 || errno == EPERM {
            guard ContinuousClock.now < deadline else { throw ACPFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let script = #"""
    #!/bin/sh
    mode="$1"
    marker="$2"
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          case "$mode" in
            unsupported-http)
              printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"http":false}}}}'
              ;;
            error)
              printf '%s\n' '{"jsonrpc":"2.0","id":0,"error":{"code":-32000,"message":"test-token must not escape"}}'
              ;;
            *)
              case "$line" in
                *'"clientCapabilities":{}'*) ;;
                *) exit 31 ;;
              esac
              printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"http":true}}}}'
              ;;
          esac
          ;;
        *'"method":"session/new"'*)
          if [ "$mode" = "mcp-bridge" ] || [ "$mode" = "mcp-draft" ]; then
            mcp_url=$(printf '%s' "$line" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
            mcp_token=$(printf '%s' "$line" | sed -n 's/.*"value":"Bearer \([^"]*\)".*/\1/p')
            [ -n "$mcp_url" ] && [ -n "$mcp_token" ] || exit 38
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}'
            continue
          fi
          case "$line" in
            *'"cwd":"/var/'*|*'"cwd":"/private/var/'*) ;;
            *) exit 32 ;;
          esac
          case "$line" in *'"type":"http"'*) ;; *) exit 33 ;; esac
          case "$line" in *'"name":"okamiuni"'*) ;; *) exit 34 ;; esac
          case "$line" in *'"url":"https://mcp.example.test/rpc"'*) ;; *) exit 35 ;; esac
          case "$line" in *'"Authorization"'*) ;; *) exit 36 ;; esac
          case "$line" in *'"Bearer test-token"'*) ;; *) exit 37 ;; esac
          if [ "$mode" = "blocked-prompt" ]; then
            printf '%s' "$$" > "$marker"
            trap '' TERM
          fi
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}'
          if [ "$mode" = "blocked-prompt" ]; then
            while :; do :; done
          fi
          ;;
        *'"method":"session/prompt"'*)
          case "$mode" in
            stream)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Olá, "}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"mundo."}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
              ;;
            cancel)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"aguardando"}}}}'
              ;;
            terminal-permission)
              printf '%s\n' '{"jsonrpc":"2.0","id":41,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"tool-1","name":"terminal.execute","kind":"execute"},"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}'
              ;;
            linked-safe)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"mcp-call-1","kind":"execute","rawInput":{"server":"okamiuni","tool":"okamiuni.lookup","arguments":{}},"_meta":{"is_mcp_tool_call":true}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"mcp-call-1","kind":"execute"},"_meta":{"is_mcp_tool_approval":true},"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}'
              ;;
            generic-structured-mcp)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"mcp-call-1","kind":"execute","rawInput":{"serverName":"okamiuni","toolName":"okamiuni.lookup","arguments":{}}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"mcp-call-1","kind":"execute"},"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}'
              ;;
            generic-standard-mcp)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"mcp-call-1","name":"mcp__okamiuni__okamiuni.lookup","kind":"execute","rawInput":{"query":"status"}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"mcp-call-1","name":"mcp__okamiuni__okamiuni.lookup","kind":"execute","rawInput":{}},"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}'
              ;;
            generic-mismatched-mcp)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"mcp-call-1","name":"mcp__okamiuni__okamiuni.lookup","kind":"execute","rawInput":{}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"mcp-call-1","name":"mcp__outside__okamiuni.lookup","kind":"execute","rawInput":{}},"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}'
              ;;
            unknown-tool-call)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"mcp-call-1","kind":"execute","rawInput":{"server":"okamiuni","tool":"okamiuni.lookup","arguments":{}},"_meta":{"is_mcp_tool_call":true}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"unknown-call","kind":"execute"},"_meta":{"is_mcp_tool_approval":true},"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}'
              ;;
            wrong-mcp-server)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"mcp-call-1","kind":"execute","rawInput":{"server":"outside","tool":"okamiuni.lookup","arguments":{}},"_meta":{"is_mcp_tool_call":true}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"mcp-call-1","kind":"execute"},"_meta":{"is_mcp_tool_approval":true},"options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject-once","kind":"reject_once"}]}}'
              ;;
            mcp-bridge)
              list=$(curl -sS --max-time 3 -X POST "$mcp_url" -H "Authorization: Bearer $mcp_token" -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-11-25' --data '{"jsonrpc":"2.0","id":10,"method":"tools/list"}') || exit 51
              case "$list" in *'"okamiuni.lookup"'*) ;; *) exit 52 ;; esac
              call=$(curl -sS --max-time 3 -X POST "$mcp_url" -H "Authorization: Bearer $mcp_token" -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-11-25' --data '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"okamiuni.lookup","arguments":{}}}') || exit 53
              case "$call" in *'"ok":true'*) ;; *) exit 54 ;; esac
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Ferramenta MCP chamada."}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
              ;;
            mcp-draft)
              list=$(curl -sS --max-time 3 -X POST "$mcp_url" -H "Authorization: Bearer $mcp_token" -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-11-25' --data '{"jsonrpc":"2.0","id":10,"method":"tools/list"}') || exit 61
              case "$list" in *'"drafts_create"'*) ;; *) exit 62 ;; esac
              call=$(curl -sS --max-time 3 -X POST "$mcp_url" -H "Authorization: Bearer $mcp_token" -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-11-25' --data '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"drafts_create","arguments":{"accountID":"account-1","subject":"Rascunho via ACP","body":"Texto persistido","to":["dest@example.com"],"requestID":"acp-draft-1"}}}') || exit 63
              case "$call" in *'"sent":false'*) ;; *) exit 64 ;; esac
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Rascunho salvo pelo MCP."}}}}'
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
              ;;
          esac
          ;;
        *'"method":"session/cancel"'*)
          printf 'cancelled' > "$marker"
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}'
          ;;
        *'"id":41'*'"outcome"'*)
          case "$line" in *'"optionId":"reject-once"'*) printf 'reject-once' > "$marker" ;; *) exit 41 ;; esac
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Recusado."}}}}'
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
          ;;
        *'"id":42'*'"outcome"'*)
          case "$mode" in
            linked-safe|generic-structured-mcp|generic-standard-mcp)
              case "$line" in *'"optionId":"allow-once"'*) printf 'allow-once' > "$marker" ;; *) exit 42 ;; esac
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Autorizado."}}}}'
              ;;
            *)
              case "$line" in *'"optionId":"reject-once"'*) printf 'reject-once' > "$marker" ;; *) exit 43 ;; esac
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Recusado."}}}}'
              ;;
          esac
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
          ;;
      esac
    done
    """#
}
