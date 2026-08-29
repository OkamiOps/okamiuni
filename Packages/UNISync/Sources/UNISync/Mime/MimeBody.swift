import Foundation

/// O corpo de um email de verdade, virando texto.
///
/// **É a peça que faltava.** O `BODY[TEXT]` do IMAP não entrega "o texto da
/// mensagem": ele entrega a **fonte** da mensagem depois dos cabeçalhos — que
/// numa mensagem moderna é quase sempre um `multipart/alternative` com uma
/// parte `text/plain` em quoted-printable e uma `text/html` em base64, com
/// fronteiras (`--xyz`) e sub-cabeçalhos no meio. Gravar isso como parágrafo é
/// o que pôs `Content-Type: multipart/alternative; boundary="…"` no leitor do
/// dono, e `=E7` no lugar de `ç`.
///
/// Puro por construção: nada aqui abre conexão, lê banco nem olha relógio. É a
/// parte que mais erra e a que mais barato se testa — a mesma razão pela qual
/// `GmailMessageParser` mora sozinho num arquivo.
///
/// **Uma regra, um lugar.** Os parágrafos saem de
/// `GmailMessageParser.paragraphs(from:)`; o quoted-printable daqui é o mesmo
/// que o `MailAddress` usa para o RFC 2047 (a variante "Q" difere em dois
/// interruptores, não em implementação). Nada aqui é uma segunda cópia de uma
/// regra que já existe.
public enum MimeBody {
    /// Quantos níveis de `multipart` dentro de `multipart` vale a pena descer.
    ///
    /// Oito é folga larga sobre o que existe no mundo (`mixed` ▸ `related` ▸
    /// `alternative` são três) e é um teto, não uma opinião: uma mensagem
    /// forjada com mil níveis aninhados faria a recursão comer a pilha do
    /// processo por causa de um email.
    static let profundidadeMaxima = 8

    // MARK: - A entrada da carga

    /// O texto do corpo, decodificado, a partir da fonte crua.
    ///
    /// - Parameters:
    ///   - raw: o que o `BODY[TEXT]` (ou equivalente) entregou.
    ///   - contentType: o `Content-Type` do **cabeçalho da mensagem**, quando
    ///     ele foi buscado. Nulo é aceito e não é desistência: sem ele, a
    ///     fronteira e os sub-cabeçalhos são farejados do próprio texto — que é
    ///     exatamente a situação dos corpos já gravados no banco, onde
    ///     cabeçalho nenhum sobreviveu.
    ///   - contentTransferEncoding: idem, para o `Content-Transfer-Encoding`.
    public static func text(
        raw: String, contentType: String? = nil, contentTransferEncoding: String? = nil
    ) -> String {
        var tipo = contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
        var codificacao = contentTransferEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        var corpo = normaliza(raw)

        // Cabeçalhos que vazaram para dentro do texto. Acontece de dois jeitos:
        // um `FETCH` que trouxe cabeçalho e corpo juntos, e um corpo gravado por
        // uma versão anterior deste app, que é o caso do banco do dono.
        if tipo == nil || tipo?.isEmpty == true,
           let (cabecalhos, resto) = cabecalhosNaFrente(corpo) {
            tipo = cabecalhos["content-type"]
            codificacao = codificacao ?? cabecalhos["content-transfer-encoding"]
            corpo = resto
        }
        // Sem `Content-Type` nenhum e uma fronteira na frente: é multipart, e a
        // fronteira está escrita ali mesmo. Sem esta linha, o corpo do dono
        // continuaria saindo cru — é o `--` que ele vê na primeira linha.
        if tipo == nil || tipo?.isEmpty == true, let limite = fronteiraSolta(corpo) {
            tipo = "multipart/mixed; boundary=\"\(limite)\""
        }

        return resolve(
            corpo: corpo, tipo: tipo ?? "text/plain",
            codificacao: codificacao ?? "", profundidade: 0
        )
    }

