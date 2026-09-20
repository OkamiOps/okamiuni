import Darwin
import Foundation
import Security
import UNICore

/// A small, local-only Streamable HTTP MCP endpoint.
///
/// The endpoint is deliberately stateless: it accepts one JSON-RPC message per
/// HTTP request and always closes the connection after its response. It never
/// discovers application capabilities itself; every tool invocation is routed
/// through the handler supplied by the composition root.
public actor LocalMCPServer {
    public struct Endpoint: Sendable, Equatable {
        public let url: URL
        public let bearerToken: String

        public init(url: URL, bearerToken: String) {
            self.url = url
            self.bearerToken = bearerToken
        }
    }

    public enum ServerError: Error, LocalizedError, Sendable {
        case alreadyRunning
        case couldNotOpenSocket(Int32)
        case couldNotBindSocket(Int32)
        case couldNotListen(Int32)
        case couldNotReadSocketAddress(Int32)
        case couldNotGenerateToken(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "O servidor MCP local já está em execução."
            case .couldNotOpenSocket(let code):
                return "Não foi possível abrir o socket MCP local (errno \(code))."
            case .couldNotBindSocket(let code):
                return "Não foi possível reservar uma porta MCP local (errno \(code))."
            case .couldNotListen(let code):
                return "Não foi possível escutar o socket MCP local (errno \(code))."
            case .couldNotReadSocketAddress(let code):
                return "Não foi possível identificar a porta MCP local (errno \(code))."
            case .couldNotGenerateToken(let code):
                return "Não foi possível gerar o token MCP local (status \(code))."
            }
        }
    }

    private let tools: [AgentToolDefinition]
    private let handler: @Sendable (String, AgentJSONValue) async throws -> AgentJSONValue
    private var runtime: LocalMCPServerRuntime?

    public init(
        tools: [AgentToolDefinition],
        handler: @escaping @Sendable (String, AgentJSONValue) async throws -> AgentJSONValue
    ) {
        self.tools = tools
        self.handler = handler
    }

    public func start() async throws -> Endpoint {
        guard runtime == nil else { throw ServerError.alreadyRunning }

        let token = try Self.makeBearerToken()
        let runtime = try LocalMCPServerRuntime(tools: tools, bearerToken: token, handler: handler)
        self.runtime = runtime
        runtime.start()
        return Endpoint(url: runtime.endpoint, bearerToken: token)
    }

    public func stop() async {
        runtime?.stop()
        runtime = nil
    }

    private static func makeBearerToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw ServerError.couldNotGenerateToken(status) }
        return Data(bytes).base64EncodedString()
    }
}

