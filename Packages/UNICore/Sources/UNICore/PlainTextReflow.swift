import Foundation

/// As quebras de linha que o **remetente** pôs para caber em 72 colunas,
/// desfeitas.
///
/// ## O defeito
///
/// Um email de texto plano chega quase sempre quebrado à mão em 72–78 colunas
/// — é o que todo cliente de email produz desde antes de haver janela
/// redimensionável. O leitor, que tem largura própria, desenha cada uma dessas
/// linhas como se fosse decisão do autor, e a frase
///
/// ```
/// Passando para confirmar nossa call amanhã, 16 de julho, às 15h,
/// no horário
/// de Brasília.
/// ```
///
/// vira três blocos na tela — que foi exatamente o que o dono viu. A quebra é
/// do transporte, não do texto: refluir é devolver o parágrafo ao autor.
///
/// ## Por que é heurística, e conservadora
///
/// Quando o remetente **declara** `format=flowed` (RFC 3676), a regra é
/// mecânica e não há dúvida: espaço no fim da linha significa "continua". Mas
/// a maioria não declara nada — e aí a única pista é o próprio texto. Por isso
/// cada re-junção exige que a linha **não** pareça intencional, e tudo o que
/// tem forma própria fica intacto: lista, citação, assinatura, tabela,
/// saudação e despedida curtas.
///
/// O custo dos dois erros não é o mesmo. Uma quebra que sobrou é um texto um
/// pouco mais alto; uma lista re-juntada é uma lista destruída. **Na dúvida,
/// mantém-se a quebra.**
///
/// Pura, sem estado e sem `Foundation` além de `String`: é a peça que mais
/// barato se testa, e é testada com emails de verdade.
public enum PlainTextReflow {

    /// A largura a partir da qual uma linha é suspeita de ter sido quebrada
    /// pelo transporte.
    ///
    /// Sessenta, e não 72: quem quebra em 72 quebra na **última palavra que
    /// coube**, e a linha resultante costuma parar entre 60 e 72. Exigir 72
    /// deixaria de fora metade das quebras de verdade. Abaixo de 60 mora a
    /// linha curta intencional — "Olá,", "Até lá!", um nome, um item de lista
    /// sem marcador — e é ela que este piso protege.
    static let larguraSuspeita = 60

    // MARK: - A entrada

    /// O texto com as quebras soltas re-juntadas, linhas em branco intactas.
    ///
    /// Serve tanto para o texto inteiro quanto para **um** parágrafo já
    /// separado — é a mesma máquina, e uma linha em branco nunca se junta a
    /// nada.
    ///
    /// - Parameters:
    ///   - flowed: o remetente declarou `Content-Type: text/plain;
    ///     format=flowed`. Aí não há heurística nenhuma: a regra é do RFC 3676.
    ///   - delSp: o `DelSp=Yes` do mesmo cabeçalho — o espaço da quebra some ao
    ///     juntar, em vez de virar o espaço entre as palavras. É o que línguas
    ///     sem espaço entre palavras precisam, e obedecê-lo é a diferença entre
    ///     juntar e corromper.
    public static func reflow(_ raw: String, flowed: Bool = false, delSp: Bool = false) -> String {
        let linhas = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { flowed ? desenche($0) : $0 }

        var saida: [String] = []
        var depoisDaAssinatura = false

        for linha in linhas {
            defer { if ehSeparadorDeAssinatura(linha) { depoisDaAssinatura = true } }
            guard let anterior = saida.last, !depoisDaAssinatura else {
                saida.append(linha)
                continue
            }
            guard junta(anterior, linha, flowed: flowed) else {
                saida.append(linha)
                continue
            }
            saida[saida.count - 1] = junte(anterior, linha, flowed: flowed, delSp: delSp)
        }
        return saida.joined(separator: "\n")
    }

