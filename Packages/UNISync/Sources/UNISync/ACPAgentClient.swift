import Foundation
import Darwin
import UNICore

/// Uma opção que o agente apresentou ao pedir autorização para uma ferramenta.
/// O cliente só seleciona opções ``allow_once`` depois de uma validação explícita
/// do host; as demais solicitações recebem uma recusa.
public struct ACPAgentPermissionOption: Sendable, Equatable {
    public let id: String
    public let kind: String

    public init(id: String, kind: String) {
        self.id = id
        self.kind = kind
    }
}

/// A parte verificável de uma solicitação de permissão ACP.
///
/// Quando o adaptador ACP correlaciona o pedido com uma chamada MCP anunciada,
/// ``toolName`` vem da `rawInput` dessa chamada, nunca de `title` nem do
/// próprio pedido de aprovação.
public struct ACPAgentPermissionRequest: Sendable, Equatable {
    public let sessionID: String
    public let toolCallID: String
    /// The MCP server observed in the associated standard ACP `tool_call`.
    /// It is `nil` for non-MCP or uncorrelated requests.
    public let mcpServerName: String?
    public let toolName: String?
    public let toolTitle: String?
    public let toolKind: String?
    public let options: [ACPAgentPermissionOption]

    public init(
        sessionID: String,
        toolCallID: String,
        mcpServerName: String? = nil,
        toolName: String?,
        toolTitle: String?,
        toolKind: String?,
        options: [ACPAgentPermissionOption]
    ) {
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.mcpServerName = mcpServerName
        self.toolName = toolName
        self.toolTitle = toolTitle
        self.toolKind = toolKind
        self.options = options
    }
}

/// Decide qual opção `allow_once` pode ser devolvida para uma ferramenta MCP
/// previamente anunciada pelo OkamiUNI. `nil` recusa a solicitação.
public typealias ACPAgentPermissionHandler = @Sendable (ACPAgentPermissionRequest) -> String?

/// Falhas do transporte ACP. Nenhum caso inclui a mensagem do processo filho,
/// pois ela pode conter URL, token ou outro material operacional sensível.
public enum ACPAgentClientError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration
    case failedToStart
    case timedOut
    case outputTooLarge
    case frameTooLarge
    case invalidResponse
    case unsupportedProtocol(Int?)
    case unsupportedHTTPTransport
    case remoteFailure
    case processFailed(exitCode: Int32)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            L10n.tr("A configuração do agente ACP não é válida.")
        case .failedToStart:
            L10n.tr("Não foi possível iniciar o agente ACP.")
        case .timedOut:
            L10n.tr("O agente ACP demorou demais para responder.")
        case .outputTooLarge, .frameTooLarge:
            L10n.tr("O agente ACP devolveu dados demais para esta ação.")
        case .invalidResponse:
            L10n.tr("O agente ACP devolveu uma resposta que o OkamiUNI não consegue usar.")
        case .unsupportedProtocol:
            L10n.tr("O agente não oferece uma versão compatível do protocolo ACP.")
        case .unsupportedHTTPTransport:
            L10n.tr("O agente não aceita servidores MCP por HTTP.")
        case .remoteFailure:
            L10n.tr("O agente ACP encerrou a solicitação com erro.")
        case .processFailed:
            L10n.tr("O processo do agente ACP encerrou inesperadamente.")
        case .emptyResponse:
            L10n.tr("O agente ACP devolveu uma resposta vazia.")
        }
    }
}

