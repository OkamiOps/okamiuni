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
    struct Content: Equatable {
        let plainText: String
        let html: String?
        let inlineResources: [InlineSignatureResource]
    }

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
        // A preferência de leitura é só da interface. O HTML enviado deve
        // preservar os pontos do `BodyStyle`, não a escala escolhida nesta
        // máquina para visualizar o composer.
        let ns = ComposerTextKit.nsAttributed(
            text,
            theme: theme.applyingTypography(.standard),
            resolvesDefaultColorForPresentation: false
        )
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

    /// Materializa o corpo que vai para a fila, inclusive uma assinatura rica
    /// que a pessoa inseriu pelo botão do composer.
    ///
    /// O editor continua guardando texto rico editável, e por isso a assinatura
    /// aparece nele pela alternativa `plainText`. Somente nesta fronteira de
    /// saída o trecho final é trocado pelo HTML assinado e seus recursos CID.
    /// Se a assinatura não estiver no fim do rascunho, nada é acrescentado:
    /// salvar uma assinatura nas Configurações não autoriza inserção silenciosa.
    @MainActor
    static func content(
        _ text: AttributedString,
        theme: Theme,
        signature: EmailSignature
    ) -> Content {
        let plain = String(text.characters)
        guard let signatureHTML = signature.html,
              var unsigned = removingInsertedSignature(signature.plainText, from: text)
        else {
            return Content(plainText: plain, html: html(text, theme: theme), inlineResources: [])
        }

        trimTrailingWhitespace(&unsigned)
        return content(
            unsigned,
            theme: theme,
            signature: signature,
            signatureIsInserted: true,
            legacyPlainText: plain,
            legacySignatureHTML: signatureHTML
        )
    }

    /// Materializa uma assinatura que o composer mantém como bloco visual
    /// próprio, fora do `NSTextView` editável.
    ///
    /// Diferentemente da API legada acima, esta não procura o texto simples da
    /// assinatura no fim do rascunho: o estado de inserção vem explicitamente
    /// da janela. Isso preserva tabela, imagem CID e espaçamento tanto na tela
    /// quanto na mensagem que sai, sem transformar a assinatura em texto
    /// editável só para depois tentar adivinhar onde ela estava.
    @MainActor
    static func content(
        _ text: AttributedString,
        theme: Theme,
        signature: EmailSignature,
        signatureIsInserted: Bool
    ) -> Content {
        content(
            text,
            theme: theme,
            signature: signature,
            signatureIsInserted: signatureIsInserted,
            legacyPlainText: nil,
            legacySignatureHTML: nil
        )
    }

    @MainActor
    private static func content(
        _ text: AttributedString,
        theme: Theme,
        signature: EmailSignature,
        signatureIsInserted: Bool,
        legacyPlainText: String?,
        legacySignatureHTML: String?
    ) -> Content {
        let bodyPlain = String(text.characters)
        let signatureHTML = legacySignatureHTML ?? signature.html
        let hasPlainSignature = !signature.plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard signatureIsInserted, hasPlainSignature || signatureHTML != nil else {
            return Content(
                plainText: legacyPlainText ?? bodyPlain,
                html: html(text, theme: theme),
                inlineResources: []
            )
        }

        let plain = legacyPlainText ?? joining(bodyPlain, and: signature.plainText)
        let bodyHTML = html(text, theme: theme)

        guard let signatureHTML else {
            // Uma assinatura só de texto não obriga uma mensagem simples a
            // virar HTML. Se o corpo já é rico, porém, o texto da assinatura
            // precisa entrar na mesma alternativa HTML para não desaparecer
            // em clientes que preferem essa parte do MIME.
            guard let bodyHTML else {
                return Content(plainText: plain, html: nil, inlineResources: [])
            }
            return Content(
                plainText: plain,
                html: insertingSignatureHTML(
                    htmlFragment(htmlDocument(forPlainText: signature.plainText)),
                    into: bodyHTML,
                    needsSeparator: !bodyPlain.isEmpty
                ),
                inlineResources: []
            )
        }

        let baseHTML = bodyHTML ?? htmlDocument(forPlainText: bodyPlain)
        return Content(
            plainText: plain,
            html: insertingSignatureHTML(
                htmlFragment(signatureHTML),
                into: baseHTML,
                needsSeparator: !bodyPlain.isEmpty
            ),
            inlineResources: signature.inlineResources
        )
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
        html: String?,
        attachments: [OutgoingAttachment] = [],
        inlineResources: [InlineSignatureResource] = [],
        replyingTo original: Message? = nil
    ) -> OutgoingMessage {
        func limpa(_ contatos: [Contact]) -> [OutgoingAddress] {
            contatos
                .filter { !$0.address.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(OutgoingAddress.init)
        }
        let corrente = conversa(original)
        return OutgoingMessage(
            messageID: OutgoingMessage.newMessageID(for: from.address),
            accountID: accountID,
            from: OutgoingAddress(from),
            to: limpa(to),
            cc: limpa(cc),
            bcc: limpa(bcc),
            subject: subject,
            plainText: plainText,
            html: html,
            inReplyTo: corrente.inReplyTo,
            references: corrente.references,
            attachments: attachments,
            inlineResources: inlineResources
        )
    }

    // MARK: - Assinatura rica

    private static func removingInsertedSignature(
        _ signature: String, from body: AttributedString
    ) -> AttributedString? {
        let tail = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }

        var result = body
        trimTrailingWhitespace(&result)
        guard result.characters.count >= tail.count else { return nil }
        let start = result.characters.index(result.endIndex, offsetBy: -tail.count)
        guard String(result.characters[start..<result.endIndex]) == tail else { return nil }
        result.removeSubrange(start..<result.endIndex)
        return result
    }

    private static func trimTrailingWhitespace(_ text: inout AttributedString) {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.characters.index(before: end)
            guard text.characters[previous].isWhitespace else { break }
            end = previous
        }
        if end < text.endIndex { text.removeSubrange(end..<text.endIndex) }
    }

    private static func joining(_ body: String, and signature: String) -> String {
        guard !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return body
        }
        guard !body.isEmpty else { return signature }
        return "\(body)\n\n\(signature)"
    }

    private static func htmlDocument(forPlainText text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<html><body>\(escaped)</body></html>"
    }

    /// Aceita tanto um fragmento digitado no modo HTML como um documento
    /// completo exportado pelo TextKit, sem aninhar `<html><body>` dentro do
    /// corpo da mensagem.
    private static func htmlFragment(_ html: String) -> String {
        guard let bodyOpen = html.range(of: "<body", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: bodyOpen.lowerBound..<html.endIndex),
              let bodyClose = html.range(
                of: "</body>", options: [.caseInsensitive, .backwards]
              ),
              openEnd.upperBound <= bodyClose.lowerBound
        else { return html }
        return String(html[openEnd.upperBound..<bodyClose.lowerBound])
    }

    private static func insertingSignatureHTML(
        _ signature: String, into document: String, needsSeparator: Bool
    ) -> String {
        let separator = needsSeparator ? "<br><br>" : ""
        let addition = separator + signature
        guard let close = document.range(
            of: "</body>", options: [.caseInsensitive, .backwards]
        ) else {
            return "<html><body>\(document)\(addition)</body></html>"
        }
        var result = document
        result.insert(contentsOf: addition, at: close.lowerBound)
        return result
    }

    /// `In-Reply-To` e `References` de uma resposta — **a dívida da M3-5,
    /// paga**.
    ///
    /// `OutgoingMime.compose` já escrevia os dois cabeçalhos desde então; o que
    /// faltava era alguém preenchê-los, porque a mensagem respondida não
    /// guardava o `Message-ID` dela. Agora guarda (v4), e a conta é a do RFC
    /// 5322 §3.6.4:
    ///
    /// - `In-Reply-To` é o `Message-ID` da mensagem respondida, e só dele.
    /// - `References` é a corrente **dela** com o `Message-ID` dela no fim —
    ///   a resposta acrescenta um elo, não recomeça a corrente. Sem isso, o
    ///   cliente de quem recebe abre uma conversa nova a cada resposta, que é
    ///   o mesmo defeito que esta tarefa conserta do lado de cá.
    ///
    /// Sem mensagem de origem, ou com uma que não tem `Message-ID` (linha
    /// antiga, fixture), os dois saem vazios — e a mensagem sai como nova, que
    /// é a verdade: não há a que responder.
    /// Acrescenta a citação da original no fim do corpo. O compositor mostra o
    /// histórico na janela; quem recebe precisa dele **no email**, senão um
    /// cliente que não empilha conversa lê só a resposta solta.
    static func citing(
        _ original: Message,
        dateLabel: String,
        onto content: Content
    ) -> Content {
        let bloco = citation(original, dateLabel: dateLabel)
        guard !bloco.isEmpty, !content.plainText.contains(bloco) else { return content }
        let plain = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let juntos = plain.isEmpty ? bloco : plain + "\n\n" + bloco
        let html: String?
        if let existente = content.html, !existente.isEmpty {
            let citado = citationHTML(original, dateLabel: dateLabel)
            html = insertingCitation(citado, into: existente)
        } else {
            html = nil
        }
        return Content(plainText: juntos, html: html, inlineResources: content.inlineResources)
    }

    static func citation(_ original: Message, dateLabel: String) -> String {
        let quem = original.from.display
        let cabeca = dateLabel.isEmpty
            ? L10n.tr("\(quem) escreveu:")
            : L10n.tr("Em \(dateLabel), \(quem) escreveu:")
        let linhas: [String]
        if original.body.isEmpty {
            linhas = original.subject.isEmpty ? [] : ["> \(original.subject)"]
        } else {
            linhas = original.body.flatMap { paragrafo -> [String] in
                paragrafo.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
            }
        }
        guard !linhas.isEmpty else { return "" }
        return ([cabeca, ""] + linhas).joined(separator: "\n")
    }

    private static func citationHTML(_ original: Message, dateLabel: String) -> String {
        let texto = citation(original, dateLabel: dateLabel)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<blockquote>\(texto)</blockquote>"
    }

    private static func insertingCitation(_ citation: String, into document: String) -> String {
        guard let close = document.range(
            of: "</body>", options: [.caseInsensitive, .backwards]
        ) else {
            return document + citation
        }
        var result = document
        result.insert(contentsOf: "<br>" + citation, at: close.lowerBound)
        return result
    }

    static func conversa(_ original: Message?) -> (inReplyTo: String?, references: [String]) {
        guard let original, let messageID = original.rfcMessageID, !messageID.isEmpty else {
            return (nil, [])
        }
        var corrente = original.references.filter { !$0.isEmpty }
        if !corrente.contains(messageID) { corrente.append(messageID) }
        return (messageID, corrente)
    }
}
