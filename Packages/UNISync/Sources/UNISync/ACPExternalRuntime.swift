import Foundation
import UNICore

/// Operation requested from the separately signed ACP XPC service.
///
/// The request crosses XPC as encoded `Data`, never as an Objective-C object
/// graph. It contains no persisted credentials: the bearer token exists only
/// for this MCP session and is redacted on both sides if execution fails.
public enum ACPExternalRuntimeMode: String, Codable, Sendable, Equatable {
    case check
    case answer
}

public struct ACPExternalRuntimeRequest: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    /// `nil` directs the helper to create its own private temporary directory.
    public let workingDirectoryPath: String?
    /// A transient security-scoped bookmark for an app-container managed
    /// runtime, when the helper needs to resolve it as a separate process.
    public let runtimeBookmarkData: Data?
    public let prompt: String?
    public let mcpURL: String
    public let bearerToken: String
    public let toolNames: [String]
    public let mode: ACPExternalRuntimeMode

    public init(
        requestID: UUID = UUID(),
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryPath: String? = nil,
        runtimeBookmarkData: Data? = nil,
        prompt: String? = nil,
        mcpURL: URL,
        bearerToken: String,
        toolNames: [String] = [],
        mode: ACPExternalRuntimeMode
    ) {
        self.requestID = requestID
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryPath = workingDirectoryPath
        self.runtimeBookmarkData = runtimeBookmarkData
        self.prompt = prompt
        self.mcpURL = mcpURL.absoluteString
        self.bearerToken = bearerToken
        self.toolNames = toolNames
        self.mode = mode
    }
}

public enum ACPExternalRuntimeFailure: String, Codable, Sendable, Equatable {
    case invalidRequest
    case cancelled
    case timedOut
    case failedToStart
    case outputTooLarge
    case frameTooLarge
    case invalidResponse
    case unsupportedProtocol
    case unsupportedHTTPTransport
    case remoteFailure
    case processFailed
    case emptyResponse
    case agentFailed

    public static func from(_ error: ACPAgentClientError) -> Self {
        switch error {
        case .invalidConfiguration: .invalidRequest
        case .failedToStart: .failedToStart
        case .timedOut: .timedOut
        case .outputTooLarge: .outputTooLarge
        case .frameTooLarge: .frameTooLarge
        case .invalidResponse: .invalidResponse
        case .unsupportedProtocol: .unsupportedProtocol
        case .unsupportedHTTPTransport: .unsupportedHTTPTransport
        case .remoteFailure: .remoteFailure
        case .processFailed: .processFailed
        case .emptyResponse: .emptyResponse
        }
    }
}

public struct ACPExternalRuntimeResponse: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let answer: String?
    public let agentName: String?
    public let failure: ACPExternalRuntimeFailure?

    public init(
        requestID: UUID,
        answer: String? = nil,
        agentName: String? = nil,
        failure: ACPExternalRuntimeFailure? = nil
    ) {
        self.requestID = requestID
        self.answer = answer
        self.agentName = agentName
        self.failure = failure
    }
}

public enum ACPExternalRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case timedOut
    case invalidResponse
    case invalidRequest
    case cancelled
    case agentFailed
    /// A bounded, provider-safe ACP transport error. The helper never returns
    /// the child process stderr, environment, runtime path, or credentials.
    case agent(ACPAgentClientError)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            L10n.tr("O serviço externo do agente ACP não está disponível.")
        case .timedOut:
            L10n.tr("O agente ACP demorou demais para responder.")
        case .invalidResponse:
            L10n.tr("O serviço ACP devolveu uma resposta inválida.")
        case .invalidRequest:
            L10n.tr("A configuração do agente ACP não é válida.")
        case .cancelled:
            L10n.tr("A solicitação ao agente ACP foi cancelada.")
        case .agentFailed:
            L10n.tr("O agente ACP não concluiu a solicitação.")
        case .agent(let error):
            error.localizedDescription
        }
    }
}

