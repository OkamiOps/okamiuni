import Foundation
import UNICore

/// A mensagem que sai, em RFC 5322 — **uma função pura**.
///
/// Pura de propósito, e é a decisão central desta peça: montar o texto da
/// mensagem dentro do cliente SMTP (ou dentro do cliente do Gmail) faria a
/// única parte que dá para provar sem rede ficar amarrada à parte que precisa
/// de socket. Aqui entra uma `OutgoingMessage` e sai uma `String` com CRLF em
/// toda linha; quem manda pelo fio é outro arquivo, e ele não sabe montar nada.
///
/// O que ela decide:
///
/// - **`Bcc` só existe no caminho do Gmail.** No SMTP a cópia oculta viaja em
///   `RCPT TO` e em lugar nenhum do texto — um cabeçalho `Bcc` no corpo é a
///   cópia oculta deixando de ser oculta na caixa de quem recebe. A Gmail API
///   é o contrário: ela monta os destinatários **a partir do texto**, então sem
///   o cabeçalho a cópia oculta simplesmente não é enviada, e o servidor a tira
///   antes de entregar. Daí o parâmetro, e daí ele não ter valor padrão: quem
///   chama tem de decidir, porque errar para qualquer um dos lados é perder ou
///   vazar uma cópia.
/// - **Acento em assunto e em nome vira RFC 2047.** O repo já sabia *ler* isso
///   (`MimeHeaderDecoding`); escrever é o outro lado, e sem ele "Reunião" sai
///   como bytes crus num cabeçalho que o RFC manda ser ASCII.
/// - **O corpo vai em quoted-printable.** Ele é reversível, legível para quem
///   olha o texto cru (o que base64 não é) e não estoura o limite de 998 bytes
///   por linha do RFC — que uma linha de texto colada de um navegador estoura
///   sozinha.
public enum OutgoingMime {
    /// A mensagem inteira, pronta para o `DATA` do SMTP ou para o `raw` do
    /// Gmail.
    ///
    /// - Parameters:
    ///   - includeBcc: ver a nota do tipo. `false` no SMTP, `true` no Gmail.
    ///   - boundary: injetável para o teste poder afirmar o texto inteiro —
    ///     um separador sorteado tornaria a comparação impossível.
    public static func compose(
        _ message: OutgoingMessage,
        date: Date,
        includeBcc: Bool,
        boundary: String = "okamiuni-\(UUID().uuidString.lowercased())"
    ) -> String {
        var linhas: [String] = []
        // `EmailSignature` já impede duplicata, mas `OutgoingMessage` também
        // é uma API pública e pode ser montada por outra superfície. Não há
        // como dois bytes responderem ao mesmo `cid:` sem cliente dependente
        // da ordem, então o MIME conserva somente o primeiro de cada ID.
        let inlineResources = uniqueInlineResources(message.inlineResources)
        // Segunda defesa no limite de transporte: mesmo um chamador que criou
        // `OutgoingMessage` sem passar por `EmailSignature` não consegue
        // colocar pixel remoto, `file:`, SVG ou data URL no e-mail.
        let safeHTML = EmailSignature.sanitizedHTML(
            message.html, inlineResources: inlineResources
        )
        linhas.append("From: \(addressList([message.from]))")
        if !message.to.isEmpty { linhas.append("To: \(addressList(message.to))") }
        if !message.cc.isEmpty { linhas.append("Cc: \(addressList(message.cc))") }
        if includeBcc, !message.bcc.isEmpty { linhas.append("Bcc: \(addressList(message.bcc))") }
        linhas.append("Subject: \(encodeHeaderText(message.subject))")
        linhas.append("Date: \(rfc5322Date(date))")
        linhas.append("Message-ID: <\(message.messageID)>")
        if let respondendo = message.inReplyTo, !respondendo.isEmpty {
            linhas.append("In-Reply-To: <\(respondendo)>")
        }
        if !message.references.isEmpty {
            // Uma corrente longa passa dos 78 caracteres recomendados, e o
            // jeito certo de quebrar um cabeçalho é o dobramento: CRLF seguido
            // de espaço. Cortar sem o espaço faria a segunda linha virar um
            // cabeçalho inventado.
            linhas.append(dobra("References: " + message.references.map { "<\($0)>" }.joined(separator: " ")))
        }
        linhas.append("MIME-Version: 1.0")

        // RSVP/iTIP é calendário, não uma mensagem rica com um texto que o
        // cliente do organizador precise adivinhar. A mesma `OutgoingMessage`
        // segue pelo mesmo SMTP/Gmail/outbox; muda somente a representação MIME.
        if let calendar = message.calendarICS, !calendar.isEmpty {
            let method = calendarMethod(in: calendar)
            let suffix = method.map { "; method=\($0)" } ?? ""
            linhas.append("Content-Type: text/calendar\(suffix); charset=utf-8")
            linhas.append("Content-Transfer-Encoding: quoted-printable")
            linhas.append("")
            linhas.append(quotedPrintable(calendar))
            return linhas.joined(separator: "\r\n")
        }

        if message.attachments.isEmpty, let html = safeHTML, !html.isEmpty {
            linhas.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            linhas.append("")
            linhas.append("Esta mensagem tem várias partes em MIME.")
            linhas.append("")
            appendTextParts(
                &linhas, boundary: boundary, plainText: message.plainText, html: html,
                inlineResources: inlineResources
            )
            return linhas.joined(separator: "\r\n")
        }

        if message.attachments.isEmpty {
            linhas.append("Content-Type: text/plain; charset=utf-8")
            linhas.append("Content-Transfer-Encoding: quoted-printable")
            linhas.append("")
            linhas.append(quotedPrintable(message.plainText))
            return linhas.joined(separator: "\r\n")
        }

        // O arquivo fica no `multipart/mixed` externo, e texto/HTML continuam
        // irmãos dentro de `multipart/alternative`. Pôr o anexo dentro do
        // alternative faz clientes escolherem o PDF *ou* o texto como se uma
        // fosse alternativa do outro.
        let alternativeBoundary = "\(boundary)-alt"
        linhas.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        linhas.append("")
        linhas.append("Esta mensagem tem várias partes em MIME.")
        linhas.append("")
        if let html = safeHTML, !html.isEmpty {
            linhas.append("--\(boundary)")
            linhas.append("Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"")
            linhas.append("")
            appendTextParts(
                &linhas, boundary: alternativeBoundary, plainText: message.plainText, html: html,
                inlineResources: inlineResources
            )
        } else {
            linhas.append("--\(boundary)")
            linhas.append("Content-Type: text/plain; charset=utf-8")
            linhas.append("Content-Transfer-Encoding: quoted-printable")
            linhas.append("")
            linhas.append(quotedPrintable(message.plainText))
        }
        for attachment in message.attachments {
            linhas.append("--\(boundary)")
            linhas.append("Content-Type: \(attachment.mimeType); name*=utf-8''\(encodedFilename(attachment.filename))")
            linhas.append("Content-Transfer-Encoding: base64")
            linhas.append("Content-Disposition: attachment; filename*=utf-8''\(encodedFilename(attachment.filename))")
            linhas.append("")
            linhas.append(base64Lines(attachment.data))
        }
        linhas.append("--\(boundary)--")
        return linhas.joined(separator: "\r\n")
    }

    private static func appendTextParts(
        _ lines: inout [String], boundary: String, plainText: String, html: String,
        inlineResources: [InlineSignatureResource]
    ) {
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: quoted-printable")
        lines.append("")
        lines.append(quotedPrintable(plainText))
        if inlineResources.isEmpty {
            lines.append("--\(boundary)")
            appendHTMLPart(&lines, html: html)
        } else {
            // `related` fica dentro de `alternative`: o cliente primeiro
            // escolhe a alternativa HTML, e só então resolve os `cid:` que
            // pertencem a ela. Fazer as imagens irmãs do texto no `mixed`
            // externo deixa Outlook e Apple Mail tratarem o logo como anexo.
            let relatedBoundary = "\(boundary)-related"
            lines.append("--\(boundary)")
            lines.append(
                "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"; type=\"text/html\""
            )
            lines.append("")
            appendRelatedParts(
                &lines, boundary: relatedBoundary, html: html,
                inlineResources: inlineResources
            )
        }
        lines.append("--\(boundary)--")
    }

    private static func appendRelatedParts(
        _ lines: inout [String], boundary: String, html: String,
        inlineResources: [InlineSignatureResource]
    ) {
        lines.append("--\(boundary)")
        appendHTMLPart(&lines, html: html)
        for (index, resource) in inlineResources.enumerated() {
            lines.append("--\(boundary)")
            lines.append("Content-Type: \(resource.mimeType); name=\"\(inlineFilename(for: resource, index: index))\"")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("Content-ID: <\(resource.contentID)>")
            lines.append(
                "Content-Disposition: inline; filename=\"\(inlineFilename(for: resource, index: index))\""
            )
            lines.append("")
            lines.append(base64Lines(resource.data))
        }
        lines.append("--\(boundary)--")
    }

    private static func appendHTMLPart(_ lines: inout [String], html: String) {
        lines.append("Content-Type: text/html; charset=utf-8")
        lines.append("Content-Transfer-Encoding: quoted-printable")
        lines.append("")
        lines.append(quotedPrintable(html))
    }

    /// O recurso não recebe um nome vindo de caminho local; além de não haver
    /// caminho para vazar, o nome fixo impede caractere estranho em cabeçalho.
    private static func inlineFilename(for resource: InlineSignatureResource, index: Int) -> String {
        let suffix: String
        switch resource.mimeType {
        case "image/jpeg": suffix = "jpg"
        case "image/gif": suffix = "gif"
        case "image/webp": suffix = "webp"
        default: suffix = "png"
        }
        return "signature-image-\(index + 1).\(suffix)"
    }

    private static func uniqueInlineResources(
        _ resources: [InlineSignatureResource]
    ) -> [InlineSignatureResource] {
        var seen = Set<String>()
        return resources.filter { seen.insert($0.contentID).inserted }
    }

    /// RFC 2045 limita linhas base64 a 76 caracteres. `Data` produz uma linha
    /// só, que funcionaria em servidores permissivos e falharia no primeiro
    /// relay estrito ou em anexos maiores.
    private static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        return stride(from: 0, to: encoded.count, by: 76).map { start in
            let lower = encoded.index(encoded.startIndex, offsetBy: start)
            let upper = encoded.index(lower, offsetBy: min(76, encoded.count - start))
            return String(encoded[lower..<upper])
        }.joined(separator: "\r\n")
    }

