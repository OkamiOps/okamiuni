import Foundation
import Testing
@testable import UNICore

/// A tradução "proposta → cartão → efeito". É a peça que decide o que sai
/// pela fila do app quando alguém clica no verbo de um cartão da gaveta, e
/// por isso ela é pura e mora aqui, e não dentro de uma `View`.
@Suite("Cartão de ação do assistente")
struct AssistantProposalCardTests {

    private func proposta(
        _ title: String, _ actions: [AssistantAction], _ why: String = "porque sim"
    ) -> AssistantProposal {
        AssistantProposal(title: title, actions: actions, rationale: why)
    }

    // MARK: - Que cartão para qual proposta

    @Test("o verbo do botão vem da primeira ação da leva")
    func verbComesFromTheFirstAction() {
        let cartoes = AssistantProposalCard.cards(
            for: [proposta("Arquivar e aprender", [
                .archive(messageID: "m1"), .learnSender(address: "a@b.com"),
            ])],
            turnID: "t1"
        )
        #expect(cartoes.count == 1)
        #expect(cartoes[0].verb == "Arquivar")
    }

    @Test("cada ação tem o verbo dela, e nenhum deles é Enviar", arguments: [
        (AssistantAction.archive(messageID: "m"), "Arquivar"),
        (.moveToLater(messageID: "m"), "Depois"),
        (.moveToToday(messageID: "m"), "Trazer para hoje"),
        (.markRead(messageID: "m"), "Marcar como lida"),
        (.flag(messageID: "m"), "Sinalizar"),
        (.reply(messageID: "m", draft: "oi"), "Responder"),
        (.addToAgenda(messageID: "m"), "Agendar"),
        (.openMessage(messageID: "m"), "Abrir"),
        (.learnSender(address: "a@b.com"), "Aprender"),
        (.reserveBlock(day: 0, startMinute: 780, minutes: 20, title: "Responder"), "Reservar"),
    ])
    func everyActionHasItsVerb(action: AssistantAction, expected: String) {
        let verbo = AssistantProposalCard.verb(for: action)
        #expect(verbo == expected)
        #expect(verbo != "Enviar", "o verbo do cartão nunca promete envio")
    }

