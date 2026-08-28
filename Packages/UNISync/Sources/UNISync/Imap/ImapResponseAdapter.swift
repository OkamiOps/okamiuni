import Foundation

/// A fronteira entre o texto que o servidor manda e os nossos tipos.
///
/// Tudo que sai daqui é `ImapWire.Untagged`, que é nosso e é puro — testável
/// sem NIO, sem rede e sem servidor.
///
/// **A leitura é em bytes, e não em `Character`.** Duas razões, as duas
/// aprendidas do jeito caro: `\r\n` é um grafema **só** para o Swift, então
/// `primeiro == "\r"` é falso justamente na ponta que importa; e o literal
/// `{n}` é contado em **bytes**, então qualquer contagem feita em `Character`
/// erra no primeiro assunto acentuado.
enum ImapResponseAdapter {
    /// Uma linha lógica de resposta untagged virando o nosso caso.
    ///
    /// "Linha lógica" quer dizer: o `CRLFLineDecoder` já juntou os literais
    /// `{n}` ao resto, então o que chega aqui é a resposta inteira, com os
    /// bytes do corpo dentro dela — CRLFs e tudo.
    /// Lança `SyncError.resposta` quando a linha traz um cabeçalho de literal
    /// com tamanho impossível de ler. Não é preciosismo de tipo: o laço de
    /// dígitos multiplica e soma em `Int`, e em Swift `*`/`+` **armadilham** no
    /// estouro — vinte noves dentro de `{}` matavam o processo com SIGTRAP,
    /// dentro do `channelRead` do NIO, com a carga em voo.
    static func untagged(fromLogicalLine linha: String) throws -> ImapWire.Untagged {
        let corpo = linha.hasPrefix("* ") ? String(linha.dropFirst(2)) : linha
        let analise = try Analise(corpo)

        if analise.comecaCom("LIST ") { return list(analise) }
        if analise.comecaCom("SEARCH") { return search(corpo) }
        if analise.comecaCom("OK [") { return okCode(corpo) }
        if let quantas = exists(corpo) { return .exists(quantas) }
        if analise.contem(" FETCH (") || analise.comecaCom("FETCH (") {
            if let linhaFetch = fetch(analise) { return .fetch(linhaFetch) }
        }
        return .outra(corpo)
    }

    // MARK: A análise da linha lógica

    /// Uma linha lógica com os literais **mapeados**.
    ///
    /// Saber onde estão os literais é o que separa ler a resposta de ler o
    /// conteúdo dela por engano. Sem isto, duas coisas acontecem em produção e
    /// em nenhum teste ingênuo: um `UID 999` escrito no corpo de uma mensagem
    /// vira o UID da resposta; e um assunto mandado em literal — o que Dovecot
    /// e Courier fazem com cabeçalho 8-bit ou longo — desloca **todos** os
    /// campos do `ENVELOPE`, deixando remetente e destinatários nulos.
    ///
    /// **O que custa:** um `[Bool]` do tamanho da linha lógica, ou seja, cerca
    /// de um byte por byte de resposta. Para envelope é nada; para um corpo de
    /// um mebibyte é um mebibyte a mais, vivo só enquanto aquela resposta é
    /// interpretada. O caminho de corpo é `bodyText`, uma mensagem por vez e
    /// por demanda — não é o laço de lotes —, então o pico é de uma resposta e
    /// não do lote. Se um dia isso apertar, o corte é mapear só a parte-de-linha
    /// e tratar o conteúdo do literal como opaco; não vale a complexidade
    /// enquanto o pico for este.
    struct Analise {
        let bytes: [UInt8]
        /// `true` onde o byte pertence a um literal — cabeçalho `{n}` incluído.
        private let dentroDeLiteral: [Bool]
        /// Índice de onde o cabeçalho começa → faixa do conteúdo daquele literal.
        private let conteudo: [Int: Range<Int>]

