import Foundation

/// Com o que a janela de resposta nasce.
///
/// Vive aqui, e não dentro da `View`, porque no Swift 6 um `View` é
/// implicitamente `@MainActor` e um `static` dentro dele herda o isolamento —
/// um teste nonisolated que o chamasse trapava em runtime. Já aconteceu nesta
/// base; ver `docs/decisoes-de-engenharia.md`.
public struct ComposerSeed: Sendable, Hashable {
    public let to: [Contact]
    /// Cópia e cópia oculta, e os anexos.
    ///
    /// Existem aqui porque a faixa de resposta do leitor captura os três — os
    /// botões "Cc"/"Cco" e o 📎 gravam em `ReplyDraft` — e a janela cheia
    /// desenha os três. Enquanto o seed não os carregava, promover pelo "⤢"
    /// apagava em silêncio quem estava em cópia e o anexo escolhido: a pessoa
    /// apertava Enviar achando que o jurídico estava na linha. É a mesma classe
    /// de perda que `body` documenta para a formatação, pela outra porta.
    public let cc: [Contact]
    public let bcc: [Contact]
    /// Os anexos, pelo nome — o Marco 1 não copia arquivo nenhum, é a mesma
    /// lista de exemplo que a janela 03 usa.
    public let attachments: [String]
    public let subject: String
    /// O corpo em texto simples — a projeção de `rich`.
    ///
    /// Continua existindo porque é o que `ComposerWindow` lê hoje. Enquanto
    /// for **este** campo que a janela usa, promover uma resposta formatada
    /// pelo "⤢" chega lá **sem** negrito, sem cor e sem realce: `String` não
    /// carrega atributo nenhum. Ver o relatório da Task Z.
    public let body: String
    /// O corpo **rico**, que é o que a faixa de resposta de fato guarda desde
    /// que ela ganhou barra de formatação. Uma linha em `ComposerWindow.seed()`
    /// (`draft = seed.rich` no lugar de `AttributedString(seed.body)`) fecha a
    /// perda acima.
    public let rich: AttributedString

    public init(
        to: [Contact],
        cc: [Contact] = [],
        bcc: [Contact] = [],
        attachments: [String] = [],
        subject: String,
        body: String
    ) {
        self.init(
            to: to, cc: cc, bcc: bcc, attachments: attachments,
            subject: subject, rich: AttributedString(body)
        )
    }

    public init(
        to: [Contact],
        cc: [Contact] = [],
        bcc: [Contact] = [],
        attachments: [String] = [],
        subject: String,
        rich: AttributedString
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.attachments = attachments
        self.subject = subject
        self.rich = rich
        self.body = String(rich.characters)
    }

    /// Resolve o estado inicial de uma resposta.
    ///
    /// O rascunho vem da faixa embutida no leitor, que grava antes de promover
    /// para a janela cheia. Quando ele existe e tem conteúdo, vence o padrão —
    /// abrir a janela vazia perderia o que a pessoa escreveu, que é pior que
    /// não ter o botão de promover.
    ///
    /// Um rascunho **sem** destinatário não apaga o remetente da mensagem: a
    /// pessoa pode ter escrito o texto e ainda não escolhido para quem vai.
    public static func reply(to message: Message, draft: ReplyDraft?) -> ComposerSeed {
        // Mensagem sem assunto não vira "Re: " pendurado. `ComposerWindow`
        // .windowTitle já trata esse caso devolvendo "Nova mensagem"; o campo
        // Assunto tem de concordar, senão o título e o campo se contradizem na
        // mesma janela.
        let subject = message.subject.isEmpty ? "" : "Re: \(message.subject)"
        guard let draft, !draft.isEmpty else {
            return ComposerSeed(to: [message.from], subject: subject, body: "")
        }
        return ComposerSeed(
            to: draft.to.isEmpty ? [message.from] : draft.to,
            cc: draft.cc,
            bcc: draft.bcc,
            attachments: draft.attachments,
            subject: subject,
            rich: draft.body
        )
    }

