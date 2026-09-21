import Foundation
import UNICore

/// Models with small context windows discover complete schemas on demand.
/// The same executor and permissions are used by every provider.
public enum AgentPlanningContext: Sendable {
    case standard
    case compact
}

struct TextAssistantAgentPlanner: AgentPlanning {
    let assistant: any TextAssisting
    func agentPlan(prompt: String) async throws -> String {
        try await assistant.answer(
            question: AgentToolLoop.instructions + "\n" + prompt,
            in: .init(mailContext: .email(.init(subject: "OkamiUNI", sender: "", body: "")))
        )
    }
}

/// Combines protocol tools with native tools without changing model adapters.
struct WorkspaceAgentToolSet: AgentToolExecuting {
    let definitions: [AgentToolDefinition]
    private let executors: [String: any AgentToolExecuting]

    init(_ groups: [any AgentToolExecuting]) throws {
        var executors: [String: any AgentToolExecuting] = [:]
        var definitions: [AgentToolDefinition] = []
        for group in groups {
            for definition in group.definitions {
                guard executors[definition.name] == nil else {
                    throw AgentToolError.invalidArguments("Duplicate tool: \(definition.name)")
                }
                executors[definition.name] = group
                definitions.append(definition)
            }
        }
        self.definitions = definitions
        self.executors = executors
    }

    func execute(name: String, arguments: AgentJSONValue) async throws -> AgentJSONValue {
        guard let executor = executors[name] else { throw AgentToolError.unknownTool }
        return try await executor.execute(name: name, arguments: arguments)
    }
}

enum AgentPromptContext {
    static func compactContext(question: String, conversation: AssistantConversationSnapshot) -> String {
        let selected: String
        switch conversation.mailContext {
        case let .email(email):
            selected = "messageID=\(email.messageID ?? "") subject=\(email.subject.prefix(140)) sender=\(email.sender.prefix(100))"
        case let .conversation(emails):
            selected = emails.suffix(3).map { "messageID=\($0.messageID ?? "") subject=\($0.subject.prefix(90))" }.joined(separator: "\n")
        case let .workspace(workspace):
            selected = "workspace accounts=\(workspace.accounts.joined(separator: ", ")) messages=\(workspace.emailCount). Use search tools for mail."
        }
        let turns = conversation.turns.suffix(2).map { "\($0.role.rawValue): \($0.text.prefix(220))" }.joined(separator: "\n")
        return "PEDIDO: " + String(question.prefix(2_000)) + "\nAgora: " + ISO8601DateFormatter().string(from: Date())
            + "\n<contexto-nao-confiavel>\n" + selected + "\n" + turns + "\n</contexto-nao-confiavel>"
    }
    static func compactCatalog(_ definitions: [AgentToolDefinition]) -> String {
        definitions.map { definition in
            let fields = definition.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue).map { name in
                let type = definition.inputSchema["properties"]?[name]?["type"]?.stringValue ?? "string"
                return name + ":" + (type == "array" ? "string[]" : type)
            }.joined(separator: ", ") ?? ""
            return "\(definition.name)(\(fields)): \(definition.description.prefix(70))"
        }.joined(separator: "\n")
        + "\ntool_describe: {\"name\":\"tool name\"} returns its complete input schema. Call before using an unfamiliar tool."
    }

    static func history(_ results: [AgentJSONValue], compact: Bool) throws -> String {
        guard compact else { return try AgentJSONValue.array(results).jsonString() }
        // Keep the latest result in detail and retain IDs/outcomes from older
        // operations. A truncated body is labelled, never silently complete.
        let recent = results.suffix(4).enumerated().map { index, result in
            bounded(result, stringLimit: index == results.suffix(4).count - 1 ? 900 : 180)
        }
        return try AgentJSONValue.array(recent).jsonString()
    }

    static func bounded(_ value: AgentJSONValue, stringLimit: Int, depth: Int = 0) -> AgentJSONValue {
        guard depth < 10 else { return .string("[nested result omitted]") }
        switch value {
        case let .string(text) where text.count > stringLimit:
            return .string(String(text.prefix(stringLimit)) + "\n[TRUNCATED: read a smaller page/range with the tool]")
        case let .array(items):
            var result = items.prefix(5).map { bounded($0, stringLimit: stringLimit, depth: depth + 1) }
            if items.count > 5 { result.append(.object(["omittedItems": .number(Double(items.count - 5))])) }
            return .array(result)
        case let .object(fields):
            return .object(fields.mapValues { bounded($0, stringLimit: stringLimit, depth: depth + 1) }
                .merging(fields.filter { $0.key == "required" || $0.key == "enum" }) { _, original in original })
        default: return value
        }
    }
}
