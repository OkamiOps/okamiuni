import Foundation
import Security
import UNISync

// `main.swift` is the XPC service entry point. Keeping these references at
// file scope ensures the listener delegate outlives the run loop.
private let runtimeListener = NSXPCListener.service()
private let runtimeListenerDelegate = AgentRuntimeServiceListener()
runtimeListener.delegate = runtimeListenerDelegate
runtimeListener.resume()
RunLoop.current.run()

/// The helper deliberately has no App Sandbox entitlement. It accepts only a
/// signed host that satisfies the signed identifier and team requirements in
/// its Info.plist, then exposes a single bounded ACP request per XPC client.
private final class AgentRuntimeServiceListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Apply the validated, signed requirement to this peer before it can
        // send a request. Foundation evaluates it against the XPC audit token.
        connection.setCodeSigningRequirement(CodeSignedClientValidator.requiredConnectionRequirement)
        let service = AgentRuntimeConnectionService()
        connection.exportedInterface = NSXPCInterface(with: ACPExternalRuntimeXPCService.self)
        connection.exportedObject = service
        connection.interruptionHandler = { service.cancelAll() }
        connection.invalidationHandler = { service.cancelAll() }
        connection.resume()
        return true
    }
}

private enum CodeSignedClientValidator {
    static let requiredConnectionRequirement: String = {
        guard let requirement = connectionRequirement() else {
            fatalError("AgentRuntimeService has no valid signed client requirement")
        }
        return requirement
    }()

    static func connectionRequirement() -> String? {
        guard let identifiers = Bundle.main.object(forInfoDictionaryKey: "AllowedClientIdentifiers") as? [String],
              !identifiers.isEmpty,
              let expectedTeam = Bundle.main.object(forInfoDictionaryKey: "AllowedClientTeamIdentifier") as? String,
              isRequirementComponent(expectedTeam),
              identifiers.allSatisfy(isRequirementComponent)
        else { return nil }

        let identifiersRequirement = identifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeam)\" and (\(identifiersRequirement))"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement
        else { return nil }
        _ = requirement
        return requirementText
    }

    private static func isRequirementComponent(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (65...90).contains(scalar.value) ||
                (97...122).contains(scalar.value) || scalar.value == 45 || scalar.value == 46
        }
    }
}

/// One exported object belongs to exactly one XPC connection. Invalidating it
/// terminates every ACP child associated with that client and releases all
/// callback closures.
private final class AgentRuntimeConnectionService: NSObject, ACPExternalRuntimeXPCService {
    private static let maximumRequestBytes = 1_200_000
    private let requests = AgentRuntimeRequestRegistry()

    func execute(_ encodedRequest: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        guard encodedRequest.count <= Self.maximumRequestBytes else {
            reply(Self.encodedResponse(.init(requestID: UUID(), failure: .invalidRequest)), nil)
            return
        }

        let request: ACPExternalRuntimeRequest
        do {
            request = try JSONDecoder().decode(ACPExternalRuntimeRequest.self, from: encodedRequest)
            try RequestValidator.validate(request)
        } catch {
            reply(Self.encodedResponse(.init(requestID: Self.requestID(in: encodedRequest), failure: .invalidRequest)), nil)
            return
        }

        let callback = AgentRuntimeReply(reply)
        Task { [requests] in
            let started = await requests.start(request.requestID) {
                let response = await Self.run(request)
                callback.send(Self.encodedResponse(response), nil)
            }
            if !started {
                callback.send(Self.encodedResponse(.init(requestID: request.requestID, failure: .invalidRequest)), nil)
            }
        }
    }

    func cancel(_ requestID: String, withReply reply: @escaping () -> Void) {
        let callback = AgentRuntimeCancelReply(reply)
        guard let id = UUID(uuidString: requestID) else {
            callback.send()
            return
        }
        Task { [requests] in
            await requests.cancel(id)
            callback.send()
        }
    }

    func cancelAll() {
        Task { [requests] in await requests.cancelAll() }
    }

    private static func run(_ request: ACPExternalRuntimeRequest) async -> ACPExternalRuntimeResponse {
        var scopedURL: URL?
        var didStartSecurityScope = false
        defer {
            if didStartSecurityScope { scopedURL?.stopAccessingSecurityScopedResource() }
        }
        do {
            if let bookmark = request.runtimeBookmarkData {
                var stale = false
                let resolved = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                guard !stale, resolved.standardizedFileURL.path == request.executablePath else {
                    return .init(requestID: request.requestID, failure: .invalidRequest)
                }
                scopedURL = resolved
                didStartSecurityScope = resolved.startAccessingSecurityScopedResource()
            }

            let mcpURL = try RequestValidator.mcpURL(request.mcpURL)
            let client = ACPAgentClient(configuration: .init(
                executableURL: URL(fileURLWithPath: request.executablePath),
                arguments: request.arguments,
                environment: request.environment,
                cwd: request.workingDirectoryPath.map(URL.init(fileURLWithPath:)),
                safeMCPToolNames: Set(request.toolNames)
            ))
            switch request.mode {
            case .check:
                let name = try await client.checkConnection(mcpURL: mcpURL, bearerToken: request.bearerToken)
                return .init(requestID: request.requestID, agentName: name)
            case .answer:
                guard let prompt = request.prompt else {
                    return .init(requestID: request.requestID, failure: .invalidRequest)
                }
                let answer = try await client.answer(prompt: prompt, mcpURL: mcpURL, bearerToken: request.bearerToken)
                return .init(requestID: request.requestID, answer: answer)
            }
        } catch is CancellationError {
            return .init(requestID: request.requestID, failure: .cancelled)
        } catch let error as ACPAgentClientError {
            return .init(requestID: request.requestID, failure: .from(error))
        } catch {
            // The client does not receive a path, token, ACP stderr, or other
            // provider-owned state from this boundary.
            return .init(requestID: request.requestID, failure: .agentFailed)
        }
    }

