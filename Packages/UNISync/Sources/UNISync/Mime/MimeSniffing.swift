import Foundation

/// "Este corpo que já está no banco é texto, ou é fonte MIME crua?"
///
/// A pergunta existe porque o banco do dono está cheio das duas coisas: 44
/// mensagens com corpo, e a maioria delas guardando `--fronteira`,
/// `Content-Type:` e `=E7` como se fosse a leitura. Elas foram gravadas por um
/// caminho de carga que não decodificava, e não há mais cabeçalho nenhum ao
/// lado delas para consultar — só o texto.
///
/// **A heurística é conservadora de propósito.** O custo de um falso negativo é
/// um corpo cru que continua cru (o que já é o estado de hoje); o custo de um
/// falso positivo é uma mensagem legítima reescrita em cima de si mesma. Por
/// isso cada família exige duas evidências, e a reescrita ainda tem a última
/// guarda: se o resultado for vazio, ou igual ao que já estava lá, nada é
/// gravado.
extension MimeBody {
    /// De que família é o texto cru, quando ele é cru.
    enum Familia: Equatable {
        /// Tem cabeçalhos MIME ou fronteiras dentro: o decodificador inteiro
        /// resolve.
        case mime
        /// Sem cabeçalho nenhum, mas com as marcas do quoted-printable: é o
        /// `BODY[TEXT]` de uma mensagem de parte única, onde o
        /// `Content-Transfer-Encoding` ficou no cabeçalho que ninguém buscou.
        case quotedPrintable
        /// Idem, em base64.
        case base64
        /// **Documento HTML avulso gravado como se fosse leitura.** Sem
        /// cabeçalho, sem fronteira: o corpo começa em `<!doctype html>` (ou
        /// `<html`) e segue com a página inteira, muitas vezes ainda com as
        /// cicatrizes do quoted-printable (`lang=3D"en"`, `=` no fim da linha).
        ///
        /// É o email do dono que aparecia no leitor como código-fonte. As três
        /// famílias acima não o pegam: não há cabeçalho MIME, o alfabeto tem
        /// `<` e `>` (não é base64), e classificá-lo como quoted-printable
        /// só tirava os `=3D` — o leitor continuava desenhando marcação como
        /// texto.
        case htmlCru
    }

    /// O conserto de um corpo, nas duas metades que o banco guarda.
    public struct Redecoded: Sendable, Equatable {
        public var paragraphs: [String]
        /// O HTML sanitizado, quando o que estava gravado era uma página. `nil`
        /// nos outros casos — e aí a coluna `html` não é tocada.
        public var html: String?
    }

    /// O corpo re-decodificado, ou `nil` quando não há o que fazer.
    ///
    /// Recebe e devolve **parágrafos** porque é assim que o banco os guarda. O
    /// reagrupamento por linha em branco não é perda: os parágrafos gravados
    /// nasceram de `GmailMessageParser.paragraphs(from:)` sobre o mesmo texto,
    /// que corta exatamente em linha em branco — e uma linha em branco é
    /// justamente o que separa cabeçalho de conteúdo em MIME. A estrutura que
    /// importa sobrevive à ida e à volta.
    public static func redecoded(_ paragrafos: [String]) -> [String]? {
        redecodedBody(paragrafos)?.paragraphs
    }

    /// O mesmo conserto, com o HTML junto — que é o que a varredura da abertura
    /// precisa desde o corpo gravado como fonte HTML.
    public static func redecodedBody(_ paragrafos: [String]) -> Redecoded? {
        let cru = paragrafos.joined(separator: "\n\n")
        guard let familia = familia(de: cru) else { return nil }

        let novo: [String]
        var pagina: String?
        switch familia {
        case .mime:
            novo = paragraphs(raw: cru)
        case .htmlCru:
            // Primeiro as cicatrizes do transporte, se houver: `=3D` vira `=`,
            // e a quebra suave desaparece **antes** de qualquer coisa olhar a
            // marcação — uma tag partida no meio por `=\n` não é tag nenhuma.
            let fonte = pareceQuotedPrintable(normalizaParaFarejar(cru))
                ? string(
                    de: quotedPrintable(normalizaParaFarejar(cru), sublinhadoEhEspaco: false),
                    charset: .utf8
                )
                : cru
            // A mesma limpeza da M3-8, e não uma segunda opinião: o que o
            // leitor desenha tem de ter passado pelo mesmo filtro, venha da
            // rede ou de uma linha antiga do banco.
            pagina = MimeSanitize.sanitize(html: fonte)
            // E a leitura em texto pelo mesmo caminho de sempre — é ela que
            // vira prévia da lista e índice de busca.
            novo = GmailMessageParser.paragraphs(from: textFromHTML(fonte))
        case .quotedPrintable:
            novo = GmailMessageParser.paragraphs(
                from: string(
                    de: quotedPrintable(normalizaParaFarejar(cru), sublinhadoEhEspaco: false),
                    charset: .utf8
                )
            )
        case .base64:
            guard let dados = base64(cru) else { return nil }
            novo = GmailMessageParser.paragraphs(from: string(de: dados, charset: .utf8))
        }

        // As duas guardas finais. Vazio significa que a decodificação não achou
        // parte de texto nenhuma — e trocar um corpo cru e legível-com-esforço
        // por nada é uma perda, não um conserto. Igual significa que não havia
        // o que consertar.
        //
        // **A exceção é a página.** Uma newsletter que é só imagem não tem uma
        // palavra a extrair, e a guarda do vazio abortava o conserto inteiro:
        // sem texto, sem página, e o **fonte** continuava sendo a leitura. Onde
        // há página sanitizada há conserto, com ou sem texto ao lado.
        guard !novo.isEmpty || pagina != nil, novo != paragrafos || pagina != nil else {
            return nil
        }
        return Redecoded(paragraphs: novo, html: pagina)
    }

