import Foundation
import Testing

@testable import UNICore

@Suite("ReadyDraft e SenderRule")
struct ReadyDraftTests {

    private func mensagem(assunto: String = "Assunto", corpo: [String] = ["Corpo"]) -> Message {
        Message(
            id: "m1", accountID: "gmail",
            from: Contact(name: "Jack Whitmore", address: "jack@whitmore.dev"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: assunto, snippet: "Trecho", body: corpo,
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil
        )
    }

    @Test("o hash é o mesmo em duas chamadas e muda quando o texto muda")
    func hashIsStableAndSensitive() {
        let original = mensagem()
        #expect(
            ReadyDraft.contentHash(for: original) == ReadyDraft.contentHash(for: original)
        )
        #expect(
            ReadyDraft.contentHash(for: original)
                != ReadyDraft.contentHash(for: mensagem(corpo: ["Outro corpo"]))
        )
    }

    @Test("marcar como lida não invalida o rascunho")
    func readingDoesNotInvalidate() {
        let original = mensagem()
        let rascunho = ReadyDraft(
            messageID: original.id, text: "Oi.",
            contentHash: ReadyDraft.contentHash(for: original), modelVersion: "fm"
        )
        #expect(rascunho.matches(original.withRead(false)))
    }

    @Test("a prévia pula a saudação e pega a frase que decide")
    func firstSentenceSkipsTheGreeting() {
        let rascunho = ReadyDraft(
            messageID: "m1",
            text: "Oi Jack,\n\nSim — hoje a página exige login. Libero até sexta."
                + "\n\nAbraço,\nMarcos",
            contentHash: "x", modelVersion: "fm"
        )
        #expect(rascunho.firstSentence == "Sim — hoje a página exige login.")
    }

    @Test("a regra compara o endereço sem caixa nem espaço")
    func ruleNormalizesTheAddress() {
        let regra = SenderRule(
            address: "  Carol@Zoho.Example  ", createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(regra.normalizedAddress == "carol@zoho.example")
        #expect(SenderRule.silences([regra], address: "CAROL@zoho.example"))
        #expect(SenderRule.silences([regra], address: "outra@zoho.example") == false)
    }

    @Test("regra desligada não cala ninguém")
    func disabledRuleSilencesNobody() {
        let regra = SenderRule(
            address: "carol@zoho.example", neverPriority: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(SenderRule.silences([regra], address: "carol@zoho.example") == false)
    }
}
