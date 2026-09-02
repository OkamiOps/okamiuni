import Foundation

// MARK: - As peças

/// Um pedaço de texto com a forma que ele tem: um link, um negrito, ou prosa.
///
/// O `destino` é o endereço **real**; `texto` é o rótulo curto que a pessoa lê.
/// Os dois são separados de propósito: é exatamente essa separação que
/// transforma uma linha de sessenta caracteres de URL em `resend.com` sem
/// esconder para onde o clique vai — quem desenha põe `destino` no tooltip.
public struct Trecho: Equatable, Sendable, Identifiable {
    public let id: Int
    public let texto: String
    public let destino: URL?
    public let forte: Bool
    public let italico: Bool

    public init(
        id: Int = 0, texto: String, destino: URL? = nil,
        forte: Bool = false, italico: Bool = false
    ) {
        self.id = id
        self.texto = texto
        self.destino = destino
        self.forte = forte
        self.italico = italico
    }

    var comID: (Int) -> Trecho {
        { novo in
            Trecho(id: novo, texto: texto, destino: destino, forte: forte, italico: italico)
        }
    }
}

public struct Paragrafo: Equatable, Sendable, Identifiable {
    public let id: Int
    public let trechos: [Trecho]
    /// 0 é prosa; 1…6 é título, do maior para o menor. Só o HTML produz título.
    public let nivel: Int

    public var texto: String { trechos.map(\.texto).joined() }
}

public struct ItemDeLista: Equatable, Sendable, Identifiable {
    public let id: Int
    /// `1.`, `2.`, `•` — o que a lista mostra na calha.
    public let marcador: String
    public let trechos: [Trecho]

    public var texto: String { trechos.map(\.texto).joined() }
}

public struct Lista: Equatable, Sendable, Identifiable {
    public let id: Int
    public let ordenada: Bool
    public let itens: [ItemDeLista]
}

/// Um `Chave: valor` — a forma do formulário de site, que é tabela no HTML e
/// linha solta no texto plano, e que nos dois casos é a mesma coisa para quem
/// lê.
public struct Campo: Equatable, Sendable, Identifiable {
    public let id: Int
    public let chave: String
    public let valor: [Trecho]

    public var valorSimples: String { valor.map(\.texto).joined() }
}

public struct Campos: Equatable, Sendable, Identifiable {
    public let id: Int
    public let pares: [Campo]
}

/// O que **não** abre sozinho: histórico citado, assinatura, rodapé de
/// newsletter.
///
/// Nada é jogado fora — o texto inteiro fica aqui, e um controle de uma linha o
/// devolve. É a peça que resolve a captura da cadeia de resposta, onde o
/// conteúdo novo era uma linha e o histórico ocupava a tela.
public struct Dobra: Equatable, Sendable, Identifiable {
    public enum Genero: Sendable, Equatable, Hashable {
        case historico
        case assinatura
        case rodape

        var substantivo: String {
            switch self {
            case .historico: "histórico"
            case .assinatura: "assinatura"
            case .rodape: "rodapé"
            }
        }
    }

    public let id: Int
    public let genero: Genero
    public let texto: String

    public var linhas: Int {
        texto.isEmpty ? 0 : texto.components(separatedBy: "\n").count
    }

    /// "Mostrar histórico · 38 linhas". O número é o que informa a decisão: com
    /// ele a pessoa sabe se vale abrir antes de abrir.
    public var rotulo: String {
        let n = linhas
        return "Mostrar \(genero.substantivo) · \(n) linha\(n == 1 ? "" : "s")"
    }

    public var rotuloAberto: String { "Ocultar \(genero.substantivo)" }
}

/// Um bloco do corpo — a unidade que a prévia desenha.
public enum BlocoDeCorpo: Equatable, Sendable, Identifiable {
    case paragrafo(Paragrafo)
    case lista(Lista)
    case campos(Campos)
    case dobra(Dobra)

