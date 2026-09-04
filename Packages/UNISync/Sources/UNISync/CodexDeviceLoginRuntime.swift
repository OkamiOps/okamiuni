import UNICore
@preconcurrency import Foundation

/// Identifica um login iniciado pelo app-server oficial. `loginID` é opaco e
/// só serve para correlacionar a notificação de conclusão; nunca é serializado
/// nem mostrado à pessoa.
public struct CodexDeviceLogin: Sendable, Hashable {
    public let loginID: String
    public let verificationURL: URL
    public let userCode: String

    public init(loginID: String, verificationURL: URL, userCode: String) {
        self.loginID = loginID
        self.verificationURL = verificationURL
        self.userCode = userCode
    }
}

public enum CodexDeviceLoginRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case codexUnavailable
    case storageUnavailable
    case protocolUnavailable
    case invalidDeviceAuthorization
    case loginFailed
    case notAuthenticated
    case invalidModelCatalog

    public var errorDescription: String? {
        switch self {
        case .codexUnavailable:
            L10n.tr("O Codex não foi encontrado neste Mac. Instale ou atualize o Codex para entrar com ChatGPT.")
        case .storageUnavailable:
            L10n.tr("O OkamiUNI não conseguiu preparar o espaço privado do Codex neste Mac. Verifique o acesso ao armazenamento do app e tente novamente.")
        case .protocolUnavailable:
            L10n.tr("O runtime do Codex não respondeu ao login seguro. Atualize o Codex e tente novamente.")
        case .invalidDeviceAuthorization:
            L10n.tr("O Codex devolveu um código de dispositivo inválido. Gere um novo código.")
        case .loginFailed:
            L10n.tr("O login com ChatGPT não foi concluído. Tente novamente pelo código de dispositivo.")
        case .notAuthenticated:
            L10n.tr("A sessão ChatGPT deste OkamiUNI não está disponível. Conecte novamente para carregar os modelos.")
        case .invalidModelCatalog:
            L10n.tr("O Codex devolveu um catálogo de modelos inválido.")
        }
    }
}

/// A fronteira permite testar o fluxo sem iniciar processos e mantém o estado
/// ChatGPT dentro do runtime Codex. Não existe método para extrair token.
public protocol CodexDeviceLoginRuntime: Sendable {
    func startDeviceLogin() async throws -> CodexDeviceLogin
    func waitForDeviceLogin(loginID: String) async throws
    func cancelDeviceLogin() async
    func isSignedIn() async -> Bool
    func availableModels() async throws -> [AssistantProviderModel]
    func signOut() async throws
}

