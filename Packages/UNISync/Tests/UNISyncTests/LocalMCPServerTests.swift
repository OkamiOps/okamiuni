import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("MCP local por HTTP", .serialized)
struct LocalMCPServerTests {
    @Test("negocia, lista e chama ferramentas somente pelo loopback autenticado")
    func servesMCPOverAuthenticatedLoopback() async throws {
        let calls = LocalMCPInvocationRecorder()
        let server = LocalMCPServer(
            tools: [
                AgentToolDefinition(
                    name: "mail.search",
                    description: "Busca mensagens já disponíveis no app.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object(["query": .object(["type": .string("string")])]),
                    ]),
                    readOnly: true
                ),
            ],
            handler: { name, arguments in
                await calls.record(name: name, arguments: arguments)
                return .object([
                    "matches": .array([.object(["subject": .string("Status semanal")])]),
                ])
            }
        )
        let endpoint = try await server.start()
        defer { Task { await server.stop() } }
        #expect(endpoint.url.host == "127.0.0.1")
        #expect(!endpoint.bearerToken.isEmpty)

        let initialize = try await send(
            endpoint: endpoint,
            message: .object([
                "jsonrpc": .string("2.0"),
                "id": .number(1),
                "method": .string("initialize"),
                "params": .object([
                    "protocolVersion": .string("2025-11-25"),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("Local test"), "version": .string("1")]),
                ]),
            ])
        )
        #expect(initialize.statusCode == 200)
        #expect(initialize.body?["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
        #expect(initialize.body?["result"]?["capabilities"]?["tools"]?.objectValue != nil)

        let compatibleInitialize = try await send(
            endpoint: endpoint,
            message: .object([
                "jsonrpc": .string("2.0"),
                "id": .number(9),
                "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("2024-11-05")]),
            ])
        )
        #expect(compatibleInitialize.body?["result"]?["protocolVersion"]?.stringValue == "2024-11-05")

        let initialized = try await send(
            endpoint: endpoint,
            message: .object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized"),
            ])
        )
        #expect(initialized.statusCode == 202)
        #expect(initialized.body == nil)

        let list = try await send(
            endpoint: endpoint,
            message: .object([
                "jsonrpc": .string("2.0"),
                "id": .number(2),
                "method": .string("tools/list"),
            ])
        )
        #expect(list.statusCode == 200)
        let listedTool = try #require(list.body?["result"]?["tools"]?.arrayValue?.first?.objectValue)
        #expect(listedTool["name"]?.stringValue == "mail.search")
        #expect(listedTool["annotations"]?["readOnlyHint"]?.boolValue == true)

        let call = try await send(
            endpoint: endpoint,
            message: .object([
                "jsonrpc": .string("2.0"),
                "id": .number(3),
                "method": .string("tools/call"),
                "params": .object([
                    "name": .string("mail.search"),
                    "arguments": .object(["query": .string("semanal")]),
                ]),
            ])
        )
        #expect(call.statusCode == 200)
        #expect(call.body?["result"]?["isError"]?.boolValue == false)
        #expect(call.body?["result"]?["structuredContent"]?["matches"]?.arrayValue?.count == 1)
        #expect(await calls.snapshot() == [
            LocalMCPInvocation(name: "mail.search", arguments: .object(["query": .string("semanal")]))
        ])
    }

    @Test("recusa autenticação, origem e método inválidos sem chamar a ferramenta")
    func rejectsUnsafeRequestsBeforeToolExecution() async throws {
        let calls = LocalMCPInvocationRecorder()
        let server = LocalMCPServer(
            tools: [
                AgentToolDefinition(
                    name: "mail.search",
                    description: "Busca mensagens.",
                    inputSchema: .object(["type": .string("object")]),
                    readOnly: true
                ),
            ],
            handler: { name, arguments in
                await calls.record(name: name, arguments: arguments)
                return .object([:])
            }
        )
        let endpoint = try await server.start()
        defer { Task { await server.stop() } }
        let call = AgentJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("tools/call"),
            "params": .object(["name": .string("mail.search"), "arguments": .object([:])]),
        ])

        let missingToken = try await send(endpoint: endpoint, message: call, includeToken: false)
        #expect(missingToken.statusCode == 401)

        let badOrigin = try await send(
            endpoint: endpoint,
            message: call,
            origin: "https://attacker.example"
        )
        #expect(badOrigin.statusCode == 403)

        let get = try await send(endpoint: endpoint, method: "GET", message: nil)
        #expect(get.statusCode == 405)

        let unknown = try await send(
            endpoint: endpoint,
            message: .object([
                "jsonrpc": .string("2.0"),
                "id": .number(2),
                "method": .string("mail/send"),
            ])
        )
        #expect(unknown.statusCode == 200)
        #expect(unknown.body?["error"]?["code"]?.intValue == -32601)

        // A única implementação injetada neste ensaio é o gravador em memória:
        // nenhum adaptador de e-mail, conta ou rede externa participa da rota.
        #expect(await calls.snapshot().isEmpty)
    }

    @Test("parar o servidor cancela a ferramenta em voo antes de ela gravar")
    func stopCancelsInFlightToolBeforeMutation() async throws {
        let gate = LocalMCPCancellationGate()
        let server = LocalMCPServer(
            tools: [
                AgentToolDefinition(
                    name: "drafts_create",
                    description: "Cria um rascunho local.",
                    inputSchema: .object(["type": .string("object")]),
                    readOnly: false
                ),
            ],
            handler: { _, _ in
                await gate.markStarted()
                try await Task.sleep(for: .seconds(10))
                await gate.markWrite()
                return .object(["saved": .bool(true)])
            }
        )
        let endpoint = try await server.start()
        let inFlight = Task {
            try await send(
                endpoint: endpoint,
                message: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .number(7),
                    "method": .string("tools/call"),
                    "params": .object(["name": .string("drafts_create"), "arguments": .object([:])]),
                ])
            )
        }

        try await gate.waitUntilStarted()
        await server.stop()
        _ = try? await inFlight.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gate.didWrite() == false)
    }

    private func send(
        endpoint: LocalMCPServer.Endpoint,
        method: String = "POST",
        message: AgentJSONValue?,
        includeToken: Bool = true,
        origin: String? = nil
    ) async throws -> LocalMCPTestResponse {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if includeToken {
            request.setValue("Bearer \(endpoint.bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let message {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
            request.httpBody = try JSONEncoder().encode(message)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        let body = data.isEmpty ? nil : try JSONDecoder().decode(AgentJSONValue.self, from: data)
        return LocalMCPTestResponse(statusCode: http.statusCode, body: body)
    }
}

private struct LocalMCPTestResponse {
    let statusCode: Int
    let body: AgentJSONValue?
}

private struct LocalMCPInvocation: Sendable, Equatable {
    let name: String
    let arguments: AgentJSONValue
}

private actor LocalMCPInvocationRecorder {
    private var calls: [LocalMCPInvocation] = []

    func record(name: String, arguments: AgentJSONValue) {
        calls.append(LocalMCPInvocation(name: name, arguments: arguments))
    }

    func snapshot() -> [LocalMCPInvocation] {
        calls
    }
}

private actor LocalMCPCancellationGate {
    private var started = false
    private var wrote = false

    func markStarted() { started = true }
    func markWrite() { wrote = true }
    func didWrite() -> Bool { wrote }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !started {
            guard ContinuousClock.now < deadline else { throw LocalMCPCancellationTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum LocalMCPCancellationTestError: Error {
    case timedOut
}
