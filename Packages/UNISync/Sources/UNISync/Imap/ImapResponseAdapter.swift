import Foundation
import NIOCore
import NIOIMAP

/// A fronteira com o `swift-nio-imap`. **É o único arquivo do app que conhece
/// os tipos de resposta da biblioteca.**
///
/// Tudo que sai daqui é `ImapWire.Untagged`, que é nosso e é puro. A troco de
/// um arquivo de tradução, a lógica inteira do IMAP fica testável sem NIO, e
/// uma mudança de forma na biblioteca custa este arquivo em vez de custar a
/// sessão, a carga inicial e os testes de todas as duas.
enum ImapResponseAdapter {
    /// Uma linha lógica de resposta untagged virando o nosso caso.
    ///
    /// A tradução é feita sobre o **texto** da linha, e não sobre a árvore da
    /// biblioteca, por um motivo prático: a superfície que a gente usa é
    /// pequena (LIST, SEARCH, EXISTS, OK[código], FETCH) e a árvore da
    /// biblioteca é grande e versionada. O que a biblioteca faz por nós é o
    /// trabalho que a gente não sabe fazer: contar os bytes de um literal
    /// `{123}` para que a linha lógica chegue aqui inteira — é o
    /// `ImapFrameJoiner`, logo abaixo, sobre o `FrameDecoder` dela.
    static func untagged(fromLogicalLine linha: String) -> ImapWire.Untagged {
        let corpo = linha.hasPrefix("* ") ? String(linha.dropFirst(2)) : linha

        if corpo.uppercased().hasPrefix("LIST ") { return list(corpo) }
        if corpo.uppercased().hasPrefix("SEARCH") { return search(corpo) }
        if corpo.uppercased().hasPrefix("OK [") { return okCode(corpo) }
        if let quantas = exists(corpo) { return .exists(quantas) }
        if corpo.uppercased().contains(" FETCH ") || corpo.uppercased().hasPrefix("FETCH ") {
            if let linhaFetch = fetch(corpo) { return .fetch(linhaFetch) }
        }
        return .outra(corpo)
    }

