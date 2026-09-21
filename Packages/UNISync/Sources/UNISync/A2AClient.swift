import Foundation
import UNICore

/// A non-secret configuration for one explicitly selected remote A2A agent.
///
/// `credentialID` is only a Keychain lookup key. It never carries an API key,
/// token, password, or a credential-bearing URL.
public struct A2APeerConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The public card URL, or just an origin. An origin resolves to the A2A
    /// well-known Agent Card path.
    public var cardURL: String
    /// Optional reference resolved by the composition root from a secure store.
    public var credentialID: String
    public var enabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        cardURL: String = "",
        credentialID: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.cardURL = cardURL
        self.credentialID = credentialID
        self.enabled = enabled
    }

    public func validated() throws -> Self {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCredentialID = credentialID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, normalizedID.count <= 128,
              normalizedID.unicodeScalars.allSatisfy({
                  $0.properties.isAlphabetic || $0.properties.numericType != nil || "-_.".unicodeScalars.contains($0)
              }),
              !normalizedName.isEmpty, normalizedName.count <= 160,
              normalizedCredentialID.count <= 128,
              !normalizedCredentialID.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 })
        else { throw A2AClientError.invalidConfiguration }

        _ = try agentCardURL()
        return .init(
            id: normalizedID,
            name: normalizedName,
            cardURL: cardURL.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialID: normalizedCredentialID,
            enabled: enabled
        )
    }

    /// Resolves a bare origin to the discovery location registered by A2A.
    public func agentCardURL() throws -> URL {
        let raw = cardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              scheme == "https" || (scheme == "http" && Self.isLoopback(host))
        else { throw A2AClientError.invalidConfiguration }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/.well-known/agent-card.json"
        }
        guard let url = components.url else { throw A2AClientError.invalidConfiguration }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

/// Additive assistant preference for A2A. Secrets are intentionally absent.
public struct A2AConfiguration: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var peers: [A2APeerConfiguration]

    public init(enabled: Bool = false, peers: [A2APeerConfiguration] = []) {
        self.enabled = enabled
        self.peers = peers
    }

    public func validated() throws -> Self {
        guard enabled else { return self }
        guard peers.count <= 32 else { throw A2AClientError.invalidConfiguration }
        let peers = try peers.map { try $0.validated() }
        guard Set(peers.map(\.id)).count == peers.count else {
            throw A2AClientError.invalidConfiguration
        }
        return .init(enabled: true, peers: peers)
    }

    private enum CodingKeys: String, CodingKey { case enabled, peers }

    /// Existing settings documents did not have A2A. Decode them as disabled
    /// rather than turning an upgrade into an outbound connection.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        peers = try values.decodeIfPresent([A2APeerConfiguration].self, forKey: .peers) ?? []
    }
}

public struct A2APollingPolicy: Sendable, Hashable {
    public var requestTimeout: TimeInterval
    public var interval: TimeInterval
    public var maximumAttempts: Int
    public var maximumResponseBytes: Int

    public init(
        requestTimeout: TimeInterval = 30,
        interval: TimeInterval = 1,
        maximumAttempts: Int = 30,
        maximumResponseBytes: Int = 1_024 * 1_024
    ) {
        self.requestTimeout = min(max(requestTimeout, 1), 120)
        self.interval = min(max(interval, 0.1), 10)
        self.maximumAttempts = min(max(maximumAttempts, 1), 120)
        self.maximumResponseBytes = min(max(maximumResponseBytes, 4_096), 4 * 1_024 * 1_024)
    }
}

/// A deliberately redacted error surface: remote bodies can contain task data,
/// tokens, or provider diagnostics and are never promoted into an app error.
public enum A2AClientError: Error, Sendable, Equatable, LocalizedError {
    case disabled
    case peerNotFound
    case peerDisabled
    case invalidConfiguration
    case invalidAgentCard
    case unsupportedTransport
    case crossOriginEndpoint
    case redirectRefused
    case responseTooLarge
    case invalidResponse
    case networkUnavailable
    case server(statusCode: Int)
    case rpc(code: Int?)
    case pollLimitReached(taskID: String)