    /// Só a pergunta, sem a resposta. Existe separada porque a migração relata
    /// quantos corpos **pareciam** crus, e porque é o que um teste consegue
    /// afirmar sobre um corpo que não deve ser tocado.
    public static func looksRaw(_ paragrafos: [String]) -> Bool {
        familia(de: paragrafos.joined(separator: "\n\n")) != nil
    }

    static func familia(de cru: String) -> Familia? {
        let texto = normalizaParaFarejar(cru)
        guard !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if pareceMIME(texto) { return .mime }
        // **Antes** do quoted-printable, e por isso: uma página HTML gravada
        // como texto costuma trazer `=3D` em toda parte, e a família QP a
        // reclamaria primeiro — devolvendo a mesma marcação, só que sem os
        // `=3D`. O leitor continuaria mostrando código-fonte.
        if pareceHTMLCru(texto) { return .htmlCru }
        // E de novo, com o transporte desfeito. A quebra suave do QP cai onde a
        // linha completa 76 colunas — o que pode ser no meio de `<!DOCTYPE` ou
        // de `<html`. Enquanto o `=\n` estiver lá não há prefixo nenhum a
        // casar, e a família de quoted-printable reclamava o caso: devolvia a
        // mesma marcação sem os `=3D`, e o leitor continuava desenhando fonte.
        // É a tela "Zoho Workplace — Informações alteradas" da M3-21.
        //
        // Só um prefixo é desfeito: a pergunta é sobre o **começo** do corpo, e
        // decodificar cem kB para olhar os primeiros cem caracteres seria pagar
        // a decodificação duas vezes em toda mensagem do banco.
        if pareceQuotedPrintable(texto), pareceHTMLCru(semQuotedPrintable(texto)) {
            return .htmlCru
        }
        // Base64 **antes** de quoted-printable, e não por gosto: o `=` de
        // enchimento no fim de um bloco base64 é indistinguível de uma quebra
        // suave de QP, e a ordem inversa classificava todo corpo base64 como
        // quoted-printable — decodificando-o em si mesmo, sem erro nenhum e sem
        // conserto nenhum. O teste do base64 é o mais estrito dos dois (o
        // alfabeto tem de fechar no texto inteiro), então ele é o que pode ser
        // perguntado primeiro sem roubar caso do outro.
        if pareceBase64(texto) { return .base64 }
        if pareceQuotedPrintable(texto) { return .quotedPrintable }
        return nil
    }

