import Foundation

/// O corpo formatável do composer — **fora de qualquer `View`**.
///
/// Existe aqui, e não em `UNIShell`, pelo motivo registrado em
/// `docs/decisoes-de-engenharia.md`: `View` é `@MainActor` implícito no Swift 6,
/// e lógica pura pendurada num `static` dentro de uma `View` trapa em runtime
/// quando um teste nonisolated a chama.
///
/// O contrato é: **uma** fonte de verdade por trecho de texto — o atributo
/// `BodyStyleAttribute`, que guarda família, corpo, negrito, itálico,
/// sublinhado, tachado, cor e realce. Quem desenha (o `UNIShell`) projeta esse
/// atributo nos atributos que o SwiftUI entende (`\.font`, `\.foregroundColor`,
/// …). Assim ler o estado da seleção é exato: `Font` do SwiftUI é opaca e não
/// dá para perguntar a ela se está em negrito.
///
/// Alinhamento, tabela e hyperlink são de **parágrafo** ou de **trecho** e têm
/// atributo próprio; ver `BodyAlignment`, `BodyTableCell` e o `\.link` da
/// Foundation.
public enum RichBody {}

// MARK: - Alinhamento

/// O alinhamento de um parágrafo do corpo, com os **quatro** do protótipo.
///
/// Até a Task AF o alinhamento morava em
/// `AttributeScopes.CoreTextAttributes.TextAlignmentAttribute`, que tem três
/// casos — `left`, `center`, `right`. Não havia justificado no tipo, e por isso
/// o botão "≡" da barra ficava desabilitado com o motivo escrito no `help`.
///
/// `NSParagraphStyle.alignment` do AppKit tem `.justified` desde sempre; o que
/// faltava era o editor ser um `NSTextView`. O modelo guarda este enum — puro,
/// sem AppKit, testável fora da `View` — e quem desenha projeta em
/// `NSTextAlignment`.
public enum BodyAlignment: String, Codable, Hashable, Sendable, CaseIterable {
    case left
    case center
    case right
    case justified
}

public enum BodyAlignmentAttribute: CodableAttributedStringKey, Sendable {
    public typealias Value = BodyAlignment
    public static let name = "br.okamiuni.bodyAlignment"
}

// MARK: - Tabela

/// Uma célula de tabela, do ponto de vista do modelo.
///
/// O desenho é `NSTextTable` + `NSTextTableBlock` dentro de
/// `NSParagraphStyle.textBlocks`, mas isso é AppKit e não pode subir para cá.
/// O que sobe é a **posição**: que tabela, que linha, que coluna, e de que
/// tamanho é a grade. Quem desenha reconstrói os blocos a partir disto.
///
/// `table` é a identidade da tabela dentro deste corpo, e não um índice de
/// ordem: duas tabelas seguidas precisam de números diferentes para não
/// virarem uma só de oito linhas.
public struct BodyTableCell: Codable, Hashable, Sendable {
    public var table: Int
    public var row: Int
    public var column: Int
    public var rows: Int
    public var columns: Int

    public init(table: Int, row: Int, column: Int, rows: Int, columns: Int) {
        self.table = table
        self.row = row
        self.column = column
        self.rows = rows
        self.columns = columns
    }
}

public enum BodyTableAttribute: CodableAttributedStringKey, Sendable {
    public typealias Value = BodyTableCell
    public static let name = "br.okamiuni.bodyTable"
}

// MARK: - O estilo de um trecho

public struct BodyStyle: Codable, Hashable, Sendable {
    public var family: String
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strike: Bool
    /// `#RRGGBB`. Nunca `transparent`: texto invisível não é formatação.
    public var colorHex: String
    /// `#RRGGBB` ou o literal `transparent`, que é a ausência de realce.
    public var highlightHex: String

    public init(
        family: String = BodyStyle.defaultFamily,
        size: Double = BodyStyle.defaultSize,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strike: Bool = false,
        colorHex: String = BodyStyle.defaultColorHex,
        highlightHex: String = BodyStyle.noHighlight
    ) {
        self.family = family
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.colorHex = colorHex
        self.highlightHex = highlightHex
    }

    /// Protótipo: `FMT_DEFAULTS`.
    public static let defaultFamily = "Newsreader"
    public static let defaultSize: Double = 15
    public static let defaultColorHex = "#241F18"
    public static let noHighlight = "transparent"

    public static let `default` = BodyStyle()
}

