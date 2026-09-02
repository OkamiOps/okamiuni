import Foundation

/// HTML virando **blocos**, e não texto.
///
/// ## Por que não é o `MimeBody.textFromHTML`
///
/// Aquele existe para responder "o que esta mensagem diz" quando não há mais
/// nada — e faz isso jogando fora a marcação. É o certo para um `snippet` e é
/// exatamente o defeito da captura do formulário: no leitor completo aquele
/// email é uma tabela HTML alinhada, e na prévia ele saía como quatro
/// parágrafos soltos porque a extração de texto tinha descartado a tabela.
///
/// Este leitor guarda o que aquele descarta: `<table>` de duas colunas vira
/// campo, `<ul>`/`<ol>` vira lista, `<a href>` vira link com o texto da âncora
/// por rótulo, `<b>`/`<i>` viram ênfase, `<blockquote>` vira dobra de
/// histórico.
///
/// ## Por que não é uma `WKWebView`
///
/// A prévia tem 380pt. O leitor completo (`ReaderHTMLBody`) renderiza HTML de
/// verdade porque tem a largura de um email; espremer a mesma `WKWebView` aqui
/// devolveria o leitor cortado — a área morta que o dashboard veio matar — e
/// ainda deixaria a prévia sem poder ser fotografada fora da tela, que é como
/// esta interface é verificada. O alvo aqui é outro: **estrutura suficiente**
/// para os casos que aparecem de verdade em caixa de entrada.
///
/// Tolerante de propósito: HTML de email é malformado por hábito, e a saída
/// certa para uma tag que não fecha é o texto continuar, não a leitura parar.
enum LeitorDeHTML {

    /// Os elementos cujo miolo não é texto da mensagem. Deixá-los passar
    /// despejaria CSS na prévia — o defeito clássico de resolver HTML com uma
    /// expressão regular.
    private static let mudos: Set<String> = ["script", "style", "head", "title", "noscript"]