    private static func normalizaParaFarejar(_ texto: String) -> String {
        texto.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Cabeçalho MIME na frente, ou fronteira na frente. As duas perguntas são
    /// as mesmas que o decodificador faz para se orientar — e é bom que sejam:
    /// dizer "isto é MIME" por um critério e decodificar por outro é como se
    /// produz um corpo reescrito em vazio.
    private static func pareceMIME(_ texto: String) -> Bool {
        cabecalhosNaFrente(texto) != nil || fronteiraSolta(texto) != nil
    }

    /// Um prefixo do corpo com o quoted-printable desfeito, para farejar.
    ///
    /// Só o prefixo, e de propósito: quem pergunta é `pareceHTMLCru`, e a
    /// pergunta dele é sobre os primeiros caracteres. A folga de 512 cabe o
    /// `DOCTYPE` mais comprido que existe (o XHTML Transitional tem 109) com o
    /// prólogo XML e um comentário na frente.
    private static func semQuotedPrintable(_ texto: String) -> String {
        string(
            de: quotedPrintable(String(texto.prefix(512)), sublinhadoEhEspaco: false),
            charset: .utf8
        )
    }

    /// O corpo **começa** sendo um documento HTML?
    ///
    /// A exigência é a posição, não a presença: `<!doctype html`, `<html`,
    /// `<head` ou `<body` nos primeiros bytes do corpo. É o que separa "isto é
    /// uma página que alguém gravou como texto" de "isto é um email meu que
    /// fala sobre HTML e tem um `<div>` no meio da terceira frase" — o segundo
    /// não pode virar página, e um teste de presença o transformaria.
    ///
    /// O prefixo é procurado depois de pular linhas em branco, comentários
    /// (`<!-- … -->`, que é onde alguns geradores põem a condicional do
    /// Outlook antes do `<html>`) e o prólogo XML (`<?xml … ?>`), que é como
    /// meio gerador de XHTML abre o documento — e que não é prosa de ninguém.
    ///
    /// O `DOCTYPE` é aceito **em qualquer caixa e com qualquer declaração**:
    /// o `<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" …>`
    /// do Zoho é tão documento quanto o `<!doctype html>` do HTML5, e o espaço
    /// entre `<!doctype` e `html` pode ser mais de um.
    private static func pareceHTMLCru(_ texto: String) -> Bool {
        var inicio = Substring(texto).drop { $0.isWhitespace }
        // Comentário e prólogo na frente ainda são "a página começa aqui".
        var pulou = true
        while pulou {
            pulou = false
            if inicio.hasPrefix("<!--"), let fim = inicio.range(of: "-->") {
                inicio = inicio[fim.upperBound...].drop { $0.isWhitespace }
                pulou = true
            }
            if inicio.hasPrefix("<?xml"), let fim = inicio.range(of: "?>") {
                inicio = inicio[fim.upperBound...].drop { $0.isWhitespace }
                pulou = true
            }
        }
        let cabeca = inicio.prefix(120).lowercased()
        if ["<html", "<head", "<body"].contains(where: cabeca.hasPrefix) { return true }
        guard cabeca.hasPrefix("<!doctype") else { return false }
        return cabeca.dropFirst("<!doctype".count).drop { $0.isWhitespace }.hasPrefix("html")
    }

    /// Uma quebra suave (`=` sozinho no fim da linha) ou dois escapes `=XX`.
    ///
    /// Dois, e não um: `=20` aparece em texto sobre protocolos, e uma ocorrência
    /// isolada não é evidência. Uma quebra suave, por outro lado, não acontece
    /// em prosa nenhuma — linha terminada em `=` é assinatura do formato.
    static func pareceQuotedPrintable(_ texto: String) -> Bool {
        var escapes = 0
        for linha in texto.split(separator: "\n", omittingEmptySubsequences: false) {
            if linha.count > 1, linha.hasSuffix("=") { return true }
            var i = linha.startIndex
            while let achado = linha[i...].firstIndex(of: "=") {
                let depois = linha.index(achado, offsetBy: 3, limitedBy: linha.endIndex)
                if let depois, UInt8(linha[linha.index(after: achado)..<depois], radix: 16) != nil {
                    escapes += 1
                    if escapes >= 2 { return true }
                }
                guard achado < linha.endIndex else { break }
                i = linha.index(after: achado)
            }
        }
        return false
    }

    /// Um bloco inteiro de base64 e nada mais.
    ///
    /// As três exigências juntas são o que torna isto seguro: o alfabeto tem de
    /// fechar **em todo o texto** (uma frase em português tem espaço, ponto e
    /// acento, e nenhum dos três está no alfabeto), o bloco tem de ser longo o
    /// bastante para não ser uma palavra, e o resultado tem de ser texto legível
    /// de verdade. Uma palavra como "Confirmado" é base64 válido; ela não passa
    /// pelo tamanho nem pela legibilidade do que sai.
    private static func pareceBase64(_ texto: String) -> Bool {
        let limpo = texto.filter { !$0.isWhitespace }
        guard limpo.count >= 32 else { return false }
        let alfabeto = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard limpo.allSatisfy(alfabeto.contains) else { return false }
        guard let dados = base64(limpo), dados.count >= 16 else { return false }
        guard let decodificado = String(data: dados, encoding: .utf8) else { return false }
        // Legível: sem bytes de controle além dos de espaço, e com pelo menos um
        // separador de palavra — um binário curto que por acaso decodifica em
        // UTF-8 não tem espaço nenhum.
        guard decodificado.contains(where: { $0 == " " || $0 == "\n" }) else { return false }
        return !decodificado.unicodeScalars.contains {
            $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }
    }
}
