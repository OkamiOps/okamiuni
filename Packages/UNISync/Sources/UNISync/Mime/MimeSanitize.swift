import Foundation

/// O HTML de um email virando HTML que pode ser desenhado sem medo.
///
/// **Por que ela existe.** Até aqui o decodificador jogava a parte `text/html`
/// fora e guardava só a leitura em texto: o email do provedor — logotipo,
/// tabela, botão — chegava ao leitor como prosa seca, sem uma imagem. Mostrar o
/// HTML de verdade é a única forma de o leitor parecer um leitor de email; e
/// mostrar HTML de terceiro sem o limpar antes é a forma clássica de um cliente
/// de email virar uma superfície de ataque.
///
/// **Função pura, e num arquivo só.** Nada aqui abre conexão, lê banco nem olha
/// relógio: entra texto e um punhado de imagens embutidas, sai texto. É a peça
/// que mais barato se testa e a que mais caro custa errar — a mesma razão pela
/// qual `MimeBody` e `GmailMessageParser` moram sozinhos.
///
/// ## O que é arrancado, e por quê
///
/// - `script`, `iframe`, `object`, `embed`, `applet`, `frame`, `frameset`: são
///   contêineres de execução ou de documento alheio. Vão embora **com o
///   conteúdo** — deixar o miolo de um `<script>` passar despejaria código no
///   leitor, que é o defeito clássico de quem resolve HTML com uma expressão
///   regular de `<[^>]*>`.
/// - `input`, `button`, `select`, `textarea`: são a parte clicável de um
///   formulário. Sem eles não há o que submeter.
/// - `form`: **só a etiqueta**, o miolo fica. Muita newsletter embrulha o
///   conteúdo inteiro num `<form>`, e jogar o miolo fora apagaria a mensagem
///   para arrancar uma casca.
/// - `base`, `link`, `meta`: mandam o motor buscar coisa de fora ou reescrevem
///   o alvo dos links relativos. Nada disso tem uso legítimo aqui.
/// - Comentários: fora inteiros, inclusive as condicionais do Outlook.
/// - Atributos `on*` e qualquer `href`/`src` que aponte para `javascript:`,
///   `vbscript:` ou `data:text/html`.
///
/// O `<style>` **fica**. Ele é o que faz o email do provedor parecer o email do
/// provedor; o que ele poderia pedir de fora (`url(https://…)`) é barrado na
/// WebView pela lista de regras, não aqui.
public enum MimeSanitize {
    // MARK: - Os tetos

    /// Quanto pesa, no máximo, **uma** imagem embutida — em bytes já
    /// decodificados.
    ///
    /// 512 kB é largo para o que uma imagem de email é de verdade (logotipo,
    /// ícone, banner: dezenas de kB) e estreito o bastante para uma mensagem
    /// não carregar uma fotografia inteira dentro do banco. Acima do teto, a
    /// imagem vira `placeholder`: o lugar dela continua no layout, o peso não.
    public static let tetoPorImagem = 512 * 1024

    /// Quanto pesam, somadas, todas as imagens embutidas de **uma** mensagem.
    ///
    /// Duas contas diferentes, porque os dois abusos são diferentes: uma imagem
    /// gigante e mil imagens pequenas. O orçamento é gasto na ordem do
    /// documento — a primeira imagem da mensagem é a que mais importa, e é a
    /// que tem a maior chance de caber.
    public static let tetoPorMensagem = 2 * 1024 * 1024

    /// Quanto pode pesar o HTML sanitizado que vai para o banco, em bytes UTF-8.
    ///
    /// Acima disto o decodificador devolve `nil` em vez de HTML — e o leitor
    /// desenha o texto, que é o caminho de sempre. Truncar não é opção: HTML
    /// cortado no meio de uma etiqueta é pior do que HTML nenhum. E o `data:`
    /// das imagens conta aqui dentro: base64 infla um terço, então
    /// `tetoPorMensagem` de imagem já ocupa quase 2,7 MB deste orçamento — é de
    /// propósito que este teto é maior que aquele.
    public static let tetoDoHTML = 4 * 1024 * 1024

    /// O que entra no lugar de uma imagem que estourou o teto: um GIF
    /// transparente de 1×1. O `alt` do remetente continua lá para dizer o que
    /// era.
    public static let placeholder =
        "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    /// Uma imagem que veio dentro da própria mensagem, referenciada por
    /// `cid:` no HTML.
    public struct ImagemInline: Sendable, Equatable {
        /// O `Content-ID` **sem** os sinais de menor e maior.
        public let contentID: String
        public let mime: String
        public let dados: Data

        public init(contentID: String, mime: String, dados: Data) {
            self.contentID = contentID
            self.mime = mime
            self.dados = dados
        }
    }

    // MARK: - As listas