    /// "Responder a todos": o remetente **mais** todo mundo que estava em
    /// `to` e `cc`, menos a conta que respondeu.
    ///
    /// - A conta dona sai por endereço, sem distinguir maiúsculas (`Contact.id`
    ///   já é o endereço em minúsculas). Responder a todos e mandar um email
    ///   para si mesmo é o defeito clássico desta ação.
    /// - Repetido entra uma vez só, e a **primeira** posição vence: o remetente
    ///   abre a lista, como em qualquer cliente.
    /// - `cc` do seed fica vazio de propósito. Gmail e Mail devolvem os
    ///   copiados na linha Cc; aqui a janela 03 só tem uma linha aberta por
    ///   padrão, e esconder metade dos destinatários numa linha recolhida é a
    ///   perda em silêncio que `ComposerSeed.cc` documenta. Todos ficam
    ///   visíveis em "Para".
    ///
    /// Sem `to` nem `cc` a lista resultante é só o remetente — igual a
    /// "Responder". É por isso que quem monta o menu **não** oferece o item
    /// nesse caso: ver `ContextMenus.replyAllItem`.
    public static func replyAll(
        to message: Message,
        accountAddress: String,
        draft: ReplyDraft? = nil
    ) -> ComposerSeed {
        let base = reply(to: message, draft: draft)
        let mine = accountAddress.lowercased()
        var seen: Set<String> = []
        var everyone: [Contact] = []
        for person in [message.from] + message.to + message.cc + base.to {
            guard person.id != mine, !person.address.isEmpty else { continue }
            guard seen.insert(person.id).inserted else { continue }
            everyone.append(person)
        }
        return ComposerSeed(
            to: everyone,
            cc: base.cc,
            bcc: base.bcc,
            attachments: base.attachments,
            subject: base.subject,
            rich: base.rich
        )
    }

    /// Quanta gente "Responder a todos" alcançaria além do remetente.
    ///
    /// É a pergunta que decide se o item entra aceso ou apagado, e ela é do
    /// modelo — não da tela. Zero quer dizer que responder a todos e responder
    /// dariam a mesma janela.
    public static func replyAllExtras(_ message: Message, accountAddress: String) -> Int {
        max(0, replyAll(to: message, accountAddress: accountAddress).to.count - 1)
    }

    /// "Encaminhar": o mesmo conteúdo, para quem a pessoa ainda vai escolher.
    ///
    /// Era a dívida registrada desde a revisão AG — a janela 03 só tinha
    /// `.reply` e `.new`, e um item chamado "Encaminhar" que abrisse uma
    /// resposta seria o botão mentiroso que a regra do marco proíbe.
    ///
    /// Três decisões, e cada uma é o contrário de uma resposta:
    ///
    /// - **"Para" nasce vazio.** Encaminhar sem escolher para quem é a metade
    ///   que a pessoa faz; adivinhar um destinatário aqui mandaria a mensagem
    ///   de volta para quem já a tem.
    /// - **O assunto é "Enc: "**, não "Re: " — e assunto vazio não vira "Enc: "
    ///   pendurado, pela mesma razão que `reply` documenta.
    /// - **O corpo já vem citado**, com remetente, data e assunto no cabeçalho,
    ///   porque encaminhar sem o conteúdo é encaminhar nada.
    ///
    /// `dateLabel` entra pronto, como em `AgendaAddReceipt.note`: formatar data
    /// aqui reintroduziria a conversão de fuso que esta base já pagou duas
    /// vezes. Quem chama usa `DateLabels.eventDate`, que é a mesma regra que o
    /// convite copiado da agenda usa.
    public static func forward(of message: Message, dateLabel: String) -> ComposerSeed {
        let subject = message.subject.isEmpty ? "" : "Enc: \(message.subject)"
        return ComposerSeed(to: [], subject: subject, body: quoted(message, dateLabel: dateLabel))
    }

    /// O corpo citado de um encaminhamento.
    ///
    /// Duas linhas em branco antes do cabeçalho: é onde o cursor começa a
    /// escrever, e sem elas o texto novo nasce colado na citação.
    ///
    /// Linha sem conteúdo não é escrita em branco — a mesma regra do convite
    /// copiado da agenda (`ContextMenus.inviteText`).
    static func quoted(_ message: Message, dateLabel: String) -> String {
        var lines = ["", "", "---------- Mensagem encaminhada ----------"]
        lines.append("De: \(message.from.display)")
        if !dateLabel.isEmpty { lines.append("Data: \(dateLabel)") }
        if !message.subject.isEmpty { lines.append("Assunto: \(message.subject)") }
        if !message.to.isEmpty {
            lines.append("Para: \(message.to.map(\.display).joined(separator: ", "))")
        }
        lines.append("")
        lines.append(contentsOf: message.body)
        return lines.joined(separator: "\n")
    }
}
