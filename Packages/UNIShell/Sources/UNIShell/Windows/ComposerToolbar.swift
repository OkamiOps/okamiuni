import SwiftUI
import UNIDesign

/// A barra de formatação das telas 03 e 06 — a única parte que as duas
/// desenham exatamente igual.
///
/// Protótipo: `padding: 9px 18px; gap: 7px; row-gap: 7px; flex-wrap: wrap;
/// background: var(--surface2); border-bottom: 0.5px solid var(--line2)`, com
/// os grupos na ordem fonte/corpo, B I U S, cor e realce, listas, alinhamento,
/// inserir e tabela. A tela 03 ainda pendura a contagem do rascunho à direita.
struct ComposerToolbar: View {
    @Environment(\.theme) private var theme
    @Binding var formatting: ComposerFormatting
    /// A tela 03 escreve "3 palavras · não salvo" no fim da barra; a 06 não.
    var trailingNote: String?

    @State private var openPanel: Panel?
    @State private var tableHover: (rows: Int, columns: Int)?

    private enum Panel { case color, highlight, table }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Protótipo: `flex-wrap: wrap; gap: 7px; row-gap: 7px`. Sem a
            // quebra, os sete grupos somam mais que os 820 da janela e o
            // conteúdo inteiro transborda para os dois lados.
            FlowLayout(spacing: 7, rowSpacing: 7) {
                fontGroup
                marksGroup
                colorGroup
                listGroup
                alignGroup
                insertGroup
                tableButton
            }

            if let trailingNote {
                Spacer(minLength: 8)
                Text(trailingNote)
                    .capsLabel()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .bottom)
    }

    // MARK: - Grupos

    /// Protótipo: os dois `<select>` dentro de um `segWrap` só, separados por
    /// uma divisória vertical de 0.5px.
    private var fontGroup: some View {
        HStack(spacing: 0) {
            Picker("Fonte", selection: $formatting.fontName) {
                ForEach(ComposerFormatting.families, id: \.value) { family in
                    Text(family.label).tag(family.value)
                }
            }
            .frame(width: 112)

            Rectangle()
                .fill(theme.btnLine.color)
                .frame(width: 0.5)

            Picker("Tamanho", selection: $formatting.size) {
                ForEach(ComposerFormatting.sizes, id: \.self) { size in
                    Text(String(Int(size))).tag(size)
                }
            }
            .frame(width: 62)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .font(theme.sans.font(size: 11.5, weight: .medium))
        .frame(height: 26)
        .background(theme.btn.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.btnLine.color, lineWidth: 0.5)
        }
        .shadow(theme.btnShadow)
    }

    private var marksGroup: some View {
        SegmentedRow {
            SegmentButton(label: "B", title: "Negrito", on: formatting.bold, weight: .bold) {
                formatting.bold.toggle()
            }
            SegmentButton(label: "I", title: "Itálico", on: formatting.italic, italic: true) {
                formatting.italic.toggle()
            }
            SegmentButton(label: "U", title: "Sublinhado", on: formatting.underline, underline: true) {
                formatting.underline.toggle()
            }
            SegmentButton(label: "S", title: "Riscado", on: formatting.strike, strike: true) {
                formatting.strike.toggle()
            }
        }
    }

    private var colorGroup: some View {
        SegmentedRow {
            SegmentButton(
                label: "A", title: "Cor da fonte", on: openPanel == .color,
                bar: TokenColor(css: formatting.colorHex)?.color ?? theme.line.color
            ) {
                openPanel = openPanel == .color ? nil : .color
            }
            SegmentButton(
                label: "▨", title: "Realce", on: openPanel == .highlight,
                bar: formatting.highlightHex == "transparent"
                    ? theme.line.color
                    : (TokenColor(css: formatting.highlightHex)?.color ?? theme.line.color)
            ) {
                openPanel = openPanel == .highlight ? nil : .highlight
            }
        }
        .overlay(alignment: .topLeading) {
            if openPanel == .color {
                swatches(ComposerFormatting.textColors, selected: formatting.colorHex) {
                    formatting.colorHex = $0
                    openPanel = nil
                }
                .offset(y: 30)
            }
        }
        .overlay(alignment: .topTrailing) {
            if openPanel == .highlight {
                swatches(ComposerFormatting.highlights, selected: formatting.highlightHex) {
                    formatting.highlightHex = $0
                    openPanel = nil
                }
                .offset(y: 30)
            }
        }
        .zIndex(30)
    }

    private var listGroup: some View {
        SegmentedRow {
            SegmentButton(label: "•—", title: "Lista com marcadores",
                          on: formatting.list == .bulleted) {
                formatting.list = formatting.list == .bulleted ? nil : .bulleted
            }
            SegmentButton(label: "1.", title: "Lista numerada",
                          on: formatting.list == .numbered) {
                formatting.list = formatting.list == .numbered ? nil : .numbered
            }
            SegmentButton(label: "⇤", title: "Diminuir indentação", on: false) {}
            SegmentButton(label: "⇥", title: "Aumentar indentação", on: false) {}
        }
    }

    private var alignGroup: some View {
        SegmentedRow {
            SegmentButton(label: "⇐", title: "Alinhar à esquerda",
                          on: formatting.align == .leading) { formatting.align = .leading }
            SegmentButton(label: "⇔", title: "Centralizar",
                          on: formatting.align == .center) { formatting.align = .center }
            SegmentButton(label: "⇒", title: "Alinhar à direita",
                          on: formatting.align == .trailing) { formatting.align = .trailing }
            SegmentButton(label: "≡", title: "Justificar", on: false) {}
        }
    }

    private var insertGroup: some View {
        SegmentedRow {
            SegmentButton(label: "↗", title: "Inserir hyperlink na seleção", on: false) {}
            SegmentButton(label: "⌫", title: "Limpar toda a formatação", on: false) {
                formatting = ComposerFormatting()
            }
        }
    }

    private var tableButton: some View {
        SoloToolButton(label: "⊞", title: "Inserir tabela", on: openPanel == .table) {
            openPanel = openPanel == .table ? nil : .table
            tableHover = nil
        }
        .overlay(alignment: .topLeading) {
            if openPanel == .table { tablePicker.offset(y: 30) }
        }
        .zIndex(30)
    }

    /// Protótipo: grade de 8 colunas × 6 linhas, células de 14pt com 3 de folga,
    /// e o rótulo "N × M" embaixo.
    private var tablePicker: some View {
        VStack(spacing: 7) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(1...6, id: \.self) { row in
                    GridRow {
                        ForEach(1...8, id: \.self) { column in
                            let on = row <= (tableHover?.rows ?? 0) && column <= (tableHover?.columns ?? 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(on ? theme.accent.color : theme.surface3.color)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(on ? theme.accent.color : theme.line.color, lineWidth: 0.5)
                                }
                                .frame(width: 14, height: 14)
                                .onHover { inside in
                                    if inside { tableHover = (row, column) }
                                }
                                .onTapGesture { openPanel = nil }
                        }
                    }
                }
            }
            Text(tableHover.map { "\($0.rows) × \($0.columns)" } ?? "Tabela")
                .font(theme.mono.font(size: 9.5, weight: .medium))
                .tracking(theme.capsTracking(at: 9.5))
                .textCase(.uppercase)
                .foregroundStyle(theme.ink3.color)
        }
        .padding(8)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 15, x: 0, y: 14)
    }

    private func swatches(
        _ list: [(hex: String, name: String)],
        selected: String,
        pick: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(list, id: \.hex) { swatch in
                Button { pick(swatch.hex) } label: {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(swatch.hex == "transparent"
                              ? theme.surface.color
                              : (TokenColor(css: swatch.hex)?.color ?? theme.surface.color))
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(
                                    selected == swatch.hex ? theme.accent.color : theme.line.color,
                                    lineWidth: selected == swatch.hex ? 2 : 0.5
                                )
                        }
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(swatch.name)
            }
        }
        .padding(6)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 10)
        .fixedSize()
    }
}