/// Cliente ACP v1 sobre JSON-RPC newline-delimited em stdin/stdout.
///
/// Cada ``answer(prompt:mcpURL:bearerToken:onUpdate:)`` abre um filho, mantém
/// a conexão viva por initialize → session/new → session/prompt e a encerra ao
/// fim do turno. O processo não recebe as credenciais como argumento ou
/// ambiente: o token aparece somente no cabeçalho do MCP HTTP dentro do frame
/// `session/new` e nunca é registrado pelo cliente.
public struct ACPAgentClient: Sendable {
    public struct Configuration: Sendable {
        public let executableURL: URL
        public let arguments: [String]
        public let environment: [String: String]
        /// Keeps security-scoped bookmarks active while the configured child
        /// process is running. It is optional so unit fixtures can launch
        /// bundled system tools without an external authorization.
        public let runtimeLaunch: AgentRuntimeLaunch?
        /// Diretório em que o filho é iniciado. O `cwd` enviado ao ACP continua
        /// sendo sempre uma pasta temporária privada por sessão.
        public let cwd: URL?
        public let timeout: TimeInterval
        public let maximumFrameBytes: Int
        public let maximumOutputBytes: Int
        /// Nomes exatos das ferramentas MCP que o host anunciou como seguras.
        /// Uma lista vazia desabilita toda autorização automática.
        public let safeMCPToolNames: Set<String>
        /// Uma validação adicional do host. Sem handler, só uma chamada MCP
        /// local já anunciada pelo adaptador e presente em ``safeMCPToolNames``
        /// pode receber `allow_once`; todo pedido sem essa correlação é negado.
        public let permissionHandler: ACPAgentPermissionHandler?

        public init(
            executableURL: URL,
            arguments: [String] = [],
            environment: [String: String] = [:],
            runtimeLaunch: AgentRuntimeLaunch? = nil,
            cwd: URL? = nil,
            timeout: TimeInterval = 120,
            maximumFrameBytes: Int = 1_024 * 1_024,
            maximumOutputBytes: Int = 1_024 * 1_024,
            safeMCPToolNames: Set<String> = [],
            permissionHandler: ACPAgentPermissionHandler? = nil
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
            self.runtimeLaunch = runtimeLaunch
            self.cwd = cwd
            self.timeout = min(max(timeout, 1), 300)
            self.maximumFrameBytes = min(max(maximumFrameBytes, 1_024), 4 * 1_024 * 1_024)
            self.maximumOutputBytes = min(max(maximumOutputBytes, 1_024), 8 * 1_024 * 1_024)
            self.safeMCPToolNames = safeMCPToolNames
            self.permissionHandler = permissionHandler
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func answer(
        prompt: String,
        mcpURL: URL,
        bearerToken: String,
        onUpdate: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let run = ACPAgentRun(configuration: configuration, onUpdate: onUpdate)
        return try await withTaskCancellationHandler(operation: {
            try await run.answer(prompt: prompt, mcpURL: mcpURL, bearerToken: bearerToken)
        }, onCancel: {
            run.cancel()
        })
    }

    /// Verifies the ACP v1 and HTTP-MCP handshake without submitting a prompt.
    /// Callers should provide an empty, throwaway MCP server for UI diagnostics;
    /// this method never asks the agent to inspect mail or execute a tool.
    public func checkConnection(mcpURL: URL, bearerToken: String) async throws -> String {
        let run = ACPAgentRun(configuration: configuration, onUpdate: { _ in })
        return try await withTaskCancellationHandler(operation: {
            try await run.checkConnection(mcpURL: mcpURL, bearerToken: bearerToken)
        }, onCancel: {
            run.cancel()
        })
    }
}

private struct ACPStartedSession: Sendable {
    let id: String
    let agentName: String
}

private final class ACPAgentRun: @unchecked Sendable {
    private let configuration: ACPAgentClient.Configuration
    private let onUpdate: @Sendable (String) -> Void
    private let control = ACPProcessControl()
    private let outputBudget: ACPOutputBudget
    private var standardOutput: ACPLineReader?
    private var standardError: ACPTailReader?

    init(configuration: ACPAgentClient.Configuration, onUpdate: @escaping @Sendable (String) -> Void) {
        self.configuration = configuration
        self.onUpdate = onUpdate
        outputBudget = ACPOutputBudget(limit: configuration.maximumOutputBytes)
    }

