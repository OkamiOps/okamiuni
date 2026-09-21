import Darwin
import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("Cliente A2A por HTTP real", .serialized)
struct A2AClientTests {
    @Test("descobre, delega só o texto explícito, autentica e busca artefatos")
    func delegatesThroughConfiguredToolOverLoopbackHTTP() async throws {
        let peer = try A2ATestPeer()
        defer { peer.stop() }
        let tool = A2ADelegateTool(
            configuration: .init(enabled: true, peers: [peer.configuration]),
            polling: .init(interval: 0.1, maximumAttempts: 4),
            credentialHeaders: { credentialID in
                #expect(credentialID == "a2a-test-secret")
                return ["Authorization": "Bearer test-only"]
            }
        )

        #expect(tool.definitions.map(\.name) == [
            "a2a_agents_list", "a2a_agents_discover", "a2a_task_delegate",
        ])
        let listed = try await tool.execute(name: "a2a_agents_list", arguments: .object([:]))
        #expect(listed["agents"]?.arrayValue?.first?["peerID"]?.stringValue == "research")

        let discovered = try await tool.execute(
            name: "a2a_agents_discover",
            arguments: .object(["peerID": .string("research")])
        )
        #expect(discovered["agent"]?["name"]?.stringValue == "Loopback research")
        #expect(discovered["agent"]?["skills"]?.arrayValue?.first?["id"]?.stringValue == "summarize")

        let delegated = try await tool.execute(
            name: "a2a_task_delegate",
            arguments: .object([
                "peerID": .string("research"),
                "task": .string("Resuma somente esta frase."),
            ])
        )
        #expect(delegated["response"]?["kind"]?.stringValue == "task")
        #expect(delegated["response"]?["task"]?["state"]?.stringValue == "TASK_STATE_COMPLETED")
        #expect(delegated["response"]?["task"]?["artifacts"]?.arrayValue?.first?["text"]?.stringValue == "Relatório pronto.")

        let requests = peer.requests()
        let cardRequests = requests.filter { $0.target == "/.well-known/agent-card.json" }
        #expect(!cardRequests.isEmpty)
        #expect(cardRequests.allSatisfy { $0.authorization == nil })

        let send = try #require(requests.first { $0.rpcMethod == "SendMessage" })
        #expect(send.authorization == "Bearer test-only")
        #expect(send.body?["params"]?["message"]?["parts"]?.arrayValue?.first?["text"]?.stringValue == "Resuma somente esta frase.")
        #expect(send.body?["params"]?["message"]?["contextId"] == nil)
        #expect(send.body?["params"]?["message"]?["metadata"] == nil)
        #expect(send.body?["params"]?["configuration"]?["returnImmediately"]?.boolValue == true)
        #expect(requests.filter { $0.rpcMethod == "GetTask" }.count == 2)
        #expect(requests.filter { $0.rpcMethod == "GetTask" }.allSatisfy { $0.authorization == "Bearer test-only" })
    }

    @Test("cancelamento A2A é autenticado, tipado e limitado a uma chamada")
    func cancelsTaskThroughJSONRPC() async throws {
        let peer = try A2ATestPeer()
        defer { peer.stop() }
        let client = A2AClient(
            configuration: .init(enabled: true, peers: [peer.configuration]),
            credentialHeaders: { _ in ["Authorization": "Bearer test-only"] }
        )

        let canceled = try await client.cancel(peerID: "research", taskID: "task-1")
        #expect(canceled.id == "task-1")
        #expect(canceled.state == .canceled)
        let calls = peer.requests().filter { $0.rpcMethod == "CancelTask" }
        #expect(calls.count == 1)
        #expect(calls.first?.authorization == "Bearer test-only")
        #expect(calls.first?.body?["params"]?["id"]?.stringValue == "task-1")
    }

    @Test("negocia o Agent Card e métodos JSON-RPC A2A v0.3 por HTTP real")
    func delegatesThroughLegacyV03LoopbackPeer() async throws {
        let peer = try A2ATestPeer(mode: .legacyV03)
        defer { peer.stop() }
        let client = A2AClient(
            configuration: .init(enabled: true, peers: [peer.configuration]),
            polling: .init(interval: 0.1, maximumAttempts: 4),
            credentialHeaders: { _ in ["Authorization": "Bearer test-only"] }
        )

        let response = try await client.delegate(peerID: "research", task: "Somente esta tarefa legada.")
        guard case let .task(task) = response else {
            Issue.record("Expected a completed legacy task.")
            return
        }
        #expect(task.state == .completed)
        #expect(task.artifacts.first?.parts.last?.raw == "cmVsYXRvcmlv")
        #expect(task.artifacts.first?.parts.last?.filename == "report.txt")

        let canceled = try await client.cancel(peerID: "research", taskID: "task-1")
        #expect(canceled.state == .canceled)

        let requests = peer.requests()
        let send = try #require(requests.first { $0.rpcMethod == "message/send" })
        #expect(send.authorization == "Bearer test-only")
        #expect(send.a2aVersion == nil)
        #expect(send.body?["params"]?["message"]?["role"]?.stringValue == "user")
        #expect(send.body?["params"]?["configuration"]?["blocking"]?.boolValue == false)
        #expect(send.body?["params"]?["configuration"]?["returnImmediately"] == nil)
        #expect(requests.filter { $0.rpcMethod == "tasks/get" }.count == 2)
        #expect(requests.filter { $0.rpcMethod == "tasks/cancel" }.count == 1)
    }

    @Test("preserva uma resposta direta de texto sem criar polling artificial")
    func returnsDirectAgentMessage() async throws {
        let peer = try A2ATestPeer(mode: .directMessage)
        defer { peer.stop() }
        let client = A2AClient(
            configuration: .init(enabled: true, peers: [peer.configuration]),
            credentialHeaders: { _ in ["Authorization": "Bearer test-only"] }
        )

        let response = try await client.delegate(peerID: "research", task: "Responda agora.")
        guard case let .message(message) = response else {
            Issue.record("Expected a direct A2A message.")
            return
        }
        #expect(message.text == "Resposta direta.")
        #expect(peer.requests().filter { $0.rpcMethod == "GetTask" }.isEmpty)
    }

    @Test("rejeita endpoint de outra origem antes de enviar a credencial")
    func rejectsCrossOriginInterface() async throws {
        let peer = try A2ATestPeer(mode: .crossOriginInterface)
        defer { peer.stop() }
        let client = A2AClient(
            configuration: .init(enabled: true, peers: [peer.configuration]),
            credentialHeaders: { _ in ["Authorization": "Bearer must-not-leak"] }
        )

        await #expect(throws: A2AClientError.crossOriginEndpoint) {
            try await client.delegate(peerID: "research", task: "Não enviar.")
        }
        let requests = peer.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.target == "/.well-known/agent-card.json")
        #expect(requests.first?.authorization == nil)
    }

    @Test("interrompe polling finito e mascara erro RPC remoto")
    func boundsPollingAndDoesNotPromoteRemoteErrorDetail() async throws {
        let waiting = try A2ATestPeer(mode: .neverCompletes)
        defer { waiting.stop() }
        let client = A2AClient(
            configuration: .init(enabled: true, peers: [waiting.configuration]),
            polling: .init(interval: 0.1, maximumAttempts: 2),
            credentialHeaders: { _ in ["Authorization": "Bearer test-only"] }
        )
        await #expect(throws: A2AClientError.pollLimitReached(taskID: "task-1")) {
            try await client.delegate(peerID: "research", task: "Processo longo.")
        }
        #expect(waiting.requests().filter { $0.rpcMethod == "GetTask" }.count == 2)

        let failing = try A2ATestPeer(mode: .rpcError)
        defer { failing.stop() }
        let badClient = A2AClient(
            configuration: .init(enabled: true, peers: [failing.configuration]),
            credentialHeaders: { _ in ["Authorization": "Bearer test-only"] }
        )
        await #expect(throws: A2AClientError.rpc(code: -32602)) {
            try await badClient.delegate(peerID: "research", task: "Falha esperada.")
        }
    }

    @Test("interrompe um corpo HTTP sem Content-Length ao ultrapassar o limite")
    func rejectsChunkedOversizedResponse() async throws {
        let peer = try A2ATestPeer(mode: .chunkedOversizedResponse)
        defer { peer.stop() }
        let client = A2AClient(
            configuration: .init(enabled: true, peers: [peer.configuration]),
            polling: .init(maximumResponseBytes: 4_096),
            credentialHeaders: { _ in ["Authorization": "Bearer test-only"] }
        )

        await #expect(throws: A2AClientError.responseTooLarge) {
            try await client.delegate(peerID: "research", task: "Não aceite corpo grande.")
        }
        let rpc = peer.requests().filter { $0.target == "/rpc" }
        #expect(rpc.count == 1)
        #expect(rpc.first?.authorization == "Bearer test-only")
    }
}