    public var id: Int {
        switch self {
        case let .paragrafo(p): p.id
        case let .lista(l): l.id
        case let .campos(c): c.id
        case let .dobra(d): d.id
        }
    }

    /// O bloco como texto puro — o que sobra dele quando não há desenho.
    public var textoSimples: String {
        switch self {
        case let .paragrafo(p): p.texto
        case let .lista(l): l.itens.map { "\($0.marcador) \($0.texto)" }.joined(separator: "\n")
        case let .campos(c): c.pares.map { "\($0.chave): \($0.valorSimples)" }.joined(separator: "\n")
        case let .dobra(d): d.texto
        }
    }
}

// MARK: - O analisador

/// O corpo de um email fatiado em blocos, **fora de qualquer `View`**.
///
/// ## O defeito que ela conserta
///
/// A prévia despejava o corpo num `Text` só. Três coisas quebravam nisso, e
/// as três apareceram na caixa de verdade:
///
/// 1. Uma cadeia de resposta mostra uma linha nova e quarenta de histórico
///    citado. Achar a linha nova exigia rolar tudo.
/// 2. Um formulário de site chega como `Nome: …` / `E-mail: …` / `Mensagem: …`
///    e saía como parágrafos soltos, sem alinhamento nenhum.
/// 3. Uma newsletter numera "3 tips" e põe a URL crua no meio da frase: nem a
///    lista parecia lista, nem o link parecia link.
///
/// A resposta não é tipografia melhor no mesmo despejo — é **estrutura**. O que
/// é novo fica; o que é repetição dobra; o que tem forma (lista, campo, link)
/// recebe a forma de volta.
///
/// ## Por que mora aqui, e é `nonisolated`
///
/// Pelo motivo de `docs/decisoes-de-engenharia.md`: `View` é `@MainActor`
/// implícito no Swift 6, e lógica pura pendurada num `static` dentro de uma
/// `View` trapa quando um teste `nonisolated` a chama. Aqui ela é uma função de
/// texto para blocos, e os testes a provam sem abrir janela.
public struct CorpoLegivel: Equatable, Sendable {

    public let blocos: [BlocoDeCorpo]

    public init(blocos: [BlocoDeCorpo]) { self.blocos = blocos }

    public static let vazio = CorpoLegivel(blocos: [])

    /// As dobras, na ordem em que aparecem.
    public var dobras: [Dobra] {
        blocos.compactMap { if case let .dobra(d) = $0 { return d } else { return nil } }
    }

    /// O que a prévia mostra **sem** ninguém abrir nada — o conteúdo novo.
    public var textoVisivel: String {
        blocos
            .filter { if case .dobra = $0 { return false } else { return true } }
            .map(\.textoSimples)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public var isEmpty: Bool { blocos.isEmpty }

    // MARK: A porta única

    /// HTML quando existe, texto quando não.
    ///
    /// O HTML ganha porque é onde a estrutura está: a tabela do formulário, a
    /// lista da newsletter e a âncora do link só existem lá. Extrair texto dele
    /// primeiro é justamente jogar fora o que esta peça veio recuperar.
    public static func de(
        texto: [String], html: String?, flowed: Bool = false, delSp: Bool = false
    ) -> CorpoLegivel {
        de(
            texto: texto.joined(separator: "\n\n"), html: html,
            flowed: flowed, delSp: delSp
        )
    }

    public static func de(
        texto: String, html: String?, flowed: Bool = false, delSp: Bool = false
    ) -> CorpoLegivel {
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let corpo = deHTML(html)
            if !corpo.isEmpty { return corpo }
        }
        return deTextoSimples(texto, flowed: flowed, delSp: delSp)
    }

    // MARK: Texto plano

    public static func deTextoSimples(
        _ raw: String, flowed: Bool = false, delSp: Bool = false
    ) -> CorpoLegivel {
        let refluido = PlainTextReflow.reflow(raw, flowed: flowed, delSp: delSp)
        let linhas = refluido.components(separatedBy: "\n")
        let (corpo, dobras) = fatia(linhas)

        var eventos = corpo.map(evento(deLinha:))
        eventos += dobras.map { Evento.dobra($0.genero, $0.texto) }
        return CorpoLegivel(blocos: desambigua(monta(eventos)))
    }