    func answer(prompt: String, mcpURL: URL, bearerToken: String) async throws -> String {
        try validateRequest(mcpURL: mcpURL, bearerToken: bearerToken)
        try Task.checkCancellation()

        let temporaryDirectory = try makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try startProcess(sessionDirectory: temporaryDirectory)
        defer { stopProcess() }
        let timeoutTimer = startTimeoutTimer()
        defer { timeoutTimer.cancel() }

        let startedSession = try await startSession(
            sessionDirectory: temporaryDirectory,
            mcpURL: mcpURL,
            bearerToken: bearerToken
        )

        let completion = try await request(
            id: 2,
            method: "session/prompt",
            params: .object([
                "sessionId": .string(startedSession.id),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(prompt),
                    ]),
                ]),
            ])
        )
        control.clearPromptActive()
        if control.isCancelled { throw CancellationError() }
        if completion["stopReason"]?.stringValue == "cancelled" { throw CancellationError() }

        let response = control.answerText
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ACPAgentClientError.emptyResponse
        }
        return response
    }

    func checkConnection(mcpURL: URL, bearerToken: String) async throws -> String {
        try validateRequest(mcpURL: mcpURL, bearerToken: bearerToken)
        try Task.checkCancellation()

        let temporaryDirectory = try makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try startProcess(sessionDirectory: temporaryDirectory)
        defer { stopProcess() }
        let timeoutTimer = startTimeoutTimer()
        defer { timeoutTimer.cancel() }

        return try await startSession(
            sessionDirectory: temporaryDirectory,
            mcpURL: mcpURL,
            bearerToken: bearerToken
        ).agentName
    }

    func cancel() {
        control.cancel(maximumFrameBytes: configuration.maximumFrameBytes)
    }

    private func makeSessionDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-acp-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return url
        } catch {
            throw ACPAgentClientError.failedToStart
        }
    }

    private func startProcess(sessionDirectory: URL) throws {
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        // The ACP child does not need the application's full launch
        // environment. In particular, inherited CI/provider credentials must
        // not become an implicit capability. Callers can still pass the small
        // explicit environment required by a chosen adapter.
        let inheritedKeys: Set<String> = [
            "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME",
        ]
        let inherited = ProcessInfo.processInfo.environment.filter { inheritedKeys.contains($0.key) }
        process.environment = inherited.merging(configuration.environment) { _, configured in configured }
        process.currentDirectoryURL = configuration.cwd ?? configuration.runtimeLaunch?.workingDirectoryURL ?? sessionDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let lineReader = ACPLineReader(
            maximumFrameBytes: configuration.maximumFrameBytes,
            outputBudget: outputBudget,
            onFailure: { [weak self] failure in self?.fail(failure) }
        )
        let tailReader = ACPTailReader(
            outputBudget: outputBudget,
            onFailure: { [weak self] failure in self?.fail(failure) }
        )
        standardOutput = lineReader
        standardError = tailReader
        do {
            try process.run()
        } catch {
            lineReader.finish(throwing: ACPAgentClientError.failedToStart)
            tailReader.finish()
            throw ACPAgentClientError.failedToStart
        }
        control.attach(process: process, input: input.fileHandleForWriting)
        lineReader.start(handle: output.fileHandleForReading)
        tailReader.start(handle: error.fileHandleForReading)
    }

    private func stopProcess() {
        standardOutput?.finish(throwing: ACPAgentClientError.processFailed(exitCode: control.exitStatus ?? -1))
        standardError?.finish()
        control.stop()
    }

    private func startTimeoutTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + configuration.timeout)
        timer.setEventHandler { [weak self] in
            self?.fail(.timedOut)
        }
        timer.resume()
        return timer
    }

    private func fail(_ error: ACPAgentClientError) {
        guard control.fail(error) else { return }
        standardOutput?.finish(throwing: error)
        standardError?.finish()
    }

    private func validateRequest(mcpURL: URL, bearerToken: String) throws {
        guard configuration.executableURL.isFileURL,
              configuration.executableURL.path.hasPrefix("/"),
              mcpURL.scheme?.lowercased() == "http" || mcpURL.scheme?.lowercased() == "https",
              !bearerToken.isEmpty
        else { throw ACPAgentClientError.invalidConfiguration }
    }

    private func validateInitialization(_ result: AgentJSONValue) throws -> String {
        let version = result["protocolVersion"]?.intValue
        guard version == 1 else { throw ACPAgentClientError.unsupportedProtocol(version) }
        guard result["agentCapabilities"]?["mcpCapabilities"]?["http"]?.boolValue == true else {
            throw ACPAgentClientError.unsupportedHTTPTransport
        }
        let name = result["agentInfo"]?["name"]?.stringValue ?? result["agentInfo"]?["title"]?.stringValue
        guard let name,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 256,
              !name.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 })
        else { return "ACP v1" }
        return name
    }

    private func startSession(
        sessionDirectory: URL,
        mcpURL: URL,
        bearerToken: String
    ) async throws -> ACPStartedSession {
        let initialize = try await request(
            id: 0,
            method: "initialize",
            params: .object([
                "protocolVersion": .number(1),
                // Not advertising fs or terminal deliberately leaves those
                // client capabilities unavailable to the agent.
                "clientCapabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("okamiuni"),
                    "title": .string("OkamiUNI"),
                    "version": .string("1"),
                ]),
            ])
        )
        let agentName = try validateInitialization(initialize)

        let session = try await request(
            id: 1,
            method: "session/new",
            params: .object([
                "cwd": .string(sessionDirectory.path),
                "mcpServers": .array([
                    .object([
                        "type": .string("http"),
                        "name": .string("okamiuni"),
                        "url": .string(mcpURL.absoluteString),
                        "headers": .array([
                            .object([
                                "name": .string("Authorization"),
                                "value": .string("Bearer \(bearerToken)"),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )
        let sessionID = try session["sessionId"]?.stringValue ?? {
            throw ACPAgentClientError.invalidResponse
        }()
        guard !sessionID.isEmpty else { throw ACPAgentClientError.invalidResponse }
        control.setSessionID(sessionID)
        return ACPStartedSession(id: sessionID, agentName: agentName)
    }

    private func request(id: Int, method: String, params: AgentJSONValue) async throws -> AgentJSONValue {
        try send(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ]), markingPromptActive: method == "session/prompt")
        return try await waitForResponse(id: id)
    }

    private func send(_ frame: AgentJSONValue, markingPromptActive: Bool = false) throws {
        let json: String
        do {
            json = try frame.jsonString()
        } catch {
            throw ACPAgentClientError.invalidResponse
        }
        let data = Data((json + "\n").utf8)
        guard data.count <= configuration.maximumFrameBytes else {
            throw ACPAgentClientError.frameTooLarge
        }
        try control.write(data, markingPromptActive: markingPromptActive)
    }

    private func waitForResponse(id: Int) async throws -> AgentJSONValue {
        guard let standardOutput else { throw ACPAgentClientError.failedToStart }
        while let frame = try await standardOutput.next() {
            if let failure = control.failure { throw failure }
            let message: AgentJSONValue
            do {
                message = try JSONDecoder().decode(AgentJSONValue.self, from: frame)
            } catch {
                throw ACPAgentClientError.invalidResponse
            }
            guard let object = message.objectValue else { throw ACPAgentClientError.invalidResponse }

            if object["id"]?.intValue == id {
                if object["error"] != nil { throw ACPAgentClientError.remoteFailure }
                guard let result = object["result"] else { throw ACPAgentClientError.invalidResponse }
                return result
            }
            if let method = object["method"]?.stringValue {
                try handleInboundRequest(id: rpcRequestID(in: object), method: method, params: object["params"])
            }
        }
        if control.isCancelled { throw CancellationError() }
        if let failure = control.failure { throw failure }
        throw ACPAgentClientError.processFailed(exitCode: control.exitStatus ?? -1)
    }

    private func rpcRequestID(in object: [String: AgentJSONValue]) -> AgentJSONValue? {
        guard let id = object["id"] else { return nil }
        switch id {
        case .string, .number: return id
        case .object, .array, .bool, .null: return nil
        }
    }

    private func handleInboundRequest(id: AgentJSONValue?, method: String, params: AgentJSONValue?) throws {
        switch method {
        case "session/update":
            guard let params,
                  params["sessionId"]?.stringValue == control.sessionID,
                  let update = params["update"]
            else { return }
            rememberTrustedMCPToolCall(update)
            guard update["sessionUpdate"]?.stringValue == "agent_message_chunk",
                  update["content"]?["type"]?.stringValue == "text",
                  let text = update["content"]?["text"]?.stringValue
            else { return }
            control.appendAnswer(text)
            onUpdate(text)

        case "session/request_permission":
            guard let id else { return }
            try sendPermissionResponse(id: id, params: params)

        case let unsafeMethod where unsafeMethod.hasPrefix("fs/") || unsafeMethod.hasPrefix("terminal/"):
            if let id { try sendMethodNotFound(id: id) }

        default:
            // O cliente não expõe nenhum método além da decisão de permissão.
            if let id { try sendMethodNotFound(id: id) }
        }
    }

    private func sendPermissionResponse(id: AgentJSONValue, params: AgentJSONValue?) throws {
        guard let params,
              let sessionID = params["sessionId"]?.stringValue,
              sessionID == control.sessionID,
              let toolCall = params["toolCall"],
              let toolCallID = toolCall["toolCallId"]?.stringValue
        else {
            try send(.object([
                "jsonrpc": .string("2.0"), "id": id,
                "result": .object(["outcome": .object(["outcome": .string("cancelled")])]),
            ]))
            return
        }

        let options = (params["options"]?.arrayValue ?? []).compactMap { option -> ACPAgentPermissionOption? in
            guard let id = option["optionId"]?.stringValue,
                  let kind = option["kind"]?.stringValue
            else { return nil }
            return ACPAgentPermissionOption(id: id, kind: kind)
        }
        // ACP reserves `_meta` for extensions, so a generic client must never
        // use it as an authorization signal. A provider can omit tool details
        // from this request, but it cannot omit the `toolCallId`: only a
        // pending, same-session standard `tool_call` update with an observable
        // MCP server/tool identity is eligible for one-time approval.
        let trustedTool = control.trustedMCPTool(for: toolCallID)
        let requestTool = observedMCPTool(in: toolCall)
        let linkedTool: ACPMCPToolIdentity?
        if let requestTool {
            linkedTool = requestTool == trustedTool ? requestTool : nil
        } else {
            linkedTool = trustedTool
        }
        let request = ACPAgentPermissionRequest(
            sessionID: sessionID,
            toolCallID: toolCallID,
            mcpServerName: linkedTool?.server,
            toolName: linkedTool?.tool,
            toolTitle: toolCall["title"]?.stringValue,
            toolKind: toolCall["kind"]?.stringValue,
            options: options
        )
        var selected = selectedPermissionOption(for: request)
        if selected != nil,
           control.takeTrustedMCPTool(for: toolCallID) != linkedTool {
            selected = nil
        }
        let outcome: AgentJSONValue
        if let selected {
            outcome = .object([
                "outcome": .string("selected"),
                "optionId": .string(selected),
            ])
        } else if let rejected = options.first(where: { $0.kind == "reject_once" || $0.kind == "reject_always" }) {
            outcome = .object([
                "outcome": .string("selected"),
                "optionId": .string(rejected.id),
            ])
        } else {
            outcome = .object(["outcome": .string("cancelled")])
        }
        try send(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object(["outcome": outcome]),
        ]))
    }

    private func selectedPermissionOption(for request: ACPAgentPermissionRequest) -> String? {
        // `fs` and `terminal` are absent from initialize. The server/tool pair
        // comes from a standard tool-call update, never title, kind, or `_meta`
        // supplied by the permission prompt itself.
        let genericTerms = ["terminal", "shell", "filesystem", "read_file", "write_file", "delete_file"]
        guard request.mcpServerName == "okamiuni",
              let name = request.toolName,
              !genericTerms.contains(where: { name.lowercased().contains($0) }),
              configuration.safeMCPToolNames.contains(name),
              let selected = selectedPermissionOptionFromHandlerOrDefault(for: request),
              request.options.contains(where: { $0.id == selected && $0.kind == "allow_once" })
        else { return nil }
        return selected
    }

    private func selectedPermissionOptionFromHandlerOrDefault(
        for request: ACPAgentPermissionRequest
    ) -> String? {
        if let permissionHandler = configuration.permissionHandler {
            return permissionHandler(request)
        }
        return request.options.first(where: { $0.kind == "allow_once" })?.id
    }

    private func rememberTrustedMCPToolCall(_ update: AgentJSONValue) {
        guard let updateKind = update["sessionUpdate"]?.stringValue,
              updateKind == "tool_call" || updateKind == "tool_call_update",
              let toolCallID = update["toolCallId"]?.stringValue,
              let tool = observedMCPTool(in: update),
              tool.server == "okamiuni",
              configuration.safeMCPToolNames.contains(tool.tool)
        else { return }
        control.rememberTrustedMCPTool(id: toolCallID, tool: tool)
    }

    /// Accepts only MCP identity that an ACP provider exposed in the standard
    /// `tool_call` payload. `rawInput` intentionally has no ACP-mandated MCP
    /// shape, so the two explicit shapes are checked independently and common
    /// `mcp__server__tool` names are accepted only alongside an object input.
    private func observedMCPTool(in toolCall: AgentJSONValue) -> ACPMCPToolIdentity? {
        guard let rawInput = toolCall["rawInput"], rawInput.objectValue != nil else { return nil }
        if let server = rawInput["server"]?.stringValue,
           let tool = rawInput["tool"]?.stringValue,
           let identity = ACPMCPToolIdentity(server: server, tool: tool) {
            return identity
        }
        if let server = rawInput["serverName"]?.stringValue,
           let tool = rawInput["toolName"]?.stringValue,
           let identity = ACPMCPToolIdentity(server: server, tool: tool) {
            return identity
        }
        guard let name = toolCall["name"]?.stringValue,
              name.hasPrefix("mcp__")
        else { return nil }
        let components = name.split(separator: "_", omittingEmptySubsequences: false)
        // `mcp__server__tool` splits to [mcp, "", server, "", tool]. Tool
        // names may contain underscores, hence the fixed separator positions.
        guard components.count >= 5,
              components[0] == "mcp", components[1].isEmpty,
              !components[2].isEmpty, components[3].isEmpty
        else { return nil }
        return ACPMCPToolIdentity(
            server: String(components[2]),
            tool: components.dropFirst(4).joined(separator: "_")
        )
    }

    private func sendMethodNotFound(id: AgentJSONValue) throws {
        try send(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(-32601),
                "message": .string("Method not supported"),
            ]),
        ]))
    }
}

