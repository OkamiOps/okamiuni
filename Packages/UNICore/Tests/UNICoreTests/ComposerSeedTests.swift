import Foundation
import Testing
@testable import UNICore

/// A emenda entre a faixa de resposta rápida do leitor e a janela 03.
///
/// O "⤢" da faixa grava o rascunho **antes** de abrir a janela. Se a janela
/// nascer ignorando isso, a pessoa escreve três frases, clica para continuar na
/// janela grande e ela abre vazia — perder o que ela escreveu é pior do que não
/// ter o botão.
@Suite("Semente da janela de resposta")
struct ComposerSeedTests {

    /// Remetente de um domínio que não existe nas fixtures: se alguma regra
    /// filtrasse por conta ou provedor, este sumiria.
    private static func message(subject: String = "Revisão do contrato") -> Message {
        Message(
            id: "m-origem", accountID: "qualquer",
            from: Contact(name: "Yuki Tanaka", address: "yuki@example.co.jp"),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: subject, snippet: "", body: [], tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil
        )
    }

    private static let outro = Contact(name: "Ana Ø", address: "ana@nordisk.no")

    @Test("sem rascunho, a janela nasce no padrão: remetente e Re: do assunto")
    func withoutDraftUsesTheDefault() {
        let seed = ComposerSeed.reply(to: Self.message(), draft: nil)

        #expect(seed.to == [Contact(name: "Yuki Tanaka", address: "yuki@example.co.jp")])
        #expect(seed.subject == "Re: Revisão do contrato")
        #expect(seed.body == "")
    }

    @Test("com rascunho, o que a pessoa escreveu na faixa sobe para a janela")
    func draftWins() {
        let draft = ReplyDraft(to: [Self.outro], text: "Ana, fechado para quinta.")
        let seed = ComposerSeed.reply(to: Self.message(), draft: draft)

        #expect(seed.to == [Self.outro])
        #expect(seed.body == "Ana, fechado para quinta.")
        // O assunto continua saindo da mensagem: a faixa não tem campo de
        // assunto para sobrescrevê-lo. Literal de propósito — comparar com
        // `"Re: \(message.subject)"` passaria mesmo com o prefixo errado.
        #expect(seed.subject == "Re: Revisão do contrato")
    }

    @Test("rascunho com texto e sem destinatário não apaga o remetente")
    func draftWithoutRecipientKeepsTheSender() {
        let draft = ReplyDraft(to: [], text: "Escrevi antes de escolher para quem.")
        let seed = ComposerSeed.reply(to: Self.message(), draft: draft)

        #expect(seed.to == [Self.message().from])
        #expect(seed.body == "Escrevi antes de escolher para quem.")
    }

    @Test("rascunho só com destinatário sobe o destinatário e deixa o corpo vazio")
    func draftWithoutTextKeepsTheRecipient() {
        let draft = ReplyDraft(to: [Self.outro], text: "")
        let seed = ComposerSeed.reply(to: Self.message(), draft: draft)

        #expect(seed.to == [Self.outro])
        #expect(seed.body == "")
    }

    @Test("rascunho vazio é como não ter rascunho")
    func emptyDraftIsNoDraft() {
        let seed = ComposerSeed.reply(to: Self.message(), draft: ReplyDraft())
        #expect(seed.to == [Self.message().from])
        #expect(seed.body == "")
    }

    /// Um rascunho só com espaços conta como sem texto pelo `hasText` do
    /// `ReplyDraft` — mas ele traz destinatário, então não é descartado.
    @Test("espaço em branco não vale como texto, mas o destinatário continua valendo")
    func whitespaceIsNotText() {
        let draft = ReplyDraft(to: [Self.outro], text: "   \n  ")
        let seed = ComposerSeed.reply(to: Self.message(), draft: draft)

        #expect(seed.to == [Self.outro])
        #expect(draft.hasText == false)
    }

    /// Mensagem sem assunto não vira "Re: " pendurado. `windowTitle` já resolve
    /// esse caso devolvendo "Nova mensagem"; o campo Assunto tem de concordar,
    /// senão a janela mostra um título e um campo que se contradizem.
    @Test("mensagem sem assunto não gera um Re: solto no campo")
    func emptySubjectDoesNotDangle() {
        let seed = ComposerSeed.reply(to: Self.message(subject: ""), draft: nil)
        #expect(seed.subject == "")
    }
}
