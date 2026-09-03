import Foundation
import Testing
import UNICore

@testable import UNISync

@Suite("A rota das propostas")
struct AssistantProposalRouteTests {

    private func settingsStore(_ settings: AssistantSettings) throws -> AssistantSettingsStore {
        let suite = "okamiuni.assistant-proposals.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try store.save(settings)
        return store
    }

    private var remoto: AssistantSettings {
        AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://litellm.example", model: "modelo",
                credentialID: "primary"
            )
        )
    }

    private var mensagem: Message {
        Message(
            id: "m1", accountID: "gmail",
            from: Contact(name: "Jack Whitmore", address: "jack@whitmore.dev"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Orçamento", snippet: "Consegue olhar?", body: ["Consegue olhar?"],
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil
        )
    }

    private var conversa: AssistantConversationSnapshot {
        .init(mailContext: AssistantMailContext(message: mensagem))
    }

    @Test("o contexto de um email carrega o id — sem ele o validador recusa tudo")
    func contextCarriesTheMessageID() {
        #expect(conversa.mailContext.messageIDs == ["m1"])
        #expect(conversa.mailContext.messageIDsWithEvent.isEmpty)
    }

    @Test("golden: o pedido remoto explica o bloco e a lista fechada")
    func remotePromptGolden() {
        let pedido = AssistantPrompt.questionRequestingProposals("O que faço com o Jack?")
        #expect(pedido.hasPrefix("O que faço com o Jack?\n\n"))
        #expect(pedido.hasSuffix(AssistantActionsBlock.instruction))
        #expect(pedido.contains("```okami-actions"))
        #expect(pedido.contains("learnSender"))
        #expect(pedido.contains("reserveBlock"))
        #expect(!pedido.contains("\"send\""))
        #expect(
            pedido == """
                O que faço com o Jack?

                \(AssistantActionsBlock.instruction)
                """
        )
    }

    @Test("remoto: o bloco vira proposta e sai do texto")
    @available(macOS 26.0, *)
    func remoteAnswerCarriesProposals() async throws {
        let credenciais = InMemoryAssistantCredentialStore()
        try credenciais.storeAPIKey("test-key", for: "primary")
        let resposta = """
            Dá para arquivar isso.\\n\\n```okami-actions\\n\
            {\\"proposals\\":[{\\"title\\":\\"Arquivar\\",\\"rationale\\":\\"Não pede nada.\\",\
            \\"actions\\":[{\\"kind\\":\\"archive\\",\\"messageID\\":\\"m1\\"}]}]}\\n```
            """
        let sessao = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [
                .json("{\"choices\":[{\"message\":{\"content\":\"\(resposta)\"}}]}")
            ],
        ])
        let router = AssistantRouter(
            settingsStore: try settingsStore(remoto),
            credentialStore: credenciais,
            session: sessao
        )

        let dada = try await router.answerWithProposals(
            question: "O que faço?", in: conversa
        )
        #expect(dada.text == "Dá para arquivar isso.")
        #expect(dada.proposals.count == 1)
        #expect(dada.proposals[0].actions == [.archive(messageID: "m1")])

        let pedidos = StubURLProtocol.requests(for: sessao)
        #expect(pedidos.count == 1)
        #expect(pedidos[0].body.contains("okami-actions"))
    }

    @Test("remoto: a proposta que cita mensagem de fora do contexto é descartada")
    @available(macOS 26.0, *)
    func remoteAnswerDropsUnknownMessages() async throws {
        let credenciais = InMemoryAssistantCredentialStore()
        try credenciais.storeAPIKey("test-key", for: "primary")
        let resposta = """
            Olha só.\\n\\n```okami-actions\\n\
            {\\"proposals\\":[{\\"title\\":\\"Arquivar\\",\\"rationale\\":\\"r\\",\
            \\"actions\\":[{\\"kind\\":\\"archive\\",\\"messageID\\":\\"intruso\\"}]}]}\\n```
            """
        let sessao = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [
                .json("{\"choices\":[{\"message\":{\"content\":\"\(resposta)\"}}]}")
            ],
        ])
        let router = AssistantRouter(
            settingsStore: try settingsStore(remoto),
            credentialStore: credenciais,
            session: sessao
        )

        let dada = try await router.answerWithProposals(question: "O que faço?", in: conversa)
        #expect(dada.text == "Olha só.")
        #expect(dada.proposals.isEmpty)
    }

    @Test("remoto: sem bloco nenhum, a resposta continua inteira")
    @available(macOS 26.0, *)
    func remoteAnswerWithoutBlock() async throws {
        let credenciais = InMemoryAssistantCredentialStore()
        try credenciais.storeAPIKey("test-key", for: "primary")
        let sessao = StubURLProtocol.session(routes: [
            "/v1/chat/completions": [
                .json("{\"choices\":[{\"message\":{\"content\":\"Só uma explicação.\"}}]}")
            ],
        ])
        let router = AssistantRouter(
            settingsStore: try settingsStore(remoto),
            credentialStore: credenciais,
            session: sessao
        )

        let dada = try await router.answerWithProposals(question: "O que faço?", in: conversa)
        #expect(dada.text == "Só uma explicação.")
        #expect(dada.proposals.isEmpty)
    }

    @Test("addToAgenda só passa quando o compromisso já está persistido")
    func agendaNeedsAPersistedEvent() {
        let comEvento = Message(
            id: "m2", accountID: "gmail",
            from: Contact(name: "Maria", address: "maria@exemplo.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Reunião", snippet: "Quinta às 15h", body: ["Quinta às 15h"],
            tags: [], bucket: .today, isRead: false, summary: nil,
            detectedEvent: DetectedEvent(
                label: "Reunião", start: Date(timeIntervalSince1970: 1_800_100_000),
                duration: 3_600
            )
        )
        let contexto = AssistantMailContext.conversation([
            AssistantEmailContext(message: mensagem),
            AssistantEmailContext(message: comEvento),
        ])
        #expect(contexto.messageIDs == ["m1", "m2"])
        #expect(contexto.messageIDsWithEvent == ["m2"])

        let propostas = [
            AssistantProposal(
                title: "Agendar", actions: [.addToAgenda(messageID: "m2")], rationale: "r"
            ),
            AssistantProposal(
                title: "Agendar o outro", actions: [.addToAgenda(messageID: "m1")], rationale: "r"
            ),
        ]
        let validas = AssistantProposalValidator.validate(
            propostas,
            messageIDs: contexto.messageIDs,
            messageIDsWithEvent: contexto.messageIDsWithEvent
        )
        #expect(validas.map { $0.title } == ["Agendar"])
    }
}
