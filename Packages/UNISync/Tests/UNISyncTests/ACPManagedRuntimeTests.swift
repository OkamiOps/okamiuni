import Foundation
import Testing
@testable import UNISync

@Suite("Runtime ACP gerenciado")
struct ACPManagedRuntimeTests {
    @Test("importa um pacote autocontido e resolve somente a cópia gerenciada")
    func importsPortablePackage() throws {
        let fixture = try ACPManagedRuntimeFixture()
        defer { fixture.remove() }
        try fixture.writeManifest(executable: "bin/fixture-agent", arguments: ["--acp"])
        try fixture.writeExecutable(at: "bin/fixture-agent")

        let runtime = try ACPManagedRuntime.importPackage(
            at: fixture.package,
            fileManager: fixture.fileManager,
            storageRoot: fixture.storage
        )
        let launch = try runtime.resolvedLaunch(
            additionalArguments: ["--verbose"],
            additionalEnvironment: ["ACP_STATE": "relative-state"],
            access: nil,
            fileManager: fixture.fileManager,
            storageRoot: fixture.storage
        )

        #expect(launch.executableURL.path.hasPrefix(fixture.storage.path + "/"))
        #expect(launch.executableURL.path != fixture.package.appendingPathComponent("bin/fixture-agent").path)
        #expect(launch.arguments == ["--acp", "--verbose"])
        #expect(launch.environment["ACP_STATE"] == "relative-state")
        #expect(fixture.fileManager.isExecutableFile(atPath: launch.executableURL.path))
    }

    @Test("recusa links simbólicos antes de importar")
    func rejectsSymlinkInPackage() throws {
        let fixture = try ACPManagedRuntimeFixture()
        defer { fixture.remove() }
        try fixture.writeManifest(executable: "bin/fixture-agent")
        try fixture.writeExecutable(at: "bin/fixture-agent")
        try fixture.fileManager.createSymbolicLink(
            at: fixture.package.appendingPathComponent("outside-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )

        #expect(throws: ACPManagedRuntimeError.unsafePackageContents) {
            try ACPManagedRuntime.importPackage(
                at: fixture.package,
                fileManager: fixture.fileManager,
                storageRoot: fixture.storage
            )
        }
    }

    @Test("recusa caminho de executável que sai do pacote")
    func rejectsPathTraversalInManifest() throws {
        let fixture = try ACPManagedRuntimeFixture()
        defer { fixture.remove() }
        try fixture.writeManifest(executable: "../fixture-agent")
        try fixture.writeExecutable(at: "bin/fixture-agent")

        #expect(throws: ACPManagedRuntimeError.invalidManifest) {
            try ACPManagedRuntime.importPackage(
                at: fixture.package,
                fileManager: fixture.fileManager,
                storageRoot: fixture.storage
            )
        }
    }
}

private final class ACPManagedRuntimeFixture {
    let fileManager = FileManager.default
    let root: URL
    let package: URL
    let storage: URL

    init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("ACPManagedRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        package = root.appendingPathComponent("Portable Agent", isDirectory: true)
        storage = root.appendingPathComponent("Managed", isDirectory: true)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
    }

    func remove() {
        try? fileManager.removeItem(at: root)
    }

    func writeManifest(executable: String, arguments: [String] = []) throws {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "displayName": "Fixture ACP",
            "executable": executable,
            "arguments": arguments,
            "environment": [String: String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: package.appendingPathComponent(ACPManagedRuntime.manifestFileName), options: .atomic)
    }

    func writeExecutable(at relativePath: String) throws {
        let executable = relativePath.split(separator: "/").reduce(package) { url, component in
            url.appendingPathComponent(String(component))
        }
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf fixture\\n".utf8).write(to: executable, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
}
