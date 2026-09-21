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

    /// O bloco é necessário somente quando importar para o TextKit faria o
    /// rascunho perder estrutura ou recursos. HTML simples segue no editor
    /// normal, incluindo o caminho de restauração de assinatura acima.
    static func requiresLiteralPreservation(_ html: String) -> Bool {
        let value = html.lowercased()
        return value.contains("<table")
            || value.contains("<img")
            || value.contains("cid:")
            || value.contains("data:image/")
            || value.contains("<!--okamiuni-signature:")
            || value.contains("okamiuni-forward")
    }

    /// Uma parte HTML que o TextKit não pode representar sem reduzir tabela,
    /// CID ou assinatura a texto. Ela aparece como bloco no compositor e sai
    /// como o mesmo HTML salvo; texto novo é inserido antes dela.
    struct PreservedHTML: Equatable {
        let html: String
        let plainText: String
    }

    struct PositionedSignature: Equatable {
        let plainText: String
        let leadingSeparator: String
        let trailingSeparator: String
    }

    /// A assinatura é um bloco, inclusive na alternativa texto. A posição é o
    /// cursor original, mas o conteúdo não pode sair como “antesASSINATURAdepois”.
    /// Os separadores retornam para a persistência do rascunho poder retirar
    /// exatamente o que foi acrescentado, sem adivinhar pelo nome da pessoa.
    static func positionedSignature(
        in body: String, signature: String, at requestedOffset: Int
    ) -> PositionedSignature {
        let offset = min(max(0, requestedOffset), body.count)
        let index = body.index(body.startIndex, offsetBy: offset)
        let before = String(body[..<index])
        let after = String(body[index...])
        guard !signature.isEmpty else {
            return PositionedSignature(
                plainText: body, leadingSeparator: "", trailingSeparator: ""
            )
        }
        let leading: String
        if before.isEmpty || before.hasSuffix("\n\n") {
            leading = ""
        } else {
            leading = before.hasSuffix("\n") ? "\n" : "\n\n"
        }
        let trailing: String
        if after.isEmpty || after.hasPrefix("\n\n") {
            trailing = ""
        } else {
            trailing = after.hasPrefix("\n") ? "\n" : "\n\n"
        }
        return PositionedSignature(
            plainText: before + leading + signature + trailing + after,
            leadingSeparator: leading,
            trailingSeparator: trailing
        )
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
        let ns = NSMutableAttributedString(attributedString: ComposerTextKit.nsAttributed(
            text,
            theme: theme.applyingTypography(.standard),
            resolvesDefaultColorForPresentation: false
        ))
        // Cocoa HTML Writer escreve os componentes Generic RGB como valores
        // CSS. Reidentificar somente esta cópia de exportação mantém os números
        // sRGB do modelo: sem isso #336699 volta como #285287 a cada reabertura.
        // O editor na tela continua usando cores sRGB normalmente.
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
            ns.enumerateAttribute(key, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
                guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
                ns.addAttribute(key, value: NSColor(
                    calibratedRed: color.redComponent, green: color.greenComponent,
                    blue: color.blueComponent, alpha: color.alphaComponent
                ), range: range)
            }
        }
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

    /// Importa HTML simples para o modelo nativo do compositor. Esse caminho
    /// é deliberadamente limitado ao HTML que não exigiu preservação literal:
    /// links, peso, cor e tamanho voltam editáveis; tabelas e imagens seguem
    /// para o bloco de revisão, onde o AppKit não pode reserializá-las sem
    /// perda de estrutura.
    @MainActor
    static func editableText(from html: String?, fallback: String, theme: Theme) -> AttributedString {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let native = try? NSAttributedString(
                data: Data(html.utf8),
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ], documentAttributes: nil
              )
        else { return AttributedString(fallback) }

        var model = ComposerTextKit.model(native)
        let plain = native.string
        guard !plain.isEmpty else { return model }
        native.enumerateAttributes(in: NSRange(location: 0, length: native.length)) { attributes, range, _ in
            guard let span = ComposerTextKit.modelRange(range, in: model, plain: plain) else { return }
            var style = BodyStyle.default
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                style.family = font.familyName ?? BodyStyle.defaultFamily
                style.size = Double(font.pointSize)
                style.bold = traits.contains(.bold)
                style.italic = traits.contains(.italic)
            }
            if let color = attributes[.foregroundColor] as? NSColor, let hex = hex(color) {
                style.colorHex = hex
            }
            if let color = attributes[.backgroundColor] as? NSColor, let hex = hex(color) {
                style.highlightHex = hex
            }
            style.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
            style.strike = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            model[span][BodyStyleAttribute.self] = style
            if let url = attributes[.link] as? URL {
                model[span].link = url
            } else if let raw = attributes[.link] as? String, let url = URL(string: raw) {
                model[span].link = url
            }
        }
        return model
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let components = color.usingColorSpace(.sRGB) else { return nil }
        let red = Int((components.redComponent * 255).rounded())
        let green = Int((components.greenComponent * 255).rounded())
        let blue = Int((components.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
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
            signatureOffset: nil,
            legacyPlainText: plain,
            legacySignatureHTML: signatureHTML
        )
    }

    /// Junta a introdução editável a um documento rico já salvo sem importar o
    /// documento para `NSAttributedString`. O documento persistido continua
    /// completo — inclusive para outro cliente que abrir o rascunho — e os
    /// delimitadores locais permitem separar a fonte literal da introdução na
    /// próxima abertura, sem achatar tabela, CID ou assinatura.
    @MainActor
    static func preserving(
        _ editable: Content, before preserved: PreservedHTML
    ) -> Content {
        let editableHTML = editable.html ?? htmlDocument(forPlainText: editable.plainText)
        let prefix = editable.plainText.isEmpty && editable.html == nil
            ? ""
            : htmlFragment(editableHTML)
        let source = applyingEditableStyles(from: editableHTML, to: preserved.html)
        return Content(
            plainText: joining(editable.plainText, and: preserved.plainText),
            html: composingLiteralHTML(prefix: prefix, source: source),
            inlineResources: editable.inlineResources
        )
    }

    /// Recupera a fonte HTML literal de um rascunho que o compositor salvou
    /// anteriormente. Rascunhos externos e versões antigas não têm esses
    /// delimitadores e permanecem integralmente no bloco de revisão.
    static func extractingPreservedHTML(from document: String, plainText: String) -> PreservedHTML? {
        guard let start = document.range(of: literalStart),
              let end = document.range(of: literalEnd, range: start.upperBound..<document.endIndex),
              start.upperBound <= end.lowerBound
        else { return nil }
        let fragment = String(document[start.upperBound..<end.lowerBound])
        guard let bodyOpen = document.range(of: "<body", options: .caseInsensitive),
              let openEnd = document.range(of: ">", range: bodyOpen.lowerBound..<document.endIndex),
              let bodyClose = document.range(
                of: "</body>", options: [.caseInsensitive, .backwards]
              ), openEnd.upperBound <= bodyClose.lowerBound
        else {
            return PreservedHTML(
                html: "<html><body>\(fragment)</body></html>", plainText: plainText
            )
        }
        var source = document
        source.replaceSubrange(openEnd.upperBound..<bodyClose.lowerBound, with: fragment)
        return PreservedHTML(html: source, plainText: plainText)
    }

    /// A introdução fica fora do bloco literal, mas ainda no mesmo documento
    /// que vai para o rascunho. Recuperamo-la com o `<head>` original para que
    /// classes e estilos exportados pelo TextKit continuem disponíveis ao
    /// importar de volta para a área editável.
    static func extractingEditableHTML(from document: String) -> String? {
        guard let bodyOpen = document.range(of: "<body", options: .caseInsensitive),
              let openEnd = document.range(of: ">", range: bodyOpen.lowerBound..<document.endIndex),
              let literal = document.range(of: literalStart, range: openEnd.upperBound..<document.endIndex)
        else { return nil }

        let prefix: String
        if let start = document.range(of: editableStart, range: openEnd.upperBound..<literal.lowerBound),
           let end = document.range(of: editableEnd, range: start.upperBound..<literal.lowerBound) {
            prefix = String(document[start.upperBound..<end.lowerBound])
        } else {
            // Rascunhos criados antes dos delimitadores da introdução usavam
            // apenas os do HTML literal; o separador imediatamente anterior
            // era gerado pelo compositor e pode sair com segurança.
            var legacyPrefix = String(document[openEnd.upperBound..<literal.lowerBound])
            if legacyPrefix.hasSuffix("<br><br>") {
                legacyPrefix.removeLast("<br><br>".count)
            }
            prefix = legacyPrefix
        }
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let tail: String
        if let close = document.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            tail = String(document[close.lowerBound...])
        } else {
            tail = "</body></html>"
        }
        return String(document[..<openEnd.upperBound]) + prefix + tail
    }

    /// Materializa os `data:image` do HTML preservado somente para o envio.
    /// O rascunho recebe a fonte original; portanto reabrir e salvar de novo
    /// nunca deixa uma referência CID separada dos bytes que a originaram.
    static func materializingInlineResources(_ content: Content) -> (content: Content, warnings: [String]) {
        let prepared = OutgoingHTMLResources.materialize(
            html: content.html, existingResources: content.inlineResources
        )
        return (
            Content(
                plainText: content.plainText,
                html: prepared.html,
                inlineResources: prepared.inlineResources
            ),
            prepared.warnings
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
        signatureIsInserted: Bool,
        signatureOffset: Int? = nil
    ) -> Content {
        content(
            text,
            theme: theme,
            signature: signature,
            signatureIsInserted: signatureIsInserted,
            signatureOffset: signatureOffset,
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
        signatureOffset: Int?,
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

        // A janela inteira mantém a assinatura rica como um bloco não
        // editável, entre os dois trechos do corpo. A posição é um
        // deslocamento no texto real — não há caractere sentinela no rascunho
        // que possa chegar à IA, ao contador ou ao servidor. Aqui criamos uma
        // âncora efêmera somente na cópia que o TextKit exporta para HTML.
        if let signatureOffset {
            return content(
                text,
                theme: theme,
                signature: signature,
                at: signatureOffset
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

    /// Materializa uma assinatura que ocupa uma posição explícita no composer.
    /// O texto antes e depois continua com a própria formatação, e o HTML/CID
    /// da assinatura entra entre os dois na mesma ordem que a pessoa vê.
    @MainActor
    private static func content(
        _ text: AttributedString,
        theme: Theme,
        signature: EmailSignature,
        at requestedOffset: Int
    ) -> Content {
        let count = text.characters.count
        let offset = min(max(0, requestedOffset), count)
        let insertion = text.characters.index(text.startIndex, offsetBy: offset)
        let plain = String(text.characters)
        let positioned = positionedSignature(
            in: plain, signature: signature.plainText, at: offset
        )

        let existingHTML = html(text, theme: theme)
        guard signature.html != nil || existingHTML != nil else {
            return Content(plainText: positioned.plainText, html: nil, inlineResources: [])
        }

        // O token nasce só nesta cópia para preservar o documento HTML inteiro
        // produzido pelo AppKit, inclusive a folha de estilos de tabela.
        // UUID elimina a chance de texto digitado ser confundido com a âncora;
        // ele nunca volta ao AttributedString nem ao resultado.
        let token = "okamiuni-signature-anchor-\(UUID().uuidString.lowercased())"
        var anchored = text
        anchored.replaceSubrange(insertion..<insertion, with: AttributedString(token))
        let document = html(anchored, theme: theme)
            ?? htmlDocument(forPlainText: String(anchored.characters))
        let fragment = signature.html.map { htmlFragment($0) }
            ?? htmlFragment(htmlDocument(forPlainText: signature.plainText))
        let spacedFragment = htmlBreaks(for: positioned.leadingSeparator)
            + fragment
            + htmlBreaks(for: positioned.trailingSeparator)
        let replaced = replacingSignatureAnchor(token, with: spacedFragment, in: document)

        return Content(
            plainText: positioned.plainText,
            html: replaced,
            inlineResources: signature.html == nil ? [] : signature.inlineResources
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

    private static let literalStart = "<!--okamiuni-preserved-html:start-->"
    private static let literalEnd = "<!--okamiuni-preserved-html:end-->"
    private static let editableStart = "<!--okamiuni-editable-html:start-->"
    private static let editableEnd = "<!--okamiuni-editable-html:end-->"
    private static let editableStyleStart = "<!--okamiuni-editable-style:start-->"
    private static let editableStyleEnd = "<!--okamiuni-editable-style:end-->"

    private static func composingLiteralHTML(prefix: String, source: String) -> String {
        let cleanSource = removingLiteralDelimiters(from: source)
        let editable = prefix.isEmpty ? "" : editableStart + prefix + editableEnd + "<br><br>"
        let addition = editable + literalStart
        guard let bodyOpen = cleanSource.range(of: "<body", options: .caseInsensitive),
              let openEnd = cleanSource.range(
                of: ">", range: bodyOpen.lowerBound..<cleanSource.endIndex
              ), let bodyClose = cleanSource.range(
                of: "</body>", options: [.caseInsensitive, .backwards]
              ), openEnd.upperBound <= bodyClose.lowerBound
        else {
            return "<html><body>\(addition)\(cleanSource)\(literalEnd)</body></html>"
        }
        var result = cleanSource
        result.insert(contentsOf: addition, at: openEnd.upperBound)
        let close = result.range(of: "</body>", options: [.caseInsensitive, .backwards])!
        result.insert(contentsOf: literalEnd, at: close.lowerBound)
        return result
    }

    private static func removingLiteralDelimiters(from source: String) -> String {
        source
            .replacingOccurrences(of: literalStart, with: "")
            .replacingOccurrences(of: literalEnd, with: "")
            .replacingOccurrences(of: editableStart, with: "")
            .replacingOccurrences(of: editableEnd, with: "")
    }

    /// `NSAttributedString` exporta a formatação em classes dentro do body e
    /// regras no head. Ao colocar a introdução em outro documento, carregamos
    /// somente essas regras no head do original — sem mexer no layout literal
    /// nem criar folhas repetidas a cada salvar/reabrir.
    private static func applyingEditableStyles(from editable: String, to source: String) -> String {
        let styles = styleElements(in: editable)
        var result = removingEditableStyles(from: source)
        guard !styles.isEmpty else { return result }
        let marked = editableStyleStart + styles + editableStyleEnd
        if let head = result.range(of: "<head", options: .caseInsensitive),
           let end = result.range(of: ">", range: head.lowerBound..<result.endIndex) {
            result.insert(contentsOf: marked, at: end.upperBound)
            return result
        }
        if let html = result.range(of: "<html", options: .caseInsensitive),
           let end = result.range(of: ">", range: html.lowerBound..<result.endIndex) {
            result.insert(contentsOf: "<head>\(marked)</head>", at: end.upperBound)
            return result
        }
        return "<html><head>\(marked)</head><body>\(result)</body></html>"
    }

    private static func styleElements(in html: String) -> String {
        var remaining = html[...]
        var styles = ""
        while let start = remaining.range(of: "<style", options: .caseInsensitive),
              let end = remaining.range(of: "</style>", options: .caseInsensitive, range: start.lowerBound..<remaining.endIndex) {
            styles += String(remaining[start.lowerBound..<end.upperBound])
            remaining = remaining[end.upperBound...]
        }
        return styles
    }

    private static func removingEditableStyles(from html: String) -> String {
        var result = html
        while let start = result.range(of: editableStyleStart),
              let end = result.range(of: editableStyleEnd, range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    private static func replacingSignatureAnchor(
        _ token: String, with signature: String, in document: String
    ) -> String {
        document.replacingOccurrences(of: token, with: signature)
    }

    private static func htmlBreaks(for separator: String) -> String {
        String(repeating: "<br>", count: separator.filter { $0 == "\n" }.count)
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