    public var errorDescription: String? {
        switch self {
        case .disabled: "A delegação A2A está desativada."
        case .peerNotFound: "O agente A2A selecionado não existe nesta configuração."
        case .peerDisabled: "O agente A2A selecionado está desativado."
        case .invalidConfiguration: "A configuração do agente A2A é inválida."
        case .invalidAgentCard: "O agente A2A publicou um Agent Card inválido."
        case .unsupportedTransport: "O agente A2A não publicou um transporte JSON-RPC compatível."
        case .crossOriginEndpoint: "O Agent Card apontou para outro domínio; a delegação foi interrompida."
        case .redirectRefused: "A rota A2A tentou redirecionar a requisição; a delegação foi interrompida."
        case .responseTooLarge: "O agente A2A devolveu uma resposta grande demais."
        case .invalidResponse: "O agente A2A devolveu uma resposta incompatível."
        case .networkUnavailable: "Não foi possível alcançar o agente A2A configurado."
        case let .server(statusCode): "O agente A2A respondeu com erro \(statusCode)."
        case .rpc: "O agente A2A recusou a operação solicitada."
        case let .pollLimitReached(taskID): "O agente A2A ainda está processando a tarefa \(taskID)."
        }
    }
}

/// The two wire contracts understood by this client. The Agent Card chooses
/// the contract; a configured peer never gets to choose an arbitrary endpoint.
public enum A2AProtocolGeneration: String, Sendable, Equatable, Hashable {
    case v1
    case v0_3
}

public struct A2AAgentInterface: Sendable, Equatable, Hashable {
    public let url: URL
    public let protocolBinding: String
    public let protocolVersion: String
    public let tenant: String?
    public let generation: A2AProtocolGeneration

    public init(
        url: URL,
        protocolBinding: String,
        protocolVersion: String,
        tenant: String?,
        generation: A2AProtocolGeneration = .v1
    ) {
        self.url = url
        self.protocolBinding = protocolBinding
        self.protocolVersion = protocolVersion
        self.tenant = tenant
        self.generation = generation
    }
}

public struct A2AAgentSkill: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let tags: [String]

    public init(id: String, name: String, description: String, tags: [String]) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
    }

    var toolValue: AgentJSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "description": .string(description),
            "tags": .array(tags.map(AgentJSONValue.string)),
        ])
    }
}

public struct A2AAgentCard: Sendable, Equatable {
    public let name: String
    public let description: String
    public let version: String
    public let interfaces: [A2AAgentInterface]
    public let skills: [A2AAgentSkill]
    public let supportsStreaming: Bool

    public init(
        name: String,
        description: String,
        version: String,
        interfaces: [A2AAgentInterface],
        skills: [A2AAgentSkill],
        supportsStreaming: Bool
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.interfaces = interfaces
        self.skills = skills
        self.supportsStreaming = supportsStreaming
    }

    var toolValue: AgentJSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "version": .string(version),
            "protocolVersion": .string(interfaces.first?.protocolVersion ?? ""),
            "supportsStreaming": .bool(supportsStreaming),
            "skills": .array(skills.map(\.toolValue)),
        ])
    }
}

public enum A2ATaskState: String, Sendable, Equatable, Hashable {
    case submitted = "TASK_STATE_SUBMITTED"
    case working = "TASK_STATE_WORKING"
    case completed = "TASK_STATE_COMPLETED"
    case failed = "TASK_STATE_FAILED"
    case canceled = "TASK_STATE_CANCELED"
    case inputRequired = "TASK_STATE_INPUT_REQUIRED"
    case rejected = "TASK_STATE_REJECTED"
    case authRequired = "TASK_STATE_AUTH_REQUIRED"
    case unspecified = "TASK_STATE_UNSPECIFIED"
    case unknown