        /// O teto de dígitos do tamanho de um literal — o **mesmo** número que
        /// o `CRLFLineDecoder.tamanhoDoLiteral` já usava (`ImapSession.swift`).
        /// Duas respostas diferentes para a mesma pergunta é o defeito que este
        /// arquivo inteiro existe para não ter.
        static let tetoDeDigitos = 12

        init(_ texto: String) throws {
            let bytes = Array(texto.utf8)
            var literal = [Bool](repeating: false, count: bytes.count)
            var conteudos: [Int: Range<Int>] = [:]
            var aspas = false
            var i = 0
            while i < bytes.count {
                let byte = bytes[i]
                if aspas {
                    if byte == UInt8(ascii: "\\") { i += 2; continue }
                    if byte == UInt8(ascii: "\"") { aspas = false }
                    i += 1
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    aspas = true
                    i += 1
                    continue
                }
                if let cabecalho = try Self.cabecalho(em: bytes, desde: i) {
                    let fim = max(
                        cabecalho.depoisDoCabecalho,
                        min(cabecalho.depoisDoCabecalho + cabecalho.tamanho, bytes.count)
                    )
                    conteudos[i] = cabecalho.depoisDoCabecalho..<fim
                    for marcado in i..<fim { literal[marcado] = true }
                    i = max(fim, i + 1)
                    continue
                }
                i += 1
            }
            self.bytes = bytes
            dentroDeLiteral = literal
            conteudo = conteudos
        }

