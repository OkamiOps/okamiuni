import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// A ponte entre o **modelo** do corpo (`AttributedString`, em `UNICore`) e o
/// que o `NSTextView` desenha (`NSAttributedString`).
///
/// ## Por que ela existe
///
/// O contrato do projeto não mudou com a Task AF: **uma** fonte de verdade por
/// trecho — `BodyStyleAttribute` — e os atributos de desenho como **projeção**
/// dela. O que mudou foi o alvo da projeção. Era `\.font` do SwiftUI; agora é
/// `.font`/`.foregroundColor`/`NSParagraphStyle` do AppKit.
///
/// A troca é o que destrava os três que estavam desabilitados desde a Task W:
///
/// - **Tabela** — `NSTextTable` + `NSTextTableBlock` em
///   `NSParagraphStyle.textBlocks`. `AttributedString` não tem modelo de tabela
///   nenhum; `NSParagraphStyle` tem.
/// - **Justificado** — `NSParagraphStyle.alignment = .justified`. O
///   `TextAlignmentAttribute` do CoreText, que o `TextEditor` usava, só tem
///   três casos.
/// - **Hyperlink** — `.link`, que o `NSTextView` desenha, clica e arrasta
///   sozinho.
///
/// De quebra a altura de linha volta para onde ela sempre foi na plataforma:
/// `minimumLineHeight`/`maximumLineHeight`. A indisponibilidade que a Task AA
/// documentou (`conformance of 'NSParagraphStyle' to 'Sendable' is unavailable`)
/// era da restrição do **SwiftUI**, que exige `Sendable` no valor do atributo.
/// Aqui não há restrição: o estilo de parágrafo é construído na hora de
/// desenhar, a partir do modelo, e nunca atravessa fronteira de concorrência.
///
/// ## O que atravessa a volta
///
/// O `NSTextView` é dono do texto enquanto a pessoa digita, então a conversão
/// tem de ser **de ida e de volta**. O que o modelo guarda e a volta precisa
/// reencontrar:
///
/// | modelo | no `NSAttributedString` |
/// |---|---|
/// | `BodyStyleAttribute` | chave própria, em JSON — ver `bodyStyleKey` |
/// | `BodyAlignmentAttribute` | `NSParagraphStyle.alignment` |
/// | `BodyTableAttribute` | `NSParagraphStyle.textBlocks` |
/// | `\.link` | `.link` |
///
/// Alinhamento e tabela **não** precisam de chave própria: o `NSParagraphStyle`
/// os carrega com a mesma informação, e ler de lá é ler o que de fato foi
/// desenhado. O `BodyStyle` precisa, porque ele guarda a família como o design
/// a chama ("Newsreader", "-apple-system") e as cores como token — reconstruir
/// isso de uma `NSFont` e de uma `NSColor` seria adivinhação.
///
/// É um `enum` sem `View` em volta de propósito: `View` é `@MainActor`
/// implícito no Swift 6 e lógica pura pendurada nela trapa em teste nonisolated.
enum ComposerTextKit {

    /// O `BodyStyle` do trecho, em JSON, dentro do `NSAttributedString`.
    ///
    /// Chave própria e não `NSFont`: a fonte desenhada é derivada: perguntar a
    /// ela "que família o design pediu?" devolve o nome da face que o sistema
    /// escolheu, não o que a barra deve mostrar. O mesmo vale para cor de token.
    static let bodyStyleKey = NSAttributedString.Key("br.okamiuni.bodyStyle")

    // MARK: - Modelo → desenho

    /// O corpo pronto para o `NSTextStorage`.
    static func nsAttributed(
        _ model: AttributedString,
        theme: Theme,
        resolvesDefaultColorForPresentation: Bool = true
    ) -> NSAttributedString {
        let plain = String(model.characters)
        let result = NSMutableAttributedString(string: plain)
        guard !plain.isEmpty else { return result }

        for run in model.runs {
            guard let range = nsRange(run.range, in: model, plain: plain) else { continue }
            let style = RichBody.style(of: run.attributes)
            result.addAttributes(
                characterAttributes(
                    style,
                    theme: theme,
                    resolvesDefaultColorForPresentation: resolvesDefaultColorForPresentation
                ),
                range: range
            )
            if let link = run.attributes.link {
                result.addAttribute(.link, value: link, range: range)
            }
        }

        applyParagraphStyles(model, plain: plain, into: result, theme: theme)
        return result
    }