    fileprivate init(wireValue: String) {
        switch wireValue {
        case "submitted": self = .submitted
        case "working": self = .working
        case "completed": self = .completed
        case "failed": self = .failed
        case "canceled", "cancelled": self = .canceled
        case "input-required": self = .inputRequired
        case "rejected": self = .rejected
        case "auth-required": self = .authRequired
        case "unspecified": self = .unspecified
        default: self = Self(rawValue: wireValue) ?? .unknown
        }
    }

    public var isTerminalOrInterrupted: Bool {
        switch self {
        case .completed, .failed, .canceled, .inputRequired, .rejected, .authRequired: true
        case .submitted, .working, .unspecified, .unknown: false
        }
    }
}

public struct A2APart: Sendable, Equatable {
    public let text: String?
    public let data: AgentJSONValue?
    public let url: URL?
    public let raw: String?
    public let filename: String?
    public let mediaType: String?

    fileprivate init?(wire: AgentJSONValue) {
        guard let object = wire.objectValue else { return nil }
        let file = object["file"]?.objectValue
        let text = object["text"]?.stringValue
        let data = object["data"]
        let url = (object["url"]?.stringValue ?? file?["uri"]?.stringValue).flatMap(URL.init(string:))
        let raw = object["raw"]?.stringValue ?? file?["bytes"]?.stringValue ?? file?["data"]?.stringValue
        guard text != nil || data != nil || url != nil || raw != nil else { return nil }
        self.text = text
        self.data = data
        self.url = url
        self.raw = raw
        filename = object["filename"]?.stringValue ?? file?["name"]?.stringValue
        mediaType = object["mediaType"]?.stringValue ?? file?["mimeType"]?.stringValue
    }

    var toolValue: AgentJSONValue {
        var result: [String: AgentJSONValue] = [:]
        if let text { result["text"] = .string(Self.limit(text, to: 100_000)) }
        if let data { result["data"] = data }
        if let url { result["url"] = .string(url.absoluteString) }
        if let raw { result["raw"] = .string(Self.limit(raw, to: 100_000)) }
        if let filename { result["filename"] = .string(filename) }
        if let mediaType { result["mediaType"] = .string(mediaType) }
        return .object(result)
    }

    private static func limit(_ value: String, to maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum)) + "\n[truncated]"
    }
}

public struct A2AMessage: Sendable, Equatable {
    public let role: String
    public let parts: [A2APart]
    public let contextID: String?
    public let taskID: String?

    fileprivate init?(wire: AgentJSONValue) {
        guard let object = wire.objectValue,
              let role = object["role"]?.stringValue,
              let parts = object["parts"]?.arrayValue?.compactMap(A2APart.init(wire:)),
              !parts.isEmpty
        else { return nil }
        self.role = role
        self.parts = parts
        contextID = object["contextId"]?.stringValue
        taskID = object["taskId"]?.stringValue
    }

    public var text: String {
        parts.compactMap(\.text).joined(separator: "\n")
    }

    var toolValue: AgentJSONValue {
        .object([
            "role": .string(role),
            "text": .string(A2APartTextLimit.limit(text)),
            "parts": .array(parts.map(\.toolValue)),
        ])
    }
}

public struct A2AArtifact: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let parts: [A2APart]

    fileprivate init?(wire: AgentJSONValue) {
        guard let object = wire.objectValue,
              let id = object["artifactId"]?.stringValue,
              !id.isEmpty,
              let parts = object["parts"]?.arrayValue?.compactMap(A2APart.init(wire:)),
              !parts.isEmpty
        else { return nil }
        self.id = id
        self.name = object["name"]?.stringValue ?? ""
        self.description = object["description"]?.stringValue ?? ""
        self.parts = parts
    }

    public var text: String {
        parts.compactMap(\.text).joined(separator: "\n")
    }

    var toolValue: AgentJSONValue {
        .object([
            "artifactID": .string(id),
            "name": .string(name),
            "description": .string(description),
            "text": .string(A2APartTextLimit.limit(text)),
            "parts": .array(parts.map(\.toolValue)),
        ])
    }
}