/// Protótipo `segWrap`: `height: 26px; border-radius: var(--r2); border: 0.5px
/// solid var(--btn-line); background: var(--btn); overflow: hidden`, com as
/// divisórias entre os itens.
private struct SegmentedRow<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: 26)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.btnLine.color, lineWidth: 0.5)
            }
            .shadow(theme.btnShadow)
            .fixedSize()
    }
}

/// Um item do grupo. Protótipo: `min-width: 28px; padding: 0 5px; font-size: 12px`,
/// com a divisória de 0.5px à esquerda de todos menos do primeiro — aqui ela é
/// desenhada como borda `leading` de cada item, e o primeiro a esconde.
private struct SegmentButton: View {
    @Environment(\.theme) private var theme
    let label: String
    var title: String = ""
    let on: Bool
    var weight: Font.Weight = .regular
    var italic = false
    var underline = false
    var strike = false
    /// A barrinha de cor sob o "A" e o "▨". Protótipo: 13×3, raio 1.
    var bar: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label)
                    .font(labelFont)
                    .italic(italic)
                    .underline(underline)
                    .strikethrough(strike)
                if let bar {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(bar)
                        .frame(width: 13, height: 3)
                }
            }
            .foregroundStyle(on ? theme.accentInk.color : theme.ink2.color)
            // Protótipo: `min-width: 28px; padding: 0 5px`. A folga é por dentro
            // do mínimo — somá-la por fora dava 38pt por item e fazia a barra
            // inteira quebrar numa segunda linha que o protótipo não tem.
            .padding(.horizontal, 5)
            .frame(minWidth: 28, maxHeight: .infinity)
            .background(on ? theme.accentSoft.color : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(theme.btnLine.color)
                    .frame(width: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var labelFont: Font {
        italic ? theme.serif.font(size: 12) : theme.sans.font(size: 12, weight: weight)
    }
}

/// O botão da tabela, que fica sozinho fora dos grupos.
/// Protótipo: `width: 30px; height: 26px`.
private struct SoloToolButton: View {
    @Environment(\.theme) private var theme
    let label: String
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(on ? theme.accentInk.color : theme.ink2.color)
                .frame(width: 30, height: 26)
                .background(on ? theme.accentSoft.color : theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(on ? theme.accent.color : theme.btnLine.color, lineWidth: 0.5)
                }
                .shadow(theme.btnShadow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