/// Ponte estrita para o protocolo do app-server instalado. A chamada
/// `account/login/start` com `chatgptDeviceCode`, `account/login/completed` e
/// `account/read` seguida de `model/list` é descrita pelo schema publicado pelo próprio binário. O
/// processo é aberto sem shell, stderr é descartado e stdout só é interpretado
/// como JSON-RPC; nenhuma linha é registrada ou reaproveitada como texto UI.
public actor SystemCodexDeviceLoginRuntime: CodexDeviceLoginRuntime {
    private let installations: @Sendable () -> [AssistantCLIInstallation]
    private let executor: any AssistantCLIProcessExecuting
    private var activeConnection: CodexAppServerConnection?

    public init(
        installations: @escaping @Sendable () -> [AssistantCLIInstallation] = { AssistantCLIDiscovery().scan() },
        executor: any AssistantCLIProcessExecuting = SystemAssistantCLIProcessExecutor()
    ) {
        self.installations = installations
        self.executor = executor
    }

    public func startDeviceLogin() async throws -> CodexDeviceLogin {
        await cancelDeviceLogin()
        let installation = try codexInstallation()
        let environment = try CodexManagedRuntimeEnvironment.environment()
        let connection = try await CodexAppServerConnection.connect(
            executableURL: executableURL(for: installation),
            environment: environment
        )
        do {
            let result = try await connection.request(
                method: "account/login/start",
                params: Data(#"{"type":"chatgptDeviceCode"}"#.utf8),
                timeout: 15
            )
            guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
                  object["type"] as? String == "chatgptDeviceCode",
                  let loginID = normalized(object["loginId"] as? String, maximum: 512),
                  let rawURL = normalized(object["verificationUrl"] as? String, maximum: 4_096),
                  let verificationURL = Self.safeVerificationURL(rawURL),
                  let userCode = normalized(object["userCode"] as? String, maximum: 256)
            else {
                await connection.close()
                throw CodexDeviceLoginRuntimeError.invalidDeviceAuthorization
            }
            activeConnection = connection
            return .init(loginID: loginID, verificationURL: verificationURL, userCode: userCode)
        } catch {
            await connection.close()
            throw error
        }
    }

    public func waitForDeviceLogin(loginID: String) async throws {
        guard let connection = activeConnection else { throw CodexDeviceLoginRuntimeError.loginFailed }
        defer { activeConnection = nil }
        do {
            try await connection.waitForLoginCompletion(loginID: loginID)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    public func cancelDeviceLogin() async {
        let connection = activeConnection
        activeConnection = nil
        await connection?.close()
    }

    public func isSignedIn() async -> Bool {
        guard let installation = try? codexInstallation(),
              let environment = try? CodexManagedRuntimeEnvironment.environment()
        else { return false }
        let connection: CodexAppServerConnection
        do {
            connection = try await CodexAppServerConnection.connect(
                executableURL: executableURL(for: installation),
                environment: environment
            )
        } catch {
            return false
        }
        do {
            let result = try await connection.request(
                method: "account/read",
                params: Data(#"{"refreshToken":false}"#.utf8),
                timeout: 15
            )
            await connection.close()
            return CodexAccountReadParser.isChatGPTSignedIn(result)
        } catch {
            await connection.close()
            return false
        }
    }

    public func availableModels() async throws -> [AssistantProviderModel] {
        let installation = try codexInstallation()
        let environment = try CodexManagedRuntimeEnvironment.environment()
        let connection = try await CodexAppServerConnection.connect(
            executableURL: executableURL(for: installation),
            environment: environment
        )
        let result: Data
        do {
            let account = try await connection.request(
                method: "account/read",
                params: Data(#"{"refreshToken":false}"#.utf8),
                timeout: 15
            )
            guard CodexAccountReadParser.isChatGPTSignedIn(account) else {
                throw CodexDeviceLoginRuntimeError.notAuthenticated
            }
            result = try await connection.request(
                method: "model/list",
                params: Data(#"{"includeHidden":false,"limit":100}"#.utf8),
                timeout: 15
            )
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
        guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              let data = object["data"] as? [Any]
        else {
            throw CodexDeviceLoginRuntimeError.invalidModelCatalog
        }
        var seen = Set<String>()
        let models = data.prefix(512).compactMap { raw -> AssistantProviderModel? in
            guard let item = raw as? [String: Any],
                  item["hidden"] as? Bool != true,
                  let id = normalized((item["model"] as? String) ?? (item["id"] as? String), maximum: 256),
                  seen.insert(id).inserted
            else { return nil }
            return .init(id: id, displayName: normalized(item["displayName"] as? String, maximum: 512))
        }
        guard !models.isEmpty else { throw CodexDeviceLoginRuntimeError.invalidModelCatalog }
        return models
    }

    public func signOut() async throws {
        await cancelDeviceLogin()
        let installation = try codexInstallation()
        let request = try Self.logoutRequest(
            for: installation,
            environment: CodexManagedRuntimeEnvironment.environment()
        )
        let result = try await executor.execute(request)
        guard result.exitStatus == 0 else { throw CodexDeviceLoginRuntimeError.loginFailed }
    }

    private func codexInstallation() throws -> AssistantCLIInstallation {
        guard let installation = installations().first(where: { $0.kind == .codex && $0.isDetected }) else {
            throw CodexDeviceLoginRuntimeError.codexUnavailable
        }
        return installation
    }

    private func executableURL(for installation: AssistantCLIInstallation) -> URL {
        // `codexInstallation` deriva exclusivamente de AssistantCLIDiscovery;
        // `logoutRequest` e CodexAppServerConnection repetem a allowlist antes
        // de executar, para que uma preferência nunca consiga trocar binário.
        URL(fileURLWithPath: installation.executablePath!).standardizedFileURL
    }

    private static func logoutRequest(
        for installation: AssistantCLIInstallation,
        environment: [String: String]
    ) throws -> AssistantCLIProcessRequest {
        guard installation.kind == .codex, let path = installation.executablePath else {
            throw CodexDeviceLoginRuntimeError.codexUnavailable
        }
        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        guard (path as NSString).isAbsolutePath, executableURL.lastPathComponent == "codex" else {
            throw CodexDeviceLoginRuntimeError.codexUnavailable
        }
        return .init(
            executableURL: executableURL,
            arguments: ["logout"],
            standardInput: Data(),
            timeout: 10,
            maximumOutputBytes: 48 * 1_024,
            environment: environment
        )
    }

    private static func safeVerificationURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { return nil }
        return components.url
    }
}

/// Interpreta somente o discriminador público de `account/read`. O runtime
/// também pode devolver e-mail e tipo de plano, mas o OkamiUNI não precisa
/// desses dados para decidir se a assinatura ChatGPT está disponível e não os
/// propaga para logs, preferências ou interface.
enum CodexAccountReadParser {
    static func isChatGPTSignedIn(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["account"] as? [String: Any]
        else { return false }
        return account["type"] as? String == "chatgpt"
    }
}

/// O Codex oficial reconhece `CODEX_HOME`. Ao apontá-lo para Application
/// Support, app-server, `login status`, catálogo, logout e `codex exec`
/// compartilham a mesma sessão sem o OkamiUNI ler arquivos de autenticação.
/// Em um app sandboxed, esse diretório pertence ao container do próprio app;
/// se não for possível criá-lo, o login falha em vez de tentar `~/.codex`.
enum CodexManagedRuntimeEnvironment {
    private static let variable = "CODEX_HOME"

    static func environment(
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        fileManager: FileManager = .default
    ) throws -> [String: String] {
        guard let applicationSupportDirectory else {
            throw CodexDeviceLoginRuntimeError.storageUnavailable
        }
        let directory = applicationSupportDirectory
            .appendingPathComponent("OkamiUNI", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw CodexDeviceLoginRuntimeError.storageUnavailable
        }
        return [variable: directory.path]
    }
}

private func normalized(_ value: String?, maximum: Int) -> String? {
    guard let rawValue = value else { return nil }
    let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasForbiddenControl = normalizedValue.unicodeScalars.contains { scalar in
        scalar.value == 0 || scalar.value == 10 || scalar.value == 13
    }
    guard !normalizedValue.isEmpty, normalizedValue.count <= maximum, !hasForbiddenControl
    else { return nil }
    return normalizedValue
}

/// O schema atual permite `loginId: null` na notificação. Como cada conexão
/// criada pelo app mantém no máximo um login, a ausência do id ainda conclui a
/// conexão dedicada; um id presente continua sendo correlacionado.
struct CodexDeviceLoginCompletion: Sendable, Equatable {
    let loginID: String?
    let success: Bool

    func matches(_ requestedLoginID: String) -> Bool {
        loginID == nil || loginID == requestedLoginID
    }
}

/// Conexão de vida curta para `codex app-server --stdio`. Ela é um actor para
/// serializar pipe, continuations e encerramento do processo.
private actor CodexAppServerConnection {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let workDirectory: URL
    private var reader: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextID = 1
    private var loginCompletion: CodexDeviceLoginCompletion?
    private var loginWaiter: CheckedContinuation<Void, Error>?
    private var waitingLoginID: String?
    private var isClosed = false

    static func connect(
        executableURL: URL,
        environment: [String: String]
    ) async throws -> CodexAppServerConnection {
        guard executableURL.isFileURL, executableURL.lastPathComponent == "codex" else {
            throw CodexDeviceLoginRuntimeError.codexUnavailable
        }
        let connection = try CodexAppServerConnection(
            executableURL: executableURL,
            environment: environment
        )
        await connection.startReader()
        do {
            _ = try await connection.request(
                method: "initialize",
                params: Data(#"{"clientInfo":{"name":"OkamiUNI","version":"1.0"},"capabilities":{}}"#.utf8),
                timeout: 10
            )
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }

    private init(executableURL: URL, environment: [String: String]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("okamiuni-codex-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        workDirectory = directory
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, managed in managed }
        process.currentDirectoryURL = directory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw CodexDeviceLoginRuntimeError.protocolUnavailable
        }
    }

    private func startReader() {
        reader = Task { [weak self, output] in
            do {
                for try await line in output.bytes.lines {
                    guard line.utf8.count <= 65_536 else { continue }
                    await self?.receive(line: String(line))
                }
                await self?.finish(with: CodexDeviceLoginRuntimeError.protocolUnavailable)
            } catch {
                await self?.finish(with: CodexDeviceLoginRuntimeError.protocolUnavailable)
            }
        }
    }

    func request(method: String, params: Data, timeout: TimeInterval) async throws -> Data {
        guard !isClosed else { throw CodexDeviceLoginRuntimeError.protocolUnavailable }
        let id = nextID
        nextID += 1
        guard let rawParams = try? JSONSerialization.jsonObject(with: params), rawParams is [String: Any] else {
            throw CodexDeviceLoginRuntimeError.protocolUnavailable
        }
        let payload: [String: Any] = ["id": id, "method": method, "params": rawParams]
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload),
              encoded.count <= 65_536
        else { throw CodexDeviceLoginRuntimeError.protocolUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(min(max(timeout, 1), 30)))
                guard !Task.isCancelled else { return }
                await self?.timeout(id: id)
            }
            timeouts[id] = timeoutTask
            do {
                try input.write(contentsOf: encoded + Data("\n".utf8))
            } catch {
                timeoutTask.cancel()
                timeouts[id] = nil
                pending[id] = nil
                continuation.resume(throwing: CodexDeviceLoginRuntimeError.protocolUnavailable)
            }
        }
    }

    func waitForLoginCompletion(loginID: String) async throws {
        guard !isClosed else { throw CodexDeviceLoginRuntimeError.protocolUnavailable }
        if let completed = loginCompletion, completed.matches(loginID) {
            guard completed.success else { throw CodexDeviceLoginRuntimeError.loginFailed }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            loginWaiter = continuation
            waitingLoginID = loginID
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        reader?.cancel()
        reader = nil
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for continuation in pending.values { continuation.resume(throwing: CodexDeviceLoginRuntimeError.protocolUnavailable) }
        pending.removeAll()
        loginWaiter?.resume(throwing: CancellationError())
        loginWaiter = nil
        waitingLoginID = nil
        try? input.close()
        try? output.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func receive(line: String) {
        guard !isClosed, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if object["method"] as? String == "account/login/completed",
           let params = object["params"] as? [String: Any],
           let success = params["success"] as? Bool {
            let completion = CodexDeviceLoginCompletion(loginID: params["loginId"] as? String, success: success)
            loginCompletion = completion
            if let waiter = loginWaiter,
               let waitingLoginID,
               completion.matches(waitingLoginID) {
                loginWaiter = nil
                self.waitingLoginID = nil
                success ? waiter.resume() : waiter.resume(throwing: CodexDeviceLoginRuntimeError.loginFailed)
            }
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue ?? object["id"] as? Int,
              let continuation = pending.removeValue(forKey: id)
        else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        if let result = object["result"], JSONSerialization.isValidJSONObject(result),
           let encoded = try? JSONSerialization.data(withJSONObject: result), encoded.count <= 1_048_576 {
            continuation.resume(returning: encoded)
        } else {
            continuation.resume(throwing: CodexDeviceLoginRuntimeError.protocolUnavailable)
        }
    }

    private func timeout(id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeouts[id] = nil
        continuation.resume(throwing: CodexDeviceLoginRuntimeError.protocolUnavailable)
    }

    private func finish(with error: Error) {
        guard !isClosed else { return }
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        loginWaiter?.resume(throwing: error)
        loginWaiter = nil
        waitingLoginID = nil
    }
}