private struct ACPMCPToolIdentity: Sendable, Equatable {
    let server: String
    let tool: String

    init?(server: String, tool: String) {
        guard Self.isIdentifier(server, maximum: 128),
              Self.isIdentifier(tool, maximum: 512)
        else { return nil }
        self.server = server
        self.tool = tool
    }

    private static func isIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum &&
            !value.unicodeScalars.contains { scalar in
                scalar.value == 0 || scalar.value == 10 || scalar.value == 13
            }
    }
}

private final class ACPProcessControl: @unchecked Sendable {
    /// Protege apenas o estado. Nunca o segure durante I/O: um filho que não
    /// lê stdin pode bloquear `FileHandle.write`, mas timeout/cancelamento
    /// ainda precisam adquirir este lock para terminar o processo.
    private let stateLock = NSLock()
    /// Frames normais não podem se misturar no stdin. Este lock é separado do
    /// estado; o cancelamento tenta escrevê-lo sem esperar e sempre agenda um
    /// término limitado caso outro frame esteja preso no pipe.
    private let writeLock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private(set) var sessionID: String?
    private var promptActive = false
    private var cancelled = false
    private var failureStorage: ACPAgentClientError?
    private var exitStatusStorage: Int32?
    private var answers: [String] = []
    /// Only MCP calls observed during this session. The entry is consumed when
    /// approved so one `toolCallId` cannot yield several fresh permissions.
    private var trustedMCPTools: [String: ACPMCPToolIdentity] = [:]