    /// O mockup escreve "Enviar" no cartão do rascunho pronto. O `.reply`
    /// abre o composer e **não** envia — um botão "Enviar" que abre janela é
    /// um botão que mente. Ver a divergência no relatório.
    @Test("o cartão do rascunho diz Responder, e o efeito é abrir o composer")
    func replyOpensTheComposerAndSaysSo() throws {
        let cartao = try #require(
            AssistantProposalCard.cards(
                for: [proposta("Resposta pronta", [.reply(messageID: "m1", draft: "Oi")])],
                turnID: "t1"
            ).first
        )
        #expect(cartao.verb == "Responder")
        #expect(cartao.effects == [.command(.reply(messageID: "m1"))])
    }

    @Test("uma mensagem dá Ver; várias dão Ver a lista; nenhuma não dá secundário")
    func theSecondaryLabelCountsMessages() throws {
        let uma = try #require(AssistantProposalCard.cards(
            for: [proposta("Arquivar", [.archive(messageID: "m1")])], turnID: "t"
        ).first)
        #expect(uma.secondary == "Ver")
        #expect(uma.secondaryMessageID == "m1")

        let varias = try #require(AssistantProposalCard.cards(
            for: [proposta("13 emails", [
                .archive(messageID: "m1"), .archive(messageID: "m2"),
            ])], turnID: "t"
        ).first)
        #expect(varias.secondary == "Ver a lista")

        let nenhuma = try #require(AssistantProposalCard.cards(
            for: [proposta("Reservar", [
                .reserveBlock(day: 0, startMinute: 960, minutes: 45, title: "Proposta"),
            ])], turnID: "t"
        ).first)
        #expect(nenhuma.secondary == nil)
        #expect(nenhuma.secondaryMessageID == nil)
    }

    /// A **mesma** mensagem em duas ações continua sendo uma: "Arquivar e
    /// aprender" mostra "Ver", não "Ver a lista".
    @Test("a mesma mensagem em duas ações não vira lista")
    func repeatedMessageIsStillOne() throws {
        let cartao = try #require(AssistantProposalCard.cards(
            for: [proposta("Arquivar e aprender", [
                .archive(messageID: "m1"), .markRead(messageID: "m1"),
            ])], turnID: "t"
        ).first)
        #expect(cartao.secondary == "Ver")
    }

    @Test("proposta sem ação nenhuma não vira cartão")
    func emptyProposalIsNotACard() {
        #expect(AssistantProposalCard.cards(
            for: [proposta("Nada a fazer", [])], turnID: "t"
        ).isEmpty)
    }

    @Test("dois turnos com a mesma proposta não colidem de identidade")
    func idsAreScopedToTheTurn() {
        let a = AssistantProposalCard.cards(
            for: [proposta("Arquivar", [.archive(messageID: "m1")])], turnID: "t1"
        )
        let b = AssistantProposalCard.cards(
            for: [proposta("Arquivar", [.archive(messageID: "m1")])], turnID: "t2"
        )
        #expect(a[0].id != b[0].id)
    }

    // MARK: - Quais ações uma proposta gera

    @Test("cada ação vira o comando da fila que já existe", arguments: [
        (
            AssistantAction.archive(messageID: "m"),
            [AssistantProposalCard.Effect.command(.move(messageID: "m", to: .archived))]
        ),
        (.moveToLater(messageID: "m"), [.command(.move(messageID: "m", to: .later))]),
        (.moveToToday(messageID: "m"), [.command(.move(messageID: "m", to: .today))]),
        (.markRead(messageID: "m"), [.command(.setRead(messageID: "m", isRead: true))]),
        (.flag(messageID: "m"), [.command(.setFlagged(messageID: "m", isFlagged: true))]),
        (.openMessage(messageID: "m"), [.command(.revealMessage(messageID: "m"))]),
        (
            .learnSender(address: "a@b.com"),
            [.command(.learnSender(address: "a@b.com", neverPriority: true))]
        ),
        (.addToAgenda(messageID: "m"), [.addToAgenda(messageID: "m")]),
        (
            .reserveBlock(day: 1, startMinute: 540, minutes: 45, title: "Proposta"),
            [.reserveBlock(day: 1, startMinute: 540, minutes: 45, title: "Proposta")]
        ),
    ])
    func actionsBecomeCommands(
        action: AssistantAction, expected: [AssistantProposalCard.Effect]
    ) {
        #expect(AssistantProposalCard.effects(of: action) == expected)
    }

    /// A leva inteira, na ordem: "Arquivar e aprender" é `.move` **e**
    /// `.learnSender`, e é isso que o `ActionReceipts` pareia num recibo só.
    @Test("a leva sai inteira, na ordem em que a proposta a escreveu")
    func theWholeBatchComesOutInOrder() throws {
        let cartao = try #require(AssistantProposalCard.cards(
            for: [proposta("Arquivar e aprender", [
                .archive(messageID: "m1"), .learnSender(address: "no-reply@abacus.ai"),
            ])], turnID: "t"
        ).first)
        #expect(cartao.effects == [
            .command(.move(messageID: "m1", to: .archived)),
            .command(.learnSender(address: "no-reply@abacus.ai", neverPriority: true)),
        ])
    }

    /// **A porta de envio não existe neste caminho.** O vocabulário do modelo
    /// não tem "enviar" (`allKinds`), e nenhuma tradução daqui produz um
    /// comando que ponha mensagem na fila de saída.
    @Test("nenhum efeito de nenhuma ação encosta na saída")
    func nothingHereSends() {
        let todas: [AssistantAction] = [
            .archive(messageID: "m"), .moveToLater(messageID: "m"),
            .moveToToday(messageID: "m"), .markRead(messageID: "m"),
            .flag(messageID: "m"), .reply(messageID: "m", draft: "oi"),
            .addToAgenda(messageID: "m"), .openMessage(messageID: "m"),
            .learnSender(address: "a@b.com"),
            .reserveBlock(day: 0, startMinute: 780, minutes: 20, title: "t"),
        ]
        #expect(!AssistantAction.allKinds.contains("send"))
        for acao in todas {
            for efeito in AssistantProposalCard.effects(of: acao) {
                guard case let .command(comando) = efeito else { continue }
                // A lista fechada do que a gaveta pode emitir. Um caso novo
                // aqui é uma decisão, não um descuido.
                switch comando {
                case .move, .setRead, .setFlagged, .reply, .revealMessage, .learnSender:
                    break
                default:
                    Issue.record("a gaveta emitiu \(comando), fora da lista fechada")
                }
            }
        }
    }

    // MARK: - O que o validador jogou fora não vira cartão

    /// A costura inteira, do texto cru ao cartão: das duas propostas que o
    /// modelo escreveu, a que cita uma mensagem fora do contexto é descartada
    /// pelo validador e **nunca** chega a virar botão.
    @Test("proposta descartada pelo validador não vira cartão")
    func discardedProposalNeverBecomesACard() {
        let bruto = """
            Duas coisas.

            ```okami-actions
            {"text":"Duas coisas.","proposals":[
              {"title":"Arquivar o disparo","rationale":"você nunca abriu",
               "actions":[{"kind":"archive","messageID":"m1"}]},
              {"title":"Arquivar o intruso","rationale":"não é seu",
               "actions":[{"kind":"archive","messageID":"intruso"}]}
            ]}
            ```
            """
        let lido = AssistantActionsBlock.answer(bruto)
        #expect(lido.proposals.count == 2)

        let validas = AssistantProposalValidator.validate(
            lido.proposals, messageIDs: ["m1"], messageIDsWithEvent: []
        )
        let cartoes = AssistantProposalCard.cards(for: validas, turnID: "t")
        #expect(cartoes.count == 1)
        #expect(cartoes[0].text == "Arquivar o disparo")
        #expect(cartoes.allSatisfy { !$0.effects.contains(.command(
            .move(messageID: "intruso", to: .archived)
        )) })
    }
}
