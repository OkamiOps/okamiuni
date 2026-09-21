import Foundation
import UNICore

/// A location outside the App Sandbox that the person selected expressly for
/// provider-owned ACP state. The bookmark is deliberately scoped to one file or
/// directory; it is never a bookmark for the user's home directory.
public struct AgentRuntimeAuthorization: Codable, Sendable, Hashable {
    /// Security-scoped bookmark data returned by `NSOpenPanel` selection.
    /// It stays in the app's preferences container and is never logged.
    public let bookmarkData: Data
    /// A display-only path. Runtime authorization is always based on
    /// `bookmarkData`, never this value.
    public let displayPath: String

    public init(bookmarkData: Data, displayPath: String) throws {
        guard !bookmarkData.isEmpty, bookmarkData.count <= 1_048_576,
              Self.isSafeDisplayPath(displayPath)
        else { throw AgentRuntimeAuthorizationError.invalidBookmark }
        self.bookmarkData = bookmarkData
        self.displayPath = displayPath
    }

    /// Creates the persistent authorization immediately after a user selected
    /// file or directory in an `NSOpenPanel`.
    public static func make(url: URL) throws -> Self {
        let url = url.standardizedFileURL
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else { throw AgentRuntimeAuthorizationError.invalidBookmark }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // A provider may need a small child of the home directory (for example
        // `.nvm` or `.codex`), but never the complete home directory or one
        // of its ancestors. That would silently turn a per-runtime grant into
        // broad personal-file access.
        guard canonical.path != "/",
              canonical.path != home.path,
              !home.path.hasPrefix(canonical.path.hasSuffix("/") ? canonical.path : canonical.path + "/")
        else { throw AgentRuntimeAuthorizationError.invalidBookmark }
        do {
            let bookmarkData = try canonical.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return try Self(bookmarkData: bookmarkData, displayPath: canonical.path)
        } catch {
            throw AgentRuntimeAuthorizationError.invalidBookmark
        }
    }

    private static func isSafeDisplayPath(_ path: String) -> Bool {
        (path as NSString).isAbsolutePath && path.count <= 4_096 &&
            !path.unicodeScalars.contains { $0.value == 0 || $0.value == 10 || $0.value == 13 }
    }
}

public enum AgentRuntimeAuthorizationError: Error, Sendable, Equatable, LocalizedError {
    case invalidBookmark
    case noAuthorizedLocations
    case managedRuntimeRequired
    case staleBookmark
    case locationUnavailable
    case executableOutsideAuthorizedLocations
    case argumentOutsideAuthorizedLocations
    case environmentOutsideAuthorizedLocations
    case unsafeEnvironment

    public var errorDescription: String? {
        switch self {
        case .invalidBookmark:
            L10n.tr("A autorização do runtime ACP não é válida. Escolha a localização novamente.")
        case .noAuthorizedLocations:
            L10n.tr("Autorize as localizações do runtime ACP antes de conectar.")
        case .managedRuntimeRequired:
            L10n.tr("Importe um pacote de runtime ACP antes de conectar.")
        case .staleBookmark:
            L10n.tr("A autorização do runtime ACP mudou. Escolha a localização novamente.")
        case .locationUnavailable:
            L10n.tr("O OkamiUNI não conseguiu acessar uma localização autorizada do runtime ACP.")
        case .executableOutsideAuthorizedLocations:
            L10n.tr("O executável ACP precisa estar dentro de uma localização autorizada.")
        case .argumentOutsideAuthorizedLocations:
            L10n.tr("O caminho usado pelo agente ACP precisa estar dentro de uma localização autorizada.")
        case .environmentOutsideAuthorizedLocations:
            L10n.tr("O caminho configurado para o agente ACP precisa estar dentro de uma localização autorizada.")
        case .unsafeEnvironment:
            L10n.tr("A variável de ambiente do agente ACP não é permitida.")
        }
    }
}

/// A live, security-scoped launch authorization. Keeping this object alive
/// keeps the extensions alive for the complete child-process lifetime.
public final class AgentRuntimeLaunch: @unchecked Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    /// The ACP child starts here, while its ACP session itself receives a
    /// separate private working directory.
    public let workingDirectoryURL: URL
    private let access: AgentRuntimeSecurityScopedAccess?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL,
        access: AgentRuntimeSecurityScopedAccess?
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.access = access
    }
}