/// A complete, socket-backed HTTP peer used to exercise URLSession, Agent Card
/// discovery, JSON-RPC, authentication, polling, artifacts and cancellation.
/// It is intentionally independent of `LocalMCPServer` and URLProtocol mocks.
private final class A2ATestPeer: @unchecked Sendable {
    enum Mode: Sendable {
        case standard
        case legacyV03
        case directMessage
        case neverCompletes
        case crossOriginInterface
        case rpcError
        case chunkedOversizedResponse
    }

    struct Request: Sendable {
        let target: String
        let authorization: String?
        let a2aVersion: String?
        let body: AgentJSONValue?

        var rpcMethod: String? { body?["method"]?.stringValue }
    }

    let configuration: A2APeerConfiguration
    private let mode: Mode
    private let socket: Int32
    private let port: Int
    private let lock = NSLock()
    private var running = true
    private var seen: [Request] = []
    private var getTaskCount = 0
    private let queue = DispatchQueue(label: "com.okamiuni.tests.a2a-peer")

    init(mode: Mode = .standard) throws {
        self.mode = mode
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw A2ATestPeerError.socket(errno) }
        self.socket = socket
        do {
            var reuse: Int32 = 1
            guard Darwin.setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw A2ATestPeerError.socket(errno)
            }
            var address = sockaddr_in()
            address.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(socket, 8) == 0 else { throw A2ATestPeerError.socket(errno) }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(socket, $0, &length)
                }
            }
            guard named == 0 else { throw A2ATestPeerError.socket(errno) }
            port = Int(UInt16(bigEndian: actual.sin_port))
        } catch {
            Darwin.close(socket)
            throw error
        }

        configuration = .init(
            id: "research",
            name: "Research peer",
            cardURL: "http://127.0.0.1:\(port)",
            credentialID: "a2a-test-secret",
            enabled: true
        )
        queue.async { [weak self] in self?.serve() }
    }

    deinit { stop() }

    func stop() {
        let shouldClose = lock.withLock { () -> Bool in
            guard running else { return false }
            running = false
            return true
        }
        guard shouldClose else { return }
        _ = Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    func requests() -> [Request] { lock.withLock { seen } }

    private func serve() {
        while lock.withLock({ running }) {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(socket, $0, &length)
                }
            }
            guard client >= 0 else { continue }
            handle(client: client)
            Darwin.close(client)
        }
    }

    private func handle(client: Int32) {
        guard let request = readRequest(client: client) else {
            write(client: client, status: 400, body: .object([:]))
            return
        }
        lock.withLock { seen.append(request) }
        switch request.target {
        case "/.well-known/agent-card.json":
            if mode == .legacyV03 {
                writeRaw(client: client, status: 200, body: legacyCardJSON())
            } else {
                write(client: client, status: 200, body: card())
            }
        case "/rpc":
            if mode == .legacyV03 {
                writeRaw(client: client, status: 200, body: legacyRPCJSON(for: request.body))
            } else if mode == .chunkedOversizedResponse {
                writeChunked(
                    client: client,
                    status: 200,
                    chunks: Array(repeating: Data(repeating: 120, count: 2_048), count: 3)
                )
            } else {
                write(client: client, status: 200, body: rpcResponse(for: request.body))
            }
        default:
            write(client: client, status: 404, body: .object([:]))
        }
    }

    private func card() -> AgentJSONValue {
        let interfaceHost = mode == .crossOriginInterface ? "localhost" : "127.0.0.1"
        return .object([
            "name": .string("Loopback research"),
            "description": .string("An agent only available to the A2A integration test."),
            "version": .string("1.0.0"),
            "capabilities": .object(["streaming": .bool(false)]),
            "supportedInterfaces": .array([.object([
                "url": .string("http://\(interfaceHost):\(port)/rpc"),
                "protocolBinding": .string("JSONRPC"),
                "protocolVersion": .string("1.0"),
                "tenant": .string("test-tenant"),
            ])]),
            "skills": .array([.object([
                "id": .string("summarize"),
                "name": .string("Summarize"),
                "description": .string("Summarizes an explicitly delegated text."),
                "tags": .array([.string("text")]),
            ])]),
        ])
    }

    private func rpcResponse(for request: AgentJSONValue?) -> AgentJSONValue {
        let id = request?["id"] ?? .null
        guard let method = request?["method"]?.stringValue else {
            return rpcError(id: id, code: -32600)
        }
        if mode == .rpcError && method == "SendMessage" { return rpcError(id: id, code: -32602) }
        switch method {
        case "SendMessage":
            if mode == .directMessage {
                return rpcResult(id: id, result: .object(["message": .object([
                    "role": .string("ROLE_AGENT"),
                    "parts": .array([.object(["text": .string("Resposta direta.")])]),
                ])]))
            }
            return rpcResult(id: id, result: .object(["task": task(state: "TASK_STATE_WORKING")]))
        case "GetTask":
            let iteration = lock.withLock { () -> Int in
                getTaskCount += 1
                return getTaskCount
            }
            let complete = mode != .neverCompletes && iteration >= 2
            return rpcResult(id: id, result: task(state: complete ? "TASK_STATE_COMPLETED" : "TASK_STATE_WORKING", artifact: complete))
        case "CancelTask":
            return rpcResult(id: id, result: task(state: "TASK_STATE_CANCELED"))
        default:
            return rpcError(id: id, code: -32601)
        }
    }

    private func task(state: String, artifact: Bool = false) -> AgentJSONValue {
        var task: [String: AgentJSONValue] = [
            "id": .string("task-1"),
            "contextId": .string("context-1"),
            "status": .object([
                "state": .string(state),
                "message": .object([
                    "role": .string("ROLE_AGENT"),
                    "parts": .array([.object(["text": .string(state == "TASK_STATE_WORKING" ? "Trabalhando." : "Concluído.")])]),
                ]),
            ]),
        ]
        if artifact {
            let parts: [AgentJSONValue] = [
                .object(["text": .string("Relatório pronto.")]),
                .object(["data": .object(["confidence": .number(0.9)])]),
            ]
            task["artifacts"] = .array([.object([
                "artifactId": .string("report-1"),
                "name": .string("Report"),
                "description": .string("Result from the loopback peer."),
                "parts": .array(parts),
            ])])
        }
        return .object(task)
    }

    /// A deliberately separate v0.3 server implementation. Its Agent Card and
    /// JSON-RPC responses are raw JSON rather than `AgentJSONValue` values, so
    /// this test proves the client accepts the published wire contract rather
    /// than a second use of its own serializer.
    private func legacyCardJSON() -> String {
        """
        {"name":"Loopback research","description":"A legacy A2A v0.3 peer used by the integration test.","version":"0.3-peer","protocolVersion":"0.3.0","url":"http://127.0.0.1:\(port)/rpc","preferredTransport":"JSONRPC","additionalInterfaces":[{"url":"http://127.0.0.1:\(port)/rpc","transport":"JSONRPC"}],"capabilities":{"streaming":false},"skills":[{"id":"summarize","name":"Summarize","description":"Summarizes an explicitly delegated text.","tags":["text"]}]}
        """
    }

    private func legacyRPCJSON(for request: AgentJSONValue?) -> String {
        let id = request?["id"]?.stringValue ?? ""
        guard let method = request?["method"]?.stringValue else { return legacyErrorJSON(id: id, code: -32600) }
        switch method {
        case "message/send":
            return legacyResultJSON(id: id, result: legacyTaskJSON(state: "working"))
        case "tasks/get":
            let iteration = lock.withLock { () -> Int in
                getTaskCount += 1
                return getTaskCount
            }
            return legacyResultJSON(
                id: id,
                result: legacyTaskJSON(state: iteration >= 2 ? "completed" : "working", artifact: iteration >= 2)
            )
        case "tasks/cancel":
            return legacyResultJSON(id: id, result: legacyTaskJSON(state: "canceled"))
        default:
            return legacyErrorJSON(id: id, code: -32601)
        }
    }

    private func legacyTaskJSON(state: String, artifact: Bool = false) -> String {
        let message = state == "working" ? "Trabalhando." : "Concluído."
        let artifacts = artifact
            ? ",\"artifacts\":[{\"artifactId\":\"report-1\",\"name\":\"Report\",\"description\":\"Result from the loopback peer.\",\"parts\":[{\"kind\":\"text\",\"text\":\"Relatório pronto.\"},{\"kind\":\"data\",\"data\":{\"confidence\":0.9}},{\"kind\":\"file\",\"file\":{\"bytes\":\"cmVsYXRvcmlv\",\"name\":\"report.txt\",\"mimeType\":\"text/plain\"}}]}]"
            : ""
        return "{\"id\":\"task-1\",\"contextId\":\"context-1\",\"status\":{\"state\":\"\(state)\",\"message\":{\"role\":\"agent\",\"parts\":[{\"kind\":\"text\",\"text\":\"\(message)\"}]}}\(artifacts)}"
    }

    private func legacyResultJSON(id: String, result: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":\(result)}"
    }

    private func legacyErrorJSON(id: String, code: Int) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"error\":{\"code\":\(code),\"message\":\"legacy test error\"}}"
    }

    private func rpcResult(id: AgentJSONValue, result: AgentJSONValue) -> AgentJSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func rpcError(id: AgentJSONValue, code: Int) -> AgentJSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string("sensitive remote detail")]),
        ])
    }

    private func readRequest(client: Int32) -> Request? {
        var data = Data()
        let marker = Data("\r\n\r\n".utf8)
        while data.range(of: marker) == nil, data.count < 32_768 {
            guard let next = receive(client: client) else { return nil }
            data.append(next)
        }
        guard let range = data.range(of: marker),
              let headers = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = headers.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count == 3 else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { return nil }
            fields[line[..<split].lowercased()] = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(fields["content-length"] ?? "0") ?? 0
        guard (0...1_024_000).contains(length) else { return nil }
        var body = Data(data[range.upperBound..<data.endIndex])
        while body.count < length {
            guard let next = receive(client: client) else { return nil }
            body.append(next)
        }
        guard body.count == length else { return nil }
        return .init(
            target: String(parts[1]),
            authorization: fields["authorization"],
            a2aVersion: fields["a2a-version"],
            body: body.isEmpty ? nil : try? JSONDecoder().decode(AgentJSONValue.self, from: body)
        )
    }

    private func receive(client: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.recv(client, buffer.baseAddress, buffer.count, 0)
        }
        guard count > 0 else { return nil }
        return Data(bytes.prefix(Int(count)))
    }

    private func write(client: Int32, status: Int, body: AgentJSONValue) {
        guard let encoded = try? JSONEncoder().encode(body) else { return }
        writeRaw(client: client, status: status, data: encoded)
    }

    private func writeRaw(client: Int32, status: Int, body: String) {
        writeRaw(client: client, status: status, data: Data(body.utf8))
    }

    private func writeRaw(client: Int32, status: Int, data: Data) {
        let reason = status == 200 ? "OK" : "Not Found"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        send(response, to: client)
    }

    private func writeChunked(client: Int32, status: Int, chunks: [Data]) {
        let reason = status == 200 ? "OK" : "Not Found"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
        for chunk in chunks {
            response.append(Data(String(chunk.count, radix: 16).utf8))
            response.append(Data("\r\n".utf8))
            response.append(chunk)
            response.append(Data("\r\n".utf8))
        }
        response.append(Data("0\r\n\r\n".utf8))
        send(response, to: client)
    }

    private func send(_ response: Data, to client: Int32) {
        response.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let sent = Darwin.send(client, pointer, remaining, 0)
                guard sent > 0 else { return }
                pointer = pointer.advanced(by: sent)
                remaining -= sent
            }
        }
    }
}

private enum A2ATestPeerError: Error { case socket(Int32) }
