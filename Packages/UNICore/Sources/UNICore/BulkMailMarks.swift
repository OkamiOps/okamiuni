import Foundation

/// O que os **cabeçalhos** dizem sobre a mensagem ser disparo em massa.
///
/// Existe porque a triagem por modelo errava exatamente aqui: a coluna de
/// prioridades do dono trazia sete linhas com a mesma etiqueta `PRECISA
/// RESPOSTA`, e três delas eram um boas-vindas do Resend, um marketing da Zoho
/// e um disparo do Upwork. Nenhum pedia resposta dele. Um modelo lendo o texto
/// não tem como saber; o **cabeçalho** sabe, e sabe sem palpite: quem manda
/// `List-Unsubscribe` está mandando para uma lista, e quem assina
/// `no-reply@` está dizendo, por escrito, que não vai ler a resposta.
///
/// `OptionSet` e não `Bool` porque a razão importa: a tela precisa poder dizer
/// **por que** algo é disparo, e o banco guarda o conjunto num inteiro só.
///
/// A regra que sai daqui é determinística e vem **depois** do modelo — ver
/// `MessageTriage.barred(byBulk:)`. Depois, e não antes, porque a ordem
/// importa: o modelo pode enriquecer o que sabe do texto, mas não tem
/// permissão de desfazer o que o cabeçalho afirma.
public struct BulkMailMarks: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `List-Unsubscribe` — a mensagem veio de uma lista de que se pode sair.
    public static let listUnsubscribe = BulkMailMarks(rawValue: 1 << 0)
    /// `List-Id` — a mensagem tem uma lista dona, e não uma pessoa.
    public static let listID = BulkMailMarks(rawValue: 1 << 1)
    /// `Precedence: bulk` / `list` / `junk` — o remetente se declarou em massa.
    public static let precedence = BulkMailMarks(rawValue: 1 << 2)
    /// `Auto-Submitted` com qualquer valor que não seja `no` (RFC 3834): a
    /// mensagem foi gerada por uma máquina.
    public static let autoSubmitted = BulkMailMarks(rawValue: 1 << 3)
    /// `X-Auto-Response-Suppress` — o remetente pede que ninguém responda.
    public static let autoResponseSuppress = BulkMailMarks(rawValue: 1 << 4)
    /// `no-reply@`, `noreply@`, `no_reply@`, `donotreply@`. A caixa que não lê.
    public static let noReplySender = BulkMailMarks(rawValue: 1 << 5)

    /// Alguma marca bateu. É a única pergunta que o ranking faz.
    public var isBulk: Bool { !isEmpty }

    /// A frase curta que a tela pode escrever ao lado da linha. A **primeira**
    /// marca, na ordem em que elas explicam melhor — não a soma, que viraria
    /// uma lista ilegível numa linha de 13pt.
    public var explanation: String? {
        if contains(.noReplySender) { return "O remetente não lê respostas" }
        if contains(.listUnsubscribe) || contains(.listID) { return "Enviado para uma lista" }
        if contains(.autoResponseSuppress) { return "O remetente pede que não se responda" }
        if contains(.autoSubmitted) { return "Gerado automaticamente" }
        if contains(.precedence) { return "Marcado como envio em massa" }
        return nil
    }

    // MARK: Detecção

    /// Os nomes que a detecção procura, em minúsculas. Fora da função para o
    /// sync poder pedi-los ao servidor com **as mesmas** palavras — duas
    /// listas divergiriam na primeira adição.
    public static let headerNames = [
        "list-unsubscribe", "list-id", "precedence",
        "auto-submitted", "x-auto-response-suppress",
    ]

    /// O que estes cabeçalhos e este remetente denunciam.
    ///
    /// Os nomes chegam como vierem: a busca é insensível a caixa, e valor só
    /// de espaço é ausência — um `Precedence:` vazio não afirma nada.
    public static func detect(headers: [String: String], from: String) -> BulkMailMarks {
        var normalizados: [String: String] = [:]
        for (nome, valor) in headers {
            let limpo = valor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limpo.isEmpty else { continue }
            normalizados[nome.lowercased()] = limpo
        }

        var marcas: BulkMailMarks = []
        if normalizados["list-unsubscribe"] != nil { marcas.insert(.listUnsubscribe) }
        if normalizados["list-id"] != nil { marcas.insert(.listID) }
        if let precedencia = normalizados["precedence"]?.lowercased(),
           ["bulk", "list", "junk"].contains(precedencia) {
            marcas.insert(.precedence)
        }
        // RFC 3834: `no` é a única forma de dizer "isto foi uma pessoa".
        if let auto = normalizados["auto-submitted"]?.lowercased(), auto != "no" {
            marcas.insert(.autoSubmitted)
        }
        if normalizados["x-auto-response-suppress"] != nil { marcas.insert(.autoResponseSuppress) }
        if isNoReply(from) { marcas.insert(.noReplySender) }
        return marcas
    }

    /// A mesma leitura sobre o bloco cru que o IMAP devolve, com a dobra de
    /// linha do RFC 5322 desfeita — uma continuação começa por espaço ou tabulação
    /// e pertence ao cabeçalho de cima.
    public static func detect(rawHeaderBlock: String, from: String) -> BulkMailMarks {
        var headers: [String: String] = [:]
        var nomeCorrente: String?
        for linha in rawHeaderBlock.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            if linha.first == " " || linha.first == "\t" {
                guard let nome = nomeCorrente else { continue }
                headers[nome, default: ""] += " " + linha.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let doisPontos = linha.firstIndex(of: ":") else {
                nomeCorrente = nil
                continue
            }
            let nome = String(linha[linha.startIndex..<doisPontos]).lowercased()
            let valor = String(linha[linha.index(after: doisPontos)...])
                .trimmingCharacters(in: .whitespaces)
            headers[nome] = valor
            nomeCorrente = nome
        }
        return detect(headers: headers, from: from)
    }

    /// A parte local do endereço é uma caixa que não lê.
    ///
    /// Compara a **parte local inteira** contra uma lista curta em vez de caçar
    /// substring: `reply@` e `noreplyclub@` não são caixas mudas, e uma busca
    /// por "noreply" dentro do endereço os pegaria. Prefixo com separador
    /// (`no-reply-123@`) continua contando, que é a forma que os provedores
    /// usam para numerar disparo.
    private static func isNoReply(_ from: String) -> Bool {
        let endereco = from.lowercased().trimmingCharacters(in: .whitespaces)
        guard let arroba = endereco.firstIndex(of: "@") else { return false }
        let local = String(endereco[endereco.startIndex..<arroba])
        let semSeparador = local.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
        for raiz in ["noreply", "donotreply"] {
            if semSeparador == raiz { return true }
            // `no-reply-42@` e `noreply+news@`: o que vem depois da raiz tem de
            // começar por separador ou dígito, senão `noreplyclub` entraria.
            if semSeparador.hasPrefix(raiz) {
                let resto = semSeparador.dropFirst(raiz.count)
                if resto.allSatisfy({ $0.isNumber || $0 == "+" }) { return true }
            }
        }
        return false
    }
}
