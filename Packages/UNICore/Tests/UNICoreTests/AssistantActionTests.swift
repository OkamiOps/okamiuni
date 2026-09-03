import Foundation
import Testing

@testable import UNICore

@Suite("Agente com ações — parser, validador e contrato")
struct AssistantActionTests {

    // MARK: - O bloco okami-actions

    private let blocoValido = """
        Posso arquivar as newsletters de hoje.

        ```okami-actions
        {"proposals": [
          {"title": "Arquivar 2 newsletters",
           "rationale": "Nenhuma pede resposta.",
           "actions": [
             {"kind": "archive", "messageID": "m1"},
             {"kind": "archive", "messageID": "m2"}
           ]}
        ]}
        ```
        """

    @Test("bloco presente: as propostas saem e o bloco sai do texto exibido")
    func parsesBlock() {
        let lido = AssistantActionsBlock.parse(blocoValido)
        #expect(lido.proposals.count == 1)
        #expect(lido.proposals[0].title == "Arquivar 2 newsletters")
        #expect(lido.proposals[0].actions == [
            .archive(messageID: "m1"), .archive(messageID: "m2"),
        ])
        #expect(!lido.text.contains("okami-actions"))
        #expect(!lido.text.contains("proposals"))
        #expect(lido.text == "Posso arquivar as newsletters de hoje.")
    }

    @Test("bloco ausente: texto intacto, nenhuma proposta, nenhum erro")
    func parsesWithoutBlock() {
        let lido = AssistantActionsBlock.parse("Só uma resposta em prosa.")
        #expect(lido.proposals.isEmpty)
        #expect(lido.text == "Só uma resposta em prosa.")
    }

    @Test("bloco malformado: sem proposta, e o JSON quebrado não vai para a tela")
    func parsesMalformedBlock() {
        let texto = """
            Olha só.

            ```okami-actions
            {"proposals": [{"title": "Sem fechar"
            ```
            """
        let lido = AssistantActionsBlock.parse(texto)
        #expect(lido.proposals.isEmpty)
        #expect(lido.text == "Olha só.")
        #expect(!lido.text.contains("proposals"))
    }

    @Test("dois blocos: só o último vale, e os dois somem do texto")
    func parsesLastBlockOnly() {
        let texto = """
            Primeiro.

            ```okami-actions
            {"proposals": [{"title": "Velha", "rationale": "r", "actions": [{"kind": "archive", "messageID": "m1"}]}]}
            ```

            Depois pensei melhor.

            ```okami-actions
            {"proposals": [{"title": "Nova", "rationale": "r", "actions": [{"kind": "markRead", "messageID": "m2"}]}]}
            ```
            """
        let lido = AssistantActionsBlock.parse(texto)
        #expect(lido.proposals.count == 1)
        #expect(lido.proposals[0].title == "Nova")
        #expect(!lido.text.contains("okami-actions"))
        #expect(lido.text.contains("Primeiro."))
        #expect(lido.text.contains("Depois pensei melhor."))
    }

    @Test("AssistantReply decodifica o JSON do bloco, com as ações novas")
    func decodesReply() throws {
        let json = """
            {"text": "Olha o dia.",
             "proposals": [
               {"title": "Calar a lista", "rationale": "Você nunca abriu.",
                "actions": [
                  {"kind": "learnSender", "address": "News@Zoho.com"},
                  {"kind": "reserveBlock", "day": 0, "startMinute": 780, "minutes": 20, "title": "Responder"},
                  {"kind": "reply", "messageID": "m1", "draft": "Oi."}
                ]}
             ]}
            """
        let reply = try JSONDecoder().decode(AssistantReply.self, from: Data(json.utf8))
        #expect(reply.text == "Olha o dia.")
        let propostas = reply.assistantProposals
        #expect(propostas.count == 1)
        #expect(propostas[0].actions == [
            .learnSender(address: "News@Zoho.com"),
            .reserveBlock(day: 0, startMinute: 780, minutes: 20, title: "Responder"),
            .reply(messageID: "m1", draft: "Oi."),
        ])
    }

    @Test("ação de tipo desconhecido derruba a proposta inteira")
    func unknownKindDropsProposal() {
        let texto = """
            ```okami-actions
            {"proposals": [{"title": "Apagar", "rationale": "r", "actions": [{"kind": "deleteForever", "messageID": "m1"}]}]}
            ```
            """
        #expect(AssistantActionsBlock.parse(texto).proposals.isEmpty)
    }

    // MARK: - O validador

    private func proposta(_ actions: [AssistantAction]) -> AssistantProposal {
        AssistantProposal(title: "Título", actions: actions, rationale: "Porque sim.")
    }

    @Test("id fora do contexto descarta a proposta inteira")
    func rejectsUnknownMessageID() {
        let validas = AssistantProposalValidator.validate(
            [proposta([.archive(messageID: "m1"), .archive(messageID: "intruso")])],
            messageIDs: ["m1"],
            messageIDsWithEvent: []
        )
        #expect(validas.isEmpty)
    }

    @Test("proposta só com ids do contexto sobrevive")
    func keepsKnownMessageIDs() {
        let validas = AssistantProposalValidator.validate(
            [proposta([.archive(messageID: "m1"), .markRead(messageID: "m2")])],
            messageIDs: ["m1", "m2"],
            messageIDsWithEvent: []
        )
        #expect(validas.count == 1)
    }

    @Test("addToAgenda sem compromisso persistido descarta")
    func rejectsAddToAgendaWithoutEvent() {
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.addToAgenda(messageID: "m1")])],
                messageIDs: ["m1"], messageIDsWithEvent: []
            ).isEmpty
        )
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.addToAgenda(messageID: "m1")])],
                messageIDs: ["m1"], messageIDsWithEvent: ["m1"]
            ).count == 1
        )
    }

    @Test("rascunho vazio não é resposta")
    func rejectsEmptyDraft() {
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.reply(messageID: "m1", draft: "   \n ")])],
                messageIDs: ["m1"], messageIDsWithEvent: []
            ).isEmpty
        )
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.reply(messageID: "m1", draft: "Oi, Jack.")])],
                messageIDs: ["m1"], messageIDsWithEvent: []
            ).count == 1
        )
    }

    @Test("reservar bloco com minutos ≤ 0 descarta")
    func rejectsEmptyBlock() {
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.reserveBlock(day: 0, startMinute: 600, minutes: 0, title: "X")])],
                messageIDs: [], messageIDsWithEvent: []
            ).isEmpty
        )
    }

    @Test("reservar bloco fora do expediente descarta")
    func rejectsBlockOutsideWorkday() {
        // 07:00, antes das 9h.
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.reserveBlock(day: 0, startMinute: 420, minutes: 30, title: "X")])],
                messageIDs: [], messageIDsWithEvent: []
            ).isEmpty
        )
        // Começa às 17:50 e passa das 18h.
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.reserveBlock(day: 0, startMinute: 1070, minutes: 30, title: "X")])],
                messageIDs: [], messageIDsWithEvent: []
            ).isEmpty
        )
        // Dia no passado.
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.reserveBlock(day: -1, startMinute: 600, minutes: 30, title: "X")])],
                messageIDs: [], messageIDsWithEvent: []
            ).isEmpty
        )
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.reserveBlock(day: 1, startMinute: 600, minutes: 30, title: "Responder")])],
                messageIDs: [], messageIDsWithEvent: []
            ).count == 1
        )
    }

    @Test("bloco sem título descarta — a agenda não recebe linha em branco")
    func rejectsBlockWithoutTitle() {
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.reserveBlock(day: 0, startMinute: 600, minutes: 30, title: "  ")])],
                messageIDs: [], messageIDsWithEvent: []
            ).isEmpty
        )
    }

    @Test("aprender remetente sem endereço descarta")
    func rejectsEmptySender() {
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.learnSender(address: "sem-arroba")])],
                messageIDs: [], messageIDsWithEvent: []
            ).isEmpty
        )
        #expect(
            AssistantProposalValidator.validate(
                [proposta([.learnSender(address: "news@zoho.com")])],
                messageIDs: [], messageIDsWithEvent: []
            ).count == 1
        )
    }

    @Test("proposta sem ação nenhuma não vira cartão")
    func rejectsEmptyProposal() {
        #expect(
            AssistantProposalValidator.validate(
                [proposta([])], messageIDs: ["m1"], messageIDsWithEvent: []
            ).isEmpty
        )
    }

    @Test("uma proposta inválida não leva as outras junto")
    func keepsValidNeighbours() {
        let validas = AssistantProposalValidator.validate(
            [
                proposta([.archive(messageID: "intruso")]),
                proposta([.archive(messageID: "m1")]),
            ],
            messageIDs: ["m1"], messageIDsWithEvent: []
        )
        #expect(validas.count == 1)
        #expect(validas[0].actions == [.archive(messageID: "m1")])
    }

    @Test("a lista fechada não tem enviar, apagar nem RSVP")
    func allowlistIsClosed() {
        let nomes = Set(AssistantAction.allKinds)
        #expect(!nomes.contains("send"))
        #expect(!nomes.contains("delete"))
        #expect(!nomes.contains("deleteForever"))
        #expect(!nomes.contains("emptyTrash"))
        #expect(!nomes.contains("rsvp"))
        #expect(nomes == [
            "archive", "moveToLater", "moveToToday", "markRead", "flag",
            "reply", "addToAgenda", "openMessage", "learnSender", "reserveBlock",
        ])
    }
}
