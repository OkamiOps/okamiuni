import Foundation
import UNICore

/// O "o que mudou" de uma versão, em duas listas.
///
/// Duas, e não quatro: o appcast carrega `<description xml:lang="pt-BR">` e
/// `<description xml:lang="en">`, porque manter quatro traduções de changelog
/// a cada release é um custo que ninguém ia pagar por muito tempo — e um
/// changelog desatualizado é pior do que um changelog em inglês. Alemão e
/// francês leem a lista em inglês; ver `bullets(for:)`.
///
/// `undetermined` existe por causa de um detalhe do Sparkle: ele guarda
/// **uma** `<description>` por item do appcast, escolhida pelo idioma
/// preferido do **sistema** (ver `-[SUAppcast bestNodeInNodes:name:]`), e
/// descarta as outras. Quando a lista chega por esse caminho não há como dizer
/// em que idioma ela está — e ela tem de aparecer de todo jeito, senão o
/// painel abre vazio num Mac em alemão.
public struct UpdateChangelog: Codable, Sendable, Equatable {
    public var portuguese: [String]
    public var english: [String]
    public var undetermined: [String]

    public init(
        portuguese: [String] = [],
        english: [String] = [],
        undetermined: [String] = []
    ) {
        self.portuguese = portuguese
        self.english = english
        self.undetermined = undetermined
    }

    public var isEmpty: Bool {
        portuguese.isEmpty && english.isEmpty && undetermined.isEmpty
    }

    /// Os marcadores que esta interface deve mostrar.
    ///
    /// O recuo é intencional e tem ordem: a lista do idioma pedido, depois a
    /// que veio sem idioma, depois a outra. Mostrar o changelog em inglês para
    /// quem pediu português é melhor do que mostrar um painel vazio — é a
    /// mesma escolha que o `L10n` faz ao cair para o português quando a chave
    /// falta na tradução.
    public func bullets(for language: AppLanguage) -> [String] {
        let preferida: [String]
        let alternativa: [String]
        switch language.resolved {
        case .portugueseBrazil:
            preferida = portuguese
            alternativa = english
        default:
            preferida = english
            alternativa = portuguese
        }
        if !preferida.isEmpty { return preferida }
        if !undetermined.isEmpty { return undetermined }
        return alternativa
    }

    // MARK: - Leitura do HTML do appcast

    /// Quantos marcadores o painel mostra, no máximo.
    ///
    /// Um teto existe porque o painel é um popover estreito, não uma página:
    /// um release com quarenta linhas de changelog viraria uma lista que não
    /// cabe e que ninguém lê. Quem quiser a lista inteira tem o link "Ver
    /// release no GitHub" logo abaixo.
    static let maximumBullets = 20

    /// Lê os marcadores do HTML de uma `<description>`.
    ///
    /// O gerador do appcast emite `<ul><li>…</li></ul>`, e esse é o caminho
    /// normal. Os outros dois não são hipótese remota: o gerador é de outra
    /// pessoa e pode mudar de marcação, e um painel vazio porque o `<ul>`
    /// virou `<p>` seria um defeito nosso. Então, sem `<li>`, lê linha por
    /// linha o que houver; sem marcação nenhuma, lê o texto cru.
    ///
    /// Nada de `NSAttributedString(html:)`: ele monta um WebKit por chamada,
    /// exige a main thread e interpreta `<script>` — três coisas que não se
    /// quer para transformar seis linhas de texto em seis linhas de texto.
    public static func bullets(fromHTML html: String) -> [String] {
        let comQuebras = html.replacing(/<br\s*\/?>/.ignoresCase(), with: "\n")
        let itens = itensDeLista(in: comQuebras)
        let cru = itens.isEmpty
            ? comQuebras
                .replacing(/<\/(?:p|div|li|h[1-6]|tr)\s*>/.ignoresCase(), with: "\n")
                .components(separatedBy: "\n")
            : itens
        let limpos = cru
            .map { textoSimples(de: $0) }
            .filter { !$0.isEmpty }
        return Array(limpos.prefix(maximumBullets))
    }

    /// O conteúdo de cada `<li>`, na ordem em que aparecem.
    private static func itensDeLista(in html: String) -> [String] {
        let regra = /<li\b[^>]*>(.*?)<\/li\s*>/
            .ignoresCase()
            .dotMatchesNewlines()
        return html.matches(of: regra).map { String($0.output.1) }
    }

    /// Tira as etiquetas, devolve as entidades ao texto e apara as pontas.
    private static func textoSimples(de fragmento: String) -> String {
        let semEtiquetas = fragmento.replacing(
            /<[^>]+>/.dotMatchesNewlines(), with: ""
        )
        return decodificandoEntidades(semEtiquetas)
            .replacing(/[ \t\u{00A0}]+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// As entidades que um changelog produz na prática, mais as numéricas.
    ///
    /// `&amp;` é desfeita **por último**: desfazê-la antes transformaria
    /// `&amp;lt;` — que é o texto literal "&lt;" — no sinal de menor, e o
    /// changelog passaria a dizer outra coisa.
    private static func decodificandoEntidades(_ texto: String) -> String {
        var resultado = texto
        for (entidade, caractere) in [
            ("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"),
        ] {
            resultado = resultado.replacingOccurrences(of: entidade, with: caractere)
        }
        resultado = resultado.replacing(/&#(x?)([0-9A-Fa-f]+);/) { match in
            let hexadecimal = !match.output.1.isEmpty
            guard let valor = UInt32(match.output.2, radix: hexadecimal ? 16 : 10),
                  let escalar = Unicode.Scalar(valor)
            else { return "" }
            return String(Character(escalar))
        }
        return resultado.replacingOccurrences(of: "&amp;", with: "&")
    }
}