    /// Etiqueta e miolo, os dois fora.
    private static let removidasComConteudo: Set<String> = [
        "script", "iframe", "object", "embed", "applet", "frame", "frameset",
        "select", "textarea", "base", "link", "meta", "input", "button",
    ]

    /// Só a etiqueta; o miolo continua sendo a mensagem.
    private static let removidasSoATag: Set<String> = ["form"]

    /// As que não têm fechamento — não podem abrir região muda, ou o resto do
    /// documento inteiro sumiria atrás de um `<input>`.
    private static let vazias: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr",
    ]

    /// Os atributos que carregam endereço, e por isso precisam de esquema
    /// examinado.
    private static let atributosDeURL: Set<String> = [
        "href", "src", "action", "formaction", "background", "poster",
        "srcset", "xlink:href", "data", "codebase", "cite", "longdesc",
    ]

    /// Os esquemas que não entram, examinados **depois** de decodificar
    /// entidades: `&#106;avascript:alert(1)` é `javascript:alert(1)` para o
    /// motor, e um teste de prefixo sobre o texto cru não veria nada.
    private static let esquemasProibidos = [
        "javascript:", "vbscript:", "data:text/html", "data:application",
        "data:image/svg", "livescript:", "mocha:",
    ]

    // MARK: - A entrada

    /// O HTML limpo, com as imagens `cid:` já resolvidas em `data:`.
    ///
    /// - Returns: `nil` quando não sobrou nada de útil (HTML vazio) ou quando o
    ///   resultado estourou `tetoDoHTML`.
    public static func sanitize(html: String, imagens: [ImagemInline] = []) -> String? {
        let mapa = embute(imagens)
        let limpo = varre(html, imagens: mapa)
        let podado = limpo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !podado.isEmpty else { return nil }
        guard podado.utf8.count <= tetoDoHTML else { return nil }
        return podado
    }

    /// As imagens viram `data:` — na ordem do documento, gastando o orçamento
    /// até ele acabar.
    ///
    /// Interna e testável à parte porque a regra do teto é uma decisão de
    /// produto ("a mensagem não carrega uma fotografia inteira"), não um
    /// detalhe do varredor.
    static func embute(_ imagens: [ImagemInline]) -> [String: String] {
        var mapa: [String: String] = [:]
        var gasto = 0
        for imagem in imagens {
            let chave = normalizaContentID(imagem.contentID)
            guard mapa[chave] == nil else { continue }
            guard imagem.dados.count <= tetoPorImagem,
                  gasto + imagem.dados.count <= tetoPorMensagem else {
                mapa[chave] = placeholder
                continue
            }
            gasto += imagem.dados.count
            let mime = imagem.mime.isEmpty ? "image/png" : imagem.mime
            mapa[chave] = "data:\(mime);base64,\(imagem.dados.base64EncodedString())"
        }
        return mapa
    }

    /// `<abc@def>` e `ABC@DEF` viram a mesma chave. O RFC diz que `Content-ID`
    /// é sensível a maiúsculas, mas geradores de email reais divergem entre o
    /// cabeçalho e o `src` da mesma mensagem — casar por igualdade exata
    /// deixaria imagens legítimas sem `data:` por causa de uma letra.
    static func normalizaContentID(_ cru: String) -> String {
        var texto = cru.trimmingCharacters(in: .whitespacesAndNewlines)
        if texto.hasPrefix("<") { texto = String(texto.dropFirst()) }
        if texto.hasSuffix(">") { texto = String(texto.dropLast()) }
        return texto.lowercased()
    }

    // MARK: - O varredor

    private static func varre(_ html: String, imagens: [String: String]) -> String {
        var saida = ""
        var mudo: String?
        var i = html.startIndex

        while i < html.endIndex {
            let c = html[i]
            guard c == "<" else {
                if mudo == nil { saida.append(c) }
                i = html.index(after: i)
                continue
            }
            if html[i...].hasPrefix("<!--") {
                if let fim = html.range(of: "-->", range: i..<html.endIndex) {
                    i = fim.upperBound
                } else {
                    i = html.endIndex
                }
                continue
            }
            guard let fecha = html[i...].firstIndex(of: ">") else {
                // `<` solto no meio do texto: é texto, e como texto tem de sair
                // escapado — senão o motor o lê como o começo de uma etiqueta
                // que o varredor achou que não existia.
                if mudo == nil { saida.append("&lt;") }
                i = html.index(after: i)
                continue
            }
            let crua = String(html[html.index(after: i)..<fecha])
            i = html.index(after: fecha)

            let fechamento = crua.hasPrefix("/")
            let autofechada = crua.hasSuffix("/")
            let nome = nomeDaTag(crua)

            if let aberto = mudo {
                if fechamento, nome == aberto { mudo = nil }
                continue
            }
            if nome.isEmpty {
                // `<!DOCTYPE …>`, `<?xml …>` e companhia: fora, sem drama.
                continue
            }
            if removidasComConteudo.contains(nome) {
                if !fechamento, !autofechada, !vazias.contains(nome) { mudo = nome }
                continue
            }
            if removidasSoATag.contains(nome) { continue }
            if fechamento {
                saida += "</\(nome)>"
                continue
            }
            saida += reescreve(nome: nome, crua: crua, imagens: imagens)
        }
        return saida
    }

    /// `/p class="x"` → `p`.
    private static func nomeDaTag(_ crua: String) -> String {
        let semBarra = crua.hasPrefix("/") ? String(crua.dropFirst()) : crua
        return String(semBarra.prefix { $0.isLetter || $0.isNumber })
            .lowercased()
    }

    /// A etiqueta de abertura, remontada só com o que passou.
    private static func reescreve(
        nome: String, crua: String, imagens: [String: String]
    ) -> String {
        var saida = "<" + nome
        for (chave, valor) in atributos(de: crua) {
            guard let limpo = valorPermitido(
                atributo: chave, valor: valor, imagens: imagens
            ) else { continue }
            saida += " \(chave)=\"\(escapa(limpo))\""
        }
        if crua.hasSuffix("/") || vazias.contains(nome) { saida += " /" }
        return saida + ">"
    }

    /// O que sobra de um atributo, ou `nil` quando ele inteiro vai embora.
    static func valorPermitido(
        atributo: String, valor: String, imagens: [String: String]
    ) -> String? {
        let chave = atributo.lowercased()
        // `onclick`, `onerror`, `onload`: o vetor mais comum que existe em
        // email, e o único que sobrevive a JavaScript desligado se um dia
        // alguém religar o interruptor por engano.
        if chave.hasPrefix("on") { return nil }
        // `srcdoc` é um documento inteiro dentro de um atributo. Só existe em
        // `<iframe>`, que já foi embora — mas o dia em que a lista mudar, esta
        // linha é a que impede o documento de voltar por baixo.
        if chave == "srcdoc" { return nil }
        guard atributosDeURL.contains(chave) else { return valor }

        let alvo = MimeBody.decodeEntities(valor)
            .filter { !$0.isWhitespace && $0.unicodeScalars.allSatisfy { e in e.value >= 0x20 } }
            .lowercased()
        if esquemasProibidos.contains(where: { alvo.hasPrefix($0) }) { return nil }
        if alvo.hasPrefix("cid:") {
            // A imagem embutida da própria mensagem. Resolvida **aqui**, contra
            // o que veio no MIME — nunca por uma busca que a WebView faria.
            let id = normalizaContentID(String(alvo.dropFirst(4)))
            return imagens[id] ?? placeholder
        }
        return valor
    }

    /// Só as aspas e o menor: reescapar `&` transformaria todo `&amp;` de uma
    /// URL em `&amp;amp;` a cada passada.
    private static func escapa(_ valor: String) -> String {
        valor
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: - Atributos

    /// Os atributos de uma etiqueta crua, na ordem em que foram escritos.
    ///
    /// Escrito à mão, e não por expressão regular, pela mesma razão que o resto
    /// deste arquivo: os casos que interessam são justamente os malformados —
    /// aspas simples, valor sem aspas, atributo sem valor, `=` com espaço em
    /// volta —, e é neles que uma expressão regular curta se cala.
    static func atributos(de crua: String) -> [(String, String)] {
        let texto = Array(crua.hasPrefix("/") ? String(crua.dropFirst()) : crua)
        var i = 0
        // O nome da etiqueta.
        while i < texto.count, texto[i].isLetter || texto[i].isNumber { i += 1 }

        var pares: [(String, String)] = []
        while i < texto.count {
            while i < texto.count, texto[i].isWhitespace || texto[i] == "/" { i += 1 }
            guard i < texto.count else { break }
            let inicio = i
            while i < texto.count, !texto[i].isWhitespace, texto[i] != "=", texto[i] != "/" { i += 1 }
            guard i > inicio else { i += 1; continue }
            let nome = String(texto[inicio..<i])
            var j = i
            while j < texto.count, texto[j].isWhitespace { j += 1 }
            guard j < texto.count, texto[j] == "=" else {
                // Atributo sem valor (`disabled`, `hidden`): vale como vazio.
                pares.append((nome, ""))
                continue
            }
            j += 1
            while j < texto.count, texto[j].isWhitespace { j += 1 }
            guard j < texto.count else {
                pares.append((nome, ""))
                i = j
                break
            }
            let aspas = texto[j]
            if aspas == "\"" || aspas == "'" {
                j += 1
                let comeco = j
                while j < texto.count, texto[j] != aspas { j += 1 }
                pares.append((nome, String(texto[comeco..<min(j, texto.count)])))
                i = min(j + 1, texto.count)
            } else {
                let comeco = j
                while j < texto.count, !texto[j].isWhitespace { j += 1 }
                pares.append((nome, String(texto[comeco..<j])))
                i = j
            }
        }
        return pares
    }
}