    var isCancelled: Bool { withLock { cancelled } }
    var failure: ACPAgentClientError? { withLock { failureStorage } }
    var exitStatus: Int32? { withLock { exitStatusStorage } }
    var answerText: String { withLock { answers.joined() } }

    func attach(process: Process, input: FileHandle) {
        withLock {
            self.process = process
            self.input = input
        }
        // `Process` conecta stdin por pipe. Sem esta flag, EPIPE depois de um
        // timeout pode enviar SIGPIPE ao próprio app em vez de a escrita
        // devolver erro para o cliente tratar.
        #if os(macOS)
        _ = Darwin.fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        process.terminationHandler = { [weak self] process in
            self?.withLock { self?.exitStatusStorage = process.terminationStatus }
        }
    }

    func setSessionID(_ sessionID: String) {
        withLock {
            self.sessionID = sessionID
            trustedMCPTools.removeAll(keepingCapacity: true)
        }
    }
    func clearPromptActive() { withLock { promptActive = false } }
    func appendAnswer(_ text: String) { withLock { answers.append(text) } }
    func rememberTrustedMCPTool(id: String, tool: ACPMCPToolIdentity) {
        withLock {
            guard trustedMCPTools[id] == nil else { return }
            trustedMCPTools[id] = tool
        }
    }
    func trustedMCPTool(for id: String) -> ACPMCPToolIdentity? {
        withLock { trustedMCPTools[id] }
    }
    func takeTrustedMCPTool(for id: String) -> ACPMCPToolIdentity? {
        withLock { trustedMCPTools.removeValue(forKey: id) }
    }