public struct A2ATask: Sendable, Equatable {
    public let id: String
    public let contextID: String?
    public let state: A2ATaskState
    public let statusMessage: A2AMessage?
    public let artifacts: [A2AArtifact]

    fileprivate init?(wire: AgentJSONValue) {
        guard let object = wire.objectValue,
              let id = object["id"]?.stringValue,
              !id.isEmpty,
              let state = object["status"]?["state"]?.stringValue
        else { return nil }
        self.id = id
        contextID = object["contextId"]?.stringValue
        self.state = .init(wireValue: state)
        statusMessage = object["status"]?["message"].flatMap(A2AMessage.init(wire:))
        artifacts = object["artifacts"]?.arrayValue?.compactMap(A2AArtifact.init(wire:)) ?? []
    }

    var toolValue: AgentJSONValue {
        var result: [String: AgentJSONValue] = [
            "taskID": .string(id),
            "state": .string(state.rawValue),
            "artifacts": .array(artifacts.prefix(20).map(\.toolValue)),
        ]
        if let contextID { result["contextID"] = .string(contextID) }
        if let statusMessage { result["message"] = statusMessage.toolValue }
        return .object(result)
    }
}

public enum A2AResponse: Sendable, Equatable {
    case task(A2ATask)
    case message(A2AMessage)

    var toolValue: AgentJSONValue {
        switch self {
        case let .task(task):
            return .object(["kind": .string("task"), "task": task.toolValue])
        case let .message(message):
            return .object(["kind": .string("message"), "message": message.toolValue])
        }
    }
}

private enum A2APartTextLimit {
    static func limit(_ value: String) -> String {
        guard value.count > 100_000 else { return value }
        return String(value.prefix(100_000)) + "\n[truncated]"
    }
}