    /// O mesmo, já em parágrafos — que é a forma que o modelo (`Message.body`)
    /// e o leitor usam.
    public static func paragraphs(
        raw: String, contentType: String? = nil, contentTransferEncoding: String? = nil
    ) -> [String] {
        GmailMessageParser.paragraphs(
            from: text(
                raw: raw, contentType: contentType,
                contentTransferEncoding: contentTransferEncoding
            )
        )
    }

    // MARK: - A árvore

    /// Uma folha de texto da árvore MIME: o tipo dela, e o texto já decodificado.
    struct Folha {
        let mime: String
        let texto: String
    }

    /// A escolha, dada a árvore: `text/plain` primeiro; `text/html` virado
    /// texto quando não houver plain nenhum.
    ///
    /// **Nessa ordem, e não "a última parte do alternative"**, que é o que o RFC
    /// 2046 sugere para quem renderiza rich text. Este leitor desenha
    /// `[String]` de parágrafos: a parte mais rica é a que ele menos consegue
    /// mostrar, e preferi-la encheria a tela de marcação para depois a arrancar.
    private static func resolve(
        corpo: String, tipo: String, codificacao: String, profundidade: Int
    ) -> String {
        let folhas = folhas(
            corpo: corpo, tipo: tipo, codificacao: codificacao, profundidade: profundidade
        )
        if let plana = folhas.first(where: { $0.mime == "text/plain" }) {
            return plana.texto
        }
        if let html = folhas.first(where: { $0.mime == "text/html" }) {
            return textFromHTML(html.texto)
        }
        return ""
    }

    /// As folhas de **texto** da árvore, na ordem do documento.
    ///
    /// Anexos e imagens não entram: `text/*` é o único ramo que vira leitura.
    /// Uma parte marcada `Content-Disposition: attachment` também fica de fora
    /// mesmo sendo texto — um `.csv` anexado é arquivo, não a mensagem.
    private static func folhas(
        corpo: String, tipo: String, codificacao: String, profundidade: Int
    ) -> [Folha] {
        let mime = mimeType(de: tipo)
        guard mime.hasPrefix("multipart/") else {
            guard mime.hasPrefix("text/") else { return [] }
            let dados = decodificaTransporte(corpo, codificacao: codificacao)
            return [Folha(mime: mime, texto: string(de: dados, charset: charset(de: tipo)))]
        }
        guard profundidade < profundidadeMaxima, let limite = parametro("boundary", em: tipo) else {
            return []
        }
        var encontradas: [Folha] = []
        for parte in partes(de: corpo, limite: limite) {
            let (cabecalhos, conteudo) = separaCabecalhos(parte)
            if let disposicao = cabecalhos["content-disposition"],
               disposicao.lowercased().contains("attachment") {
                continue
            }
            encontradas += folhas(
                corpo: conteudo,
                tipo: cabecalhos["content-type"] ?? "text/plain",
                codificacao: cabecalhos["content-transfer-encoding"] ?? "",
                profundidade: profundidade + 1
            )
        }
        return encontradas
    }

