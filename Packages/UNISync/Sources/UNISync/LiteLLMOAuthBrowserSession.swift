import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

public protocol LiteLLMOAuthBrowserSession: Sendable {
    var redirectURI: URL { get }
    func authorize(at url: URL) async throws -> URL
}

public protocol LiteLLMOAuthBrowserSessionMaking: Sendable {
    func makeSession() async throws -> any LiteLLMOAuthBrowserSession
}

public protocol LiteLLMSystemBrowserOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

public struct AppKitLiteLLMSystemBrowserOpener: LiteLLMSystemBrowserOpening, Sendable {
    public init() {}

    public func open(_ url: URL) async -> Bool {
        #if canImport(AppKit)
        return await MainActor.run { NSWorkspace.shared.open(url) }
        #else
        return false
        #endif
    }
}

public struct SystemLiteLLMOAuthBrowserSessionFactory:
    LiteLLMOAuthBrowserSessionMaking, Sendable {

    private let opener: any LiteLLMSystemBrowserOpening
    private let timeout: TimeInterval

    public init(
        opener: any LiteLLMSystemBrowserOpening = AppKitLiteLLMSystemBrowserOpener(),
        timeout: TimeInterval = 300
    ) {
        self.opener = opener
        self.timeout = max(30, timeout)
    }

    public func makeSession() async throws -> any LiteLLMOAuthBrowserSession {
        try await NetworkLiteLLMOAuthBrowserSession.start(opener: opener, timeout: timeout)
    }
}

