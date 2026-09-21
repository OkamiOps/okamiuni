import Foundation
import UNICore

/// Agent-tool facade for explicitly configured A2A peers.
///
/// This type deliberately exposes no argument that can smuggle an inbox,
/// conversation snapshot, attachment, URL, or an unconfigured endpoint into a
/// delegation. The composition root decides which peer credentials exist; the
/// model can only choose a configured peer and pass the exact task text.
public struct A2ADelegateTool: AgentToolExecuting {
    public nonisolated let definitions: [AgentToolDefinition]
    private let configuration: A2AConfiguration
    private let client: A2AClient

    public init(
        configuration: A2AConfiguration,
        polling: A2APollingPolicy = .init(),
        credentialHeaders: @escaping A2AClient.CredentialHeaders = { _ in [:] }
    ) {
        self.configuration = configuration
        client = A2AClient(
            configuration: configuration,
            polling: polling,
            credentialHeaders: credentialHeaders
        )
        definitions = configuration.enabled ? Self.catalog : []
    }

    public func execute(name: String, arguments: AgentJSONValue) async throws -> AgentJSONValue {
        guard configuration.enabled else { throw AgentToolError.unavailable("A delegação A2A está desativada.") }
        guard let values = arguments.objectValue else { throw AgentToolError.invalidArguments("Os argumentos A2A devem ser um objeto.") }
        switch name {
        case "a2a_agents_list":
            guard values.isEmpty else { throw AgentToolError.invalidArguments("a2a_agents_list não aceita argumentos.") }
            let peers = try await client.configuredPeers()
            return .object([
                "agents": .array(peers.map { peer in
                    .object([
                        "peerID": .string(peer.id),
                        "name": .string(peer.name),
                        "discovered": .bool(false),
                    ])
                }),
            ])

        case "a2a_agents_discover":
            let peerID = try exactly(values, keys: ["peerID"])["peerID"]?.stringValue ?? {
                throw AgentToolError.invalidArguments("peerID é obrigatório.")
            }()
            let card = try await client.discover(peerID: peerID)
            return .object(["peerID": .string(peerID), "agent": card.toolValue])

        case "a2a_task_delegate":
            let arguments = try exactly(values, keys: ["peerID", "task"])
            guard let peerID = arguments["peerID"]?.stringValue,
                  let task = arguments["task"]?.stringValue
            else { throw AgentToolError.invalidArguments("peerID e task são obrigatórios.") }
            let response = try await client.delegate(peerID: peerID, task: task)
            return .object(["peerID": .string(peerID), "response": response.toolValue])

        default:
            throw AgentToolError.unknownTool
        }
    }

    private func exactly(_ values: [String: AgentJSONValue], keys: Set<String>) throws -> [String: AgentJSONValue] {
        guard Set(values.keys) == keys else { throw AgentToolError.invalidArguments("Argumentos A2A inválidos.") }
        return values
    }

    private nonisolated static let catalog: [AgentToolDefinition] = [
        .init(
            name: "a2a_agents_list",
            description: "Lista somente os agentes A2A configurados pela pessoa. Use a descoberta antes de delegar quando precisar conhecer habilidades.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            readOnly: true
        ),
        .init(
            name: "a2a_agents_discover",
            description: "Lê o Agent Card público de um agente A2A configurado e retorna suas habilidades declaradas. Não envia dados do aplicativo.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "peerID": .object(["type": .string("string"), "description": .string("ID exato devolvido por a2a_agents_list.")]),
                ]),
                "required": .array([.string("peerID")]),
                "additionalProperties": .bool(false),
            ]),
            readOnly: true
        ),
        .init(
            name: "a2a_task_delegate",
            description: "Delega somente uma tarefa de texto explícita a um agente A2A configurado. Não inclua e-mails, histórico, anexos, URLs ou dados que a pessoa não tenha pedido para compartilhar.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "peerID": .object(["type": .string("string"), "description": .string("ID exato de um agente A2A configurado.")]),
                    "task": .object(["type": .string("string"), "description": .string("A tarefa exata que a pessoa pediu para delegar, sem contexto automático do aplicativo.")]),
                ]),
                "required": .array([.string("peerID"), .string("task")]),
                "additionalProperties": .bool(false),
            ]),
            readOnly: false
        ),
    ]
}