/// Resolves an Agent Card and talks to the first same-origin JSON-RPC
/// interface it publishes. The client never follows redirects while a request
/// carries credentials, and it does not fetch a remote task unless the caller
/// selected one of the configured peers by ID.
public actor A2AClient {
    public typealias CredentialHeaders = @Sendable (String) throws -> [String: String]

    private let configuration: A2AConfiguration
    private let credentialHeaders: CredentialHeaders
    private let polling: A2APollingPolicy

    public init(
        configuration: A2AConfiguration,
        polling: A2APollingPolicy = .init(),
        credentialHeaders: @escaping CredentialHeaders = { _ in [:] }
    ) {
        self.configuration = configuration
        self.polling = polling
        self.credentialHeaders = credentialHeaders
    }

    public func configuredPeers() throws -> [A2APeerConfiguration] {
        guard configuration.enabled else { throw A2AClientError.disabled }
        return try configuration.validated().peers.filter(\.enabled)
    }

    public func discover(peerID: String) async throws -> A2AAgentCard {
        let peer = try configuredPeer(id: peerID)
        return try await resolve(peer: peer).card
    }

    /// Sends exactly `task`, as a single A2A text part. The caller is
    /// responsible for deciding what the task says; no app state, mailbox,
    /// history, attachments, or prompt snapshot is appended here.
    public func delegate(peerID: String, task: String) async throws -> A2AResponse {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 100_000 else { throw A2AClientError.invalidConfiguration }
        let peer = try configuredPeer(id: peerID)
        let route = try await resolve(peer: peer)
        let response = try await send(peer: peer, route: route, task: text)
        guard case let .task(started) = response, !started.state.isTerminalOrInterrupted else { return response }

        let cancellation = A2AInFlightCancellation(peerID: peer.id, taskID: started.id)
        return try await withTaskCancellationHandler(operation: {
            try await poll(peer: peer, route: route, taskID: started.id)
        }, onCancel: {
            cancellation.cancel(using: self)
        })
    }

    /// Cancels an A2A task explicitly. Cancel is an idempotent A2A operation;
    /// the method performs one bounded request and returns the state observed
    /// in that response.
    public func cancel(peerID: String, taskID: String) async throws -> A2ATask {
        let taskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty, taskID.count <= 512 else { throw A2AClientError.invalidConfiguration }
        let peer = try configuredPeer(id: peerID)
        let route = try await resolve(peer: peer)
        let result = try await request(
            peer: peer,
            route: route,
            method: method(for: route.interface, v1: "CancelTask", legacy: "tasks/cancel"),
            params: parameters(["id": .string(taskID)], tenant: route.interface.tenant)
        )
        guard let task = A2ATask(wire: result) else { throw A2AClientError.invalidResponse }
        return task
    }

    private func configuredPeer(id: String) throws -> A2APeerConfiguration {
        guard configuration.enabled else { throw A2AClientError.disabled }
        let valid = try configuration.validated()
        guard let peer = valid.peers.first(where: { $0.id == id }) else { throw A2AClientError.peerNotFound }
        guard peer.enabled else { throw A2AClientError.peerDisabled }
        return peer
    }

    private func resolve(peer: A2APeerConfiguration) async throws -> A2AResolvedRoute {
        let cardURL = try peer.agentCardURL()
        let cardOrigin = try A2AOrigin(cardURL)
        var request = URLRequest(url: cardURL)
        request.httpMethod = "GET"
        request.timeoutInterval = polling.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, application/a2a+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        guard let responseURL = response.url, try A2AOrigin(responseURL) == cardOrigin else {
            throw A2AClientError.crossOriginEndpoint
        }
        let card = try decodeCard(data)
        guard let interface = card.interfaces.first(where: {
            $0.protocolBinding.caseInsensitiveCompare("JSONRPC") == .orderedSame
        }) else { throw A2AClientError.unsupportedTransport }
        guard try A2AOrigin(interface.url) == cardOrigin else { throw A2AClientError.crossOriginEndpoint }
        return .init(card: card, interface: interface)
    }

    private func send(peer: A2APeerConfiguration, route: A2AResolvedRoute, task: String) async throws -> A2AResponse {
        let legacy = route.interface.generation == .v0_3
        // Do not send context, history, metadata, mailbox contents, or any
        // prompt snapshot: this is one independent explicit delegation.
        let configuration: [String: AgentJSONValue] = [
            legacy ? "blocking" : "returnImmediately": .bool(legacy ? false : true),
            "acceptedOutputModes": .array([.string("text/plain"), .string("application/json")]),
        ]
        let params = parameters([
            "message": .object([
                "messageId": .string(UUID().uuidString),
                "role": .string(legacy ? "user" : "ROLE_USER"),
                "parts": .array([.object(["text": .string(task)])]),
            ]),
            "configuration": .object(configuration),
        ], tenant: route.interface.tenant)
        let result = try await request(
            peer: peer,
            route: route,
            method: method(for: route.interface, v1: "SendMessage", legacy: "message/send"),
            params: params
        )
        // JSON-RPC A2A v0.3 returns the Task or Message directly. v1 wraps
        // the same payload in `task` or `message` for SendMessage.
        if legacy {
            if let task = A2ATask(wire: result) { return .task(task) }
            if let message = A2AMessage(wire: result) { return .message(message) }
        }
        if let task = result["task"].flatMap(A2ATask.init(wire:)) { return .task(task) }
        if let message = result["message"].flatMap(A2AMessage.init(wire:)) { return .message(message) }
        throw A2AClientError.invalidResponse
    }

    private func poll(peer: A2APeerConfiguration, route: A2AResolvedRoute, taskID: String) async throws -> A2AResponse {
        for attempt in 0..<polling.maximumAttempts {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .seconds(polling.interval)) }
            let result = try await request(
                peer: peer,
                route: route,
                method: method(for: route.interface, v1: "GetTask", legacy: "tasks/get"),
                params: parameters(["id": .string(taskID), "historyLength": .number(0)], tenant: route.interface.tenant)
            )
            guard let task = A2ATask(wire: result) else { throw A2AClientError.invalidResponse }
            if task.state.isTerminalOrInterrupted { return .task(task) }
        }
        throw A2AClientError.pollLimitReached(taskID: taskID)
    }

    private func request(
        peer: A2APeerConfiguration,
        route: A2AResolvedRoute,
        method: String,
        params: AgentJSONValue
    ) async throws -> AgentJSONValue {
        var request = URLRequest(url: route.interface.url)
        request.httpMethod = "POST"
        request.timeoutInterval = polling.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if route.interface.generation == .v1, !route.interface.protocolVersion.isEmpty {
            request.setValue(route.interface.protocolVersion, forHTTPHeaderField: "A2A-Version")
        }
        for (name, value) in try authenticatedHeaders(for: peer) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let id = UUID().uuidString
        request.httpBody = try JSONEncoder().encode(AgentJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "method": .string(method),
            "params": params,
        ]))
        let (data, response) = try await perform(request)
        guard response.url == route.interface.url else { throw A2AClientError.redirectRefused }
        guard let object = try? JSONDecoder().decode(AgentJSONValue.self, from: data).objectValue,
              object["jsonrpc"]?.stringValue == "2.0",
              object["id"]?.stringValue == id
        else { throw A2AClientError.invalidResponse }
        if let error = object["error"]?.objectValue {
            throw A2AClientError.rpc(code: error["code"]?.intValue)
        }
        guard let result = object["result"] else { throw A2AClientError.invalidResponse }
        return result
    }

    private func authenticatedHeaders(for peer: A2APeerConfiguration) throws -> [String: String] {
        guard !peer.credentialID.isEmpty else { return [:] }
        let headers = try credentialHeaders(peer.credentialID)
        guard headers.count <= 16 else { throw A2AClientError.invalidConfiguration }
        for (name, value) in headers {
            let containsBreak = name.unicodeScalars.contains { $0.value == 10 || $0.value == 13 }
                || value.unicodeScalars.contains { $0.value == 10 || $0.value == 13 }
            guard !name.isEmpty, name.count <= 256, value.count <= 16_384, !containsBreak,
                  name.caseInsensitiveCompare("Host") != .orderedSame,
                  name.caseInsensitiveCompare("Content-Length") != .orderedSame
            else { throw A2AClientError.invalidConfiguration }
        }
        return headers
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(
            configuration: .ephemeral,
            delegate: A2ANoRedirectDelegate.shared,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw A2AClientError.networkUnavailable }
            if (300..<400).contains(http.statusCode) { throw A2AClientError.redirectRefused }
            guard (200..<300).contains(http.statusCode) else { throw A2AClientError.server(statusCode: http.statusCode) }
            guard response.expectedContentLength <= polling.maximumResponseBytes else { throw A2AClientError.responseTooLarge }
            var data = Data()
            data.reserveCapacity(min(polling.maximumResponseBytes, 65_536))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < polling.maximumResponseBytes else { throw A2AClientError.responseTooLarge }
                data.append(byte)
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as A2AClientError {
            throw error
        } catch {
            throw A2AClientError.networkUnavailable
        }
    }

    private func decodeCard(_ data: Data) throws -> A2AAgentCard {
        guard data.count <= polling.maximumResponseBytes,
              let object = try? JSONDecoder().decode(AgentJSONValue.self, from: data).objectValue,
              let name = object["name"]?.stringValue,
              !name.isEmpty,
              let description = object["description"]?.stringValue
        else { throw A2AClientError.invalidAgentCard }

        let interfaces: [A2AAgentInterface]
        if let rawInterfaces = object["supportedInterfaces"]?.arrayValue, !rawInterfaces.isEmpty {
            interfaces = try rawInterfaces.map { raw in
                guard let value = raw.objectValue,
                      let rawURL = value["url"]?.stringValue,
                      let url = URL(string: rawURL),
                      let binding = value["protocolBinding"]?.stringValue,
                      let version = value["protocolVersion"]?.stringValue,
                      !binding.isEmpty,
                      !version.isEmpty
                else { throw A2AClientError.invalidAgentCard }
                _ = try A2AOrigin(url)
                return .init(
                    url: url,
                    protocolBinding: binding,
                    protocolVersion: version,
                    tenant: value["tenant"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    generation: .v1
                )
            }
        } else {
            guard let protocolVersion = object["protocolVersion"]?.stringValue,
                  protocolVersion == "0.3" || protocolVersion.hasPrefix("0.3."),
                  let rawURL = object["url"]?.stringValue,
                  let url = URL(string: rawURL),
                  let preferredTransport = object["preferredTransport"]?.stringValue,
                  !preferredTransport.isEmpty
            else { throw A2AClientError.invalidAgentCard }
            _ = try A2AOrigin(url)
            let primary = A2AAgentInterface(
                url: url,
                protocolBinding: preferredTransport,
                protocolVersion: protocolVersion,
                tenant: nil,
                generation: .v0_3
            )
            let additions = try (object["additionalInterfaces"]?.arrayValue ?? []).map { raw in
                guard let value = raw.objectValue,
                      let rawURL = value["url"]?.stringValue,
                      let url = URL(string: rawURL),
                      let transport = value["transport"]?.stringValue,
                      !transport.isEmpty
                else { throw A2AClientError.invalidAgentCard }
                _ = try A2AOrigin(url)
                return A2AAgentInterface(
                    url: url,
                    protocolBinding: transport,
                    protocolVersion: protocolVersion,
                    tenant: nil,
                    generation: .v0_3
                )
            }
            interfaces = [primary] + additions
        }
        let skills = object["skills"]?.arrayValue?.compactMap { raw -> A2AAgentSkill? in
            guard let value = raw.objectValue,
                  let id = value["id"]?.stringValue,
                  let name = value["name"]?.stringValue,
                  let description = value["description"]?.stringValue,
                  !id.isEmpty, !name.isEmpty
            else { return nil }
            return .init(id: id, name: name, description: description, tags: value["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        } ?? []
        return .init(
            name: name,
            description: description,
            version: object["version"]?.stringValue ?? "",
            interfaces: interfaces,
            skills: skills,
            supportsStreaming: object["capabilities"]?["streaming"]?.boolValue ?? false
        )
    }

    private func parameters(_ values: [String: AgentJSONValue], tenant: String?) -> AgentJSONValue {
        var values = values
        if let tenant { values["tenant"] = .string(tenant) }
        return .object(values)
    }

    private func method(for interface: A2AAgentInterface, v1: String, legacy: String) -> String {
        interface.generation == .v0_3 ? legacy : v1
    }
}

private struct A2AResolvedRoute: Sendable {
    let card: A2AAgentCard
    let interface: A2AAgentInterface
}

private struct A2AOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1"))
        else { throw A2AClientError.invalidAgentCard }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

private final class A2ANoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = A2ANoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class A2AInFlightCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private let peerID: String
    private let taskID: String

    init(peerID: String, taskID: String) {
        self.peerID = peerID
        self.taskID = taskID
    }

    func cancel(using client: A2AClient) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !canceled else { return false }
            canceled = true
            return true
        }
        guard shouldCancel else { return }
        Task { _ = try? await client.cancel(peerID: peerID, taskID: taskID) }
    }
}
