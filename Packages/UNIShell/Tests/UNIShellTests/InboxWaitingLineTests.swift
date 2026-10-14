import Foundation
import Testing
import UNICore
@testable import UNIShell

/// A frase de acento da linha de vidro e a seção em que ela cai.
///
/// Nada aqui monta janela: o que a pessoa lê é comportamento, e o tipo que o
/// decide é puro.
@Suite("Linha da IA na Caixa de vidro")
struct InboxWaitingLineTests {

    private let hoje = Date(timeIntervalSince1970: 1_800_000_000)

    private func mensagem(
        triage: MessageTriage? = nil,
        tags: [UNICore.Tag] = [],
        id: String = "m"
    ) -> Message {
        Message(
            id: id, accountID: "c1",
            from: Contact(name: "Marina", address: "marina@cliente.com"),
            receivedAt: hoje, subject: "Contrato", snippet: "Trecho",
            body: [], tags: tags, bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil, triage: triage
        )
    }

    private func triagem(
        needsReply: Bool, deadline: Date? = nil
    ) -> MessageTriage {
        MessageTriage(
            needsReply: needsReply, intent: .request, urgency: .normal,
            deadline: deadline.map { DetectedDeadline(date: $0, evidence: "até quinta") }
        )
    }

    @Test("a triagem guardada decide quem espera resposta")
    func triageDecides() {
        #expect(InboxWaitingLine.waitsForYou(mensagem(triage: triagem(needsReply: true))))
        #expect(!InboxWaitingLine.waitsForYou(mensagem(triage: triagem(needsReply: false))))
    }

    /// **A mutação:** tirar a saída pela etiqueta faz a seção "Esperando você"
    /// nascer vazia em toda mensagem sem análise guardada — que é o caso de
    /// todas as fixtures, e portanto de todos os retratos.
    @Test("sem triagem, a etiqueta de sempre ainda responde")
    func legacyTagAnswers() {
        let comEtiqueta = mensagem(tags: [UNICore.Tag(name: InboxWaitingLine.legacyNeedsReplyTag, tintHex: nil)])
        #expect(InboxWaitingLine.waitsForYou(comEtiqueta))
        #expect(!InboxWaitingLine.waitsForYou(mensagem(tags: [UNICore.Tag(name: "Leitura", tintHex: nil)])))
    }

    /// A triagem **vence** a etiqueta: um "não precisa resposta" analisado não
    /// pode ser desmentido por uma etiqueta antiga pendurada na mensagem.
    @Test("a triagem vence a etiqueta quando as duas existem")
    func triageWinsOverTag() {
        let m = mensagem(
            triage: triagem(needsReply: false),
            tags: [UNICore.Tag(name: InboxWaitingLine.legacyNeedsReplyTag, tintHex: nil)]
        )
        #expect(!InboxWaitingLine.waitsForYou(m))
    }

    @Test("sem prazo, a frase é 'Precisa de resposta'")
    func phraseWithoutDeadline() {
        let frase = InboxWaitingLine.phrase(
            for: mensagem(triage: triagem(needsReply: true)),
            hasReadyDraft: false, today: hoje
        )
        #expect(frase == "Precisa de resposta")
    }

    @Test("com rascunho pronto, a frase diz que ele existe")
    func phraseWithDraft() throws {
        let frase = try #require(InboxWaitingLine.phrase(
            for: mensagem(triage: triagem(needsReply: true)),
            hasReadyDraft: true, today: hoje
        ))
        #expect(frase.hasSuffix("resposta pronta"))
    }

    @Test("o prazo de hoje e o de amanhã têm nome, e não data")
    func deadlineLabels() {
        let amanha = Calendar.current.date(byAdding: .day, value: 1, to: hoje)!
        #expect(InboxWaitingLine.deadlineLabel(hoje, today: hoje) == "hoje")
        #expect(InboxWaitingLine.deadlineLabel(amanha, today: hoje) == "amanhã")
    }

    @Test("sem precisar de resposta, um prazo ainda vira frase")
    func deadlineOnlyPhrase() throws {
        let frase = try #require(InboxWaitingLine.phrase(
            for: mensagem(triage: triagem(needsReply: false, deadline: hoje)),
            hasReadyDraft: false, today: hoje
        ))
        #expect(frase == "Prazo hoje")
    }

    /// Sem triagem e sem etiqueta não há o que dizer — e pôr ✦ em cima de um
    /// palpite seria pior do que não dizer nada.
    @Test("mensagem sem sinal nenhum não ganha linha de IA")
    func silentWhenNothingToSay() {
        #expect(InboxWaitingLine.phrase(for: mensagem(), hasReadyDraft: false, today: hoje) == nil)
    }

    @Test("a lista parte em duas, cada metade na ordem que veio")
    func splitKeepsOrder() {
        let espera = mensagem(triage: triagem(needsReply: true), id: "a")
        let resto1 = mensagem(triage: triagem(needsReply: false), id: "b")
        let resto2 = mensagem(triage: triagem(needsReply: false), id: "c")
        let conversas = Conversation.build(from: [resto1, espera, resto2])
        let partes = InboxWaitingLine.split(conversas)
        #expect(partes.waiting.map { $0.latest.id } == ["a"])
        #expect(partes.rest.map { $0.latest.id } == ["b", "c"])
    }
}
