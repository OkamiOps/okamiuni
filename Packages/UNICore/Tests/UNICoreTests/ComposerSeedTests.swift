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

    /// Promover pela "⤢" não pode perder nada do que a faixa capturou.
    ///
    /// A faixa grava `to`, `cc`, `bcc`, corpo e anexos (`QuickReplyBand`
    /// .currentDraft), e a janela 03 desenha os cinco. Enquanto o seed só
    /// carregava `to`, `subject` e o corpo, promover apagava em silêncio quem
    /// estava em cópia e o anexo escolhido — a pessoa apertava Enviar achando
    /// que o jurídico estava na linha.
    @Test("a promoção carrega cc, cco e anexos, e não só o destinatário e o corpo")
    func carriesEverythingTheBandCaptures() {
        let juridico = Contact(name: "Jurídico", address: "juridico@empresa.com")
        let financeiro = Contact(name: "Financeiro", address: "fin@empresa.com")
        let draft = ReplyDraft(
            to: [Self.outro],
            cc: [juridico],
            bcc: [financeiro],
            body: AttributedString("texto"),
            attachments: ["contrato-v4.docx", "anexo-2.pdf"]
        )
        let seed = ComposerSeed.reply(to: Self.message(), draft: draft)

        #expect(seed.to == [Self.outro])
        #expect(seed.cc == [juridico])
        #expect(seed.bcc == [financeiro])
        #expect(seed.attachments == ["contrato-v4.docx", "anexo-2.pdf"])
        #expect(seed.body == "texto")
    }

    /// Um rascunho **só** com gente em cópia e um anexo não tem texto nenhum, e
    /// mesmo assim não pode ser tratado como "sem rascunho": `ReplyDraft.isEmpty`
    /// já conta cc, cco e anexo, e o seed tem de concordar com ele.
    @Test("rascunho sem texto, só com cópia e anexo, ainda atravessa")
    func copiesSurviveWithoutText() {
        let juridico = Contact(name: "Jurídico", address: "juridico@empresa.com")
        let draft = ReplyDraft(to: [], cc: [juridico], attachments: ["contrato-v4.docx"])
        #expect(draft.isEmpty == false)

        let seed = ComposerSeed.reply(to: Self.message(), draft: draft)
        // Sem destinatário no rascunho o remetente da mensagem continua valendo.
        #expect(seed.to == [Self.message().from])
        #expect(seed.cc == [juridico])
        #expect(seed.attachments == ["contrato-v4.docx"])
    }

    /// Sem rascunho não há cópia nem anexo para inventar.
    @Test("sem rascunho, cc, cco e anexos nascem vazios")
    func withoutDraftThereAreNoCopies() {
        let seed = ComposerSeed.reply(to: Self.message(), draft: nil)
        #expect(seed.cc.isEmpty)
        #expect(seed.bcc.isEmpty)
        #expect(seed.attachments.isEmpty)
    }
}
