import Foundation
import UNICore

/// ACP is an optional interactive connection. Background analysis and writing
/// retain their configured provider. No shell interpolation or stored token.
public struct AgentConnectionConfiguration: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var executablePath: String
    public var arguments: [String]
    public init(enabled: Bool = false, executablePath: String = "", arguments: [String] = []) {
        self.enabled = enabled; self.executablePath = executablePath; self.arguments = arguments
    }
    public func validated(requireExecutable: Bool = true) throws -> Self {
        guard enabled else { return self }
        guard (executablePath as NSString).isAbsolutePath,
              (!requireExecutable || FileManager.default.isExecutableFile(atPath: executablePath)),
              arguments.count <= 32, arguments.allSatisfy({ !$0.contains("\0") && $0.count <= 4_096 }) else {
            throw AgentToolError.invalidArguments(L10n.tr("Informe o caminho absoluto de um agente ACP executável."))
        }
        return self
    }
    public var destination: AssistantDestination {
        .init(label: "ACP · " + URL(fileURLWithPath: executablePath).lastPathComponent,
              detail: L10n.tr("O agente configurado recebe o contexto e pode usar seu provedor remoto."), isLocal: false)
    }
}