/// XPC only accepts Foundation bridgeable values. Codable payloads keep the
/// public transport contract versionable and prevent the agent configuration
/// from becoming an implicit Objective-C API surface.
@objc public protocol ACPExternalRuntimeXPCService {
    func execute(_ encodedRequest: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func cancel(_ requestID: String, withReply reply: @escaping () -> Void)
}

/// Client for the embedded, separately signed runtime service. Every call gets
/// a new XPC connection, a deadline, and an invalidation handler so cancelled
/// or crashed helpers cannot leave a UI operation awaiting indefinitely.
public struct ACPExternalRuntime: Sendable {
    public static let productionServiceName = "com.okamiops.okamiuni.AgentRuntimeService"

    public let serviceName: String
    public let timeout: TimeInterval

    public init(serviceName: String = ACPExternalRuntime.productionServiceName, timeout: TimeInterval = 120) {
        self.serviceName = serviceName
        self.timeout = min(max(timeout, 1), 300)
    }

    public func answer(
        configuration: AgentConnectionConfiguration,
        prompt: String,
        mcpURL: URL,
        bearerToken: String,
        safeToolNames: Set<String>
    ) async throws -> String {
        let request = try makeRequest(
            configuration: configuration,
            prompt: prompt,
            mcpURL: mcpURL,
            bearerToken: bearerToken,
            safeToolNames: safeToolNames,
            mode: .answer
        )
        let response = try await perform(request)
        if let failure = response.failure { throw Self.error(for: failure) }
        guard let answer = response.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ACPExternalRuntimeError.invalidResponse
        }
        return answer
    }

    public func checkConnection(
        configuration: AgentConnectionConfiguration,
        mcpURL: URL,
        bearerToken: String
    ) async throws -> String {
        let request = try makeRequest(
            configuration: configuration,
            prompt: nil,
            mcpURL: mcpURL,
            bearerToken: bearerToken,
            safeToolNames: [],
            mode: .check
        )
        let response = try await perform(request)
        if let failure = response.failure { throw Self.error(for: failure) }
        guard let agentName = response.agentName, !agentName.isEmpty else {
            throw ACPExternalRuntimeError.invalidResponse
        }
        return agentName
    }

    public func perform(_ request: ACPExternalRuntimeRequest) async throws -> ACPExternalRuntimeResponse {
        let call = ACPExternalRuntimeCall(serviceName: serviceName, requestID: request.requestID, timeout: timeout)
        return try await withTaskCancellationHandler(operation: {
            try await call.perform(request)
        }, onCancel: {
            call.cancel()
        })
    }

    private func makeRequest(
        configuration: AgentConnectionConfiguration,
        prompt: String?,
        mcpURL: URL,
        bearerToken: String,
        safeToolNames: Set<String>,
        mode: ACPExternalRuntimeMode
    ) throws -> ACPExternalRuntimeRequest {
        _ = try configuration.validated(requireExecutable: false)
        let executableURL: URL
        let workingDirectory: URL?
        let runtimeBookmarkData: Data?
        if let managed = configuration.managedRuntime {
            let root = try ACPManagedRuntime.managedRuntimeRoot()
            let install = root.appendingPathComponent(managed.installationID, isDirectory: true)
            executableURL = install.appendingPathComponent(managed.executableRelativePath, isDirectory: false)
            workingDirectory = install
            // The helper is a distinct process. The bookmark is ephemeral and
            // sent only with this request; it is never stored by the helper.
            runtimeBookmarkData = try? executableURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            guard (configuration.executablePath as NSString).isAbsolutePath else {
                throw ACPExternalRuntimeError.invalidRequest
            }
            executableURL = URL(fileURLWithPath: configuration.executablePath)
            workingDirectory = nil
            runtimeBookmarkData = nil
        }
        return ACPExternalRuntimeRequest(
            executablePath: executableURL.path,
            arguments: configuration.managedRuntime.map { $0.arguments + configuration.arguments } ?? configuration.arguments,
            environment: configuration.managedRuntime.map {
                $0.environment.merging(configuration.environment) { _, configured in configured }
            } ?? configuration.environment,
            workingDirectoryPath: workingDirectory?.path,
            runtimeBookmarkData: runtimeBookmarkData,
            prompt: prompt,
            mcpURL: mcpURL,
            bearerToken: bearerToken,
            toolNames: safeToolNames.sorted(),
            mode: mode
        )
    }

