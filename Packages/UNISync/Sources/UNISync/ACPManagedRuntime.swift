import Foundation
import UNICore

/// A portable ACP runtime that has been copied into the app container. App
/// Sandbox cannot execute a program directly from a user-selected folder, so
/// the configuration stores only this install identifier and relative paths.
public struct ACPManagedRuntime: Codable, Sendable, Hashable {
    public static let manifestFileName = "okamiuni-acp-runtime.json"

    /// A random, app-container-only directory name. It is not an external
    /// path and therefore does not expand the sandbox when persisted.
    public let installationID: String
    public let displayName: String
    public let executableRelativePath: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        installationID: String,
        displayName: String,
        executableRelativePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws {
        guard Self.isSafeInstallationID(installationID),
              Self.isSafeDisplayName(displayName),
              Self.isSafeRelativePath(executableRelativePath),
              arguments.count <= 32,
              arguments.allSatisfy(Self.isSafeArgument),
              environment.count <= 16,
              environment.allSatisfy(Self.isSafeEnvironment)
        else { throw ACPManagedRuntimeError.invalidManifest }
        self.installationID = installationID
        self.displayName = displayName
        self.executableRelativePath = executableRelativePath
        self.arguments = arguments
        self.environment = environment
    }

    /// Imports a complete, portable runtime package selected with
    /// `NSOpenPanel`. The package must include its executable and every
    /// dependency it needs; no executable is launched from the selected URL.
    public static func importPackage(
        at selectedURL: URL,
        fileManager: FileManager = .default,
        storageRoot: URL? = nil
    ) throws -> ACPManagedRuntime {
        let selected = selectedURL.standardizedFileURL
        guard selected.isFileURL,
              fileManager.fileExists(atPath: selected.path),
              let selectedValues = try? selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              selectedValues.isDirectory == true,
              selectedValues.isSymbolicLink != true
        else { throw ACPManagedRuntimeError.invalidPackage }
        let source = selected.resolvingSymlinksInPath().standardizedFileURL
        try rejectBroadSelection(source, fileManager: fileManager)

        // An NSOpenPanel selection is normally already available for the
        // callback that imports it. Start a scope explicitly as well so this
        // function has one clear lifetime when called from a saved selection.
        let startedAccess = selected.startAccessingSecurityScopedResource()
        defer {
            if startedAccess { selected.stopAccessingSecurityScopedResource() }
        }

        // Inspect every entry before decoding any package-controlled file.
        // This prevents a manifest or executable symlink from crossing the
        // selected package boundary during validation.
        try validatePackageTree(source, fileManager: fileManager)
        let manifest = try readManifest(at: source, fileManager: fileManager)
        let runtime = try ACPManagedRuntime(
            installationID: UUID().uuidString.lowercased(),
            displayName: manifest.displayName,
            executableRelativePath: manifest.executable,
            arguments: manifest.arguments,
            environment: manifest.environment
        )

        // The validated package is self-contained; copyItem will preserve
        // executable bits and signatures without following a symlink.
        let sourceExecutable = source.appendingSafeRelativePath(manifest.executable)
        guard fileManager.isExecutableFile(atPath: sourceExecutable.path) else {
            throw ACPManagedRuntimeError.executableUnavailable
        }

        let root: URL
        if let storageRoot {
            root = storageRoot
        } else {
            root = try managedRuntimeRoot(fileManager: fileManager)
        }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent(runtime.installationID, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ACPManagedRuntimeError.installationFailed
        }
        do {
            // `copyItem` preserves executable mode bits, extended attributes
            // and nested code signatures. The preceding walk rejected every
            // symlink and special file rather than following one while copy.
            try fileManager.copyItem(at: source, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ACPManagedRuntimeError.installationFailed
        }

        let installedExecutable = destination.appendingSafeRelativePath(runtime.executableRelativePath)
        guard fileManager.isExecutableFile(atPath: installedExecutable.path) else {
            try? fileManager.removeItem(at: destination)
            throw ACPManagedRuntimeError.executableUnavailable
        }
        return runtime
    }

    /// Resolves the installed executable without reopening any external path.
    /// The configuration may append literal arguments and override safe
    /// manifest defaults through `additionalEnvironment`. Environment values
    /// may point to a separately selected provider state directory.
    func resolvedLaunch(
        additionalArguments: [String],
        additionalEnvironment: [String: String],
        access: AgentRuntimeSecurityScopedAccess?,
        fileManager: FileManager,
        storageRoot: URL? = nil
    ) throws -> AgentRuntimeLaunch {
        let root: URL
        if let storageRoot {
            root = storageRoot
        } else {
            root = try Self.managedRuntimeRoot(fileManager: fileManager)
        }
        let install = root.appendingPathComponent(installationID, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard Self.isWithin(install, root), fileManager.fileExists(atPath: install.path) else {
            throw ACPManagedRuntimeError.installationUnavailable
        }
        let executable = install.appendingSafeRelativePath(executableRelativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard Self.isWithin(executable, install), fileManager.isExecutableFile(atPath: executable.path) else {
            throw ACPManagedRuntimeError.executableUnavailable
        }
        return AgentRuntimeLaunch(
            executableURL: executable,
            arguments: arguments + additionalArguments,
            // User configuration is intentional provider state, and can
            // replace a package default without mutating the package itself.
            environment: environment.merging(additionalEnvironment) { _, configured in configured },
            workingDirectoryURL: install,
            access: access
        )
    }

    /// The only app-owned storage location that may contain imported code.
    public static func managedRuntimeRoot(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport: URL
        do {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw ACPManagedRuntimeError.installationUnavailable
        }
        return applicationSupport
            .appendingPathComponent("OkamiUNI", isDirectory: true)
            .appendingPathComponent("ACPManagedRuntimes", isDirectory: true)
            .standardizedFileURL
    }

    static func isSafeEnvironment(_ item: (key: String, value: String)) -> Bool {
        let name = item.key
        guard name.count <= 128, !name.isEmpty,
              name.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value) || (97...122).contains(scalar.value) ||
                      (48...57).contains(scalar.value) || scalar.value == 95
              }),
              let first = name.unicodeScalars.first,
              (65...90).contains(first.value) || (97...122).contains(first.value) || first.value == 95,
              item.value.count <= 4_096,
              !item.value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 })
        else { return false }

        let upper = name.uppercased()
        let prohibitedExact: Set<String> = [
            "PATH", "HOME", "TMPDIR", "TMP", "TEMP", "PWD", "SHELL", "SHLVL", "ENV", "BASH_ENV",
            "NODE_OPTIONS", "NODE_PATH", "NODE_REPL_HISTORY", "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP",
            "RUBYOPT", "RUBYLIB", "PERL5OPT", "JAVA_TOOL_OPTIONS",
        ]
        let credentialTerms = ["TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "API_KEY", "ACCESS_KEY"]
        return !prohibitedExact.contains(upper) &&
            !upper.hasPrefix("DYLD_") && !upper.hasPrefix("LD_") &&
            !credentialTerms.contains(where: upper.contains)
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let displayName: String
        let executable: String
        let arguments: [String]
        let environment: [String: String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion, displayName, executable, arguments, environment
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            displayName = try values.decode(String.self, forKey: .displayName)
            executable = try values.decode(String.self, forKey: .executable)
            arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
            environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        }
    }

    private static func readManifest(at source: URL, fileManager: FileManager) throws -> Manifest {
        let url = source.appendingPathComponent(manifestFileName, isDirectory: false)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= 65_536
        else { throw ACPManagedRuntimeError.invalidManifest }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            guard manifest.schemaVersion == 1 else { throw ACPManagedRuntimeError.unsupportedManifest }
            return manifest
        } catch let error as ACPManagedRuntimeError {
            throw error
        } catch {
            throw ACPManagedRuntimeError.invalidManifest
        }
    }

    private static func validatePackageTree(_ source: URL, fileManager: FileManager) throws {
        guard let rootValues = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true
        else { throw ACPManagedRuntimeError.invalidPackage }

        guard let entries = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw ACPManagedRuntimeError.invalidPackage }

        var totalBytes: Int64 = 0
        var count = 0
        for case let item as URL in entries {
            count += 1
            guard count <= 100_000,
                  let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true
            else { throw ACPManagedRuntimeError.unsafePackageContents }
            if values.isRegularFile == true {
                totalBytes += Int64(values.fileSize ?? 0)
                guard totalBytes <= 1_073_741_824 else { throw ACPManagedRuntimeError.packageTooLarge }
            }
        }
    }

    private static func rejectBroadSelection(_ source: URL, fileManager: FileManager) throws {
        let home = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        guard source.path != "/",
              source.path != home.path,
              !home.path.hasPrefix(source.path.hasSuffix("/") ? source.path : source.path + "/")
        else { throw ACPManagedRuntimeError.invalidPackage }
    }

    private static func isSafeInstallationID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func isSafeDisplayName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 128 &&
            !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 })
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 1_024,
              !(value as NSString).isAbsolutePath
        else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isSafeArgument(_ value: String) -> Bool {
        value.count <= 4_096 && !value.unicodeScalars.contains { $0.value == 0 || $0.value == 10 || $0.value == 13 }
    }

    private static func isWithin(_ child: URL, _ root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

public enum ACPManagedRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case invalidPackage
    case invalidManifest
    case unsupportedManifest
    case unsafePackageContents
    case packageTooLarge
    case executableUnavailable
    case installationFailed
    case installationUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidPackage:
            L10n.tr("Escolha uma pasta de runtime ACP específica, não a pasta pessoal inteira.")
        case .invalidManifest:
            L10n.tr("O pacote ACP não contém um manifesto válido.")
        case .unsupportedManifest:
            L10n.tr("O pacote ACP usa uma versão de manifesto não suportada.")
        case .unsafePackageContents:
            L10n.tr("O pacote ACP contém links ou tipos de arquivo que não podem ser importados.")
        case .packageTooLarge:
            L10n.tr("O pacote ACP é grande demais para importar.")
        case .executableUnavailable:
            L10n.tr("O executável declarado pelo pacote ACP não está disponível.")
        case .installationFailed:
            L10n.tr("O OkamiUNI não conseguiu importar o runtime ACP.")
        case .installationUnavailable:
            L10n.tr("O runtime ACP importado não está mais disponível.")
        }
    }
}

private extension URL {
    func appendingSafeRelativePath(_ path: String) -> URL {
        path.split(separator: "/").reduce(self) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }
}