    /// `filename*` usa RFC 2231/RFC 5987: cabeçalho ASCII e UTF-8 percent
    /// encoded. Nome cru com acento, aspas ou CRLF não pode entrar num header.
    private static func encodedFilename(_ filename: String) -> String {
        filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
            ?? "anexo"
    }

    /// O `raw` que a Gmail API pede: base64 **url-safe**, sem preenchimento.
    ///
    /// Url-safe e não o base64 comum: o `+` e o `/` do alfabeto normal são
    /// caracteres com significado em URL e em JSON de query, e a Gmail API
    /// documenta `base64url`. Mandar o alfabeto errado devolve 400 numa
    /// mensagem que estava perfeita.
    public static func base64URL(_ texto: String) -> String {
        Data(texto.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Endereços

    /// `Nome <endereço>`, com o nome citado ou codificado quando precisa.
    static func addressList(_ enderecos: [OutgoingAddress]) -> String {
        enderecos.map { endereco in
            let nome = endereco.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nome.isEmpty, nome != endereco.address else { return endereco.address }
            return "\(encodeHeaderText(nome)) <\(endereco.address)>"
        }.joined(separator: ", ")
    }

    // MARK: RFC 2047

    /// Um texto de cabeçalho: como veio quando é ASCII seguro, codificado
    /// quando não é.
    ///
    /// "ASCII seguro" exclui os caracteres que o RFC 5322 dá significado num
    /// cabeçalho estruturado (`<`, `>`, `,`, `:`, `"`, `@`...) — um nome
    /// "Duarte, Marina" escrito cru na linha `To:` vira **dois**
    /// destinatários, e o segundo não existe. Codificar resolve os dois
    /// problemas com uma regra só.
    static func encodeHeaderText(_ texto: String) -> String {
        guard !texto.isEmpty else { return "" }
        if texto.unicodeScalars.allSatisfy({ ehSeguroEmCabecalho($0) }) { return texto }
        // Pedaços por **caractere**, nunca por byte: cortar um "ç" ao meio
        // produziria dois base64 que remontam em lixo. 24 caracteres cabem com
        // folga no limite de 75 do RFC 2047 mesmo em quatro bytes por
        // caractere.
        let pedacos = stride(from: 0, to: Array(texto).count, by: 24).map { inicio -> String in
            let todos = Array(texto)
            let fim = min(inicio + 24, todos.count)
            let fatia = String(todos[inicio..<fim])
            return "=?UTF-8?B?\(Data(fatia.utf8).base64EncodedString())?="
        }
        // Palavras codificadas seguidas dobram com CRLF + espaço: é assim que
        // quem lê sabe que as duas linhas são o mesmo cabeçalho.
        return pedacos.joined(separator: "\r\n ")
    }

    private static func ehSeguroEmCabecalho(_ escalar: Unicode.Scalar) -> Bool {
        guard escalar.isASCII, escalar.value >= 32, escalar.value < 127 else { return false }
        return !"<>,;:\"\\@[]()".unicodeScalars.contains(escalar)
    }

    /// Dobra um cabeçalho comprido em linhas de até 78 caracteres, cortando
    /// **só** em espaço — cortar dentro de um `<id>` o partiria em dois.
    static func dobra(_ cabecalho: String) -> String {
        guard cabecalho.count > 78 else { return cabecalho }
        var linhas: [String] = []
        var corrente = ""
        for palavra in cabecalho.split(separator: " ", omittingEmptySubsequences: false) {
            if corrente.isEmpty {
                corrente = String(palavra)
            } else if corrente.count + 1 + palavra.count <= 78 {
                corrente += " " + palavra
            } else {
                linhas.append(corrente)
                corrente = String(palavra)
            }
        }
        if !corrente.isEmpty { linhas.append(corrente) }
        return linhas.joined(separator: "\r\n ")
    }

    // MARK: Quoted-printable

    /// O corpo em quoted-printable, com quebra suave a cada 76 colunas.
    ///
    /// Três regras, e cada uma existe por um defeito conhecido:
    ///
    /// 1. `=` vira `=3D`, sempre. Sem isso, um `=` do texto seria lido como o
    ///    começo de uma sequência de escape e comeria os dois caracteres
    ///    seguintes.
    /// 2. Espaço ou tabulação **no fim da linha** vira `=20`/`=09`. Todo
    ///    servidor do caminho tem o direito de aparar espaço final, e sem a
    ///    codificação o texto chegaria diferente do que saiu.
    /// 3. A quebra suave (`=` no fim da linha) nunca cai no meio de uma
    ///    sequência de escape: as três posições de `=XX` andam juntas ou não
    ///    andam.
    static func quotedPrintable(_ texto: String) -> String {
        // Juntar com separador, e **não** somar `"\r\n"` e cortar no fim: no
        // Swift, `"\r\n"` é um grafema só, e um `removeLast(2)` sobre ele leva
        // a quebra **e o último caractere do texto** junto. A mensagem chegava
        // com a última letra faltando, em toda linha, sem erro nenhum.
        normalizaQuebras(texto)
            .components(separatedBy: "\r\n")
            .map(codificaLinha)
            .joined(separator: "\r\n")
    }

    private static func codificaLinha(_ linha: String) -> String {
        var pedacos: [String] = []
        let bytes = Array(linha.utf8)
        for (indice, byte) in bytes.enumerated() {
            let ultimo = indice == bytes.count - 1
            switch byte {
            case UInt8(ascii: "="):
                pedacos.append("=3D")
            case UInt8(ascii: " "):
                pedacos.append(ultimo ? "=20" : " ")
            case UInt8(ascii: "\t"):
                pedacos.append(ultimo ? "=09" : "\t")
            case 33...126:
                pedacos.append(String(UnicodeScalar(byte)))
            default:
                pedacos.append(String(format: "=%02X", byte))
            }
        }
        var saida = ""
        var coluna = 0
        for pedaco in pedacos {
            // 75, e não 76: a quebra suave gasta o `=` da 76ª coluna.
            if coluna + pedaco.count > 75 {
                saida += "=\r\n"
                coluna = 0
            }
            saida += pedaco
            coluna += pedaco.count
        }
        return saida
    }

    /// Toda quebra vira CRLF, venha ela como LF (o que o `NSTextView` produz),
    /// como CR sozinho ou já como CRLF.
    static func normalizaQuebras(_ texto: String) -> String {
        texto
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// `METHOD` pertence ao VCALENDAR, mas o parâmetro do Content-Type é o
    /// que muitos clientes usam para despachar iTIP. Aceita só token ASCII para
    /// que uma parte malformada não consiga injetar um cabeçalho.
    static func calendarMethod(in calendar: String) -> String? {
        for rawLine in normalizaQuebras(calendar).components(separatedBy: "\r\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.uppercased().hasPrefix("METHOD:") else { continue }
            let value = String(line.dropFirst("METHOD:".count)).uppercased()
            guard !value.isEmpty,
                  value.utf8.allSatisfy({
                      ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 45
                  })
            else { return nil }
            return value
        }
        return nil
    }

    // MARK: Data

    /// A data no formato do RFC 5322, sempre em inglês e sempre com fuso
    /// numérico.
    ///
    /// `Locale(identifier: "en_US_POSIX")` não é preciosismo: sem ele, num
    /// aparelho em português, o dia da semana sairia "qui" e o mês "ago" — e a
    /// linha `Date:` seria descartada por qualquer analisador que siga o RFC.
    static func rfc5322Date(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatador = DateFormatter()
        formatador.locale = Locale(identifier: "en_US_POSIX")
        formatador.timeZone = timeZone
        formatador.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatador.string(from: date)
    }
}