    /// O texto refluído, já em parágrafos — linha em branco separa, pontas
    /// somem. É a mesma regra de `GmailMessageParser.paragraphs(from:)`, agora
    /// sobre um texto em que a quebra de 72 colunas não existe mais.
    public static func paragraphs(
        from raw: String, flowed: Bool = false, delSp: Bool = false
    ) -> [String] {
        reflow(raw, flowed: flowed, delSp: delSp)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - A decisão

    /// Esta linha continua a anterior?
    static func junta(_ anterior: String, _ proxima: String, flowed: Bool) -> Bool {
        // Nem uma linha em branco nem a que vem depois dela: linha em branco é
        // separação de parágrafo, a única que nunca foi decisão do transporte.
        guard !ehVazia(anterior), !ehVazia(proxima) else { return false }
        // O separador de assinatura (`-- `) termina em espaço e seria a
        // primeira vítima da regra do `format=flowed`. O RFC 3676 o excetua
        // por escrito, e aqui vale nos dois modos.
        guard !ehSeparadorDeAssinatura(anterior) else { return false }
        // Citação: `>` marca o que **outra pessoa** escreveu, e re-juntar
        // dentro dela mistura os dois textos.
        guard !ehCitacao(anterior), !ehCitacao(proxima) else { return false }

        if flowed {
            // A regra inteira do RFC 3676: espaço no fim da linha é "esta
            // linha continua". Sem espaço, a quebra é do autor.
            return anterior.hasSuffix(" ")
        }

        // Daqui para baixo é a heurística — e cada guarda é uma forma que a
        // re-junção destruiria.
        guard !ehLista(proxima), !ehLista(anterior) else { return false }
        // Indentação é forma: tabela ASCII, bloco de código, item continuado.
        guard !comecaIndentada(proxima), !comecaIndentada(anterior) else { return false }
        // Quem terminou a frase quebrou de propósito.
        guard !terminaFrase(anterior) else { return false }

        // O que sobra: uma linha que parou no meio de uma frase. Ou ela é
        // longa o bastante para a quebra ter sido do transporte, ou a linha
        // seguinte começa em minúscula — que é a mesma frase continuando, e
        // ninguém começa um parágrafo assim.
        return podada(anterior).count >= larguraSuspeita || continuaFrase(proxima)
    }

    private static func junte(
        _ anterior: String, _ proxima: String, flowed: Bool, delSp: Bool
    ) -> String {
        if flowed {
            // Sem `DelSp`, o espaço da quebra **é** o espaço entre as palavras
            // e já está no fim de `anterior`. Com `DelSp=Yes`, ele é só a marca
            // da quebra e some.
            return delSp ? String(anterior.dropLast()) + proxima : anterior + proxima
        }
        return podada(anterior) + " " + proxima.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - As formas que não se juntam

    /// `-`, `*`, `•`, `–`, `—` seguidos de espaço, ou `1.` / `1)` — os
    /// marcadores que um email escrito à mão usa.
    static func ehLista(_ linha: String) -> Bool {
        let podada = linha.trimmingCharacters(in: .whitespaces)
        guard let primeira = podada.first else { return false }
        if "-*•–—+".contains(primeira) {
            // `--` é assinatura, não item; e um traço colado na palavra
            // ("bem-vindo" no começo da linha) não é marcador nenhum.
            let resto = podada.dropFirst()
            return resto.first == " " || resto.first == "\t"
        }
        guard primeira.isNumber else { return false }
        let numero = podada.prefix { $0.isNumber }
        let depois = podada.dropFirst(numero.count)
        guard let marca = depois.first, marca == "." || marca == ")" else { return false }
        let sobra = depois.dropFirst()
        return sobra.first == " " || sobra.isEmpty
    }

    static func ehCitacao(_ linha: String) -> Bool {
        linha.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    /// `--` sozinho na linha, com ou sem o espaço que o RFC pede.
    static func ehSeparadorDeAssinatura(_ linha: String) -> Bool {
        let podada = linha.trimmingCharacters(in: .whitespaces)
        return podada == "--"
    }

    static func comecaIndentada(_ linha: String) -> Bool {
        guard let primeira = linha.first else { return false }
        return primeira == " " || primeira == "\t"
    }

    private static func ehVazia(_ linha: String) -> Bool {
        linha.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A linha termina uma frase?
    ///
    /// O fecho conta depois de aspas e parênteses: `disse "vamos."` termina do
    /// mesmo jeito. Vírgula e ponto-e-vírgula **não** terminam — são o meio da
    /// frase, e é justamente aí que a quebra de 72 colunas cai.
    static func terminaFrase(_ linha: String) -> Bool {
        var texto = Substring(podada(linha))
        while let ultima = texto.last, "\"'”’)]»".contains(ultima) {
            texto = texto.dropLast()
        }
        guard let ultima = texto.last else { return false }
        return ".!?…:".contains(ultima)
    }

    /// A linha começa como quem continua a frase de cima: minúscula, ou um
    /// sinal de fechamento.
    static func continuaFrase(_ linha: String) -> Bool {
        guard let primeira = linha.trimmingCharacters(in: .whitespaces).first else { return false }
        if primeira.isLowercase { return true }
        return ")]»”’".contains(primeira)
    }

    private static func podada(_ linha: String) -> String {
        String(linha.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }

    /// O "space-stuffing" do RFC 3676: o remetente acrescenta um espaço à
    /// frente da linha que começaria com espaço, `>` ou `From `. Quem lê tira
    /// esse espaço antes de qualquer outra coisa — e tirá-lo é o que impede o
    /// texto flowed inteiro de parecer indentado.
    private static func desenche(_ linha: String) -> String {
        linha.hasPrefix(" ") ? String(linha.dropFirst()) : linha
    }
}
