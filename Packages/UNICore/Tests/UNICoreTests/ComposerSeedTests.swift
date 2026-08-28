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
    private static func message(
        subject: String = "Revisão do contrato",
        to: [Contact] = [],
        cc: [Contact] = []
    ) -> Message {
        Message(
            id: "m-origem", accountID: "qualquer",
            from: Contact(name: "Yuki Tanaka", address: "yuki@example.co.jp"),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: subject, snippet: "", body: [], tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil,
            to: to, cc: cc
        )
    }

    private static let eu = Contact(name: "Ricardo", address: "Ricardo@Empresa.com")
    private static let time = Contact(name: "Time", address: "time@example.co.jp")

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

    // MARK: - Responder a todos

    @Test("responder a todos abre com remetente, «para» e cópia — menos a conta dona")
    func replyAllGathersEveryone() {
        let seed = ComposerSeed.replyAll(
            to: Self.message(to: [Self.eu, Self.time], cc: [Self.outro]),
            accountAddress: "ricardo@empresa.com"
        )

        #expect(seed.to.map(\.address) == [
            "yuki@example.co.jp",   // o remetente abre a lista
            "time@example.co.jp",
            "ana@nordisk.no",
        ])
        #expect(seed.subject == "Re: Revisão do contrato")
    }

    /// O endereço da conta chega em minúsculas do `Account`, mas o `to` da
    /// mensagem vem escrito como o remetente escreveu. Comparar sem dobrar a
    /// caixa devolveria o próprio usuário na linha "Para".
    @Test("a conta dona sai mesmo escrita com maiúsculas diferentes")
    func replyAllDropsOwnAddressCaseInsensitively() {
        let seed = ComposerSeed.replyAll(
            to: Self.message(to: [Self.eu]),
            accountAddress: "RICARDO@empresa.COM"
        )
        #expect(seed.to.map(\.address) == ["yuki@example.co.jp"])
    }

    @Test("quem aparece duas vezes entra uma só, na primeira posição")
    func replyAllDeduplicates() {
        let remetente = Contact(name: "Yuki", address: "YUKI@example.co.jp")
        let seed = ComposerSeed.replyAll(
            to: Self.message(to: [remetente, Self.time], cc: [Self.time]),
            accountAddress: "ricardo@empresa.com"
        )
        #expect(seed.to.count == 2)
        #expect(seed.to.first?.address == "yuki@example.co.jp")
    }

    /// A pergunta que decide se o item de menu acende. Zero quer dizer que
    /// responder a todos daria exatamente a mesma janela que responder.
    @Test("«quantos a mais» é zero numa mensagem que só tem remetente")
    func replyAllExtrasCountsTheDifference() {
        let sozinha = Self.message()
        #expect(ComposerSeed.replyAllExtras(sozinha, accountAddress: "ricardo@empresa.com") == 0)

        let acompanhada = Self.message(to: [Self.eu, Self.time], cc: [Self.outro])
        #expect(
            ComposerSeed.replyAllExtras(acompanhada, accountAddress: "ricardo@empresa.com") == 2
        )
    }

    @Test("um endereço vazio no `to` não vira destinatário fantasma")
    func replyAllSkipsEmptyAddresses() {
        let vazio = Contact(name: "Sem endereço", address: "")
        let seed = ComposerSeed.replyAll(
            to: Self.message(to: [vazio]), accountAddress: ""
        )
        #expect(seed.to.map(\.address) == ["yuki@example.co.jp"])
    }

    // MARK: - Encaminhar

    @Test("encaminhar abre sem destinatário: para quem vai é a metade que a pessoa faz")
    func forwardHasNoRecipient() {
        let seed = ComposerSeed.forward(of: Self.message(to: [Self.eu]), dateLabel: "Terça")
        #expect(seed.to.isEmpty)
        #expect(seed.cc.isEmpty)
    }

    @Test("o assunto é «Enc: », e assunto vazio não vira «Enc: » pendurado")
    func forwardSubject() {
        #expect(ComposerSeed.forward(of: Self.message(), dateLabel: "").subject
            == "Enc: Revisão do contrato")
        #expect(ComposerSeed.forward(of: Self.message(subject: ""), dateLabel: "").subject == "")
    }

    /// Encaminhar sem o conteúdo é encaminhar nada.
    @Test("o corpo vem citado, com remetente, data e assunto no cabeçalho")
    func forwardQuotesTheBody() {
        let original = Message(
            id: "m-origem", accountID: "qualquer",
            from: Contact(name: "Yuki Tanaka", address: "yuki@example.co.jp"),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: "Revisão", snippet: "", body: ["Primeiro", "Segundo"], tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil,
            to: [Self.eu]
        )
        let lines = ComposerSeed.forward(of: original, dateLabel: "Terça, 25 de agosto")
            .body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Duas linhas em branco antes da citação: é onde o cursor escreve.
        #expect(lines[0] == "")
        #expect(lines[1] == "")
        #expect(lines[2] == "---------- Mensagem encaminhada ----------")
        #expect(lines[3] == "De: Yuki Tanaka · yuki@example.co.jp")
        #expect(lines[4] == "Data: Terça, 25 de agosto")
        #expect(lines[5] == "Assunto: Revisão")
        #expect(lines[6] == "Para: Ricardo · Ricardo@Empresa.com")
        #expect(lines.last == "Segundo")
    }

    /// Linha sem conteúdo não é escrita em branco — a mesma regra do convite
    /// copiado da agenda.
    @Test("sem data e sem «para», o cabeçalho não ganha linhas vazias")
    func forwardSkipsEmptyHeaderLines() {
        let text = ComposerSeed.forward(of: Self.message(subject: ""), dateLabel: "").body
        #expect(!text.contains("Data:"))
        #expect(!text.contains("Para:"))
        #expect(!text.contains("Assunto:"))
    }
}

@Suite("A intenção que a cena da janela 03 carrega")
struct ComposerRouteTests {
    @Test("responder não tem prefixo: todo valor antigo continua significando o mesmo")
    func replyKeepsTheBareID() {
        #expect(ComposerRoute.reply(messageID: "m1").value == "m1")
        #expect(ComposerRoute.parse("m1") == .reply(messageID: "m1"))
    }

    @Test("responder a todos e responder à mesma mensagem são duas janelas")
    func replyAllHasItsOwnValue() {
        let todos = ComposerRoute.replyAll(messageID: "m1")
        #expect(todos.value != ComposerRoute.reply(messageID: "m1").value)
        #expect(ComposerRoute.parse(todos.value) == todos)
        #expect(todos.messageID == "m1")
    }

    /// Uma cena restaurada pelo sistema pode chegar sem valor nenhum.
    @Test("valor vazio é uma resposta simples sem mensagem, nunca um travamento")
    func emptyValueParsesAsReply() {
        #expect(ComposerRoute.parse("") == .reply(messageID: ""))
    }

    @Test("as três intenções vão e voltam sem se confundirem")
    func everyRouteSurvivesTheRoundTrip() {
        let rotas: [ComposerRoute] = [
            .reply(messageID: "m1"), .replyAll(messageID: "m1"), .forward(messageID: "m1"),
        ]
        #expect(Set(rotas.map(\.value)).count == 3)
        for rota in rotas {
            #expect(ComposerRoute.parse(rota.value) == rota)
            #expect(rota.messageID == "m1")
        }
    }
}