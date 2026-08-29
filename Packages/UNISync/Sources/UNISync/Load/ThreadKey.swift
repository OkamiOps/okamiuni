import Foundation

/// A chave da conversa, derivada dos cabeçalhos.
///
/// **Pura e num arquivo próprio**, pelo mesmo motivo de `MessageIdentity` e de
/// `TriageProjection`: é a regra que decide se três mensagens são uma linha só
/// na lista, ela erra em silêncio (o defeito aparece como conversa partida ou
/// como duas conversas grudadas, semanas depois) e ela é barata de testar. Uma
/// segunda cópia dela dentro do laço da carga divergiria da primeira no
/// primeiro cabeçalho torto.
///
/// ## As regras, em ordem
///
/// 1. **Gmail**: o `threadId` que a API devolve **é** a verdade. O Gmail já
///    resolveu a conversa do lado dele, com mais informação do que temos aqui
///    (ele vê a caixa inteira, inclusive o que a janela de 90 dias deixou de
///    fora). Refazer a conta a partir dos cabeçalhos daria um resultado pior e
///    diferente do que a pessoa vê no webmail — que é justamente a comparação
///    que abriu esta tarefa.
/// 2. **IMAP e o resto**: a raiz de `References`, que é a mensagem que abriu a
///    conversa; na falta dela, `In-Reply-To`; na falta dos dois, o próprio
///    `Message-ID` — uma mensagem que não responde a nada abre a conversa dela.
/// 3. **Sem cabeçalho nenhum** (as linhas gravadas antes da v4, e o servidor
///    que não os manda): o **assunto normalizado**, por conta. É o que os
///    clientes fazem de honesto sem cabeçalho — e é só o assunto: cruzar com
///    participantes juntaria duas conversas paralelas sobre o mesmo assunto com
///    gente diferente, ou partiria uma em que alguém entrou no meio.
///
/// ## Por que as chaves têm prefixo
///
/// `:t:`, `:m:` e `:s:` separam os três espaços. Sem eles, um assunto que por
/// acaso fosse igual a um `Message-ID` juntaria duas conversas sem relação — e
/// a conta na frente impede que duas contas com a mesma conversa (a mesma troca
/// de emails chegando no trabalho e no pessoal) virem uma linha só, que é o que
/// o filtro de conta da lista promete que não acontece.
public enum ThreadKey {
    /// A chave de uma mensagem do Gmail: o `threadId` dele, e nada mais.
    public static func gmail(accountID: String, threadID: String) -> String {
        "\(accountID):t:\(threadID)"
    }

    /// A chave de uma mensagem identificada por um `Message-ID` do RFC 5322.
    public static func rfc(accountID: String, messageID: String) -> String {
        "\(accountID):m:\(bare(messageID))"
    }

    /// A chave de fallback: o assunto normalizado, por conta.
    public static func subject(accountID: String, subject: String) -> String {
        "\(accountID):s:\(normalized(subject: subject))"
    }

    /// A regra 2 e a 3 juntas, que é como quem grava a chama.
    ///
    /// - Parameter fallback: o que devolver quando não há cabeçalho **nem**
    ///   assunto. Quem chama passa o `Message.id`, que é único por construção:
    ///   uma mensagem sem nada continua sendo uma conversa de uma mensagem só,
    ///   em vez de todas as mensagens sem assunto da conta virarem uma linha.
    public static func derive(
        accountID: String,
        messageID: String?,
        inReplyTo: String?,
        references: [String],
        subject: String,
        fallback: String
    ) -> String {
        if let raiz = references.map(bare).first(where: { !$0.isEmpty }) {
            return rfc(accountID: accountID, messageID: raiz)
        }
        if let resposta = inReplyTo.map(bare), !resposta.isEmpty {
            return rfc(accountID: accountID, messageID: resposta)
        }
        if let proprio = messageID.map(bare), !proprio.isEmpty {
            return rfc(accountID: accountID, messageID: proprio)
        }
        let assunto = normalized(subject: subject)
        // `ThreadKey.` na frente porque o parâmetro `subject` desta função
        // sombreia a função de mesmo nome — sem o qualificador, o compilador lê
        // "chamar a `String`".
        return assunto.isEmpty ? fallback : ThreadKey.subject(accountID: accountID, subject: subject)
    }

