import AppKit
import UNICore
import UNIDesign

/// A ponte entre o rascunho da janela e a mensagem que vai sair.
///
/// **Ela mora aqui, e não no `UNISync`, por uma regra da casa**: `UNICore` e
/// `UNISync` nunca importam SwiftUI nem AppKit, e converter texto rico em HTML
/// é AppKit — é o `NSAttributedString` que sabe escrever o HTML de uma tabela,
/// de um link e de um realce. O que atravessa a fronteira são duas `String`
/// prontas (texto simples e HTML), e do outro lado o `OutgoingMime` monta o
/// RFC 5322 sem nunca saber que existiu um `NSTextView`.
enum ComposerOutgoing {
    /// O rascunho tem alguma formatação, ou é texto e nada mais?
    ///
    /// A pergunta decide se a mensagem sai como `text/plain` simples ou como
    /// `multipart/alternative`. Mandar HTML em tudo seria dobrar o tamanho de
    /// toda mensagem — e enfiar a folha de estilo do AppKit em cima de duas
    /// linhas de texto que ninguém formatou.
    ///
    /// "Formatação" é qualquer coisa que uma `String` não carrega: um estilo
    /// diferente do padrão, um parágrafo que não é alinhado à esquerda, uma
    /// célula de tabela, um hyperlink.
    static func hasFormatting(_ text: AttributedString) -> Bool {
        for run in text.runs {
            if let estilo = run.attributes[BodyStyleAttribute.self], estilo != .default { return true }
            if let alinhamento = run.attributes[BodyAlignmentAttribute.self], alinhamento != .left { return true }
            if run.attributes[BodyTableAttribute.self] != nil { return true }
            if run.link != nil { return true }
        }
        return false
    }

    /// O corpo em HTML, ou `nil` quando não há formatação nenhuma para
    /// preservar.
    ///
    /// `@MainActor` porque a exportação passa pelo TextKit, e o modelo que ela
    /// recebe é montado com o tema da janela — os dois já são do ator
    /// principal, e dizer isso no tipo é mais barato que descobrir em runtime.
    @MainActor
    static func html(_ text: AttributedString, theme: Theme) -> String? {
        guard hasFormatting(text) else { return nil }
        let ns = ComposerTextKit.nsAttributed(text, theme: theme)
        let dados = try? ns.data(
            from: NSRange(location: 0, length: ns.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        )
        // Falhar aqui **não** cancela o envio: quem chama manda a mensagem em
        // texto simples. Perder a cor de uma palavra é incômodo; perder a
        // mensagem porque a cor não pôde ser escrita seria defeito.
        return dados.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A mensagem pronta para a fila.
    ///
    /// Endereço vazio não entra em lista nenhuma: um chip meio digitado (o que
    /// acontece quando a pessoa aperta ⌘⏎ com o campo aberto) viraria um
    /// `RCPT TO:<>` que o servidor recusa — e o envio inteiro pararia por causa
    /// de um destinatário que ninguém quis pôr.
    static func message(
        accountID: String,
        from: Contact,
        to: [Contact],
        cc: [Contact],
        bcc: [Contact],
        subject: String,
        plainText: String,
        html: String?
    ) -> OutgoingMessage {
        func limpa(_ contatos: [Contact]) -> [OutgoingAddress] {
            contatos
                .filter { !$0.address.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(OutgoingAddress.init)
        }
        return OutgoingMessage(
            messageID: OutgoingMessage.newMessageID(for: from.address),
            accountID: accountID,
            from: OutgoingAddress(from),
            to: limpa(to),
            cc: limpa(cc),
            bcc: limpa(bcc),
            subject: subject,
            plainText: plainText,
            html: html
        )
    }
}