/// A chave do atributo. `CodableAttributedStringKey` para o corpo sobreviver a
/// qualquer serialização futura do rascunho.
public enum BodyStyleAttribute: CodableAttributedStringKey, Sendable {
    public typealias Value = BodyStyle
    public static let name = "br.okamiuni.bodyStyle"
}

public enum ListKind: String, Codable, Hashable, Sendable, CaseIterable {
    case bulleted
    case numbered
}

// MARK: - O que a barra lê da seleção

/// O estado que a barra de formatação mostra.
///
/// Campos booleanos são **conjunção**: `bold` só é `true` se *todo* o intervalo
/// estiver em negrito, que é como um processador de texto acende o B. Campos
/// opcionais são `nil` quando o intervalo mistura valores — a barra usa isso
/// para não mentir sobre "qual" fonte está selecionada.
public struct BodyReading: Equatable, Sendable {
    public var family: String?
    public var size: Double?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strike: Bool
    public var colorHex: String?
    public var highlightHex: String?
    public var alignment: BodyAlignment?
    public var list: ListKind?
    /// `true` quando os parágrafos tocados não concordam sobre a lista.
    public var listMixed: Bool
    /// O hyperlink do intervalo, quando ele é **um só** em toda a seleção.
    /// Nulo quando não há link ou quando a seleção mistura destinos.
    public var link: URL?
    /// `true` quando algum trecho da seleção tem link — inclusive quando eles
    /// divergem. É o que permite ao botão dizer "remover" sem mentir.
    public var hasLink: Bool
    /// `true` quando **todo** parágrafo tocado é célula de tabela. A barra usa
    /// isso para não oferecer uma tabela dentro de outra.
    public var inTable: Bool
    /// O menor recuo entre os parágrafos tocados. Zero desabilita o "⇤": não
    /// existe recuo negativo, e botão que não faz nada é defeito.
    public var indent: Int
    /// `false` quando o cursor é um ponto de inserção, sem texto selecionado.
    public var hasSelection: Bool

    public init(
        family: String? = nil,
        size: Double? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strike: Bool = false,
        colorHex: String? = nil,
        highlightHex: String? = nil,
        alignment: BodyAlignment? = nil,
        list: ListKind? = nil,
        listMixed: Bool = false,
        link: URL? = nil,
        hasLink: Bool = false,
        inTable: Bool = false,
        indent: Int = 0,
        hasSelection: Bool = false
    ) {
        self.family = family
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.colorHex = colorHex
        self.highlightHex = highlightHex
        self.alignment = alignment
        self.list = list
        self.listMixed = listMixed
        self.link = link
        self.hasLink = hasLink
        self.inTable = inTable
        self.indent = indent
        self.hasSelection = hasSelection
    }

    /// O que a barra mostra quando não há texto nenhum: os padrões.
    public static let blank = BodyReading(
        family: BodyStyle.defaultFamily,
        size: BodyStyle.defaultSize,
        colorHex: BodyStyle.defaultColorHex,
        highlightHex: BodyStyle.noHighlight,
        alignment: .left
    )
}

// MARK: - Leitura

extension RichBody {

    /// O estilo efetivo de um trecho: o que o atributo diz, ou o padrão.
    public static func style(of container: AttributeContainer) -> BodyStyle {
        container[BodyStyleAttribute.self] ?? .default
    }

    /// Lê o estado do intervalo. `ranges` vazio, ou só com intervalos vazios,
    /// significa cursor sem seleção — aí vale `typing`, os atributos de
    /// digitação que o editor aplicaria no próximo caractere.
    public static func reading(
        of text: AttributedString,
        over ranges: [Range<AttributedString.Index>],
        typing: BodyStyle? = nil
    ) -> BodyReading {
        let filled = ranges.filter { !$0.isEmpty }
        let paragraphs = self.paragraphs(of: text, touchedBy: ranges)

        guard !filled.isEmpty else {
            var reading = self.reading(fromStyles: [typing ?? collapsedStyle(in: text, at: ranges.first?.lowerBound)])
            reading.hasSelection = false
            applyParagraphReading(&reading, text: text, paragraphs: paragraphs)
            applyLinkReading(&reading, text: text, over: probe(in: text, at: ranges.first?.lowerBound))
            return reading
        }

        var styles: [BodyStyle] = []
        for range in filled {
            for run in text[range].runs {
                styles.append(run.attributes[BodyStyleAttribute.self] ?? .default)
            }
        }
        if styles.isEmpty { styles = [typing ?? .default] }

        var reading = self.reading(fromStyles: styles)
        reading.hasSelection = true
        applyParagraphReading(&reading, text: text, paragraphs: paragraphs)
        applyLinkReading(&reading, text: text, over: filled)
        return reading
    }