    /// `LIST (\HasNoChildren \Trash) "/" "Lixeira"`
    private static func list(_ corpo: String) -> ImapWire.Untagged {
        var atributos: [String] = []
        if let abre = corpo.firstIndex(of: "("), let fecha = corpo.firstIndex(of: ")"), abre < fecha {
            atributos = corpo[corpo.index(after: abre)..<fecha]
                .split(separator: " ").map(String.init)
        }
        // O nome é o último token; entre aspas quando tem espaço.
        let nome = ultimaStringCitada(corpo) ?? String(corpo.split(separator: " ").last ?? "")
        return .list(name: nome, attributes: atributos)
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
    /// Os campos são lidos por nome, não por posição: servidores mandam a
    /// mesma informação em ordens diferentes, e ler por posição funciona no
    /// servidor em que se testou e falha no seguinte.
    private static func fetch(_ corpo: String) -> ImapWire.FetchLine? {
        guard let uid = inteiroDepois(de: "UID", em: corpo) else { return nil }
        let envelope = grupo(depoisDe: "ENVELOPE", em: corpo).map(camposDoEnvelope) ?? []
        return ImapWire.FetchLine(
            uid: uid,
            flags: grupo(depoisDe: "FLAGS", em: corpo)?.split(separator: " ").map(String.init) ?? [],
            internalDate: dataInterna(stringCitadaDepois(de: "INTERNALDATE", em: corpo)),
            // ENVELOPE (data assunto from sender reply-to to cc bcc in-reply-to message-id)
            from: envelope.count > 2 ? enderecoDoEnvelope(envelope[2]) : nil,
            to: envelope.count > 5 ? enderecoDoEnvelope(envelope[5]) : nil,
            cc: envelope.count > 6 ? enderecoDoEnvelope(envelope[6]) : nil,
            subject: envelope.count > 1 ? semAspas(envelope[1]) : nil,
            text: stringCitadaDepois(de: "BODY[TEXT]", em: corpo)
                ?? literalDepois(de: "BODY[TEXT]", em: corpo)
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

    // MARK: Utilitários de leitura

    private static func semAspas(_ texto: String) -> String? {
        let limpo = texto.trimmingCharacters(in: .whitespaces)
        if limpo.uppercased() == "NIL" { return nil }
        guard limpo.hasPrefix("\""), limpo.hasSuffix("\""), limpo.count >= 2 else { return limpo }
        return String(limpo.dropFirst().dropLast())
    }

    private static func inteiroDepois(de chave: String, em corpo: String) -> Int64? {
        guard let intervalo = corpo.range(of: chave + " ") else { return nil }
        let resto = corpo[intervalo.upperBound...]
        return Int64(resto.prefix { $0.isNumber })
    }

    private static func stringCitadaDepois(de chave: String, em corpo: String) -> String? {
        guard let intervalo = corpo.range(of: chave + " ") else { return nil }
        let resto = corpo[intervalo.upperBound...]
        guard resto.first == "\"" else { return nil }
        let miolo = resto.dropFirst()
        guard let fim = miolo.firstIndex(of: "\"") else { return nil }
        return String(miolo[miolo.startIndex..<fim])
    }

    /// O corpo de um literal já juntado pelo `ImapFrameJoiner`, entregue como
    /// `{n}\r\n<texto>` no meio da linha lógica.
    ///
    /// O corte é pelo **tamanho declarado**, em bytes, e não pelo `)` que fecha
    /// o `FETCH`: o `)` vem depois do literal, na mesma linha lógica, e cortar
    /// nele daria um parêntese sobrando no fim de todo corpo — e um corpo que
    /// contivesse `)` sairia pela metade. Contar bytes é justamente o que o
    /// `{n}` existe para permitir.
    ///
    /// A leitura é em **bytes** e não em `Character`: `\r\n` é um grafema só
    /// para o Swift, e `first == "\r"` é falso justamente onde o CRLF importa.
    private static func literalDepois(de chave: String, em corpo: String) -> String? {
        guard let intervalo = corpo.range(of: chave + " ") else { return nil }
        let bytes = Array(corpo[intervalo.upperBound...].utf8)
        var indice = 0
        if indice < bytes.count, bytes[indice] == UInt8(ascii: "~") { indice += 1 } // binário
        guard indice < bytes.count, bytes[indice] == UInt8(ascii: "{") else { return nil }
        indice += 1
        var tamanho = 0
        var digitos = 0
        while indice < bytes.count, bytes[indice] >= UInt8(ascii: "0"), bytes[indice] <= UInt8(ascii: "9") {
            tamanho = tamanho * 10 + Int(bytes[indice] - UInt8(ascii: "0"))
            indice += 1
            digitos += 1
        }
        guard digitos > 0 else { return nil }
        if indice < bytes.count, bytes[indice] == UInt8(ascii: "+") || bytes[indice] == UInt8(ascii: "-") {
            indice += 1 // LITERAL+ / LITERAL-
        }
        guard indice < bytes.count, bytes[indice] == UInt8(ascii: "}") else { return nil }
        indice += 1
        if indice < bytes.count, bytes[indice] == UInt8(ascii: "\r") { indice += 1 }
        if indice < bytes.count, bytes[indice] == UInt8(ascii: "\n") { indice += 1 }
        return String(decoding: bytes[indice..<min(indice + tamanho, bytes.count)], as: UTF8.self)
    }

    /// O conteúdo do parêntese que vem depois da chave, respeitando aninhamento.
    private static func grupo(depoisDe chave: String, em corpo: String) -> String? {
        guard let intervalo = corpo.range(of: chave + " (") else { return nil }
        var profundidade = 1
        var resultado = ""
        for caractere in corpo[intervalo.upperBound...] {
            if caractere == "(" { profundidade += 1 }
            if caractere == ")" {
                profundidade -= 1
                if profundidade == 0 { break }
            }
            resultado.append(caractere)
        }
        return resultado
    }

    /// Os campos de primeiro nível de um `ENVELOPE`, respeitando aspas e
    /// parênteses aninhados.
    private static func camposDoEnvelope(_ texto: String) -> [String] {
        var campos: [String] = []
        var atual = ""
        var profundidade = 0
        var dentroDeAspas = false
        for caractere in texto {
            switch caractere {
            case "\"": dentroDeAspas.toggle(); atual.append(caractere)
            case "(" where !dentroDeAspas: profundidade += 1; atual.append(caractere)
            case ")" where !dentroDeAspas: profundidade -= 1; atual.append(caractere)
            case " " where !dentroDeAspas && profundidade == 0:
                if !atual.isEmpty { campos.append(atual); atual = "" }
            default: atual.append(caractere)
            }
        }
        if !atual.isEmpty { campos.append(atual) }
        return campos
    }

    /// `(("Marina" NIL "marina" "clientepremium.com"))` → `Marina <marina@clientepremium.com>`.
    private static func enderecoDoEnvelope(_ campo: String) -> String? {
        guard campo.uppercased() != "NIL" else { return nil }
        let miolo = campo.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        var enderecos: [String] = []
        for bloco in miolo.components(separatedBy: ") (") {
            let partes = camposDoEnvelope(bloco.trimmingCharacters(in: CharacterSet(charactersIn: "()")))
            guard partes.count >= 4 else { continue }
            let nome = semAspas(partes[0])
            guard let usuario = semAspas(partes[2]), let dominio = semAspas(partes[3]) else { continue }
            let endereco = "\(usuario)@\(dominio)"
            enderecos.append(nome.map { "\($0) <\(endereco)>" } ?? endereco)
        }
        return enderecos.isEmpty ? nil : enderecos.joined(separator: ", ")
    }

    private static func ultimaStringCitada(_ texto: String) -> String? {
        var partes: [String] = []
        var atual = ""
        var dentro = false
        for caractere in texto {
            if caractere == "\"" {
                if dentro { partes.append(atual); atual = "" }
                dentro.toggle()
            } else if dentro {
                atual.append(caractere)
            }
        }
        return partes.last
    }

    // MARK: A costura dos quadros

    /// `… BODY[TEXT] {21}` — o quadro acabou num cabeçalho de literal, então a
    /// linha lógica **não** acabou: vêm `n` bytes contados, e depois o resto da
    /// linha.
    ///
    /// Cobre as três formas que aparecem de verdade: `{21}`, o `{21+}` do
    /// `LITERAL+` e o `~{21}` do literal binário.
    /// A leitura é em **bytes**: `\r\n` é um grafema só para o Swift, e
    /// comparar `Character` com `"\r"` é falso justamente na ponta que importa.
    static func terminaEmCabecalhoDeLiteral(_ quadro: String) -> Bool {
        var bytes = Array(quadro.utf8)
        while let ultimo = bytes.last, ultimo == UInt8(ascii: "\r") || ultimo == UInt8(ascii: "\n") {
            bytes.removeLast()
        }
        guard bytes.last == UInt8(ascii: "}") else { return false }
        bytes.removeLast()
        if let ultimo = bytes.last, ultimo == UInt8(ascii: "+") || ultimo == UInt8(ascii: "-") {
            bytes.removeLast()
        }
        var digitos = 0
        while let ultimo = bytes.last, ultimo >= UInt8(ascii: "0"), ultimo <= UInt8(ascii: "9") {
            bytes.removeLast()
            digitos += 1
        }
        guard digitos > 0 else { return false }
        if bytes.last == UInt8(ascii: "~") { bytes.removeLast() }
        return bytes.last == UInt8(ascii: "{")
    }
}

/// Os quadros do `swift-nio-imap` virando uma linha lógica de cada vez.
///
/// **É a única razão de a biblioteca estar aqui.** Cortar por CRLF é fácil e a
/// gente faz (`CRLFLineDecoder`); o que não dá para fazer no nível da linha é o
/// literal `{n}`, cujo conteúdo é contado em **bytes** e tem CRLF dentro — o
/// corpo de qualquer mensagem. O `FrameDecoder` conta esses bytes; este tipo
/// junta os pedaços que ele emite numa linha só.
///
/// **Divergência do plano (regra da Task 9):** o plano dizia que a biblioteca
/// entregaria a linha lógica pronta. Na 0.4.0 que o SPM resolveu, o
/// `ResponseDecoder` é `internal` — só o `FrameDecoder` e o `FramingResult`
/// são públicos, e o `FrameDecoder` entrega o cabeçalho, os pedaços do literal
/// e o resto da linha como quadros separados. Costurá-los é este tipo.
struct ImapFrameJoiner {
    private var parcial = ""
    private var emLiteral = false

    /// `true` enquanto uma linha lógica está pela metade. É o que a fronteira
    /// do STARTTLS confere junto com o resto do estado.
    var montando: Bool { emLiteral || !parcial.isEmpty }

    /// A próxima linha lógica, ou `nil` enquanto ela não fechou.
    mutating func junta(_ quadro: FramingResult) throws -> String? {
        switch quadro {
        case .complete(let buffer):
            let texto = String(buffer: buffer)
            parcial += texto
            if ImapResponseAdapter.terminaEmCabecalhoDeLiteral(texto) {
                emLiteral = true
                return nil
            }
            let linha = parcial.trimmingCharacters(in: .whitespacesAndNewlines)
            parcial = ""
            emLiteral = false
            return linha.isEmpty ? nil : linha
        case .insideLiteral(let buffer, _):
            parcial += String(buffer: buffer)
            return nil
        case .incomplete:
            return nil
        case .invalid(let buffer):
            parcial = ""
            emLiteral = false
            // Descartar em silêncio deixaria a resposta tagueada nunca chegar,
            // e o comando morreria de teto de tempo com a mensagem errada.
            throw SyncError.resposta(
                "O servidor IMAP mandou um quadro inválido: \(String(buffer: buffer))"
            )
        }
    }
}
