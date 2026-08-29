import Foundation

/// HTML virando texto — a metade do decodificador que atende a mensagem que só
/// tem HTML.
///
/// **Por que ela existe.** Um terço largo do que chega hoje é `text/html` sem
/// nenhuma parte `text/plain` ao lado: newsletter, recibo, notificação de
/// sistema. Antes disto, a resposta honesta do parser era "não tenho texto" — e
/// o leitor mostrava uma tela vazia. Vazio calado é pior do que texto simples:
/// a pessoa não sabe se a mensagem é vazia, se o app quebrou, ou se ela deve
/// abrir o webmail.
///
/// O alvo não é renderizar HTML — é **ler** a mensagem. Marcação sai, blocos
/// viram parágrafos, entidades viram os caracteres que representam.
extension MimeBody {
    /// Os elementos que terminam um parágrafo. Fechá-los abre linha em branco,
    /// que é o que `GmailMessageParser.paragraphs(from:)` lê como separador —
    /// e é o que faz "blocos preservados" ser verdade em vez de promessa.
    private static let blocos: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre",
        "li", "tr", "table", "ul", "ol", "section", "article", "header",
        "footer", "nav", "aside", "figure", "figcaption", "dl", "dd", "dt", "form",
    ]

    /// Os elementos cujo **conteúdo** não é texto da mensagem. `script` e
    /// `style` não são marcação a arrancar: o miolo deles é código, e deixá-lo
    /// passar despejaria CSS no leitor — que é o defeito clássico de quem
    /// resolve HTML com uma expressão regular de `<[^>]*>`.
    private static let mudos: Set<String> = ["script", "style", "head", "title"]

    /// HTML → texto legível.
    public static func textFromHTML(_ html: String) -> String {
        var saida = ""
        var mudo: String?
        var i = html.startIndex

        while i < html.endIndex {
            let c = html[i]
            guard c == "<" else {
                if mudo == nil { saida.append(c) }
                i = html.index(after: i)
                continue
            }
            // Comentário: `<!-- … -->` inteiro fora, inclusive as condicionais
            // do Outlook, que são comentário para todo mundo menos o Outlook.
            if html[i...].hasPrefix("<!--") {
                if let fim = html.range(of: "-->", range: i..<html.endIndex) {
                    i = fim.upperBound
                } else {
                    i = html.endIndex
                }
                continue
            }
            guard let fecha = html[i...].firstIndex(of: ">") else {
                // `<` solto no meio do texto: é texto.
                if mudo == nil { saida.append(c) }
                i = html.index(after: i)
                continue
            }
            let tagCrua = String(html[html.index(after: i)..<fecha])
            i = html.index(after: fecha)

            let fechamento = tagCrua.hasPrefix("/")
            let nome = nomeDaTag(tagCrua)

            if let aberto = mudo {
                if fechamento, nome == aberto { mudo = nil }
                continue
            }
            if mudos.contains(nome), !fechamento, !tagCrua.hasSuffix("/") {
                mudo = nome
                continue
            }
            if nome == "br" {
                saida.append("\n")
            } else if nome == "hr" {
                saida.append("\n\n")
            } else if blocos.contains(nome) {
                // Abrir **e** fechar quebram: `<p>a<p>b` (sem fechar, e é
                // legal) daria um parágrafo só se só o fechamento contasse.
                saida.append("\n\n")
            }
        }
        return arruma(decodeEntities(saida))
    }

    /// `/p class="x"` → `p`.
    private static func nomeDaTag(_ crua: String) -> String {
        let semBarra = crua.hasPrefix("/") ? String(crua.dropFirst()) : crua
        return String(semBarra.prefix { $0.isLetter || $0.isNumber })
            .lowercased()
    }

    /// Espaço em branco arrumado: HTML colapsa espaços, e um texto extraído sem
    /// colapsar sai com a indentação do gerador de HTML dentro dele — trinta
    /// espaços à esquerda de cada linha da newsletter.
    ///
    /// O que **não** colapsa é a linha em branco: ela é a separação de
    /// parágrafo que `paragraphs(from:)` vai ler.
    private static func arruma(_ texto: String) -> String {
        let linhas = texto
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { linha -> String in
                linha
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
            }
        var saida: [String] = []
        for linha in linhas {
            // Três linhas em branco seguidas viram uma: `</div></p></td>` no
            // fim de uma célula produz três quebras de bloco para um parágrafo
            // só, e sem isto a mensagem sai esticada em buracos.
            if linha.isEmpty, saida.last?.isEmpty == true { continue }
            saida.append(linha)
        }
        return saida.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Entidades

    /// As nomeadas que aparecem de verdade em email — as cinco do XML, as de
    /// pontuação que todo editor WYSIWYG produz, e as acentuadas do português,
    /// que ainda saem de formulários antigos.
    private static let entidades: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "bull": "•", "middot": "·",
        "laquo": "«", "raquo": "»", "ldquo": "“", "rdquo": "”", "lsquo": "‘",
        "rsquo": "’", "copy": "©", "reg": "®", "trade": "™", "deg": "°",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§",
        "aacute": "á", "agrave": "à", "acirc": "â", "atilde": "ã", "auml": "ä",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë",
        "iacute": "í", "icirc": "î", "iuml": "ï",
        "oacute": "ó", "ograve": "ò", "ocirc": "ô", "otilde": "õ", "ouml": "ö",
        "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü",
        "ccedil": "ç", "ntilde": "ñ",
        "Aacute": "Á", "Agrave": "À", "Acirc": "Â", "Atilde": "Ã",
        "Eacute": "É", "Ecirc": "Ê", "Iacute": "Í",
        "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Uacute": "Ú", "Ccedil": "Ç",
    ]

    /// `&amp;`, `&#233;` e `&#xE9;`.
    ///
    /// `&` que não abre entidade nenhuma fica como está — em vez de sumir, que
    /// é o que uma substituição descuidada faz com "R&D".
    static func decodeEntities(_ texto: String) -> String {
        guard texto.contains("&") else { return texto }
        var saida = ""
        var i = texto.startIndex
        while i < texto.endIndex {
            guard texto[i] == "&" else {
                saida.append(texto[i])
                i = texto.index(after: i)
                continue
            }
            // Teto de busca: um `&` solto num texto de 100 kB não pode custar
            // uma varredura até o fim para descobrir que não era entidade.
            let limite = texto.index(i, offsetBy: 12, limitedBy: texto.endIndex) ?? texto.endIndex
            // O miolo termina no primeiro `;` — mas a busca por ele para num
            // `&` ou num espaço. Sem isso, "P&D e R&amp;D" acha o `;` do
            // `&amp;` lá adiante, conclui que "D e R&amp" não é entidade
            // nenhuma e devolve o texto com o `&amp;` intacto no meio: um `&`
            // solto contaminando a entidade seguinte.
            let alcance = texto[texto.index(after: i)..<limite]
                .prefix { $0 != "&" && !$0.isWhitespace }
            guard let ponto = alcance.firstIndex(of: ";") else {
                saida.append("&")
                i = texto.index(after: i)
                continue
            }
            let miolo = String(texto[texto.index(after: i)..<ponto])
            if let pronta = entidades[miolo] {
                saida += pronta
            } else if let escalar = escalarNumerico(miolo) {
                saida.append(Character(escalar))
            } else if let pronta = entidades[miolo.lowercased()] {
                saida += pronta
            } else {
                saida += "&\(miolo);"
            }
            i = texto.index(after: ponto)
        }
        return saida
    }

    private static func escalarNumerico(_ miolo: String) -> Unicode.Scalar? {
        guard miolo.hasPrefix("#") else { return nil }
        let resto = miolo.dropFirst()
        let valor: UInt32?
        if resto.hasPrefix("x") || resto.hasPrefix("X") {
            valor = UInt32(resto.dropFirst(), radix: 16)
        } else {
            valor = UInt32(resto, radix: 10)
        }
        guard let valor else { return nil }
        return Unicode.Scalar(valor)
    }
}