    func write(
        _ data: Data,
        markingPromptActive: Bool = false,
        nonBlocking: Bool = false,
        allowsCancellation: Bool = false
    ) throws {
        let input = try withLock { () throws -> FileHandle in
            if let failureStorage { throw failureStorage }
            if cancelled && !allowsCancellation { throw CancellationError() }
            guard let input else { throw ACPAgentClientError.processFailed(exitCode: exitStatusStorage ?? -1) }
            if markingPromptActive { promptActive = true }
            return input
        }

        if nonBlocking {
            guard writeLock.try() else { return }
        } else {
            writeLock.lock()
        }
        defer { writeLock.unlock() }

        // A parada pode ter ocorrido enquanto esta escrita aguardava outro
        // frame. Releia somente o estado, nunca faça I/O sob o stateLock.
        try withLock {
            if let failureStorage { throw failureStorage }
            if cancelled && !allowsCancellation { throw CancellationError() }
        }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw terminalError()
        }
    }

    func fail(_ error: ACPAgentClientError) -> Bool {
        let process: Process? = withLock {
            guard failureStorage == nil, !cancelled else { return nil }
            failureStorage = error
            return self.process
        }
        guard let process else { return false }
        terminate(process)
        return true
    }

    func cancel(maximumFrameBytes: Int) {
        let sessionID: String? = withLock {
            guard !cancelled else { return nil }
            cancelled = true
            guard promptActive else { return nil }
            return sessionID
        }
        let process = withLock { self.process }
        if let sessionID,
           let data = try? ACPAgentRun.cancelFrame(sessionID: sessionID, maximumFrameBytes: maximumFrameBytes) {
            // Não espere um prompt grande que já está preso no pipe. A escrita
            // de cancelamento é apenas uma tentativa; o término abaixo sempre
            // impede que o filho sobreviva se ela não puder entrar.
            scheduleTermination(process, after: 0.5)
            try? write(data, nonBlocking: true, allowsCancellation: true)
        } else {
            if let process { terminate(process) }
            return
        }
    }

    func stop() {
        let resources: (Process?, FileHandle?, Bool) = withLock {
            let resources = (process, input, cancelled)
            process = nil
            input = nil
            return resources
        }
        try? resources.1?.close()
        // `cancel()` já deu uma breve chance ao frame session/cancel. Em todos
        // os demais casos, encerrar stdin e TERM/KILL limitado ao filho evita
        // processos órfãos, inclusive agentes que ignoram SIGTERM.
        if resources.2 {
            let process = resources.0
            scheduleTermination(process, after: 0.5)
        } else {
            if let process = resources.0 { terminate(process) }
        }
    }

    private func terminalError() -> Error {
        withLock {
            if let failureStorage { return failureStorage }
            if cancelled { return CancellationError() }
            return ACPAgentClientError.processFailed(exitCode: exitStatusStorage ?? -1)
        }
    }

    private func scheduleTermination(_ process: Process?, after delay: TimeInterval) {
        guard let process else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            Self.terminate(process)
        }
    }

    private func terminate(_ process: Process) {
        Self.terminate(process)
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        process.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            // Nunca sinalize um PID reciclado: o objeto Process ainda precisa
            // representar o mesmo processo em execução.
            guard process.isRunning, process.processIdentifier == pid else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}