        /// `{21}`, `{21+}`, `~{21}` seguidos de CRLF (ou só LF) — o cabeçalho de
        /// um literal. Devolve o tamanho e onde o conteúdo começa.
        ///
        /// **Lança** quando os dígitos passam do teto: o `{` já foi visto, então
        /// aquilo *é* um cabeçalho, e continuar multiplicando estoura o `Int` —
        /// que em Swift não dá zero nem `nil`, dá SIGTRAP. Devolver `nil` seria
        /// pior que lançar de outra forma: seguiria lendo o conteúdo do literal
        /// como se fosse protocolo, que é a dessincronia silenciosa que o mapa
        /// de literais existe para impedir.
        static func cabecalho(
            em bytes: [UInt8], desde inicio: Int
        ) throws -> (tamanho: Int, depoisDoCabecalho: Int)? {
            var i = inicio
            if i < bytes.count, bytes[i] == UInt8(ascii: "~") { i += 1 }
            guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return nil }
            i += 1
            var tamanho = 0
            var digitos = 0
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
                digitos += 1
                guard digitos <= tetoDeDigitos else {
                    throw SyncError.resposta(
                        "O servidor IMAP anunciou um literal com mais de \(tetoDeDigitos) dígitos "
                        + "de tamanho — a sincronia da conexão se perdeu."
                    )
                }
                tamanho = tamanho * 10 + Int(bytes[i] - UInt8(ascii: "0"))
                i += 1
            }
            guard digitos > 0 else { return nil }
            // `LITERAL+` (`{21+}`) e `LITERAL-` (`{21-}`).
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, bytes[i] == UInt8(ascii: "}") else { return nil }
            i += 1
            // O CRLF é **obrigatório**, e não opcional: sem ele o `{4}` de um
            // assunto — texto de outra pessoa, no meio da linha — passaria por
            // cabeçalho e mascararia os quatro bytes seguintes, deslocando os
            // campos exatamente como o defeito que este mapa existe para
            // impedir. É também o que alinha esta leitura com a do
            // `CRLFLineDecoder`, que só reconhece literal no fim da linha:
            // duas respostas diferentes para a mesma pergunta é um defeito
            // esperando data.
            if i < bytes.count, bytes[i] == UInt8(ascii: "\r") { i += 1 }
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\n") else { return nil }
            i += 1
            return (tamanho, i)
        }

        private static func maiuscula(_ byte: UInt8) -> UInt8 {
            byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") ? byte - 32 : byte
        }

        /// O índice logo **depois** da chave, procurada só fora dos literais.
        /// A comparação ignora caixa: as palavras do IMAP são ASCII.
        func depoisDe(_ chave: String) -> Int? {
            let alvo = Array(chave.utf8).map(Self.maiuscula)
            guard !alvo.isEmpty, bytes.count >= alvo.count else { return nil }
            var i = 0
            while i + alvo.count <= bytes.count {
                if !dentroDeLiteral[i] {
                    var casou = true
                    for j in 0..<alvo.count where Self.maiuscula(bytes[i + j]) != alvo[j] {
                        casou = false
                        break
                    }
                    if casou { return i + alvo.count }
                }
                i += 1
            }
            return nil
        }

        func contem(_ chave: String) -> Bool { depoisDe(chave) != nil }

        func comecaCom(_ chave: String) -> Bool {
            let alvo = Array(chave.utf8).map(Self.maiuscula)
            guard bytes.count >= alvo.count else { return false }
            for j in 0..<alvo.count where Self.maiuscula(bytes[j]) != alvo[j] { return false }
            return true
        }

        func texto(_ faixa: Range<Int>) -> String {
            guard faixa.lowerBound >= 0, faixa.upperBound <= bytes.count,
                  faixa.lowerBound <= faixa.upperBound else { return "" }
            return String(decoding: bytes[faixa], as: UTF8.self)
        }

        /// A faixa dentro do parêntese que vem depois da chave, respeitando
        /// aspas, aninhamento e literais.
        func grupo(depoisDe chave: String) -> Range<Int>? {
            guard let abre = depoisDe(chave + " (") else { return nil }
            var profundidade = 1
            var i = abre
            var aspas = false
            while i < bytes.count {
                if let faixa = conteudo[i] { i = max(faixa.upperBound, i + 1); continue }
                let byte = bytes[i]
                if aspas {
                    if byte == UInt8(ascii: "\\") { i += 2; continue }
                    if byte == UInt8(ascii: "\"") { aspas = false }
                    i += 1
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""): aspas = true
                case UInt8(ascii: "("): profundidade += 1
                case UInt8(ascii: ")"):
                    profundidade -= 1
                    if profundidade == 0 { return abre..<i }
                default: break
                }
                i += 1
            }
            return abre..<bytes.count
        }

        /// Os itens de primeiro nível de uma faixa, separados por espaço —
        /// **sem** cortar dentro de aspas, de parêntese aninhado ou de literal.
        ///
        /// O corte que não sabe onde os literais estão é exatamente o defeito
        /// que empurra todo campo do `ENVELOPE` uma casa para o lado quando o
        /// assunto vem em `{20}`.
        func itens(de faixa: Range<Int>) -> [Range<Int>] {
            var saida: [Range<Int>] = []
            let limite = min(faixa.upperBound, bytes.count)
            var inicio = max(0, faixa.lowerBound)
            var i = inicio
            var profundidade = 0
            var aspas = false
            while i < limite {
                if let conteudoDoLiteral = conteudo[i] {
                    i = max(min(conteudoDoLiteral.upperBound, limite), i + 1)
                    continue
                }
                let byte = bytes[i]
                if aspas {
                    if byte == UInt8(ascii: "\\") { i += 2; continue }
                    if byte == UInt8(ascii: "\"") { aspas = false }
                    i += 1
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""): aspas = true
                case UInt8(ascii: "("): profundidade += 1
                case UInt8(ascii: ")"): profundidade -= 1
                case UInt8(ascii: " ") where profundidade == 0:
                    if i > inicio { saida.append(inicio..<i) }
                    inicio = i + 1
                default: break
                }
                i += 1
            }
            if limite > inicio { saida.append(inicio..<limite) }
            return saida
        }

        /// O valor de um item: literal, string entre aspas, `NIL` ou átomo.
        func valor(de faixa: Range<Int>) -> String? {
            guard !faixa.isEmpty else { return nil }
            if let conteudoDoLiteral = conteudo[faixa.lowerBound] { return texto(conteudoDoLiteral) }
            let bruto = texto(faixa)
            if bruto.uppercased() == "NIL" { return nil }
            if bruto.hasPrefix("\""), bruto.hasSuffix("\""), bruto.count >= 2 {
                return String(bruto.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return bruto
        }
    }

    // MARK: Cada forma de resposta

    /// `LIST (\HasNoChildren \Trash) "/" "Lixeira"`
    ///
    /// O nome é o item **depois do separador**, e não "o último token" nem "a
    /// última string entre aspas": `* LIST (…) "/" INBOX` é legal no RFC 3501
    /// (a forma átomo), e lê-la pela última string citada devolveria `/` como
    /// nome de pasta — a INBOX sumiria e uma pasta chamada "/" apareceria no
    /// lugar dela.
    private static func list(_ analise: Analise) -> ImapWire.Untagged {
        var atributos: [String] = []
        var depoisDosAtributos = 0
        if let faixa = analise.grupo(depoisDe: "LIST") {
            atributos = analise.itens(de: faixa).compactMap { analise.valor(de: $0) }
            depoisDosAtributos = faixa.upperBound + 1
        }
        let resto = min(depoisDosAtributos, analise.bytes.count)..<analise.bytes.count
        let itens = analise.itens(de: resto)
        // [separador, nome]. Sem separador (servidor esquisito), o que sobrar.
        let nome = itens.count >= 2
            ? analise.valor(de: itens[1])
            : itens.last.flatMap { analise.valor(de: $0) }
        return .list(name: nome ?? "", attributes: atributos)
    }

    /// `SEARCH 9001 9002`
    private static func search(_ corpo: String) -> ImapWire.Untagged {
        .search(corpo.split(separator: " ").compactMap { Int64($0) })
    }

    /// `OK [UIDVALIDITY 1755000000] UIDs valid`
    private static func okCode(_ corpo: String) -> ImapWire.Untagged {
        guard let abre = corpo.firstIndex(of: "["), let fecha = corpo.firstIndex(of: "]"), abre < fecha else {
            return .outra(corpo)
        }
        let miolo = corpo[corpo.index(after: abre)..<fecha]
        let partes = miolo.split(separator: " ", maxSplits: 1)
        return .ok(
            code: String(partes.first ?? ""),
            value: partes.count > 1 ? String(partes[1]) : ""
        )
    }

    /// `2 EXISTS`
    private static func exists(_ corpo: String) -> Int? {
        let partes = corpo.split(separator: " ")
        guard partes.count == 2, partes[1].uppercased() == "EXISTS" else { return nil }
        return Int(partes[0])
    }

    /// `1 FETCH (UID 9001 FLAGS (\Seen) INTERNALDATE "…" ENVELOPE (…))`
    ///
    /// Os campos são lidos por nome, e sempre **fora dos literais**: servidores
    /// mandam a mesma informação em ordens diferentes, e um `UID 999` escrito
    /// dentro do corpo da mensagem não é o UID da resposta.
    private static func fetch(_ analise: Analise) -> ImapWire.FetchLine? {
        guard let uid = inteiroDepois(de: "UID ", em: analise) else { return nil }
        let campos = analise.grupo(depoisDe: "ENVELOPE").map(analise.itens(de:)) ?? []
        return ImapWire.FetchLine(
            uid: uid,
            flags: analise.grupo(depoisDe: "FLAGS").map { faixa in
                analise.itens(de: faixa).compactMap { analise.valor(de: $0) }
            } ?? [],
            internalDate: dataInterna(valorDepois(de: "INTERNALDATE ", em: analise)),
            // ENVELOPE (data assunto from sender reply-to to cc bcc in-reply-to message-id)
            from: campos.count > 2 ? endereco(campos[2], em: analise) : nil,
            to: campos.count > 5 ? endereco(campos[5], em: analise) : nil,
            cc: campos.count > 6 ? endereco(campos[6], em: analise) : nil,
            subject: campos.count > 1 ? analise.valor(de: campos[1]) : nil,
            text: valorDepois(de: "BODY[TEXT] ", em: analise)
        )
    }

    /// `"25-Aug-2026 09:00:00 -0300"` → instante.
    ///
    /// `en_US_POSIX` obrigatório: o mês vem em inglês e o locale da máquina
    /// não pode opinar. Mesma família do bug de fuso do Marco 1.
    static func dataInterna(_ texto: String?) -> Date? {
        guard let texto else { return nil }
        let formatador = DateFormatter()
        formatador.locale = Locale(identifier: "en_US_POSIX")
        formatador.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatador.date(from: texto.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Leituras por nome

    /// O mesmo teto de dígitos do cabeçalho de literal, pela mesma razão: um
    /// `UID` de vinte dígitos é despejo, não número. Aqui a conversão é
    /// `Int64(_: String)`, que devolve `nil` no estouro em vez de armadilhar —
    /// então o teto é sobre o **trabalho**, e não sobre o trap; mas deixar dois
    /// laços de dígitos com regras diferentes no mesmo arquivo é o convite para
    /// o próximo deles voltar a multiplicar à mão.
    private static func inteiroDepois(de chave: String, em analise: Analise) -> Int64? {
        guard let indice = analise.depoisDe(chave) else { return nil }
        var i = indice
        var digitos: [UInt8] = []
        while i < analise.bytes.count, analise.bytes[i] >= UInt8(ascii: "0"),
              analise.bytes[i] <= UInt8(ascii: "9") {
            digitos.append(analise.bytes[i])
            i += 1
            if digitos.count > Analise.tetoDeDigitos { return nil }
        }
        return Int64(String(decoding: digitos, as: UTF8.self))
    }

    /// O item que vem logo depois da chave — literal, entre aspas ou átomo.
    private static func valorDepois(de chave: String, em analise: Analise) -> String? {
        guard let indice = analise.depoisDe(chave) else { return nil }
        let itens = analise.itens(de: indice..<analise.bytes.count)
        guard let primeiro = itens.first else { return nil }
        return analise.valor(de: primeiro)
    }

    /// `(("Marina" NIL "marina" "clientepremium.com"))` → `Marina <marina@…>`.
    ///
    /// Cada endereço é um grupo de quatro: nome, rota (obsoleta), caixa e host.
    /// O nome pode chegar em literal, e por isso a divisão é a mesma de sempre
    /// — `itens(de:)`, que sabe onde os literais estão.
    private static func endereco(_ faixa: Range<Int>, em analise: Analise) -> String? {
        guard analise.bytes.indices.contains(faixa.lowerBound),
              analise.bytes[faixa.lowerBound] == UInt8(ascii: "(") else { return nil }
        let miolo = (faixa.lowerBound + 1)..<max(faixa.lowerBound + 1, faixa.upperBound - 1)
        var enderecos: [String] = []
        for grupo in analise.itens(de: miolo) {
            guard analise.bytes.indices.contains(grupo.lowerBound),
                  analise.bytes[grupo.lowerBound] == UInt8(ascii: "(") else { continue }
            let dentro = (grupo.lowerBound + 1)..<max(grupo.lowerBound + 1, grupo.upperBound - 1)
            let partes = analise.itens(de: dentro)
            guard partes.count >= 4 else { continue }
            let nome = analise.valor(de: partes[0])
            guard let usuario = analise.valor(de: partes[2]),
                  let dominio = analise.valor(de: partes[3]) else { continue }
            let endereco = "\(usuario)@\(dominio)"
            enderecos.append(nome.map { "\($0) <\(endereco)>" } ?? endereco)
        }
        return enderecos.isEmpty ? nil : enderecos.joined(separator: ", ")
    }
}