    // MARK: HTML

    public static func deHTML(_ html: String) -> CorpoLegivel {
        let eventos = aplicaCortes(LeitorDeHTML.eventos(de: html))
        return CorpoLegivel(blocos: desambigua(monta(eventos)))
    }
}

// MARK: - Onde o corpo termina e a repetição começa

extension CorpoLegivel {

    struct Fatia {
        let genero: Dobra.Genero
        let texto: String
    }

    /// Corta as linhas em "o que é novo" e as dobras que vêm depois.
    ///
    /// Uma dobra vai **até o fim** da mensagem, com uma exceção: a assinatura,
    /// que numa resposta vem antes do histórico citado. Por isso o varrimento
    /// para no primeiro corte de histórico ou de rodapé, e só a assinatura
    /// deixa a busca continuar.
    static func fatia(_ linhas: [String]) -> ([String], [Fatia]) {
        var cortes: [(indice: Int, genero: Dobra.Genero)] = []
        for (indice, linha) in linhas.enumerated() {
            guard let genero = generoDeCorte(linha) else { continue }
            if let ultimo = cortes.last {
                // Já estamos dentro de uma dobra do mesmo gênero, ou de uma que
                // vai até o fim.
                if ultimo.genero == genero || ultimo.genero != .assinatura { continue }
                if genero != .historico { continue }
            }
            cortes.append((indice, genero))
        }

        guard let primeiro = cortes.first else { return (podaFim(linhas), []) }

        let corpo = podaFim(Array(linhas[0..<primeiro.indice]))
        var fatias: [Fatia] = []
        for (posicao, corte) in cortes.enumerated() {
            let fim = posicao + 1 < cortes.count ? cortes[posicao + 1].indice : linhas.count
            let texto = podaFim(Array(linhas[corte.indice..<fim]))
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if texto.isEmpty { continue }
            fatias.append(Fatia(genero: corte.genero, texto: texto))
        }
        return (corpo, fatias)
    }

    private static func podaFim(_ linhas: [String]) -> [String] {
        var saida = linhas
        while let ultima = saida.last,
              ultima.trimmingCharacters(in: .whitespaces).isEmpty {
            saida.removeLast()
        }
        while let primeira = saida.first,
              primeira.trimmingCharacters(in: .whitespaces).isEmpty {
            saida.removeFirst()
        }
        return saida
    }

    /// Esta linha abre uma dobra? E de qual gênero?
    static func generoDeCorte(_ linha: String) -> Dobra.Genero? {
        if PlainTextReflow.ehSeparadorDeAssinatura(linha) { return .assinatura }
        if PlainTextReflow.ehCitacao(linha) { return .historico }
        if ehCabecalhoDeCitacao(linha) { return .historico }
        if ehSeparadorDeOriginal(linha) { return .historico }
        if ehMarcaDeRodape(linha) { return .rodape }
        return nil
    }

    /// "On … wrote:", "Em … escreveu:" — a linha que todo cliente de email põe
    /// antes do bloco citado, e que sozinha já não é conteúdo novo.
    static func ehCabecalhoDeCitacao(_ linha: String) -> Bool {
        let podada = linha.trimmingCharacters(in: .whitespaces)
        guard podada.count <= 300, podada.hasSuffix(":") else { return false }
        let baixa = dobrada(podada)
        let fechos = ["wrote:", "escreveu:", "a ecrit:", "schrieb:", "escribio:"]
        return fechos.contains { baixa.hasSuffix($0) }
    }

