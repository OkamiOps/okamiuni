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
        let cru = paragrafos.joined(separator: "\n\n")
        guard let familia = familia(de: cru) else { return nil }

        let novo: [String]
        switch familia {
        case .mime:
            novo = paragraphs(raw: cru)
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
        guard !novo.isEmpty, novo != paragrafos else { return nil }
        return novo
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

    /// Uma quebra suave (`=` sozinho no fim da linha) ou dois escapes `=XX`.
    ///
    /// Dois, e não um: `=20` aparece em texto sobre protocolos, e uma ocorrência
    /// isolada não é evidência. Uma quebra suave, por outro lado, não acontece
    /// em prosa nenhuma — linha terminada em `=` é assinatura do formato.
    private static func pareceQuotedPrintable(_ texto: String) -> Bool {
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