private final class LocalMCPServerRuntime: @unchecked Sendable {
    private static let endpointPath = "/mcp"
    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumBodyBytes = 1_024 * 1_024
    private static let socketTimeout = 10
    private static let toolTimeout: DispatchTimeInterval = .seconds(30)
    private static let supportedProtocolVersions = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25",
    ]

    private let tools: [AgentToolDefinition]
    private let toolsByName: [String: AgentToolDefinition]
    private let bearerToken: String
    private let handler: @Sendable (String, AgentJSONValue) async throws -> AgentJSONValue
    private let lock = NSLock()
    private let connectionSlots = DispatchSemaphore(value: 8)
    private let toolSlots = DispatchSemaphore(value: 4)
    private let acceptQueue = DispatchQueue(label: "com.okamiuni.local-mcp.accept", qos: .utility)
    private let connectionQueue = DispatchQueue(
        label: "com.okamiuni.local-mcp.connection",
        qos: .utility,
        attributes: .concurrent
    )
    private var listeningSocket: Int32
    private var running = true
    /// Sockets são fechados pelo worker que os possui. `stop()` só faz
    /// shutdown: fechar aqui permitiria que o descritor fosse reutilizado
    /// antes de o worker terminar e fechasse acidentalmente outra conexão.
    private var activeClientSockets: Set<Int32> = []
    private var activeToolOperations: [UUID: LocalMCPToolOperation] = [:]
    let endpoint: URL

    init(
        tools: [AgentToolDefinition],
        bearerToken: String,
        handler: @escaping @Sendable (String, AgentJSONValue) async throws -> AgentJSONValue
    ) throws {
        self.tools = Self.uniqueTools(tools)
        self.toolsByName = Dictionary(uniqueKeysWithValues: self.tools.map { ($0.name, $0) })
        self.bearerToken = bearerToken
        self.handler = handler

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw LocalMCPServer.ServerError.couldNotOpenSocket(errno) }
        listeningSocket = socket

        do {
            try Self.configure(socket: socket)
            try Self.bindLoopback(socket: socket)
            guard Darwin.listen(socket, 16) == 0 else {
                throw LocalMCPServer.ServerError.couldNotListen(errno)
            }
            let port = try Self.boundPort(socket: socket)
            guard let endpoint = URL(string: "http://127.0.0.1:\(port)\(Self.endpointPath)") else {
                throw LocalMCPServer.ServerError.couldNotReadSocketAddress(EINVAL)
            }
            self.endpoint = endpoint
        } catch {
            Darwin.close(socket)
            throw error
        }
    }

    deinit {
        stop()
    }

    func start() {
        acceptQueue.async { [weak self] in
            self?.acceptConnections()
        }
    }

    func stop() {
        let state = lock.withLock { () -> (Int32, [Int32], [LocalMCPToolOperation])? in
            guard running else { return nil }
            running = false
            let socket = listeningSocket
            listeningSocket = -1
            return (socket, Array(activeClientSockets), Array(activeToolOperations.values))
        }
        guard let state else { return }
        if state.0 >= 0 {
            _ = Darwin.shutdown(state.0, SHUT_RDWR)
            _ = Darwin.close(state.0)
        }
        state.1.forEach { _ = Darwin.shutdown($0, SHUT_RDWR) }
        state.2.forEach { $0.cancel() }
    }

    private func acceptConnections() {
        while isRunning {
            guard let socket = activeListeningSocket else { return }
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(socket, $0, &length)
                }
            }

            guard client >= 0 else {
                if !isRunning { return }
                if errno == EINTR { continue }
                continue
            }

            guard connectionSlots.wait(timeout: .now()) == .success else {
                writeResponse(socket: client, status: 503, reason: "Service Unavailable")
                Darwin.close(client)
                continue
            }

            guard beginConnection(socket: client) else {
                _ = Darwin.shutdown(client, SHUT_RDWR)
                Darwin.close(client)
                connectionSlots.signal()
                continue
            }
            connectionQueue.async { [self] in
                defer { connectionSlots.signal() }
                handleConnection(socket: client)
            }
        }
    }

    private var activeListeningSocket: Int32? {
        lock.withLock { running && listeningSocket >= 0 ? listeningSocket : nil }
    }

    private var isRunning: Bool {
        lock.withLock { running }
    }

    private func beginConnection(socket: Int32) -> Bool {
        lock.withLock {
            guard running else { return false }
            activeClientSockets.insert(socket)
            return true
        }
    }

    private func finishConnection(socket: Int32) {
        _ = lock.withLock { activeClientSockets.remove(socket) }
        Darwin.close(socket)
    }

    private func handleConnection(socket: Int32) {
        defer { finishConnection(socket: socket) }
        Self.configureClient(socket: socket)

        do {
            let request = try readRequest(socket: socket)
            try validate(request: request)
            let response = respond(to: request)
            writeResponse(socket: socket, status: response.status, reason: response.reason, body: response.body)
        } catch let failure as LocalMCPHTTPFailure {
            writeResponse(
                socket: socket,
                status: failure.status,
                reason: failure.reason,
                body: failure.jsonRPCError.flatMap(Self.encode),
                additionalHeaders: failure.status == 401 ? ["WWW-Authenticate": "Bearer"] : [:]
            )
        } catch {
            writeResponse(socket: socket, status: 500, reason: "Internal Server Error")
        }
    }

    private func readRequest(socket: Int32) throws -> LocalMCPHTTPRequest {
        var data = Data()
        let marker = Data("\r\n\r\n".utf8)

        while data.range(of: marker) == nil {
            guard data.count < Self.maximumHeaderBytes else {
                throw LocalMCPHTTPFailure(status: 431, reason: "Request Header Fields Too Large")
            }
            data.append(try receive(socket: socket, maximumLength: 4_096))
        }

        guard let headerRange = data.range(of: marker) else {
            throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
        }
        guard headerRange.lowerBound <= Self.maximumHeaderBytes else {
            throw LocalMCPHTTPFailure(status: 431, reason: "Request Header Fields Too Large")
        }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
        }
        let parsed = try parseHeaders(headerText)
        let contentLength = try contentLength(for: parsed.headers, method: parsed.method)
        guard contentLength <= Self.maximumBodyBytes else {
            throw LocalMCPHTTPFailure(status: 413, reason: "Payload Too Large")
        }

        var body = data.subdata(in: headerRange.upperBound..<data.endIndex)
        guard body.count <= contentLength else {
            throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
        }
        while body.count < contentLength {
            body.append(try receive(socket: socket, maximumLength: min(4_096, contentLength - body.count)))
        }

        return LocalMCPHTTPRequest(
            method: parsed.method,
            target: parsed.target,
            headers: parsed.headers,
            body: body
        )
    }

    private func receive(socket: Int32, maximumLength: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximumLength)
        let received = bytes.withUnsafeMutableBytes { buffer in
            Darwin.recv(socket, buffer.baseAddress, buffer.count, 0)
        }
        if received > 0 { return Data(bytes.prefix(Int(received))) }
        if received == 0 { throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request") }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            throw LocalMCPHTTPFailure(status: 408, reason: "Request Timeout")
        }
        throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
    }

    private func parseHeaders(_ headerText: String) throws -> (method: String, target: String, headers: [String: String]) {
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
        }
        lines.removeFirst()
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 3, components[2] == "HTTP/1.1" else {
            throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else {
                throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else {
                throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
            }
            headers[name] = value
        }

        return (String(components[0]), String(components[1]), headers)
    }

    private func contentLength(for headers: [String: String], method: String) throws -> Int {
        if headers["transfer-encoding"] != nil {
            throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
        }
        guard method == "POST" else { return 0 }
        guard let rawLength = headers["content-length"],
              let length = Int(rawLength), length >= 0
        else {
            throw LocalMCPHTTPFailure(status: 411, reason: "Length Required")
        }
        return length
    }

    private func validate(request: LocalMCPHTTPRequest) throws {
        guard request.target == Self.endpointPath else {
            throw LocalMCPHTTPFailure(status: 404, reason: "Not Found")
        }
        guard request.headers["host"] == "127.0.0.1:\(endpoint.port ?? 0)" else {
            throw LocalMCPHTTPFailure(status: 403, reason: "Forbidden")
        }
        if let origin = request.headers["origin"], origin != "http://127.0.0.1:\(endpoint.port ?? 0)" {
            throw LocalMCPHTTPFailure(status: 403, reason: "Forbidden")
        }
        guard let authorization = request.headers["authorization"],
              constantTimeEquals(authorization, "Bearer \(bearerToken)")
        else {
            throw LocalMCPHTTPFailure(status: 401, reason: "Unauthorized")
        }
        guard request.method == "POST" else {
            throw LocalMCPHTTPFailure(status: 405, reason: "Method Not Allowed")
        }
        guard request.headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            throw LocalMCPHTTPFailure(status: 415, reason: "Unsupported Media Type")
        }
        if let version = request.headers["mcp-protocol-version"], !Self.supportedProtocolVersions.contains(version) {
            throw LocalMCPHTTPFailure(status: 400, reason: "Bad Request")
        }
    }

    private func respond(to request: LocalMCPHTTPRequest) -> LocalMCPHTTPResponse {
        let decoded: AgentJSONValue
        do {
            decoded = try JSONDecoder().decode(AgentJSONValue.self, from: request.body)
        } catch {
            return jsonRPCError(status: -32700, message: "Parse error", id: .null)
        }

        guard let message = decoded.objectValue,
              message["jsonrpc"]?.stringValue == "2.0",
              let method = message["method"]?.stringValue
        else {
            return jsonRPCError(status: -32600, message: "Invalid Request", id: requestID(from: decoded) ?? .null)
        }
        let id = requestID(from: decoded)

        // JSON-RPC notifications do not receive responses. `initialized` is
        // the only lifecycle notification this stateless server needs to act on.
        guard let id else {
            return LocalMCPHTTPResponse(status: 202, reason: "Accepted", body: nil)
        }

        switch method {
        case "initialize":
            return initialize(id: id, params: message["params"])
        case "ping":
            return jsonRPCResult(id: id, result: .object([:]))
        case "tools/list":
            return listTools(id: id)
        case "tools/call":
            return callTool(id: id, params: message["params"])
        default:
            return jsonRPCError(status: -32601, message: "Method not found", id: id)
        }
    }

    private func initialize(id: AgentJSONValue, params: AgentJSONValue?) -> LocalMCPHTTPResponse {
        guard let requested = params?.objectValue?["protocolVersion"]?.stringValue else {
            return jsonRPCError(status: -32602, message: "Invalid params", id: id)
        }
        guard Self.supportedProtocolVersions.contains(requested) else {
            return jsonRPCError(
                status: -32602,
                message: "Unsupported protocol version",
                id: id,
                data: .object([
                    "supported": .array(Self.supportedProtocolVersions.map(AgentJSONValue.string)),
                    "requested": .string(requested),
                ])
            )
        }
        return jsonRPCResult(
            id: id,
            result: .object([
                "protocolVersion": .string(requested),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("OkamiUNI Local MCP"),
                    "version": .string("1.0"),
                ]),
            ])
        )
    }

    private func listTools(id: AgentJSONValue) -> LocalMCPHTTPResponse {
        let values = tools.map { tool in
            AgentJSONValue.object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
                "annotations": .object(["readOnlyHint": .bool(tool.readOnly)]),
            ])
        }
        return jsonRPCResult(id: id, result: .object(["tools": .array(values)]))
    }

    private func callTool(id: AgentJSONValue, params: AgentJSONValue?) -> LocalMCPHTTPResponse {
        guard isRunning else {
            return toolFailure(id: id, message: "The local MCP server is stopping.")
        }
        guard let params = params?.objectValue,
              let name = params["name"]?.stringValue,
              let tool = toolsByName[name]
        else {
            return jsonRPCError(status: -32602, message: "Unknown tool", id: id)
        }
        let arguments = params["arguments"] ?? .object([:])
        guard arguments.objectValue != nil else {
            return jsonRPCError(status: -32602, message: "Tool arguments must be an object", id: id)
        }

        guard toolSlots.wait(timeout: .now()) == .success else {
            return toolFailure(id: id, message: "The local tool queue is busy. Retry shortly.")
        }

        guard isRunning else {
            toolSlots.signal()
            return toolFailure(id: id, message: "The local MCP server is stopping.")
        }

        let outcome = LocalMCPToolOutcome()
        let operation = LocalMCPToolOperation(outcome: outcome)
        guard beginToolOperation(operation) else {
            toolSlots.signal()
            return toolFailure(id: id, message: "The local MCP server is stopping.")
        }
        let reservedToolSlot = toolSlots
        let task = Task.detached { [weak self, handler, operation, reservedToolSlot] in
            defer {
                self?.finishToolOperation(id: operation.id)
                reservedToolSlot.signal()
            }
            do {
                try Task.checkCancellation()
                let value = try await handler(tool.name, arguments)
                try Task.checkCancellation()
                outcome.finish(.success(value))
            } catch is CancellationError {
                outcome.finish(.cancelled)
            } catch {
                outcome.finish(Task.isCancelled ? .cancelled : .failure(error.localizedDescription))
            }
        }
        operation.attach(task)
        guard outcome.wait(timeout: .now() + Self.toolTimeout) else {
            operation.cancel()
            return toolFailure(id: id, message: "Tool execution timed out.")
        }
        switch outcome.result {
        case .success(let value):
            return toolSuccess(id: id, value: value)
        case .failure(let message):
            return toolFailure(id: id, message: message)
        case .cancelled:
            return toolFailure(id: id, message: "Tool execution cancelled.")
        case nil:
            return toolFailure(id: id, message: "Tool execution ended without a result.")
        }
    }

    private func beginToolOperation(_ operation: LocalMCPToolOperation) -> Bool {
        lock.withLock {
            guard running else { return false }
            activeToolOperations[operation.id] = operation
            return true
        }
    }

    private func finishToolOperation(id: UUID) {
        _ = lock.withLock { activeToolOperations.removeValue(forKey: id) }
    }

    private func toolSuccess(id: AgentJSONValue, value: AgentJSONValue) -> LocalMCPHTTPResponse {
        let structured = value.objectValue == nil ? .object(["value": value]) : value
        let text = (try? value.jsonString()) ?? "null"
        return jsonRPCResult(
            id: id,
            result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "structuredContent": structured,
                "isError": .bool(false),
            ])
        )
    }

    private func toolFailure(id: AgentJSONValue, message: String) -> LocalMCPHTTPResponse {
        jsonRPCResult(
            id: id,
            result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
                "isError": .bool(true),
            ])
        )
    }

    private func jsonRPCResult(id: AgentJSONValue, result: AgentJSONValue) -> LocalMCPHTTPResponse {
        LocalMCPHTTPResponse(
            status: 200,
            reason: "OK",
            body: Self.encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        )
    }

    private func jsonRPCError(
        status: Int,
        message: String,
        id: AgentJSONValue,
        data: AgentJSONValue? = nil
    ) -> LocalMCPHTTPResponse {
        var error: [String: AgentJSONValue] = ["code": .number(Double(status)), "message": .string(message)]
        if let data { error["data"] = data }
        return LocalMCPHTTPResponse(
            status: 200,
            reason: "OK",
            body: Self.encode(.object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object(error),
            ]))
        )
    }

    private static func encode(_ value: AgentJSONValue) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private func writeResponse(
        socket: Int32,
        status: Int,
        reason: String,
        body: Data? = nil,
        additionalHeaders: [String: String] = [:]
    ) {
        let payload = body ?? Data()
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        response += "Connection: close\r\n"
        response += "X-Content-Type-Options: nosniff\r\n"
        if body != nil { response += "Content-Type: application/json; charset=utf-8\r\n" }
        for (name, value) in additionalHeaders { response += "\(name): \(value)\r\n" }
        response += "Content-Length: \(payload.count)\r\n\r\n"
        var bytes = Data(response.utf8)
        bytes.append(payload)
        _ = Self.sendAll(socket: socket, data: bytes)
    }

    private static func sendAll(socket: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var sentTotal = 0
            while sentTotal < rawBuffer.count {
                let sent = Darwin.send(socket, base.advanced(by: sentTotal), rawBuffer.count - sentTotal, 0)
                if sent > 0 {
                    sentTotal += sent
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func constantTimeEquals(_ supplied: String, _ expected: String) -> Bool {
        let lhs = Array(supplied.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        var mismatch: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { mismatch |= left ^ right }
        return mismatch == 0
    }

    private static func uniqueTools(_ tools: [AgentToolDefinition]) -> [AgentToolDefinition] {
        var known = Set<String>()
        return tools.filter { known.insert($0.name).inserted }
    }

    private static func configure(socket: Int32) throws {
        var enabled: Int32 = 1
        guard withUnsafePointer(to: &enabled, {
            Darwin.setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }) == 0 else {
            throw LocalMCPServer.ServerError.couldNotOpenSocket(errno)
        }
        #if os(macOS)
        _ = withUnsafePointer(to: &enabled) {
            Darwin.setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif
    }

    private static func configureClient(socket: Int32) {
        var timeout = timeval(tv_sec: Self.socketTimeout, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        #if os(macOS)
        var enabled: Int32 = 1
        _ = withUnsafePointer(to: &enabled) {
            Darwin.setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif
    }

    private static func bindLoopback(socket: Int32) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw LocalMCPServer.ServerError.couldNotBindSocket(errno) }
    }

    private static func boundPort(socket: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socket, $0, &length)
            }
        }
        guard result == 0 else { throw LocalMCPServer.ServerError.couldNotReadSocketAddress(errno) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

}

private struct LocalMCPHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

private struct LocalMCPHTTPResponse {
    let status: Int
    let reason: String
    let body: Data?
}

private struct LocalMCPHTTPFailure: Error {
    let status: Int
    let reason: String
    let jsonRPCError: AgentJSONValue?

    init(status: Int, reason: String, jsonRPCError: AgentJSONValue? = nil) {
        self.status = status
        self.reason = reason
        self.jsonRPCError = jsonRPCError
    }
}

private enum LocalMCPToolResult: Sendable {
    case success(AgentJSONValue)
    case failure(String)
    case cancelled
}

private final class LocalMCPToolOutcome: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedResult: LocalMCPToolResult?

    func finish(_ result: LocalMCPToolResult) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard storedResult == nil else { return false }
            storedResult = result
            return true
        }
        if shouldSignal { semaphore.signal() }
    }

    func wait(timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }

    var result: LocalMCPToolResult? {
        lock.withLock { storedResult }
    }
}

/// Owns a detached tool task until it has actually stopped. Cancellation can
/// arrive between registering the operation and attaching its task, so the
/// flag is retained and applied as soon as the task becomes available.
private final class LocalMCPToolOperation: @unchecked Sendable {
    let id = UUID()
    private let outcome: LocalMCPToolOutcome
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    init(outcome: LocalMCPToolOutcome) {
        self.outcome = outcome
    }

    func attach(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return self.task
        }
        task?.cancel()
        outcome.finish(.cancelled)
    }
}

private func requestID(from value: AgentJSONValue) -> AgentJSONValue? {
    guard let object = value.objectValue, let id = object["id"] else { return nil }
    switch id {
    case .string, .number, .null:
        return id
    case .object, .array, .bool:
        return nil
    }
}