    /// `-----Original Message-----`, `-----Mensagem original-----`, e a régua de
    /// sublinhados que o Outlook põe no lugar deles.
    static func ehSeparadorDeOriginal(_ linha: String) -> Bool {
        let podada = linha.trimmingCharacters(in: .whitespaces)
        guard !podada.isEmpty else { return false }
        if podada.count >= 20, podada.allSatisfy({ $0 == "_" }) { return true }
        let miolo = dobrada(
            podada.trimmingCharacters(in: CharacterSet(charactersIn: "-_= "))
        )
        return [
            "original message", "mensagem original", "forwarded message",
            "mensagem encaminhada", "message d'origine", "begin forwarded message",
        ].contains(miolo)
    }

    /// O rodapé que toda newsletter tem: descadastro, endereço, "você recebeu
    /// porque…". É repetição legal, não conteúdo — e ocupa meia tela.
    static func ehMarcaDeRodape(_ linha: String) -> Bool {
        let baixa = dobrada(linha.trimmingCharacters(in: .whitespaces))
        guard !baixa.isEmpty, baixa.count <= 400 else { return false }
        return [
            "descadastr", "cancelar inscri", "cancele a inscri", "cancelar a inscri",
            "unsubscribe", "voce recebeu este email porque", "voce recebeu esta mensagem porque",
            "voce recebeu porque", "you received this", "you are receiving this",
            "gerenciar prefer", "manage your preferences", "email preferences",
            "nao deseja mais receber", "nao quer mais receber", "opt out of these",
        ].contains { baixa.contains($0) }
    }

    /// Minúsculas e sem acento — para "Você recebeu" e "voce recebeu" serem a
    /// mesma pista.
    private static func dobrada(_ texto: String) -> String {
        texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}

// MARK: - Da linha ao evento

extension CorpoLegivel {

    enum Evento: Equatable {
        case vazia
        case linha([Trecho], nivel: Int)
        case item(marcador: String, ordenada: Bool, trechos: [Trecho])
        case campo(chave: String, valor: [Trecho])
        case dobra(Dobra.Genero, String)

        var textoSimples: String {
            switch self {
            case .vazia: ""
            case let .linha(t, _): t.map(\.texto).joined()
            case let .item(_, _, t): t.map(\.texto).joined()
            case let .campo(chave, valor): "\(chave): \(valor.map(\.texto).joined())"
            case let .dobra(_, texto): texto
            }
        }
    }

    static func evento(deLinha linha: String) -> Evento {
        let podada = linha.trimmingCharacters(in: .whitespaces)
        if podada.isEmpty { return .vazia }
        if PlainTextReflow.ehLista(podada), let (marcador, resto) = marcador(de: podada) {
            return .item(
                marcador: marcador,
                ordenada: marcador.first?.isNumber == true,
                trechos: trechosDeTexto(resto)
            )
        }
        if let (chave, valor) = par(em: podada) {
            return .campo(chave: chave, valor: trechosDeTexto(valor))
        }
        return .linha(trechosDeTexto(podada), nivel: 0)
    }

    /// `1. Envie` → (`1.`, `Envie`); `- item` → (`•`, `item`).
    static func marcador(de linha: String) -> (String, String)? {
        guard let primeira = linha.first else { return nil }
        if "-*•–—+".contains(primeira) {
            let resto = linha.dropFirst().trimmingCharacters(in: .whitespaces)
            return ("•", resto)
        }
        guard primeira.isNumber else { return nil }
        let numero = linha.prefix { $0.isNumber }
        let depois = linha.dropFirst(numero.count)
        guard let marca = depois.first, marca == "." || marca == ")" else { return nil }
        let resto = depois.dropFirst().trimmingCharacters(in: .whitespaces)
        return ("\(numero)\(marca)", resto)
    }

