import Foundation

/// CLIs que podem representar uma sessão de IA já configurada pela pessoa.
///
/// O OkamiUNI só procura o executável. Ele não lê arquivos de autenticação,
/// Keychains de terceiros, variáveis secretas nem tenta inferir se a sessão
/// está autenticada. Em um app sandboxed, encontrar o binário também não
/// garante que um processo filho consiga usar a configuração dele.
public enum AssistantCLIKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case openCode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .openCode: "OpenCode"
        }
    }

    /// Rótulo da escolha em Configurações: deixa explícito qual assinatura
    /// OAuth/device cada transporte consegue reutilizar sem sugerir API key.
    public var authenticationDisplayName: String {
        switch self {
        case .claude: "Claude Code · Claude.ai OAuth"
        case .codex: "Codex CLI · ChatGPT OAuth/device"
        case .openCode: "OpenCode · OpenAI ou Grok OAuth/device"
        }
    }

    /// Nomes aceitos pelo transporte. A descoberta e a execução usam a mesma
    /// allowlist para que uma configuração persistida nunca possa trocar o
    /// processo filho por um binário arbitrário.
    var executableNames: [String] {
        switch self {
        case .claude: ["claude"]
        case .codex: ["codex"]
        case .openCode: ["opencode", "opencode2"]
        }
    }
}

public struct AssistantCLIInstallation: Sendable, Hashable, Identifiable {
    public var id: AssistantCLIKind { kind }
    public let kind: AssistantCLIKind
    public let executablePath: String?

    public init(kind: AssistantCLIKind, executablePath: String?) {
        self.kind = kind
        self.executablePath = executablePath
    }

    public var isDetected: Bool { executablePath != nil }
}

/// Descoberta por allowlist, sem shell e sem executar o programa encontrado.
public struct AssistantCLIDiscovery: Sendable {
    private let searchDirectories: [String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        bundleResourceDirectory: String? = Bundle.main.resourceURL?.path,
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let bundledDirectories = [bundleResourceDirectory].compactMap { $0 }
        let commonDirectories = bundledDirectories + [
            // Se o OkamiUNI vier com um runtime Codex oficial, ele é a fonte
            // mais previsível para um app GUI sandboxed.
            // Runtime oficial distribuído pelo app ChatGPT; não depende de
            // shell, NVM ou PATH herdado pelo processo GUI.
            "/Applications/ChatGPT.app/Contents/Resources",
            "/Applications/Codex.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.volta/bin",
        ]
        var seen = Set<String>()
        self.searchDirectories = (commonDirectories + pathDirectories).compactMap { directory in
            let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path
            return seen.insert(normalized).inserted ? normalized : nil
        }
        self.isExecutable = isExecutable
    }

    public func scan() -> [AssistantCLIInstallation] {
        AssistantCLIKind.allCases.map { kind in
            let match = searchDirectories.lazy.flatMap { directory in
                kind.executableNames.lazy.map { name in
                    URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(name, isDirectory: false)
                        .path
                }
            }.first(where: isExecutable)
            return AssistantCLIInstallation(kind: kind, executablePath: match)
        }
    }
}