/// Receptor HTTP restrito a `127.0.0.1` e a uma porta efêmera escolhida pelo
/// sistema. O navegador recebe uma página estática sem parâmetros da URL; o
/// código OAuth só segue em memória para o cliente PKCE.
private final class NetworkLiteLLMOAuthBrowserSession:
    LiteLLMOAuthBrowserSession, @unchecked Sendable {

    private static let maximumRequestBytes = 16_384

    let redirectURI: URL

    private let listenerDescriptor: Int32
    private let acceptSource: DispatchSourceRead
    private let queue: DispatchQueue
    private let opener: any LiteLLMSystemBrowserOpening
    private let timeout: TimeInterval
    private var callbackContinuation: CheckedContinuation<URL, any Error>?
    private var pendingResult: Result<URL, any Error>?
    private var completed = false
    private var connections: [Int32: POSIXLoopbackConnection] = [:]

    private init(
        listenerDescriptor: Int32,
        redirectURI: URL,
        queue: DispatchQueue,
        opener: any LiteLLMSystemBrowserOpening,
        timeout: TimeInterval
    ) {
        self.listenerDescriptor = listenerDescriptor
        self.redirectURI = redirectURI
        self.queue = queue
        self.opener = opener
        self.timeout = timeout

        let source = DispatchSource.makeReadSource(
            fileDescriptor: listenerDescriptor,
            queue: queue
        )
        self.acceptSource = source
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler {
            Darwin.close(listenerDescriptor)
        }
        source.resume()
    }

    static func start(
        opener: any LiteLLMSystemBrowserOpening,
        timeout: TimeInterval
    ) async throws -> NetworkLiteLLMOAuthBrowserSession {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw LiteLLMOAuthError.callbackUnavailable
        }
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor {
                Darwin.close(descriptor)
            }
        }

        guard setNonBlocking(descriptor) else {
            throw LiteLLMOAuthError.callbackUnavailable
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            throw LiteLLMOAuthError.callbackUnavailable
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &boundAddressLength)
            }
        }
        let port = UInt16(bigEndian: boundAddress.sin_port)
        guard nameResult == 0,
              boundAddress.sin_addr.s_addr == address.sin_addr.s_addr,
              port != 0,
              let redirectURI = URL(string: "http://127.0.0.1:\(port)/callback")
        else {
            throw LiteLLMOAuthError.callbackUnavailable
        }

        let queue = DispatchQueue(label: "com.okamiops.okamiuni.litellm-oauth-loopback")
        let session = NetworkLiteLLMOAuthBrowserSession(
            listenerDescriptor: descriptor,
            redirectURI: redirectURI,
            queue: queue,
            opener: opener,
            timeout: timeout
        )
        shouldCloseDescriptor = false
        return session
    }

    func authorize(at url: URL) async throws -> URL {
        let waiting = Task { try await waitForCallback() }
        guard await opener.open(url) else {
            waiting.cancel()
            finish(.failure(LiteLLMOAuthError.browserUnavailable))
            throw LiteLLMOAuthError.browserUnavailable
        }
        return try await waiting.value
    }

    private func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: LiteLLMOAuthError.callbackUnavailable)
                        return
                    }
                    if let pendingResult {
                        self.pendingResult = nil
                        continuation.resume(with: pendingResult)
                        return
                    }
                    self.callbackContinuation = continuation
                    self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                        self?.finishOnQueue(.failure(LiteLLMOAuthError.timedOut))
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func acceptPendingConnections() {
        guard !completed else { return }
        while true {
            let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
            if descriptor < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                finishOnQueue(.failure(LiteLLMOAuthError.callbackUnavailable))
                return
            }
            guard !completed else {
                Darwin.close(descriptor)
                return
            }
            guard Self.suppressSIGPIPE(on: descriptor) else {
                Darwin.close(descriptor)
                finishOnQueue(.failure(LiteLLMOAuthError.callbackUnavailable))
                return
            }
            let connection = POSIXLoopbackConnection(
                descriptor: descriptor,
                queue: queue,
                session: self
            )
            connections[descriptor] = connection
            connection.start()
        }
    }

    fileprivate func receive(_ request: Data, from connection: POSIXLoopbackConnection) {
        guard !completed else { return }
        guard request.count <= Self.maximumRequestBytes else {
            respond(to: connection, status: "413 Payload Too Large", success: false)
            close(connection)
            return
        }
        guard request.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        handle(request: request, connection: connection)
    }

    fileprivate func connectionClosed(_ connection: POSIXLoopbackConnection) {
        guard !completed else { return }
        close(connection)
    }

    private func handle(request: Data, connection: POSIXLoopbackConnection) {
        guard let header = String(data: request, encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first
        else {
            respond(to: connection, status: "400 Bad Request", success: false)
            close(connection)
            return
        }
        let fields = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3,
              fields[0] == "GET",
              fields[2] == "HTTP/1.0" || fields[2] == "HTTP/1.1",
              fields[1].hasPrefix("/"),
              !fields[1].hasPrefix("//"),
              let callback = URL(string: String(fields[1]), relativeTo: redirectURI)?.absoluteURL,
              callback.scheme == "http",
              callback.host == "127.0.0.1",
              callback.port == redirectURI.port,
              callback.path == "/callback"
        else {
            respond(to: connection, status: "400 Bad Request", success: false)
            close(connection)
            return
        }
        respond(to: connection, status: "200 OK", success: true)
        finishOnQueue(.success(callback))
    }

    private func close(_ connection: POSIXLoopbackConnection) {
        connections[connection.descriptor] = nil
        connection.cancel()
    }

    private func respond(to connection: POSIXLoopbackConnection, status: String, success: Bool) {
        let message = success
            ? "Login concluído. Você pode fechar esta janela e voltar ao OkamiUNI."
            : "O retorno do login não pôde ser validado. Volte ao OkamiUNI e tente novamente."
        let body = """
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>OkamiUNI</title></head><body><main><h1>OkamiUNI</h1><p>\(message)</p></main></body></html>
        """
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Cache-Control: no-store\r
        Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        let data = Data(response.utf8)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(
                    connection.descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        queue.async { [weak self] in self?.finishOnQueue(result) }
    }

    private func finishOnQueue(_ result: Result<URL, any Error>) {
        guard !completed else { return }
        completed = true
        acceptSource.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }
}

private extension NetworkLiteLLMOAuthBrowserSession {
    static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return false }
        return Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func suppressSIGPIPE(on descriptor: Int32) -> Bool {
        var value: Int32 = 1
        return withUnsafePointer(to: &value) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        }
    }
}

/// Cada conexão tem seu próprio descritor e fonte de leitura, mas todo estado
/// do receptor é serializado pela fila privada da sessão.
private final class POSIXLoopbackConnection: @unchecked Sendable {
    let descriptor: Int32

    private weak var session: NetworkLiteLLMOAuthBrowserSession?
    private let readSource: DispatchSourceRead
    private var request = Data()

    init(
        descriptor: Int32,
        queue: DispatchQueue,
        session: NetworkLiteLLMOAuthBrowserSession
    ) {
        self.descriptor = descriptor
        self.session = session
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        self.readSource = source
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
    }

    func start() {
        readSource.resume()
    }

    func cancel() {
        readSource.cancel()
    }

    private func readAvailableBytes() {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            request.append(contentsOf: buffer.prefix(Int(count)))
            session?.receive(request, from: self)
        } else if count == 0 {
            session?.connectionClosed(self)
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            session?.connectionClosed(self)
        }
    }
}