    /// O caractere à esquerda do cursor, como intervalo — o mesmo que
    /// `collapsedStyle` usa. Um cursor encostado num link está "dentro" dele
    /// para efeito de barra, senão editar um link exigiria selecioná-lo inteiro.
    private static func probe(
        in text: AttributedString,
        at index: AttributedString.Index?
    ) -> [Range<AttributedString.Index>] {
        guard let index else { return [] }
        let chars = text.characters
        guard chars.startIndex < chars.endIndex else { return [] }
        let start = index > chars.startIndex ? chars.index(before: index) : index
        guard start < chars.endIndex else { return [] }
        return [start..<chars.index(after: start)]
    }

    /// O link do intervalo. `link` só é preenchido quando **todo** o intervalo
    /// aponta para o mesmo lugar; `hasLink` basta um trecho ter.
    private static func applyLinkReading(
        _ reading: inout BodyReading,
        text: AttributedString,
        over ranges: [Range<AttributedString.Index>]
    ) {
        var links: [URL?] = []
        for range in ranges {
            for run in text[range].runs { links.append(run.attributes.link) }
        }
        guard !links.isEmpty else { return }
        reading.hasLink = links.contains { $0 != nil }
        reading.link = links.allSatisfy { $0 == links[0] } ? links[0] : nil
    }

    /// O estilo sob um cursor sem seleção: o do caractere à esquerda, que é o
    /// que qualquer editor herda ao continuar digitando.
    private static func collapsedStyle(
        in text: AttributedString,
        at index: AttributedString.Index?
    ) -> BodyStyle {
        guard let index else { return .default }
        let chars = text.characters
        guard chars.startIndex < chars.endIndex else { return .default }
        let probe = index > chars.startIndex ? chars.index(before: index) : index
        guard probe < chars.endIndex else { return .default }
        return text[probe..<chars.index(after: probe)].runs.first?
            .attributes[BodyStyleAttribute.self] ?? .default
    }

    private static func reading(fromStyles styles: [BodyStyle]) -> BodyReading {
        guard let first = styles.first else { return .blank }
        func uniform<T: Equatable>(_ key: (BodyStyle) -> T) -> T? {
            let value = key(first)
            return styles.allSatisfy { key($0) == value } ? value : nil
        }
        return BodyReading(
            family: uniform(\.family),
            size: uniform(\.size),
            bold: styles.allSatisfy(\.bold),
            italic: styles.allSatisfy(\.italic),
            underline: styles.allSatisfy(\.underline),
            strike: styles.allSatisfy(\.strike),
            colorHex: uniform(\.colorHex),
            highlightHex: uniform(\.highlightHex)
        )
    }

    private static func applyParagraphReading(
        _ reading: inout BodyReading,
        text: AttributedString,
        paragraphs: [Range<AttributedString.Index>]
    ) {
        guard !paragraphs.isEmpty else {
            reading.alignment = .left
            return
        }
        let alignments = paragraphs.map { alignment(of: text, at: $0) }
        reading.alignment = alignments.allSatisfy { $0 == alignments[0] } ? alignments[0] : nil

        let cells = paragraphs.map { tableCell(of: text, at: $0) }
        reading.inTable = cells.allSatisfy { $0 != nil }

        let prefixes = paragraphs.map { prefix(of: String(text[$0].characters)) }
        let kinds = prefixes.map(\.list)
        if kinds.allSatisfy({ $0 == kinds[0] }) {
            reading.list = kinds[0]
            reading.listMixed = false
        } else {
            reading.list = nil
            reading.listMixed = true
        }
        reading.indent = prefixes.map(\.indent).min() ?? 0
    }
}

// MARK: - Escrita: estilo de trecho

extension RichBody {