    /// O assunto sem o que os clientes penduram na frente dele, sem acento e
    /// sem caixa.
    ///
    /// - **Os prefixos saem em laço**, porque eles se acumulam: "Re: Enc: Re:
    ///   Contrato" é o estado normal de uma conversa que foi encaminhada e
    ///   respondida. Tirar um só deixaria a resposta da resposta noutra
    ///   conversa.
    /// - **`Re[2]:` e `RE :` contam**, porque o Outlook manda o primeiro e
    ///   alguns webmails mandam o segundo.
    /// - **O acento cai** (`diacriticInsensitive`), e é isso que o pedido chama
    ///   de "sem acento dobrado": o mesmo assunto digitado com "ã" composto de
    ///   dois pontos de código e com "ã" de um só tem de dar a mesma chave — é a
    ///   mesma razão do `remove_diacritics 2` do índice de busca.
    /// - **Os espaços colapsam**, porque um cliente que quebra o assunto em
    ///   duas linhas de cabeçalho o devolve com espaço a mais no meio.
    public static func normalized(subject: String) -> String {
        var resto = Substring(dobra(subject))
        var cortou = true
        while cortou {
            cortou = false
            resto = Substring(resto.trimmingCharacters(in: .whitespaces))
            for prefixo in prefixos {
                guard resto.hasPrefix(prefixo) else { continue }
                var depois = resto.dropFirst(prefixo.count)
                // `Re[2]:` — a contagem que o Outlook põe entre o prefixo e os
                // dois pontos.
                if depois.hasPrefix("[") , let fecha = depois.firstIndex(of: "]") {
                    let dentro = depois[depois.index(after: depois.startIndex)..<fecha]
                    if dentro.allSatisfy(\.isNumber) { depois = depois[depois.index(after: fecha)...] }
                }
                depois = Substring(depois.trimmingCharacters(in: .whitespaces))
                guard depois.hasPrefix(":") else { continue }
                resto = depois.dropFirst()
                cortou = true
                break
            }
        }
        return resto
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Os prefixos, já dobrados (minúsculos e sem acento), porque é sobre o
    /// texto dobrado que a comparação acontece.
    ///
    /// Português, inglês e os dois que chegam de servidor alheio sem ninguém
    /// pedir: `enc`/`res` (pt), `re`/`fw`/`fwd` (en), `rv` (es) e `aw` (de).
    /// A lista é curta de propósito — cada entrada a mais é uma chance de
    /// engolir o começo de um assunto de verdade.
    static let prefixos = ["re", "res", "enc", "fwd", "fw", "rv", "aw"]

    /// Minúsculas, sem acento, com o espaço em branco das pontas fora.
    private static func dobra(_ texto: String) -> String {
        texto
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Um `Message-ID` **pelado**: sem `<>`, sem espaço em volta.
    ///
    /// A forma pelada é a que não tem duas leituras — é a mesma decisão que
    /// `OutgoingMessage.messageID` documenta. Quem escreve o cabeçalho põe os
    /// sinais de volta; quem compara, não os vê nunca.
    public static func bare(_ id: String) -> String {
        var texto = Substring(id.trimmingCharacters(in: .whitespacesAndNewlines))
        if texto.hasPrefix("<") { texto = texto.dropFirst() }
        if texto.hasSuffix(">") { texto = texto.dropLast() }
        return String(texto).trimmingCharacters(in: .whitespaces)
    }

    /// Os `Message-ID` de um cabeçalho de lista (`References`, `In-Reply-To`),
    /// na ordem em que estão escritos.
    ///
    /// Lê **só o que está entre `<` e `>`**, e é por isso que ela sobrevive ao
    /// que chega de verdade: comentários entre parênteses, quebra de linha com
    /// continuação e o servidor que separa por vírgula em vez de espaço, todos
    /// legais e todos presentes em caixa de produção.
    public static func ids(inHeader cabecalho: String) -> [String] {
        var achados: [String] = []
        var resto = Substring(cabecalho)
        while let abre = resto.firstIndex(of: "<"),
              let fecha = resto[abre...].firstIndex(of: ">") {
            let miolo = String(resto[resto.index(after: abre)..<fecha])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !miolo.isEmpty { achados.append(miolo) }
            resto = resto[resto.index(after: fecha)...]
        }
        return achados
    }

    /// O valor de um cabeçalho cru — `"References: <a> <b>\r\n"` → `"<a> <b>"`.
    ///
    /// Existe porque é assim que o `BODY[HEADER.FIELDS (…)]` do IMAP devolve o
    /// campo: com o nome, os dois pontos e o CRLF final. Devolver o bloco
    /// inteiro para `ids(inHeader:)` funcionaria — ela só olha o que está entre
    /// `<>` —, mas um bloco com **dois** campos pedidos daria os dois
    /// misturados, e essa é uma confusão que não se descobre num teste feliz.
    public static func headerValue(_ bloco: String, campo: String) -> String? {
        let alvo = campo.lowercased() + ":"
        var valor: String?
        for linha in bloco.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            // Linha de continuação (RFC 5322 §2.2.3): começa com espaço e
            // pertence ao campo anterior.
            if let atual = valor, linha.first == " " || linha.first == "\t" {
                valor = atual + " " + linha.trimmingCharacters(in: .whitespaces)
                continue
            }
            if valor != nil { break }
            guard linha.lowercased().hasPrefix(alvo) else { continue }
            valor = String(linha.dropFirst(alvo.count)).trimmingCharacters(in: .whitespaces)
        }
        return valor
    }
}