    private static func error(for failure: ACPExternalRuntimeFailure) -> ACPExternalRuntimeError {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .failedToStart: .agent(.failedToStart)
        case .outputTooLarge: .agent(.outputTooLarge)
        case .frameTooLarge: .agent(.frameTooLarge)
        case .invalidResponse: .agent(.invalidResponse)
        case .unsupportedProtocol: .agent(.unsupportedProtocol(nil))
        case .unsupportedHTTPTransport: .agent(.unsupportedHTTPTransport)
        case .remoteFailure: .agent(.remoteFailure)
        case .processFailed: .agent(.processFailed(exitCode: -1))
        case .emptyResponse: .agent(.emptyResponse)
        case .agentFailed: .agentFailed
        }
    }
}

private final class ACPExternalRuntimeCall: @unchecked Sendable {
    private static let maximumResponseBytes = 1_200_000
    private let connection: NSXPCConnection
    private let requestID: UUID
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ACPExternalRuntimeResponse, Error>?
    private var isFinished = false

    init(serviceName: String, requestID: UUID, timeout: TimeInterval) {
        // This is an embedded XPC service. `machServiceName` addresses a
        // launchd-global service and would bypass the host bundle lookup.
        connection = NSXPCConnection(serviceName: serviceName)
        self.requestID = requestID
        self.timeout = timeout
        connection.remoteObjectInterface = NSXPCInterface(with: ACPExternalRuntimeXPCService.self)
        connection.interruptionHandler = { [weak self] in self?.finish(.failure(ACPExternalRuntimeError.unavailable)) }
        connection.invalidationHandler = { [weak self] in self?.finish(.failure(ACPExternalRuntimeError.unavailable)) }
    }

    func perform(_ request: ACPExternalRuntimeRequest) async throws -> ACPExternalRuntimeResponse {
        let data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            throw ACPExternalRuntimeError.invalidRequest
        }
        return try await withCheckedThrowingContinuation { continuation in
            let started = lock.withLock { () -> Bool in
                guard !isFinished else { return false }
                self.continuation = continuation
                return true
            }
            guard started else {
                continuation.resume(throwing: ACPExternalRuntimeError.cancelled)
                return
            }

            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.finish(.failure(ACPExternalRuntimeError.unavailable))
            } as? ACPExternalRuntimeXPCService
            guard let proxy else {
                finish(.failure(ACPExternalRuntimeError.unavailable))
                return
            }
            proxy.execute(data) { [weak self] responseData, error in
                guard let self else { return }
                guard error == nil, let responseData,
                      responseData.count <= Self.maximumResponseBytes
                else {
                    self.finish(.failure(ACPExternalRuntimeError.unavailable))
                    return
                }
                do {
                    let response = try JSONDecoder().decode(ACPExternalRuntimeResponse.self, from: responseData)
                    guard response.requestID == self.requestID else {
                        self.finish(.failure(ACPExternalRuntimeError.invalidResponse))
                        return
                    }
                    self.finish(.success(response))
                } catch {
                    self.finish(.failure(ACPExternalRuntimeError.invalidResponse))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(ACPExternalRuntimeError.timedOut))
            }
        }
    }

    func cancel() {
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? ACPExternalRuntimeXPCService
        proxy?.cancel(requestID.uuidString) {}
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<ACPExternalRuntimeResponse, Error>) {
        let continuation: CheckedContinuation<ACPExternalRuntimeResponse, Error>? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            let saved = continuation
            continuation = nil
            return saved
        }
        connection.invalidate()
        continuation?.resume(with: result)
    }
}