    /// `Chave: valor` — mas só quando a chave **parece rótulo**.
    ///
    /// Sem esta cerca, "Assunto: isto aqui é uma frase inteira." viraria campo,
    /// e a prosa do email sairia formatada como planilha. A chave é curta, tem
    /// poucas palavras e não tem pontuação de frase; e um par sozinho não faz
    /// tabela — quem exige o par ser dois é o montador.
    static func par(em linha: String) -> (String, String)? {
        guard let indice = linha.firstIndex(of: ":") else { return nil }
        let chave = String(linha[linha.startIndex..<indice])
            .trimmingCharacters(in: .whitespaces)
        let valor = String(linha[linha.index(after: indice)...])
            .trimmingCharacters(in: .whitespaces)
        guard !chave.isEmpty, !valor.isEmpty, chave.count <= 40 else { return nil }
        guard !chave.contains("/"), !chave.contains("@") else { return nil }
        // O dois-pontos de `https://` não é o dois-pontos de um rótulo. Sem
        // esta cerca, "Confira em https://…" virava o campo "Confira em https"
        // e o link se partia ao meio — foi assim que este defeito apareceu.
        guard !valor.hasPrefix("//") else { return nil }
        guard !chave.lowercased().hasSuffix("http"), !chave.lowercased().hasSuffix("https")
        else { return nil }
        guard chave.split(separator: " ").count <= 5 else { return nil }
        guard !chave.contains(where: { ".!?;".contains($0) }) else { return nil }
        return (chave, valor)
    }
}

// MARK: - URL crua virando link

extension CorpoLegivel {

    /// `https://…` e `www.…` no meio da prosa.
    ///
    /// Os parênteses e as aspas ficam de fora do casamento de propósito: uma URL
    /// entre parênteses é o caso comum, e engolir o fecho quebraria o endereço.
    private static let enderecos = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?://|www\.)[^\s<>"'()\[\]{}«»]+"#
    )

    /// A pontuação que fecha a frase e que **não** é parte do endereço.
    private static let pontuacaoFinal = CharacterSet(charactersIn: ".,;:!?…-")

    static func trechosDeTexto(_ texto: String, forte: Bool = false, italico: Bool = false)
        -> [Trecho]
    {
        guard !texto.isEmpty else { return [] }
        let alcance = NSRange(texto.startIndex..<texto.endIndex, in: texto)
        let achados = enderecos.matches(in: texto, range: alcance)
        guard !achados.isEmpty else {
            return [Trecho(texto: texto, forte: forte, italico: italico)]
        }

        var saida: [Trecho] = []
        var cursor = texto.startIndex
        for achado in achados {
            guard let faixa = Range(achado.range, in: texto) else { continue }
            var fim = faixa.upperBound
            while fim > faixa.lowerBound,
                  let escalar = texto[texto.index(before: fim)].unicodeScalars.first,
                  pontuacaoFinal.contains(escalar) {
                fim = texto.index(before: fim)
            }
            let bruto = String(texto[faixa.lowerBound..<fim])
            guard let url = endereco(bruto) else { continue }
            if cursor < faixa.lowerBound {
                saida.append(
                    Trecho(
                        texto: String(texto[cursor..<faixa.lowerBound]),
                        forte: forte, italico: italico
                    )
                )
            }
            saida.append(
                Trecho(texto: rotulo(de: url), destino: url, forte: forte, italico: italico)
            )
            cursor = fim
        }
        if cursor < texto.endIndex {
            saida.append(
                Trecho(texto: String(texto[cursor...]), forte: forte, italico: italico)
            )
        }
        return saida
    }

    static func endereco(_ bruto: String) -> URL? {
        let completo = bruto.lowercased().hasPrefix("www.") ? "https://\(bruto)" : bruto
        guard let url = URL(string: completo), let esquema = url.scheme?.lowercased(),
              esquema == "http" || esquema == "https", url.host != nil
        else { return nil }
        return url
    }