/// ACP is an optional interactive connection. Background analysis and writing
/// retain their configured provider. No shell interpolation or stored token.
public struct AgentConnectionConfiguration: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var executablePath: String
    public var arguments: [String]
    /// The imported ACP runtime. Release builds launch only this copy inside
    /// the app container, never the original user-selected executable.
    public var managedRuntime: ACPManagedRuntime?
    /// External provider state selected through the system picker. The
    /// imported executable never comes from these bookmarks.
    public var authorizedLocations: [AgentRuntimeAuthorization]
    /// Small, provider-owned runtime settings such as `CODEX_HOME`. Credentials
    /// and loader/interpreter variables are rejected and never persisted here.
    public var environment: [String: String]

    public init(
        enabled: Bool = false,
        executablePath: String = "",
        arguments: [String] = [],
        managedRuntime: ACPManagedRuntime? = nil,
        authorizedLocations: [AgentRuntimeAuthorization] = [],
        environment: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.executablePath = executablePath
        self.arguments = arguments
        self.managedRuntime = managedRuntime
        self.authorizedLocations = authorizedLocations
        self.environment = environment
    }

    /// Validates persisted literals without extending the sandbox. Use
    /// `resolvedLaunch()` immediately before `Process.run()`; it validates the
    /// selected locations while their security scopes are active.
    public func validated(requireExecutable: Bool = true) throws -> Self {
        guard enabled else { return self }
        guard arguments.count <= 32,
              arguments.allSatisfy(Self.isSafeArgument),
              authorizedLocations.count <= 16,
              environment.count <= 16
        else {
            throw AgentToolError.invalidArguments(L10n.tr("Informe o caminho absoluto de um agente ACP executável."))
        }
        guard environment.allSatisfy(Self.isSafeEnvironment) else {
            throw AgentRuntimeAuthorizationError.unsafeEnvironment
        }
        if managedRuntime != nil { return self }
        guard (executablePath as NSString).isAbsolutePath,
              (!requireExecutable || FileManager.default.isExecutableFile(atPath: executablePath))
        else {
            throw AgentToolError.invalidArguments(L10n.tr("Importe um pacote de runtime ACP executável."))
        }
        return self
    }

    /// Resolves the selections and holds their security scopes for one ACP
    /// process. This is the only supported route from saved paths to a launch.
    public func resolvedLaunch(fileManager: FileManager = .default) throws -> AgentRuntimeLaunch {
        _ = try validated(requireExecutable: false)
        guard enabled else { throw AgentToolError.invalidArguments(L10n.tr("Ative o agente ACP antes de conectar.")) }
        guard let managedRuntime else { throw AgentRuntimeAuthorizationError.managedRuntimeRequired }

        let access = authorizedLocations.isEmpty
            ? nil
            : try AgentRuntimeSecurityScopedAccess(authorizedLocations: authorizedLocations)
        for value in environment.values where Self.isAbsolutePathArgument(value) {
            guard access?.contains(Self.canonicalFileURL(path: value)) == true else {
                throw AgentRuntimeAuthorizationError.environmentOutsideAuthorizedLocations
            }
        }
        return try managedRuntime.resolvedLaunch(
            additionalArguments: arguments,
            additionalEnvironment: environment,
            access: access,
            fileManager: fileManager
        )
    }

    public var destination: AssistantDestination {
        .init(label: "ACP · " + (managedRuntime?.displayName ?? URL(fileURLWithPath: executablePath).lastPathComponent),
              detail: L10n.tr("O agente configurado recebe o contexto e pode usar seu provedor remoto."), isLocal: false)
    }

    private static func isSafeArgument(_ argument: String) -> Bool {
        argument.count <= 4_096 &&
            !argument.unicodeScalars.contains { $0.value == 0 || $0.value == 10 || $0.value == 13 }
    }

    private static func isSafeEnvironment(_ item: (key: String, value: String)) -> Bool {
        ACPManagedRuntime.isSafeEnvironment(item)
    }

    private static func isAbsolutePathArgument(_ value: String) -> Bool {
        (value as NSString).isAbsolutePath
    }

    private static func canonicalFileURL(path: String) -> URL {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, executablePath, arguments, managedRuntime, authorizedLocations, environment
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        executablePath = try values.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        managedRuntime = try values.decodeIfPresent(ACPManagedRuntime.self, forKey: .managedRuntime)
        authorizedLocations = try values.decodeIfPresent([AgentRuntimeAuthorization].self, forKey: .authorizedLocations) ?? []
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}

final class AgentRuntimeSecurityScopedAccess: @unchecked Sendable {
    private let urls: [URL]

    init(authorizedLocations: [AgentRuntimeAuthorization]) throws {
        var accessed: [URL] = []
        do {
            for authorization in authorizedLocations {
                var stale = false
                let url: URL
                do {
                    url = try URL(
                        resolvingBookmarkData: authorization.bookmarkData,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    )
                } catch {
                    throw AgentRuntimeAuthorizationError.invalidBookmark
                }
                guard !stale else { throw AgentRuntimeAuthorizationError.staleBookmark }
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard canonical.isFileURL, canonical.startAccessingSecurityScopedResource() else {
                    throw AgentRuntimeAuthorizationError.locationUnavailable
                }
                accessed.append(canonical)
            }
            urls = accessed
        } catch {
            for url in accessed { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit {
        for url in urls { url.stopAccessingSecurityScopedResource() }
    }

    func contains(_ target: URL) -> Bool {
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.contains { authorized in
            let root = authorized.path.hasSuffix("/") ? String(authorized.path.dropLast()) : authorized.path
            return targetPath == root || targetPath.hasPrefix(root + "/")
        }
    }
}