    /// Reescreve o estilo de **cada trecho** do intervalo, um por vez, sem
    /// nivelar o resto do texto. É esta função que conserta o defeito da Task W:
    /// a barra antiga trocava `.font(...)` do editor inteiro.
    ///
    /// Com o intervalo vazio (cursor), não há o que reescrever: quem chama usa
    /// `restyled(_:)` sobre os atributos de digitação.
    public static func restyle(
        _ text: inout AttributedString,
        over ranges: [Range<AttributedString.Index>],
        _ body: (inout BodyStyle) -> Void
    ) {
        // Os trechos são colhidos antes de qualquer escrita. Escrever um
        // atributo não move índice nenhum, então as faixas continuam válidas —
        // e reconstruir a string com `replaceSubrange` arriscaria perder o
        // alinhamento, que é um atributo com fronteira de parágrafo.
        var updates: [(Range<AttributedString.Index>, BodyStyle)] = []
        for range in ranges where !range.isEmpty {
            for run in text[range].runs {
                var style = run.attributes[BodyStyleAttribute.self] ?? .default
                body(&style)
                updates.append((run.range, style))
            }
        }
        for (range, style) in updates {
            text[range][BodyStyleAttribute.self] = style
        }
    }

    /// A mesma transformação aplicada a um estilo solto — os atributos de
    /// digitação, quando não há seleção.
    public static func restyled(_ style: BodyStyle, _ body: (inout BodyStyle) -> Void) -> BodyStyle {
        var copy = style
        body(&copy)
        return copy
    }

    /// Devolve o texto ao estilo padrão no intervalo, incluindo o alinhamento
    /// dos parágrafos tocados. O "⌫" do protótipo.
    public static func clearFormatting(
        _ text: inout AttributedString,
        over ranges: [Range<AttributedString.Index>]
    ) {
        restyle(&text, over: ranges) { $0 = .default }
        align(&text, over: ranges, to: .left)
    }
}

// MARK: - Escrita: parágrafo

extension RichBody {

    /// Os parágrafos do texto — os trechos entre quebras de linha, sem a quebra.
    /// Um texto vazio tem um parágrafo vazio, como qualquer editor.
    public static func paragraphs(of text: AttributedString) -> [Range<AttributedString.Index>] {
        let chars = text.characters
        var result: [Range<AttributedString.Index>] = []
        var start = chars.startIndex
        var index = chars.startIndex
        while index < chars.endIndex {
            let next = chars.index(after: index)
            if chars[index] == "\n" {
                result.append(start..<index)
                start = next
            }
            index = next
        }
        result.append(start..<chars.endIndex)
        return result
    }

    /// Os parágrafos que a seleção toca. Um cursor sem seleção toca o parágrafo
    /// em que está — é o que faz "alinhar à direita" funcionar sem selecionar.
    public static func paragraphs(
        of text: AttributedString,
        touchedBy ranges: [Range<AttributedString.Index>]
    ) -> [Range<AttributedString.Index>] {
        let all = paragraphs(of: text)
        guard !ranges.isEmpty else { return all.isEmpty ? [] : [all[0]] }
        return all.filter { paragraph in
            ranges.contains { range in
                if range.isEmpty {
                    return paragraph.lowerBound <= range.lowerBound
                        && range.lowerBound <= paragraph.upperBound
                }
                return paragraph.lowerBound < range.upperBound
                    && range.lowerBound < paragraph.upperBound
            }
        }
    }

    /// O parágrafo **com** a quebra que o termina, quando ela existe.
    ///
    /// É este o intervalo em que atributo de parágrafo se escreve, e não o
    /// parágrafo nu. Um parágrafo vazio é um intervalo vazio, e escrever num
    /// intervalo vazio de `AttributedString` não faz nada — foi assim que a
    /// linha em branco entre dois parágrafos ficava sem alinhamento e sem
    /// altura de linha, e o cursor mudava de tamanho ao passar por ela.
    ///
    /// A quebra também é o **portador estável** da célula de tabela: o texto
    /// que a pessoa digita dentro de uma célula herda os atributos do caractere
    /// à esquerda, que numa célula vazia é a quebra da célula **anterior**. A
    /// quebra do próprio parágrafo, não.
    public static func span(of paragraph: Range<AttributedString.Index>, in text: AttributedString)
        -> Range<AttributedString.Index>
    {
        let chars = text.characters
        guard paragraph.upperBound < chars.endIndex else { return paragraph }
        return paragraph.lowerBound..<chars.index(after: paragraph.upperBound)
    }

    /// O que a quebra que termina o parágrafo carrega. Nulo no último
    /// parágrafo do corpo, que não tem quebra.
    private static func terminator(
        of paragraph: Range<AttributedString.Index>,
        in text: AttributedString
    ) -> AttributeContainer? {
        let chars = text.characters
        guard paragraph.upperBound < chars.endIndex else { return nil }
        let next = chars.index(after: paragraph.upperBound)
        return text[paragraph.upperBound..<next].runs.first?.attributes
    }