private extension ACPAgentRun {
    static func cancelFrame(sessionID: String, maximumFrameBytes: Int) throws -> Data {
        let frame: AgentJSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/cancel"),
            "params": .object(["sessionId": .string(sessionID)]),
        ])
        let data = Data((try frame.jsonString() + "\n").utf8)
        guard data.count <= maximumFrameBytes else { throw ACPAgentClientError.frameTooLarge }
        return data
    }
}

private final class ACPOutputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var consumed = 0

    init(limit: Int) { self.limit = limit }

    func consume(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count >= 0, consumed <= limit - count else { return false }
        consumed += count
        return true
    }
}

private final class ACPLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumFrameBytes: Int
    private let outputBudget: ACPOutputBudget
    private let onFailure: @Sendable (ACPAgentClientError) -> Void
    private var handle: FileHandle?
    private var remainder = Data()
    private var finished = false
    private let stream: AsyncThrowingStream<Data, Error>
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation!

    init(
        maximumFrameBytes: Int,
        outputBudget: ACPOutputBudget,
        onFailure: @escaping @Sendable (ACPAgentClientError) -> Void
    ) {
        self.maximumFrameBytes = maximumFrameBytes
        self.outputBudget = outputBudget
        self.onFailure = onFailure
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        iterator = stream.makeAsyncIterator()
        self.continuation = continuation
    }

    func start(handle: FileHandle) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        self.handle = handle
        lock.unlock()
        handle.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData)
        }
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }

    func finish(throwing error: Error? = nil) {
        let state: (FileHandle?, AsyncThrowingStream<Data, Error>.Continuation?) = withLock {
            guard !finished else { return (nil, nil) }
            finished = true
            return (handle, continuation)
        }
        state.0?.readabilityHandler = nil
        if let error { state.1?.finish(throwing: error) } else { state.1?.finish() }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { finish(); return }
        guard outputBudget.consume(data.count) else {
            onFailure(.outputTooLarge)
            return
        }
        var frames: [Data] = []
        var failure: ACPAgentClientError?
        let continuation: AsyncThrowingStream<Data, Error>.Continuation? = withLock {
            guard !finished else { return nil }
            remainder.append(data)
            while let newline = remainder.firstIndex(of: 0x0A) {
                var frame = Data(remainder[..<newline])
                remainder.removeSubrange(...newline)
                if frame.last == 0x0D { frame.removeLast() }
                guard frame.count <= maximumFrameBytes else {
                    failure = .frameTooLarge
                    break
                }
                if !frame.isEmpty { frames.append(frame) }
            }
            if failure == nil, remainder.count > maximumFrameBytes { failure = .frameTooLarge }
            return continuation
        }
        if let failure {
            onFailure(failure)
            return
        }
        frames.forEach { _ = continuation?.yield($0) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ACPTailReader: @unchecked Sendable {
    private let lock = NSLock()
    private let outputBudget: ACPOutputBudget
    private let onFailure: @Sendable (ACPAgentClientError) -> Void
    private var handle: FileHandle?
    private var finished = false

    init(outputBudget: ACPOutputBudget, onFailure: @escaping @Sendable (ACPAgentClientError) -> Void) {
        self.outputBudget = outputBudget
        self.onFailure = onFailure
    }

    func start(handle: FileHandle) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        self.handle = handle
        lock.unlock()
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { self?.finish(); return }
            guard self?.outputBudget.consume(data.count) == true else {
                self?.onFailure(.outputTooLarge)
                return
            }
        }
    }

    func finish() {
        let handle: FileHandle? = withLock {
            guard !finished else { return nil }
            finished = true
            return self.handle
        }
        handle?.readabilityHandler = nil
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
