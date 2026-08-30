import Foundation

/// Resultado de uma verificação de sessão que não expõe token, endereço da
/// conta, saída do processo ou detalhes de autenticação de terceiros.
public enum AssistantCLIAuthenticationState: String, Sendable, Hashable {
    case authenticated
    case unauthenticated
    case unavailable
    case unknown
}

public struct AssistantCLIAuthenticationStatus: Sendable, Hashable, Identifiable {
    public var id: AssistantCLIKind { kind }
    public let kind: AssistantCLIKind
    public let state: AssistantCLIAuthenticationState

    public init(kind: AssistantCLIKind, state: AssistantCLIAuthenticationState) {
        self.kind = kind
        self.state = state
    }
}

/// Consulta somente os comandos de estado documentados de cada CLI. Ela não
/// abre login, não executa modelo, não lê arquivos de sessão e não aceita
/// comandos, argumentos ou caminhos vindos da configuração persistida.
public struct AssistantCLIAuthenticationProbe: Sendable {
    public static let maximumStatusOutputBytes = 48 * 1_024

    private let executor: any AssistantCLIProcessExecuting
    private let requestTimeout: TimeInterval

    public init(
        executor: any AssistantCLIProcessExecuting = SystemAssistantCLIProcessExecutor(),
        requestTimeout: TimeInterval = 4
    ) {
        self.executor = executor
        self.requestTimeout = min(max(requestTimeout, 1), 10)
    }

    public func status(
        for installation: AssistantCLIInstallation,
        environment: [String: String] = [:]
    ) async -> AssistantCLIAuthenticationStatus {
        guard let request = AssistantCLIProcessRequest.authenticationStatusRequest(
            kind: installation.kind,
            installation: installation,
            timeout: requestTimeout,
            environment: environment
        ) else {
            return .init(kind: installation.kind, state: .unavailable)
        }

        do {
            let result = try await executor.execute(request)
            guard result.standardOutput.count <= Self.maximumStatusOutputBytes else {
                return .init(kind: installation.kind, state: .unknown)
            }
            return .init(
                kind: installation.kind,
                state: AssistantCLIAuthenticationStatusParser.state(
                    for: installation.kind,
                    result: result
                )
            )
        } catch {
            // Em especial, um app sandboxed pode localizar o binário e ainda
            // assim não permitir que ele acesse a própria sessão. Isso não é
            // evidência de logout, portanto permanece explicitamente unknown.
            return .init(kind: installation.kind, state: .unknown)
        }
    }

    /// Os probes independentes rodam em paralelo: uma sessão bloqueada não
    /// atrasa a visualização das outras ferramentas na tela de configurações.
    public func statuses(
        for installations: [AssistantCLIInstallation]
    ) async -> [AssistantCLIAuthenticationStatus] {
        let resolved = await withTaskGroup(
            of: AssistantCLIAuthenticationStatus.self,
            returning: [AssistantCLIAuthenticationStatus].self
        ) { group in
            for installation in installations {
                group.addTask {
                    await status(for: installation)
                }
            }

            var values: [AssistantCLIKind: AssistantCLIAuthenticationStatus] = [:]
            for await status in group {
                values[status.kind] = status
            }
            return installations.map {
                values[$0.kind] ?? .init(kind: $0.kind, state: .unknown)
            }
        }
        return resolved
    }
}

/// Parsers deliberadamente estreitos: uma saída desconhecida nunca é
/// promovida a "autenticado". O texto analisado fica apenas em memória e não
/// é incluído em logs, erros ou interface.
enum AssistantCLIAuthenticationStatusParser {
    static func state(
        for kind: AssistantCLIKind,
        result: AssistantCLIProcessResult
    ) -> AssistantCLIAuthenticationState {
        switch kind {
        case .codex:
            return textualState(
                output: result.standardOutput,
                exitStatus: result.exitStatus,
                authenticatedSignals: ["logged in", "authenticated", "using chatgpt"],
                unauthenticatedSignals: ["not logged in", "not authenticated", "no active login"]
            )
        case .claude:
            if let loggedIn = claudeLoggedIn(in: result.standardOutput) {
                return loggedIn ? .authenticated : .unauthenticated
            }
            return textualState(
                output: result.standardOutput,
                exitStatus: result.exitStatus,
                authenticatedSignals: ["logged in", "authenticated"],
                unauthenticatedSignals: ["not logged in", "not authenticated"]
            )
        case .openCode:
            if let connected = explicitConnectionState(in: result.standardOutput) {
                return connected ? .authenticated : .unauthenticated
            }
            return textualState(
                output: result.standardOutput,
                exitStatus: result.exitStatus,
                authenticatedSignals: ["logged in", "authenticated", "connected"],
                unauthenticatedSignals: [
                    "not logged in", "not authenticated", "not connected",
                    "no authentication", "no authenticated providers",
                ]
            )
        }
    }

    private static func claudeLoggedIn(in data: Data) -> Bool? {
        guard let object = jsonObject(in: data) else { return nil }
        return boolean(
            named: ["loggedIn", "logged_in", "isLoggedIn"],
            in: object
        )
    }

    /// OpenCode pode evoluir a saída de `auth list`; só acreditamos em um
    /// booleano explicitamente semântico, nunca em uma simples lista de
    /// providers, que pode existir antes de uma sessão real.
    private static func explicitConnectionState(in data: Data) -> Bool? {
        guard let object = jsonValue(in: data) else { return nil }
        return boolean(
            named: ["authenticated", "isAuthenticated", "loggedIn", "connected"],
            in: object
        )
    }

    private static func jsonObject(in data: Data) -> [String: Any]? {
        jsonValue(in: data) as? [String: Any]
    }

    private static func jsonValue(in data: Data) -> Any? {
        guard data.count <= AssistantCLIAuthenticationProbe.maximumStatusOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object
    }

    private static func boolean(named names: [String], in object: Any) -> Bool? {
        var values: [Bool] = []
        collectBooleans(named: names, in: object, values: &values)
        if values.contains(true) { return true }
        return values.first
    }

    private static func collectBooleans(
        named names: [String],
        in object: Any,
        values: inout [Bool]
    ) {
        if let dictionary = object as? [String: Any] {
            for name in names {
                if let value = dictionary[name] as? Bool {
                    values.append(value)
                }
            }
            for value in dictionary.values {
                collectBooleans(named: names, in: value, values: &values)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectBooleans(named: names, in: value, values: &values)
            }
        }
    }

    private static func textualState(
        output: Data,
        exitStatus: Int32,
        authenticatedSignals: [String],
        unauthenticatedSignals: [String]
    ) -> AssistantCLIAuthenticationState {
        guard output.count <= AssistantCLIAuthenticationProbe.maximumStatusOutputBytes,
              let text = String(data: output, encoding: .utf8)
        else { return .unknown }
        let normalized = text.lowercased()

        // O teste negativo vem antes porque "not authenticated" contém a
        // palavra authenticated.
        if unauthenticatedSignals.contains(where: normalized.contains) {
            return .unauthenticated
        }
        if exitStatus == 0,
           authenticatedSignals.contains(where: normalized.contains) {
            return .authenticated
        }
        return .unknown
    }
}