    /// Os atributos de caractere de um trecho: fonte, cor, realce, sublinhado,
    /// tachado, e o próprio `BodyStyle` para a volta.
    static func characterAttributes(
        _ style: BodyStyle,
        theme: Theme,
        resolvesDefaultColorForPresentation: Bool = true
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: nsFont(for: style, theme: theme),
            .foregroundColor: nsColor(
                style.colorHex,
                theme: theme,
                resolvesDefaultColorForPresentation: resolvesDefaultColorForPresentation
            ),
        ]
        if let highlight = highlightColor(style.highlightHex) {
            attributes[.backgroundColor] = highlight
        }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let encoded = encode(style) { attributes[bodyStyleKey] = encoded }
        return attributes
    }

    /// O estilo de parágrafo de cada parágrafo: alinhamento, ritmo de linha e,
    /// quando for célula, o bloco de tabela.
    ///
    /// Escreve sobre o parágrafo **com** a quebra que o termina — ver
    /// `RichBody.span(of:in:)`. Sem a quebra, o parágrafo vazio ficaria sem
    /// estilo nenhum e o cursor mudaria de altura ao passar pela linha em
    /// branco: é exatamente o defeito que a Task AA mediu (28,50pt no meio,
    /// 18,00pt na última linha).
    private static func applyParagraphStyles(
        _ model: AttributedString,
        plain: String,
        into result: NSMutableAttributedString,
        theme: Theme
    ) {
        var tables: [Int: NSTextTable] = [:]
        // **Um bloco por célula, não por parágrafo.**
        //
        // O `NSTextTable` junta numa célula só os parágrafos que partilham a
        // **mesma instância** de `NSTextTableBlock`. Criar um bloco por
        // parágrafo faz com que uma célula de duas linhas — que é o que Enter
        // dentro dela produz — vire duas células lado a lado, e a linha inteira
        // recalcule as larguras. Medido: uma grade 2×2 com uma quebra dentro de
        // uma célula desenhava em **quatro** colunas (minX 9, 162, 239, 315) no
        // lugar de duas (9, 239). Era o "ao dar enter ele quebra a tabela toda".
        var blocks: [Blocks: NSTextTableBlock] = [:]

        for paragraph in RichBody.paragraphs(of: model) {
            let span = RichBody.span(of: paragraph, in: model)
            guard !span.isEmpty, let range = nsRange(span, in: model, plain: plain) else { continue }

            let style = NSMutableParagraphStyle()
            style.alignment = nsAlignment(RichBody.alignment(of: model, at: paragraph))
            let box = lineHeight(of: model, in: paragraph, scale: theme.typographyScale)
            style.minimumLineHeight = box
            style.maximumLineHeight = box
            style.lineSpacing = 0

            if let cell = RichBody.tableCell(of: model, at: paragraph) {
                let table = tables[cell.table] ?? {
                    let fresh = NSTextTable()
                    fresh.numberOfColumns = cell.columns
                    tables[cell.table] = fresh
                    return fresh
                }()
                let key = Blocks(table: cell.table, row: cell.row, column: cell.column)
                let shared = blocks[key] ?? {
                    let fresh = block(table: table, cell: cell, theme: theme)
                    blocks[key] = fresh
                    return fresh
                }()
                style.textBlocks = [shared]
            }

            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// A caixa de linha do parágrafo: o **maior** corpo dele vezes o ritmo.
    ///
    /// `NSParagraphStyle` é por parágrafo e não por trecho, então um parágrafo
    /// que mistura corpos precisa de um número só. O maior é o único que não
    /// corta glifo: pelo menor, um trecho de 32 dentro de uma linha de 15
    /// sairia decepado.
    static func lineHeight(
        of model: AttributedString,
        in paragraph: Range<AttributedString.Index>,
        scale: CGFloat = 1
    ) -> CGFloat {
        var largest = BodyStyle.defaultSize
        for run in model[paragraph].runs {
            largest = max(largest, RichBody.style(of: run.attributes).size)
        }
        if let terminator = model[RichBody.span(of: paragraph, in: model)].runs.last {
            largest = max(largest, RichBody.style(of: terminator.attributes).size)
        }
        return ComposerFormatting.lineHeight(for: largest * scale)
    }

    /// A identidade de uma célula no desenho. Dois parágrafos com esta mesma
    /// chave partilham um `NSTextTableBlock` e são uma célula só.
    private struct Blocks: Hashable {
        let table: Int
        let row: Int
        let column: Int
    }

    /// Protótipo `tblStyle` (linha 2143 do `.dc.html`): borda de 1px em
    /// `--line`, célula com `padding: 6px 8px`.
    private static func block(table: NSTextTable, cell: BodyTableCell, theme: Theme)
        -> NSTextTableBlock
    {
        let block = NSTextTableBlock(
            table: table,
            startingRow: cell.row, rowSpan: 1,
            startingColumn: cell.column, columnSpan: 1
        )
        block.setBorderColor(theme.line.nsColor)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.backgroundColor = theme.surface.nsColor
        return block
    }

    // MARK: - Desenho → modelo

    /// O modelo de volta, a partir do que o `NSTextView` tem agora.
    ///
    /// Só o que é **modelo** volta: `BodyStyle`, alinhamento, célula e link. A
    /// fonte, a cor e o estilo de parágrafo desenhados ficam para trás — eles
    /// são derivados, e guardá-los daria duas fontes de verdade.
    static func model(_ ns: NSAttributedString) -> AttributedString {
        let plain = ns.string
        var model = AttributedString(plain)
        guard !plain.isEmpty else { return model }

        let whole = NSRange(location: 0, length: ns.length)
        ns.enumerateAttributes(in: whole) { attributes, range, _ in
            guard let span = modelRange(range, in: model, plain: plain) else { return }
            if let encoded = attributes[bodyStyleKey] as? String, let style = decode(encoded) {
                model[span][BodyStyleAttribute.self] = style
            }
            if let link = attributes[.link] as? URL {
                model[span].link = link
            } else if let text = attributes[.link] as? String, let link = URL(string: text) {
                model[span].link = link
            }
        }

        // Duas passadas por causa de `BodyTableCell.rows`: o `NSTextTableBlock`
        // sabe em que linha ele está, e o `NSTextTable` sabe quantas colunas
        // tem — nenhum dos dois sabe quantas **linhas** a grade tem. O total só
        // existe depois de ver todas as células.
        var tables: [ObjectIdentifier: Int] = [:]
        var cells: [(span: Range<AttributedString.Index>, cell: BodyTableCell)] = []
        var rowsByTable: [Int: Int] = [:]

        for paragraph in RichBody.paragraphs(of: model) {
            let span = RichBody.span(of: paragraph, in: model)
            guard !span.isEmpty, let range = nsRange(span, in: model, plain: plain) else { continue }
            guard let style = ns.attribute(
                .paragraphStyle, at: range.location, effectiveRange: nil
            ) as? NSParagraphStyle else { continue }

            model[span][BodyAlignmentAttribute.self] = alignment(style.alignment)

            guard let block = style.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last
            else { continue }
            let key = ObjectIdentifier(block.table)
            let id = tables[key] ?? tables.count
            tables[key] = id
            rowsByTable[id] = max(rowsByTable[id] ?? 0, block.startingRow + 1)
            cells.append((span, BodyTableCell(
                table: id,
                row: block.startingRow, column: block.startingColumn,
                rows: 0, columns: max(1, block.table.numberOfColumns)
            )))
        }

        for (span, var cell) in cells {
            cell.rows = rowsByTable[cell.table] ?? 1
            model[span][BodyTableAttribute.self] = cell
        }
        return model
    }

    // MARK: - Faces e cores

    static func nsFont(for style: BodyStyle, theme: Theme) -> NSFont {
        GlyphMetrics.nsFont(
            ComposerFormatting.family(style.family, theme: theme),
            size: CGFloat(style.size),
            weight: style.bold ? .bold : .regular,
            italic: style.italic
        )
    }

    static func nsColor(
        _ hex: String,
        theme: Theme,
        resolvesDefaultColorForPresentation: Bool = true
    ) -> NSColor {
        ComposerFormatting.resolvedTextColor(
            hex,
            theme: theme,
            resolvesDefaultColorForPresentation: resolvesDefaultColorForPresentation
        ).nsColor
    }

    /// `transparent` é ausência de realce, não uma cor.
    static func highlightColor(_ hex: String) -> NSColor? {
        hex == BodyStyle.noHighlight ? nil : TokenColor(css: hex)?.nsColor
    }

    static func nsAlignment(_ alignment: BodyAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    static func alignment(_ alignment: NSTextAlignment) -> BodyAlignment {
        switch alignment {
        case .center: .center
        case .right: .right
        case .justified: .justified
        default: .left
        }
    }

    // MARK: - Intervalos

    /// O intervalo do modelo, em UTF-16, que é a régua do `NSAttributedString`.
    static func nsRange(
        _ range: Range<AttributedString.Index>, in model: AttributedString, plain: String
    ) -> NSRange? {
        guard let lower = String.Index(range.lowerBound, within: plain),
              let upper = String.Index(range.upperBound, within: plain)
        else { return nil }
        return NSRange(lower..<upper, in: plain)
    }

    static func modelRange(
        _ range: NSRange, in model: AttributedString, plain: String
    ) -> Range<AttributedString.Index>? {
        guard let span = Range(range, in: plain),
              let lower = AttributedString.Index(span.lowerBound, within: model),
              let upper = AttributedString.Index(span.upperBound, within: model)
        else { return nil }
        return lower..<upper
    }

    // MARK: - Serialização do estilo

    private static func encode(_ style: BodyStyle) -> String? {
        guard let data = try? JSONEncoder().encode(style) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ encoded: String) -> BodyStyle? {
        try? JSONDecoder().decode(BodyStyle.self, from: Data(encoded.utf8))
    }
}