    /// O alinhamento deste parágrafo. Lê da quebra, que é onde `align` escreve,
    /// e cai para o começo do parágrafo quando ela não existe.
    public static func alignment(
        of text: AttributedString,
        at paragraph: Range<AttributedString.Index>
    ) -> BodyAlignment {
        if let value = terminator(of: paragraph, in: text)?[BodyAlignmentAttribute.self] {
            return value
        }
        return text[paragraph].runs.first?.attributes[BodyAlignmentAttribute.self] ?? .left
    }

    /// A célula de tabela deste parágrafo, ou nulo quando ele não é célula.
    public static func tableCell(
        of text: AttributedString,
        at paragraph: Range<AttributedString.Index>
    ) -> BodyTableCell? {
        terminator(of: paragraph, in: text)?[BodyTableAttribute.self]
    }

    /// Alinha os parágrafos tocados, nos **quatro** alinhamentos.
    ///
    /// Escreve no parágrafo inteiro **e** na quebra que o termina: sem a quebra,
    /// parágrafo vazio não guardaria alinhamento nenhum.
    public static func align(
        _ text: inout AttributedString,
        over ranges: [Range<AttributedString.Index>],
        to alignment: BodyAlignment
    ) {
        for paragraph in paragraphs(of: text, touchedBy: ranges) {
            let span = span(of: paragraph, in: text)
            guard !span.isEmpty else { continue }
            text[span][BodyAlignmentAttribute.self] = alignment
        }
    }
}

// MARK: - Escrita: hyperlink

extension RichBody {

    /// Põe (ou tira, com `nil`) o hyperlink nos intervalos selecionados.
    ///
    /// O atributo é o `\.link` da Foundation — o mesmo que o `NSTextView`
    /// desenha, clica e arrasta sozinho. Não inventamos chave nova para isto:
    /// uma chave nossa não seria reconhecida por ninguém que receba o texto.
    public static func setLink(
        _ text: inout AttributedString,
        over ranges: [Range<AttributedString.Index>],
        to url: URL?
    ) {
        for range in ranges where !range.isEmpty {
            text[range].link = url
        }
    }

    /// Escreve um texto novo já com link, no ponto pedido — o caminho de quem
    /// clicou em "↗" sem nada selecionado. Devolve o intervalo escrito.
    @discardableResult
    public static func insertLink(
        _ text: inout AttributedString,
        at index: AttributedString.Index,
        label: String,
        url: URL,
        style: BodyStyle
    ) -> Range<AttributedString.Index> {
        var piece = AttributedString(label)
        piece[BodyStyleAttribute.self] = style
        piece.link = url
        let offset = text.characters.distance(from: text.startIndex, to: index)
        text.insert(piece, at: index)
        let start = text.characters.index(text.startIndex, offsetBy: offset)
        let end = text.characters.index(start, offsetBy: label.count)
        return start..<end
    }
}

// MARK: - Escrita: tabela

extension RichBody {

    /// O menor número de tabela ainda livre neste corpo.
    ///
    /// Duas tabelas seguidas precisam de números diferentes, senão quem desenha
    /// junta as duas numa grade só — que é exatamente o defeito que aparece
    /// quando se usa o índice de ordem em vez de identidade.
    public static func nextTableID(in text: AttributedString) -> Int {
        var highest = -1
        for run in text.runs {
            if let cell = run.attributes[BodyTableAttribute.self] {
                highest = max(highest, cell.table)
            }
        }
        return highest + 1
    }