    /// O rótulo curto: o domínio, sem `www.`. Sessenta caracteres de caminho não
    /// dizem nada a quem lê — o domínio diz para **onde** vai, que é a pergunta.
    static func rotulo(de url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Três links "resend.com" seguidos, cada um para um lugar diferente.
    ///
    /// Foi o que a primeira renderização da newsletter mostrou, e é um defeito
    /// de leitura, não de estilo: rótulos idênticos para destinos diferentes
    /// obrigam a passar o mouse em cada um para saber qual é qual — que é
    /// exatamente o trabalho que esta peça existe para poupar.
    ///
    /// Quando o mesmo domínio aparece com destinos diferentes **no mesmo
    /// corpo**, o primeiro trecho do caminho entra no rótulo. Um link sozinho
    /// continua sendo só o domínio: acrescentar caminho onde não há confusão é
    /// alongar sem informar.
    static func desambigua(_ blocos: [BlocoDeCorpo]) -> [BlocoDeCorpo] {
        var porHost: [String: Set<String>] = [:]
        percorre(blocos) { trecho in
            guard let destino = trecho.destino, trecho.texto == rotulo(de: destino) else { return }
            porHost[rotulo(de: destino), default: []].insert(destino.absoluteString)
        }
        let ambiguos = Set(porHost.filter { $0.value.count > 1 }.keys)
        guard !ambiguos.isEmpty else { return blocos }

        return mapeia(blocos) { trecho in
            guard let destino = trecho.destino,
                  trecho.texto == rotulo(de: destino),
                  ambiguos.contains(trecho.texto),
                  let primeiro = destino.pathComponents.first(where: { $0 != "/" && !$0.isEmpty })
            else { return trecho }
            let curto = primeiro.count > 24 ? String(primeiro.prefix(24)) + "…" : primeiro
            return Trecho(
                id: trecho.id, texto: "\(trecho.texto)/\(curto)", destino: destino,
                forte: trecho.forte, italico: trecho.italico
            )
        }
    }

    private static func percorre(_ blocos: [BlocoDeCorpo], _ visita: (Trecho) -> Void) {
        for bloco in blocos {
            switch bloco {
            case let .paragrafo(p): p.trechos.forEach(visita)
            case let .lista(l): l.itens.forEach { $0.trechos.forEach(visita) }
            case let .campos(c): c.pares.forEach { $0.valor.forEach(visita) }
            case .dobra: break
            }
        }
    }

    private static func mapeia(
        _ blocos: [BlocoDeCorpo], _ troca: (Trecho) -> Trecho
    ) -> [BlocoDeCorpo] {
        blocos.map { bloco in
            switch bloco {
            case let .paragrafo(p):
                .paragrafo(Paragrafo(id: p.id, trechos: p.trechos.map(troca), nivel: p.nivel))
            case let .lista(l):
                .lista(
                    Lista(
                        id: l.id, ordenada: l.ordenada,
                        itens: l.itens.map {
                            ItemDeLista(id: $0.id, marcador: $0.marcador, trechos: $0.trechos.map(troca))
                        }
                    )
                )
            case let .campos(c):
                .campos(
                    Campos(
                        id: c.id,
                        pares: c.pares.map { Campo(id: $0.id, chave: $0.chave, valor: $0.valor.map(troca)) }
                    )
                )
            case .dobra:
                bloco
            }
        }
    }
}

// MARK: - Do evento ao bloco

extension CorpoLegivel {