    /// O conteúdo de cada parte entre as fronteiras.
    ///
    /// O que vem **antes** da primeira fronteira é o preâmbulo ("se você está
    /// lendo isto, seu cliente não fala MIME") e o que vem depois da de
    /// fechamento é o epílogo: os dois são descartados por definição, e mostrar
    /// qualquer um dos dois seria mostrar a mensagem errada.
    static func partes(de corpo: String, limite: String) -> [String] {
        let abre = "--" + limite
        let fecha = abre + "--"
        var partes: [String] = []
        var atual: [Substring]?
        for linha in corpo.split(separator: "\n", omittingEmptySubsequences: false) {
            // As fronteiras podem trazer espaço em branco à direita — o RFC
            // permite, e alguns servidores produzem.
            let podada = linha.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }
            let semRabo = String(podada.reversed())
            if semRabo == fecha {
                if let atual { partes.append(atual.joined(separator: "\n")) }
                atual = nil
                break
            }
            if semRabo == abre {
                if let atual { partes.append(atual.joined(separator: "\n")) }
                atual = []
                continue
            }
            atual?.append(linha)
        }
        // Fronteira de fechamento ausente (mensagem truncada, servidor
        // desleixado): a última parte ainda é conteúdo de verdade, e jogá-la
        // fora deixaria a mensagem vazia por causa de uma linha que faltou.
        if let atual { partes.append(atual.joined(separator: "\n")) }
        return partes
    }

    // MARK: - Cabeçalhos

    /// Os cabeçalhos de uma parte (até a primeira linha em branco) e o que vem
    /// depois deles.
    ///
    /// As continuações — linha começando com espaço ou tabulação — são
    /// **desdobradas** para a linha anterior: um `Content-Type` longo é quebrado
    /// assim por todo servidor que existe, e ler a segunda linha como um
    /// cabeçalho novo perderia justamente o `boundary=`, que é o que costuma
    /// sobrar para ela.
    static func separaCabecalhos(_ texto: String) -> ([String: String], String) {
        let linhas = texto.split(separator: "\n", omittingEmptySubsequences: false)
        var cru: [String] = []
        var indice = 0
        while indice < linhas.count {
            let linha = String(linhas[indice])
            if linha.trimmingCharacters(in: .whitespaces).isEmpty { indice += 1; break }
            if linha.hasPrefix(" ") || linha.hasPrefix("\t"), !cru.isEmpty {
                cru[cru.count - 1] += " " + linha.trimmingCharacters(in: .whitespaces)
            } else {
                cru.append(linha)
            }
            indice += 1
        }
        var mapa: [String: String] = [:]
        for linha in cru {
            guard let dois = linha.firstIndex(of: ":") else { continue }
            let nome = String(linha[linha.startIndex..<dois])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let valor = String(linha[linha.index(after: dois)...])
                .trimmingCharacters(in: .whitespaces)
            // RFC 2047 nos cabeçalhos da parte, pelo mesmo decodificador do
            // assunto e do remetente: um `filename` acentuado chega codificado
            // aqui do mesmo jeito que num `Subject`.
            if mapa[nome] == nil { mapa[nome] = MailAddress.decodeRFC2047(valor) }
        }
        return (mapa, indice < linhas.count ? linhas[indice...].joined(separator: "\n") : "")
    }

    /// Os cabeçalhos que vazaram para a frente do corpo, se houver algum.
    ///
    /// `nil` quando a primeira linha não é cabeçalho — que é o caso normal de
    /// um `BODY[TEXT]` bem-comportado, e é por isso que a resposta é opcional em
    /// vez de um mapa vazio: "não havia cabeçalho" e "havia e não dizia nada"
    /// levam a caminhos diferentes lá em cima.
    static func cabecalhosNaFrente(_ corpo: String) -> ([String: String], String)? {
        guard let primeira = corpo.split(separator: "\n").first else { return nil }
        let chaves = ["content-type:", "content-transfer-encoding:", "mime-version:"]
        let dobrada = primeira.lowercased()
        guard chaves.contains(where: { dobrada.hasPrefix($0) }) else { return nil }
        let (cabecalhos, resto) = separaCabecalhos(corpo)
        guard cabecalhos["content-type"] != nil
                || cabecalhos["content-transfer-encoding"] != nil else { return nil }
        return (cabecalhos, resto)
    }

    /// A fronteira escrita na primeira linha útil, quando não há `Content-Type`
    /// nenhum para a declarar.
    ///
    /// Só conta como fronteira o que tem cara de fronteira: dois traços e ao
    /// menos quatro caracteres do alfabeto que o RFC 2046 permite. `--` sozinho
    /// é o separador de assinatura que meio mundo usa, e tomá-lo por fronteira
    /// engoliria a assinatura de toda mensagem escrita à moda antiga.
    static func fronteiraSolta(_ corpo: String) -> String? {
        for linha in corpo.split(separator: "\n").prefix(3) {
            let podada = linha.trimmingCharacters(in: .whitespaces)
            guard podada.hasPrefix("--"), !podada.hasSuffix("--") else { continue }
            let candidata = String(podada.dropFirst(2))
            guard candidata.count >= 4, candidata.allSatisfy(ehDeFronteira) else { continue }
            // Uma fronteira sozinha não basta: a linha `----------` de um email
            // decorado passaria no teste acima. O que confirma é o que vem
            // depois dela — uma parte MIME tem sub-cabeçalhos.
            guard corpo.lowercased().contains("content-type:")
                    || corpo.lowercased().contains("content-transfer-encoding:") else { continue }
            return candidata
        }
        return nil
    }

    private static func ehDeFronteira(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "'()+_,-./:=? ".contains(c)
    }

    /// `multipart/alternative; boundary="abc"` → `multipart/alternative`.
    static func mimeType(de cabecalho: String) -> String {
        String(cabecalho.split(separator: ";").first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Um parâmetro de cabeçalho, com ou sem aspas: `boundary=abc` e
    /// `boundary="a b c"` são os dois legais, e o segundo é o único jeito de
    /// escrever uma fronteira com espaço dentro.
    static func parametro(_ nome: String, em cabecalho: String) -> String? {
        let alvo = nome.lowercased() + "="
        let dobrado = cabecalho.lowercased()
        var procura = dobrado.startIndex
        while let achado = dobrado.range(of: alvo, range: procura..<dobrado.endIndex) {
            // O parâmetro é um token depois de `;` ou de espaço — sem isto,
            // `xboundary=` casaria com `boundary=`.
            let antes = achado.lowerBound == dobrado.startIndex
                ? nil
                : dobrado[dobrado.index(before: achado.lowerBound)]
            if antes == nil || antes == ";" || antes == " " || antes == "\t" {
                var resto = Substring(cabecalho[achado.upperBound...])
                if resto.hasPrefix("\"") {
                    resto = resto.dropFirst()
                    if let fecha = resto.firstIndex(of: "\"") {
                        return String(resto[resto.startIndex..<fecha])
                    }
                    return String(resto)
                }
                let valor = resto.prefix { $0 != ";" && !$0.isWhitespace }
                return valor.isEmpty ? nil : String(valor)
            }
            procura = achado.upperBound
        }
        return nil
    }

    // MARK: - Codificações de transporte

    static func decodificaTransporte(_ texto: String, codificacao: String) -> Data {
        switch codificacao.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            return base64(texto) ?? Data(texto.utf8)
        case "quoted-printable":
            return quotedPrintable(texto, sublinhadoEhEspaco: false)
        default:
            // `7bit`, `8bit`, `binary` e o vazio: o texto já é o texto.
            return Data(texto.utf8)
        }
    }

    /// base64 tolerante à quebra de linha — que é como ele **sempre** chega:
    /// o RFC 2045 manda quebrar em 76 colunas, e `Data(base64Encoded:)` recusa
    /// a string inteira por causa das quebras se não lhe pedirem o contrário.
    static func base64(_ texto: String) -> Data? {
        let limpo = texto.filter { !$0.isWhitespace }
        guard !limpo.isEmpty else { return nil }
        var normalizado = limpo
        let sobra = normalizado.count % 4
        if sobra > 0 { normalizado += String(repeating: "=", count: 4 - sobra) }
        // **Sem** `.ignoreUnknownCharacters`, de propósito: com ele, qualquer
        // texto vira base64 "válido" — as letras que não pertencem ao alfabeto
        // somem e o que sobra decodifica em bytes quaisquer. É justamente essa
        // tolerância que faria o farejador de `MimeSniffing` aceitar prosa como
        // bloco base64 e reescrever uma mensagem legítima em despejo binário.
        return Data(base64Encoded: normalizado)
    }

    /// Quoted-printable, nas duas variantes que existem.
    ///
    /// - Parameter sublinhadoEhEspaco: a variante "Q" do RFC 2047, usada em
    ///   cabeçalho, onde `_` vale espaço e não há quebra suave. No corpo
    ///   (RFC 2045) `_` é `_` e o `=` no fim da linha é uma quebra que some.
    ///
    /// Uma função, dois chamadores: `MailAddress.decodeRFC2047` era o outro, e
    /// duas cópias divergiriam no primeiro caso esquisito.
    static func quotedPrintable(_ texto: String, sublinhadoEhEspaco: Bool) -> Data {
        var bytes: [UInt8] = []
        let caracteres = Array(texto)
        var i = 0
        while i < caracteres.count {
            let atual = caracteres[i]
            if atual == "=", !sublinhadoEhEspaco, i + 1 < caracteres.count,
               caracteres[i + 1] == "\n" {
                // Quebra suave: a linha continua na seguinte, e o `=\n` some.
                i += 2
                continue
            }
            if atual == "=", !sublinhadoEhEspaco, i + 2 < caracteres.count,
               caracteres[i + 1] == "\r", caracteres[i + 2] == "\n" {
                i += 3
                continue
            }
            if atual == "=", i + 2 < caracteres.count,
               let byte = UInt8(String(caracteres[(i + 1)...(i + 2)]), radix: 16) {
                bytes.append(byte)
                i += 3
                continue
            }
            if atual == "_", sublinhadoEhEspaco {
                bytes.append(0x20)
                i += 1
                continue
            }
            bytes.append(contentsOf: Array(String(atual).utf8))
            i += 1
        }
        return Data(bytes)
    }

    // MARK: - Charsets

    /// O `charset=` do cabeçalho, traduzido.
    ///
    /// **`iso-8859-1` vira windows-1252 de propósito.** É o que os navegadores
    /// fazem desde o HTML5, e pela razão prática que vale aqui também: metade
    /// dos remetentes que declaram `iso-8859-1` está mandando cp1252 — aspas
    /// curvas, travessão, reticências, tudo na faixa 0x80–0x9F, que o latin1
    /// puro define como controle. Ler ao pé da letra troca a aspa da pessoa por
    /// um caractere de controle invisível.
    static func charset(de cabecalho: String) -> String.Encoding {
        switch (parametro("charset", em: cabecalho) ?? "").lowercased() {
        case "", "utf-8", "utf8", "us-ascii", "ascii", "unicode-1-1-utf-8":
            return .utf8
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "windows-1252",
             "cp1252", "cp-1252", "iso-8859-15", "latin9":
            return .windowsCP1252
        case "iso-8859-2", "iso8859-2", "latin2":
            return .isoLatin2
        case "utf-16", "utf16":
            return .utf16
        default:
            return .utf8
        }
    }

    /// Bytes viram texto — e quando o charset declarado mente, o que vale é o
    /// que decodifica.
    ///
    /// A ordem não é aleatória: UTF-8 é o único que **falha** quando os bytes
    /// não são dele, então tentá-lo primeiro é grátis e decide sozinho.
    /// Windows-1252 e latin1 aceitam qualquer byte e nunca falham — pô-los na
    /// frente faria todo acento UTF-8 de um remetente que declarou
    /// `iso-8859-1` (e são muitos) sair como "Ã£", calado, sem nada a que
    /// recorrer depois.
    ///
    /// A exceção é UTF-16: os bytes dele têm zeros no meio, que são UTF-8
    /// perfeitamente válido — tentar UTF-8 primeiro devolveria a string com um
    /// NUL entre cada letra em vez de falhar.
    static func string(de dados: Data, charset: String.Encoding) -> String {
        if charset == .utf16, let texto = String(data: dados, encoding: charset) { return texto }
        if let texto = String(data: dados, encoding: .utf8) { return texto }
        if let texto = String(data: dados, encoding: charset) { return texto }
        if let texto = String(data: dados, encoding: .windowsCP1252) { return texto }
        return String(decoding: dados, as: UTF8.self)
    }

    private static func normaliza(_ texto: String) -> String {
        texto.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
