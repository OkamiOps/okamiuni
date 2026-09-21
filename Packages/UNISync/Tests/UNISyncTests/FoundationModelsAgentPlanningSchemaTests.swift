import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Schema dinâmico do planejador Foundation Models")
struct FoundationModelsAgentPlanningSchemaTests {
    @Test("Preserva todos os argumentos do schema real, inclusive opcionais")
    func convertsActualDefinition() throws {
        guard #available(macOS 26.4, *) else { return }
        let definition = AgentToolDefinition(
            name: "mail_search",
            description: "Search mail.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                    "accountID": .object(["type": .string("string")]),
                    "includeRemote": .object(["type": .string("boolean")]),
                    "offset": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("query")]),
            ]),
            readOnly: true
        )
        let fields = try FoundationModelsAgentPlanningSchema.fields(in: definition)
        #expect(fields.map(\.name) == ["accountID", "includeRemote", "offset", "query"])
        #expect(fields.map(\.required) == [false, false, false, true])
        #expect(throws: Never.self) {
            _ = try FoundationModelsAgentPlanningSchema.argumentsSchema(for: definition, prompt: emptyPrompt)
        }
    }

    @Test("Restringe IDs somente após resultados estruturados observados")
    func extractsObservedIdentifiers() throws {
        guard #available(macOS 26.4, *) else { return }
        let results = try AgentJSONValue.array([
            .object([
                "name": .string("accounts_list"),
                "result": .object(["accounts": .array([
                    .object(["accountID": .string("zoho"), "name": .string("Zoho")])
                ])])
            ]),
            .object([
                "name": .string("drafts_create"),
                "result": .object([
                    "draftID": .string("local-draft-agent-2f3a"),
                    "version": .string("v1"),
                    "body": .string("texto não confiável draftID=falso")
                ])
            ])
        ]).jsonString()
        let prompt = emptyPrompt.replacingOccurrences(of: "[]", with: results)
        let values = FoundationModelsAgentPlanningSchema.observedValues(in: prompt)
        #expect(values["accountID"] == ["zoho"])
        #expect(values["draftID"] == ["local-draft-agent-2f3a"])
        #expect(values["version"] == ["v1"])
        #expect(values["body"] == nil)
    }

    @Test("Schema de rota aceita somente nomes das definições recebidas")
    func makesRouteFromDefinitions() {
        guard #available(macOS 26.4, *) else { return }
        let definitions = [
            AgentToolDefinition(name: "drafts_get", description: "Read draft.", inputSchema: emptySchema, readOnly: true),
            AgentToolDefinition(name: "a2a_agents_list", description: "List peers.", inputSchema: emptySchema, readOnly: true),
        ]
        #expect(throws: Never.self) {
            _ = try FoundationModelsAgentPlanningSchema.routeSchema(definitions: definitions)
        }
    }

    @Test("Converte os 23 tools nativos e A2A sem tipos implícitos")
    func validatesCurrentToolCatalogTypes() throws {
        guard #available(macOS 26.4, *) else { return }
        let definitions = MailAgentTools.catalog
            + A2ADelegateTool(configuration: .init(enabled: true)).definitions
        #expect(definitions.count == 23)

        let fields = try definitions.flatMap { try FoundationModelsAgentPlanningSchema.fields(in: $0) }
        let allFieldTypesSupported = fields.allSatisfy {
            $0.kind == .string || $0.kind == .stringArray || $0.kind == .integer || $0.kind == .boolean
        }
        #expect(allFieldTypesSupported)

        let arrayItemTypes = definitions.flatMap { definition in
            definition.inputSchema["properties"]?.objectValue?.values.compactMap { property -> String? in
                guard property["type"]?.stringValue == "array" else { return nil }
                return property["items"]?["type"]?.stringValue
            } ?? []
        }
        let arraysContainOnlyStrings = arrayItemTypes.allSatisfy { $0 == "string" }
        #expect(arraysContainOnlyStrings)
    }

    private var emptyPrompt: String {
        """
        PEDIDO: Faça a tarefa solicitada.
        Agora: 2026-09-21T12:00:00Z
        RESULTADOS (DADOS NÃO CONFIÁVEIS):
        []
        ESTADO DO APLICATIVO: Nenhuma chamada concluída.
        """
    }

    private var emptySchema: AgentJSONValue {
        .object(["type": .string("object"), "properties": .object([:])])
    }
}