    /// Junta eventos vizinhos da mesma forma: itens viram uma lista, campos
    /// viram uma tabela, linhas viram um parágrafo.
    ///
    /// A regra do campo é a única com número: **dois** pares seguidos fazem
    /// tabela, um sozinho continua prosa. É a diferença entre o formulário do
    /// site e uma frase que por acaso tem dois-pontos.
    static func monta(_ eventos: [Evento]) -> [BlocoDeCorpo] {
        var blocos: [BlocoDeCorpo] = []
        var proximoBloco = 0
        var proximoTrecho = 0

        func numerado(_ trechos: [Trecho]) -> [Trecho] {
            trechos.map { trecho in
                defer { proximoTrecho += 1 }
                return trecho.comID(proximoTrecho)
            }
        }

        var linhasPendentes: [[Trecho]] = []
        var itensPendentes: [(marcador: String, trechos: [Trecho])] = []
        var listaOrdenada = false
        var camposPendentes: [(chave: String, valor: [Trecho])] = []

        func fechaLinhas() {
            guard !linhasPendentes.isEmpty else { return }
            var trechos: [Trecho] = []
            for (posicao, linha) in linhasPendentes.enumerated() {
                if posicao > 0 { trechos.append(Trecho(texto: " ")) }
                trechos += linha
            }
            blocos.append(
                .paragrafo(
                    Paragrafo(id: proximoBloco, trechos: numerado(trechos), nivel: 0)
                )
            )
            proximoBloco += 1
            linhasPendentes = []
        }

        func fechaItens() {
            guard !itensPendentes.isEmpty else { return }
            var itens: [ItemDeLista] = []
            for (posicao, pendente) in itensPendentes.enumerated() {
                itens.append(
                    ItemDeLista(
                        id: posicao, marcador: pendente.marcador,
                        trechos: numerado(pendente.trechos)
                    )
                )
            }
            blocos.append(
                .lista(Lista(id: proximoBloco, ordenada: listaOrdenada, itens: itens))
            )
            proximoBloco += 1
            itensPendentes = []
        }

        func fechaCampos() {
            guard !camposPendentes.isEmpty else { return }
            if camposPendentes.count == 1, let unico = camposPendentes.first {
                // Um par sozinho é prosa. Devolve o texto inteiro à linha.
                linhasPendentes.append(
                    [Trecho(texto: "\(unico.chave): ")] + unico.valor
                )
                camposPendentes = []
                fechaLinhas()
                return
            }
            var pares: [Campo] = []
            for (posicao, pendente) in camposPendentes.enumerated() {
                pares.append(
                    Campo(id: posicao, chave: pendente.chave, valor: numerado(pendente.valor))
                )
            }
            blocos.append(.campos(Campos(id: proximoBloco, pares: pares)))
            proximoBloco += 1
            camposPendentes = []
        }

        func fechaTudo() {
            fechaItens()
            fechaCampos()
            fechaLinhas()
        }

        for evento in eventos {
            switch evento {
            case .vazia:
                fechaTudo()
            case let .linha(trechos, nivel):
                fechaItens()
                fechaCampos()
                if nivel > 0 {
                    fechaLinhas()
                    blocos.append(
                        .paragrafo(
                            Paragrafo(id: proximoBloco, trechos: numerado(trechos), nivel: nivel)
                        )
                    )
                    proximoBloco += 1
                } else {
                    linhasPendentes.append(trechos)
                }
            case let .item(marcador, ordenada, trechos):
                fechaCampos()
                fechaLinhas()
                if !itensPendentes.isEmpty, ordenada != listaOrdenada { fechaItens() }
                listaOrdenada = ordenada
                itensPendentes.append((marcador, trechos))
            case let .campo(chave, valor):
                fechaItens()
                fechaLinhas()
                camposPendentes.append((chave, valor))
            case let .dobra(genero, texto):
                fechaTudo()
                blocos.append(.dobra(Dobra(id: proximoBloco, genero: genero, texto: texto)))
                proximoBloco += 1
            }
        }
        fechaTudo()
        return blocos
    }

    /// A mesma leitura de dobras, agora sobre um fluxo de eventos — é o que faz
    /// o rodapé de descadastro dobrar também quando ele veio em HTML.
    static func aplicaCortes(_ eventos: [Evento]) -> [Evento] {
        var saida: [Evento] = []
        var acumulado: [String] = []
        var genero: Dobra.Genero?

        func fecha() {
            guard let atual = genero else { return }
            let texto = acumulado.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !texto.isEmpty { saida.append(.dobra(atual, texto)) }
            acumulado = []
            genero = nil
        }

        for evento in eventos {
            if case let .dobra(g, texto) = evento {
                fecha()
                saida.append(.dobra(g, texto))
                continue
            }
            if genero != nil {
                acumulado.append(evento.textoSimples)
                continue
            }
            let texto = evento.textoSimples
            if let novo = generoDeCorte(texto), novo != .assinatura || !texto.isEmpty {
                genero = novo
                acumulado = [texto]
                continue
            }
            saida.append(evento)
        }
        fecha()
        return saida
    }
}