    /// Os que terminam um parágrafo.
    private static let blocos: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "section", "article",
        "header", "footer", "nav", "aside", "figure", "figcaption", "dl", "dd", "dt",
        "form", "address", "hr", "main",
    ]

    private struct Peca {
        var texto: String
        var forte: Bool
        var italico: Bool
        var destino: URL?
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func eventos(de html: String) -> [CorpoLegivel.Evento] {
        var eventos: [CorpoLegivel.Evento] = []
        var pecas: [Peca] = []

        var mudo: String?
        var forte = 0
        var italico = 0
        var links: [URL] = []

        var listas: [Bool] = []          // ordenada?
        var contagens: [Int] = []
        var itemAberto = false
        var itemTrechos: [Trecho] = []

        var emCelula = false
        var celulas: [[Trecho]] = []
        var celulaTrechos: [Trecho] = []
        var emTabela = 0

        var citacao = 0
        var citacaoTexto = ""

        var nivelTitulo = 0

        func trechosDaCorrida() -> [Trecho] {
            var saida: [Trecho] = []
            for peca in pecas {
                guard !peca.texto.isEmpty else { continue }
                if let destino = peca.destino {
                    let rotulo = peca.texto.trimmingCharacters(in: .whitespaces)
                    let curto = rotulo.isEmpty || CorpoLegivel.endereco(rotulo) != nil
                        ? CorpoLegivel.rotulo(de: destino)
                        : rotulo
                    saida.append(
                        Trecho(
                            texto: curto, destino: destino,
                            forte: peca.forte, italico: peca.italico
                        )
                    )
                } else {
                    saida += CorpoLegivel.trechosDeTexto(
                        peca.texto, forte: peca.forte, italico: peca.italico
                    )
                }
            }
            pecas = []
            return poda(saida)
        }

        func despeja() {
            let trechos = trechosDaCorrida()
            guard !trechos.isEmpty else { return }
            if emCelula {
                celulaTrechos += trechos
            } else if itemAberto {
                itemTrechos += trechos
            } else if let campo = campo(de: trechos) {
                eventos.append(campo)
            } else {
                eventos.append(.linha(trechos, nivel: nivelTitulo))
            }
        }

        func quebraDeBloco() {
            despeja()
            if case .vazia = eventos.last {} else if !eventos.isEmpty {
                eventos.append(.vazia)
            }
        }

        func fechaItem() {
            despeja()
            guard itemAberto else { return }
            itemAberto = false
            let trechos = poda(itemTrechos)
            itemTrechos = []
            guard !trechos.isEmpty else { return }
            let ordenada = listas.last ?? false
            var marcador = "•"
            if ordenada, let ultima = contagens.indices.last {
                contagens[ultima] += 1
                marcador = "\(contagens[ultima])."
            }
            eventos.append(.item(marcador: marcador, ordenada: ordenada, trechos: trechos))
        }

        func fechaCelula() {
            guard emCelula else { return }
            despeja()
            emCelula = false
            celulas.append(poda(celulaTrechos))
            celulaTrechos = []
        }

        func fechaLinhaDaTabela() {
            fechaCelula()
            defer { celulas = [] }
            guard !celulas.isEmpty else { return }
            // Duas colunas é a forma do formulário de site e do recibo: rótulo à
            // esquerda, valor à direita. É a única que vira campo — três colunas
            // são uma grade, e achatá-las em campo mentiria sobre o conteúdo.
            if celulas.count == 2 {
                let chave = celulas[0].map(\.texto).joined()
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                let valor = celulas[1]
                if !chave.isEmpty, !valor.isEmpty, chave.count <= 40 {
                    eventos.append(.campo(chave: chave, valor: valor))
                    return
                }
            }
            for celula in celulas where !celula.isEmpty {
                eventos.append(.linha(celula, nivel: 0))
            }
            eventos.append(.vazia)
        }

        var indice = html.startIndex
        while indice < html.endIndex {
            let caractere = html[indice]
            guard caractere == "<" else {
                if citacao > 0 {
                    citacaoTexto.append(caractere)
                } else if mudo == nil {
                    anexa(String(caractere), a: &pecas, forte: forte > 0, italico: italico > 0, destino: links.last)
                }
                indice = html.index(after: indice)
                continue
            }
            if html[indice...].hasPrefix("<!--") {
                if let fim = html.range(of: "-->", range: indice..<html.endIndex) {
                    indice = fim.upperBound
                } else {
                    indice = html.endIndex
                }
                continue
            }
            guard let fecha = html[indice...].firstIndex(of: ">") else {
                if mudo == nil, citacao == 0 {
                    anexa("<", a: &pecas, forte: forte > 0, italico: italico > 0, destino: links.last)
                }
                indice = html.index(after: indice)
                continue
            }
            let crua = String(html[html.index(after: indice)..<fecha])
            indice = html.index(after: fecha)

            let fechamento = crua.hasPrefix("/")
            let nome = nomeDaTag(crua)

            if let aberto = mudo {
                if fechamento, nome == aberto { mudo = nil }
                continue
            }
            if mudos.contains(nome), !fechamento { mudo = nome; continue }

            if citacao > 0 {
                if nome == "blockquote" {
                    citacao += fechamento ? -1 : 1
                    if citacao == 0 {
                        let texto = arruma(decodifica(citacaoTexto))
                        citacaoTexto = ""
                        if !texto.isEmpty { eventos.append(.dobra(.historico, texto)) }
                    }
                } else if nome == "br" || blocos.contains(nome) || nome == "li" || nome == "tr" {
                    citacaoTexto.append("\n")
                }
                continue
            }

            switch nome {
            case "blockquote" where !fechamento:
                quebraDeBloco()
                citacao = 1
            case "br":
                despeja()
            case "b", "strong":
                forte += fechamento ? -1 : 1
                forte = max(0, forte)
            case "i", "em":
                italico += fechamento ? -1 : 1
                italico = max(0, italico)
            case "a":
                despejaLink(&pecas, fechamento: fechamento, links: &links, crua: crua)
            case "ul", "ol":
                if fechamento {
                    fechaItem()
                    if !listas.isEmpty { listas.removeLast(); contagens.removeLast() }
                } else {
                    quebraDeBloco()
                    listas.append(nome == "ol")
                    contagens.append(0)
                }
            case "li":
                fechaItem()
                if !fechamento { itemAberto = true }
            case "table":
                if fechamento {
                    fechaLinhaDaTabela()
                    emTabela = max(0, emTabela - 1)
                } else {
                    quebraDeBloco()
                    emTabela += 1
                }
            case "tr":
                fechaLinhaDaTabela()
            case "td", "th":
                fechaCelula()
                if !fechamento { emCelula = true }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                quebraDeBloco()
                nivelTitulo = fechamento ? 0 : Int(String(nome.dropFirst())) ?? 0
            default:
                if blocos.contains(nome) { quebraDeBloco() }
            }
        }

        fechaItem()
        fechaLinhaDaTabela()
        despeja()
        return eventos
    }

    // MARK: Peças

    private static func anexa(
        _ texto: String, a pecas: inout [Peca], forte: Bool, italico: Bool, destino: URL?
    ) {
        if var ultima = pecas.last, ultima.forte == forte, ultima.italico == italico,
           ultima.destino == destino {
            ultima.texto += texto
            pecas[pecas.count - 1] = ultima
        } else {
            pecas.append(Peca(texto: texto, forte: forte, italico: italico, destino: destino))
        }
    }

    private static func despejaLink(
        _ pecas: inout [Peca], fechamento: Bool, links: inout [URL], crua: String
    ) {
        if fechamento {
            if !links.isEmpty { links.removeLast() }
            return
        }
        guard let href = atributo("href", em: crua),
              let url = CorpoLegivel.endereco(decodifica(href))
        else { return }
        links.append(url)
    }

    /// O `Chave: valor` que veio como uma linha de HTML — `Nome: Maria` separado
    /// por `<br>` é a mesma forma da tabela, e merece o mesmo alinhamento.
    private static func campo(de trechos: [Trecho]) -> CorpoLegivel.Evento? {
        guard trechos.allSatisfy({ $0.destino == nil }) else { return nil }
        let texto = trechos.map(\.texto).joined()
        guard let (chave, valor) = CorpoLegivel.par(em: texto) else { return nil }
        return .campo(chave: chave, valor: CorpoLegivel.trechosDeTexto(valor))
    }

    /// Espaço de HTML é espaço nenhum: o gerador indenta, e sem colapsar a
    /// prévia sai com trinta espaços à esquerda de cada frase.
    private static func poda(_ trechos: [Trecho]) -> [Trecho] {
        var saida = trechos.map { trecho in
            Trecho(
                texto: colapsa(decodifica(trecho.texto)), destino: trecho.destino,
                forte: trecho.forte, italico: trecho.italico
            )
        }
        while let primeira = saida.first {
            let podado = String(primeira.texto.drop { $0 == " " })
            if podado.isEmpty, primeira.destino == nil { saida.removeFirst(); continue }
            saida[0] = Trecho(
                texto: podado, destino: primeira.destino,
                forte: primeira.forte, italico: primeira.italico
            )
            break
        }
        while let ultima = saida.last {
            let podado = String(ultima.texto.reversed().drop { $0 == " " }.reversed())
            if podado.isEmpty, ultima.destino == nil { saida.removeLast(); continue }
            saida[saida.count - 1] = Trecho(
                texto: podado, destino: ultima.destino,
                forte: ultima.forte, italico: ultima.italico
            )
            break
        }
        return saida.filter { !$0.texto.isEmpty }
    }

    private static func colapsa(_ texto: String) -> String {
        var saida = ""
        var branco = false
        for caractere in texto {
            if caractere.isWhitespace {
                if !branco { saida.append(" ") }
                branco = true
            } else {
                saida.append(caractere)
                branco = false
            }
        }
        return saida
    }

    private static func arruma(_ texto: String) -> String {
        var linhas: [String] = []
        for linha in texto.components(separatedBy: "\n") {
            let podada = colapsa(linha).trimmingCharacters(in: .whitespaces)
            if podada.isEmpty, linhas.last?.isEmpty == true { continue }
            linhas.append(podada)
        }
        while linhas.first?.isEmpty == true { linhas.removeFirst() }
        while linhas.last?.isEmpty == true { linhas.removeLast() }
        return linhas.joined(separator: "\n")
    }

    private static func nomeDaTag(_ crua: String) -> String {
        let semBarra = crua.hasPrefix("/") ? String(crua.dropFirst()) : crua
        return String(semBarra.prefix { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static func atributo(_ nome: String, em crua: String) -> String? {
        let baixa = crua.lowercased()
        var busca = baixa.startIndex
        while let faixa = baixa.range(of: "\(nome)=", range: busca..<baixa.endIndex) {
            let antes = faixa.lowerBound
            let limpo = antes == baixa.startIndex
                || baixa[baixa.index(before: antes)].isWhitespace
            guard limpo else {
                busca = faixa.upperBound
                continue
            }
            let resto = crua[faixa.upperBound...]
            guard let primeira = resto.first else { return nil }
            if primeira == "\"" || primeira == "'" {
                let miolo = resto.dropFirst()
                guard let fim = miolo.firstIndex(of: primeira) else { return nil }
                return String(miolo[miolo.startIndex..<fim])
            }
            return String(resto.prefix { !$0.isWhitespace })
        }
        return nil
    }

    // MARK: Entidades

    private static let entidades: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "bull": "•", "middot": "·",
        "laquo": "«", "raquo": "»", "ldquo": "“", "rdquo": "”", "lsquo": "‘",
        "rsquo": "’", "copy": "©", "reg": "®", "trade": "™", "deg": "°",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§",
    ]

    static func decodifica(_ texto: String) -> String {
        guard texto.contains("&") else { return texto }
        var saida = ""
        var indice = texto.startIndex
        while indice < texto.endIndex {
            guard texto[indice] == "&",
                  let ponto = texto[indice...].firstIndex(of: ";"),
                  texto.distance(from: indice, to: ponto) <= 10
            else {
                saida.append(texto[indice])
                indice = texto.index(after: indice)
                continue
            }
            let corpo = String(texto[texto.index(after: indice)..<ponto])
            if corpo.hasPrefix("#") {
                let numero = corpo.dropFirst()
                let valor: UInt32? = numero.lowercased().hasPrefix("x")
                    ? UInt32(numero.dropFirst(), radix: 16)
                    : UInt32(numero)
                if let valor, let escalar = Unicode.Scalar(valor) {
                    saida.append(Character(escalar))
                    indice = texto.index(after: ponto)
                    continue
                }
            } else if let pronta = entidades[corpo] ?? entidades[corpo.lowercased()] {
                saida.append(pronta)
                indice = texto.index(after: ponto)
                continue
            }
            saida.append(texto[indice])
            indice = texto.index(after: indice)
        }
        return saida
    }
}