    private static func encodedResponse(_ response: ACPExternalRuntimeResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }

    private static func requestID(in data: Data) -> UUID {
        (try? JSONDecoder().decode(ACPExternalRuntimeRequest.self, from: data).requestID) ?? UUID()
    }
}

/// The actor serializes admission and removal. A task can complete before the
/// `start` call returns, but it cannot remove itself until this actor has first
/// recorded it, so duplicate request IDs remain fail-closed.
private actor AgentRuntimeRequestRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    func start(_ id: UUID, operation: @escaping @Sendable () async -> Void) -> Bool {
        guard !isClosed, tasks[id] == nil else { return false }
        let task = Task { [weak self] in
            await operation()
            await self?.finished(id)
        }
        tasks[id] = task
        return true
    }

    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    func cancelAll() {
        isClosed = true
        let active = tasks.values
        tasks.removeAll()
        active.forEach { $0.cancel() }
    }

    private func finished(_ id: UUID) {
        tasks.removeValue(forKey: id)
    }
}

/// Foundation XPC reply closures are not annotated Sendable even though XPC
/// permits asynchronous replies. These boxes restrict that escape hatch to a
/// single stored closure and keep the surrounding task graph Sendable.
private final class AgentRuntimeReply: @unchecked Sendable {
    private let handler: (Data?, NSError?) -> Void

    init(_ handler: @escaping (Data?, NSError?) -> Void) {
        self.handler = handler
    }

    func send(_ data: Data?, _ error: NSError?) {
        handler(data, error)
    }
}

private final class AgentRuntimeCancelReply: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func send() {
        handler()
    }
}

private enum RequestValidator {
    static func validate(_ request: ACPExternalRuntimeRequest) throws {
        guard isAbsolutePath(request.executablePath), request.executablePath.count <= 4_096,
              request.arguments.count <= 32,
              request.arguments.allSatisfy(isLiteral),
              request.environment.count <= 16,
              request.environment.allSatisfy(isSafeEnvironment),
              request.workingDirectoryPath.map(isAbsolutePath) ?? true,
              request.workingDirectoryPath.map({ $0.count <= 4_096 }) ?? true,
              request.runtimeBookmarkData.map({ $0.count <= 262_144 }) ?? true,
              request.toolNames.count <= 256,
              request.toolNames.allSatisfy(isToolName),
              request.bearerToken.count <= 16_384,
              request.mcpURL.count <= 8_192
        else { throw AgentRuntimeServiceError.invalidRequest }
        _ = try mcpURL(request.mcpURL)
        switch request.mode {
        case .check:
            guard request.prompt == nil else { throw AgentRuntimeServiceError.invalidRequest }
        case .answer:
            guard let prompt = request.prompt, prompt.count <= 1_000_000 else {
                throw AgentRuntimeServiceError.invalidRequest
            }
        }
    }

    /// The MCP endpoint belongs to the host app. A runtime cannot use this
    /// request channel as an arbitrary HTTP proxy.
    static func mcpURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              url.scheme == "http" || url.scheme == "https",
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host)
        else { throw AgentRuntimeServiceError.invalidRequest }
        return url
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        (value as NSString).isAbsolutePath && isLiteral(value)
    }

    private static func isLiteral(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 4_096 &&
            !value.unicodeScalars.contains { $0.value == 0 || $0.value == 10 || $0.value == 13 }
    }

    private static func isToolName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 &&
            value.unicodeScalars.allSatisfy { scalar in
                (65...90).contains(scalar.value) || (97...122).contains(scalar.value) ||
                    (48...57).contains(scalar.value) || scalar.value == 46 || scalar.value == 95 || scalar.value == 45
            }
    }

    private static func isSafeEnvironment(_ item: (key: String, value: String)) -> Bool {
        let name = item.key.uppercased()
        guard isToolName(item.key), isLiteral(item.value) else { return false }
        let prohibited = [
            "PATH", "HOME", "TMPDIR", "TMP", "TEMP", "PWD", "SHELL", "SHLVL", "ENV", "BASH_ENV",
            "NODE_OPTIONS", "NODE_PATH", "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP",
            "RUBYOPT", "RUBYLIB", "PERL5OPT", "JAVA_TOOL_OPTIONS",
        ]
        let credentialTerms = ["TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "API_KEY", "ACCESS_KEY"]
        return !prohibited.contains(name) && !name.hasPrefix("DYLD_") && !name.hasPrefix("LD_") &&
            !credentialTerms.contains(where: name.contains)
    }
}

private enum AgentRuntimeServiceError: Error {
    case invalidRequest
}
