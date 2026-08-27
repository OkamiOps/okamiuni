import Foundation
import CoreText

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
/// Alinhamento é a exceção: mora no atributo de parágrafo do CoreText, que já
/// tem a semântica de parágrafo inteiro que precisamos.
public enum RichBody {}

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
    public var alignment: AttributedString.TextAlignment?
    public var list: ListKind?
    /// `true` quando os parágrafos tocados não concordam sobre a lista.
    public var listMixed: Bool
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
        alignment: AttributedString.TextAlignment? = nil,
        list: ListKind? = nil,
        listMixed: Bool = false,
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
        return reading
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
        let alignments = paragraphs.map { range -> AttributedString.TextAlignment in
            text[range].runs.first?
                .attributes[AttributeScopes.CoreTextAttributes.TextAlignmentAttribute.self] ?? .left
        }
        reading.alignment = alignments.allSatisfy { $0 == alignments[0] } ? alignments[0] : nil

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

    /// Alinha os parágrafos tocados. O atributo do CoreText já tem fronteira de
    /// parágrafo, então escrevê-lo num trecho vale para o parágrafo inteiro.
    public static func align(
        _ text: inout AttributedString,
        over ranges: [Range<AttributedString.Index>],
        to alignment: AttributedString.TextAlignment
    ) {
        for paragraph in paragraphs(of: text, touchedBy: ranges) {
            text[paragraph][AttributeScopes.CoreTextAttributes.TextAlignmentAttribute.self] = alignment
        }
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