    /// Insere uma grade `rows`×`columns` **depois** do parágrafo em que o
    /// cursor está.
    ///
    /// Cada célula é um parágrafo, e é a **quebra** dele que carrega a posição —
    /// ver `span(of:in:)`. Uma célula vazia é um parágrafo vazio, e sem a quebra
    /// não haveria onde pendurar a coordenada dela.
    ///
    /// A tabela nunca começa no meio de uma linha: se o parágrafo do cursor tem
    /// texto, uma quebra entra antes. É o que qualquer editor faz, e evita a
    /// primeira célula nascer com metade da frase de cima dentro.
    public static func insertTable(
        _ text: inout AttributedString,
        at ranges: [Range<AttributedString.Index>],
        rows: Int,
        columns: Int,
        style: BodyStyle = .default
    ) {
        guard rows > 0, columns > 0 else { return }
        let touched = paragraphs(of: text, touchedBy: ranges)
        guard let paragraph = touched.first else { return }

        let table = nextTableID(in: text)
        var piece = AttributedString()
        if !paragraph.isEmpty { piece += AttributedString("\n") }
        for row in 0..<rows {
            for column in 0..<columns {
                var cell = AttributedString("\n")
                cell[BodyStyleAttribute.self] = style
                cell[BodyTableAttribute.self] = BodyTableCell(
                    table: table, row: row, column: column, rows: rows, columns: columns
                )
                piece += cell
            }
        }
        text.insert(piece, at: paragraph.upperBound)
    }
}

// MARK: - Escrita: listas e recuo

extension RichBody {

    /// O que já está no começo de um parágrafo: quantos níveis de recuo, que
    /// lista, e quantos caracteres isso ocupa.
    public struct Prefix: Equatable, Sendable {
        public var indent: Int
        public var list: ListKind?
        public var length: Int
    }

    /// Um nível de recuo. Protótipo usa `padding-left`; em texto puro o
    /// equivalente honesto são espaços, que sobrevivem a copiar e colar.
    public static let indentUnit = "    "
    public static let bullet = "• "

    public static func prefix(of paragraph: String) -> Prefix {
        var rest = Substring(paragraph)
        var indent = 0
        var length = 0
        while rest.hasPrefix(indentUnit) {
            rest = rest.dropFirst(indentUnit.count)
            length += indentUnit.count
            indent += 1
        }
        if rest.hasPrefix(bullet) {
            return Prefix(indent: indent, list: .bulleted, length: length + bullet.count)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            return Prefix(indent: indent, list: .numbered, length: length + digits.count + 2)
        }
        return Prefix(indent: indent, list: nil, length: length)
    }

    /// Liga, troca ou desliga a lista nos parágrafos tocados.
    /// `kind` nulo desliga. A numerada renumera de 1 dentro do bloco tocado.
    public static func setList(
        _ text: inout AttributedString,
        over ranges: [Range<AttributedString.Index>],
        to kind: ListKind?
    ) {
        rewritePrefixes(&text, over: ranges) { existing, position in
            var next = existing
            next.list = kind
            return marker(next, number: position + 1)
        }
    }

    /// Aumenta (`+1`) ou diminui (`-1`) o recuo dos parágrafos tocados.
    /// Nunca desce abaixo de zero — a barra desabilita o "⇤" nesse caso.
    public static func indent(
        _ text: inout AttributedString,
        over ranges: [Range<AttributedString.Index>],
        by delta: Int
    ) {
        rewritePrefixes(&text, over: ranges) { existing, position in
            var next = existing
            next.indent = max(0, existing.indent + delta)
            return marker(next, number: position + 1)
        }
    }

    private static func marker(_ prefix: Prefix, number: Int) -> String {
        let pad = String(repeating: indentUnit, count: prefix.indent)
        switch prefix.list {
        case .none: return pad
        case .bulleted: return pad + bullet
        case .numbered: return pad + "\(number). "
        }
    }

    /// Troca o prefixo de cada parágrafo tocado, do último para o primeiro —
    /// mexer no primeiro invalidaria os índices dos seguintes.
    private static func rewritePrefixes(
        _ text: inout AttributedString,
        over ranges: [Range<AttributedString.Index>],
        _ build: (Prefix, Int) -> String
    ) {
        let touched = paragraphs(of: text, touchedBy: ranges)
        guard !touched.isEmpty else { return }

        for (offset, paragraph) in touched.enumerated().reversed() {
            let plain = String(text[paragraph].characters)
            let existing = prefix(of: plain)
            let replacement = build(existing, offset)
            guard replacement != String(plain.prefix(existing.length)) else { continue }

            let chars = text.characters
            let cut = chars.index(paragraph.lowerBound, offsetBy: existing.length)
            var piece = AttributedString(replacement)
            // O marcador herda o estilo do texto que ele encabeça, senão a
            // bolinha sai na fonte errada assim que o parágrafo muda de fonte.
            piece[BodyStyleAttribute.self] = text[paragraph].runs.first?
                .attributes[BodyStyleAttribute.self] ?? .default
            text.replaceSubrange(paragraph.lowerBound..<cut, with: piece)
        }
    }
}
