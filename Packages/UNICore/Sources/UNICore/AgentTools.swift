import Foundation

/// JSON shared by the native action layer and protocol adapters.
public indirect enum AgentJSONValue: Sendable, Equatable, Codable {
    case object([String: AgentJSONValue]), array([AgentJSONValue]), string(String)
    case number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> Self? { objectValue?[key] }
    public var objectValue: [String: Self]? { if case .object(let v) = self { v } else { nil } }
    public var arrayValue: [Self]? { if case .array(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var intValue: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v,
              v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public func jsonString() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct AgentToolDefinition: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let inputSchema: AgentJSONValue
    public let readOnly: Bool
    public init(name: String, description: String, inputSchema: AgentJSONValue, readOnly: Bool) {
        self.name = name; self.description = description
        self.inputSchema = inputSchema; self.readOnly = readOnly
    }
}

public protocol AgentToolExecuting: Sendable {
    var definitions: [AgentToolDefinition] { get }
    func execute(name: String, arguments: AgentJSONValue) async throws -> AgentJSONValue
}

public enum AgentToolError: Error, LocalizedError, Sendable {
    case invalidArguments(String), unavailable(String), conflict, unknownTool
    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail), .unavailable(let detail): detail
        case .conflict: L10n.tr("O rascunho mudou. Leia a versão atual antes de atualizar.")
        case .unknownTool: L10n.tr("Esta ação não está disponível para o agente.")
        }
    }
}
