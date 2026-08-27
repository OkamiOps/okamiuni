import SwiftUI
import UNICore
import UNIDesign

/// A barra de formatação das telas 03 e 06 — a única parte que as duas
/// desenham exatamente igual.
///
/// Protótipo: `padding: 9px 18px; gap: 7px; background: var(--surface2);
/// border-bottom: 0.5px solid var(--line2)`, com os grupos na ordem fonte/corpo,
/// B I U S, cor e realce, listas, alinhamento, inserir e tabela.
///
/// Duas regras deste marco moram aqui:
///
/// 1. **A barra lê a seleção.** Ela recebe um `BodyReading` e acende o que o
///    intervalo de fato tem. Selecionar um trecho em negrito acende o B.
/// 2. **Controle mudo é defeito.** Cada botão ou age sobre a seleção, ou fica
///    `.disabled` — apagado e não clicável, com o motivo no `help`. Três ficam
///    desabilitados neste marco: justificar (o atributo de alinhamento do SDK só
///    tem esquerda, centro e direita), hyperlink (falta a folha que pede a URL)
///    e tabela (`AttributedString` não tem modelo de tabela e o `TextEditor` não
///    desenharia uma).
///
/// A barra **não** escreve texto: ela emite `ComposerCommand` e o composer
/// aplica. A contagem do rascunho saiu daqui de propósito — ela disputava a
/// faixa e fazia a barra quebrar em duas linhas na janela de resposta.
struct ComposerToolbar: View {
    @Environment(\.theme) private var theme

    let reading: BodyReading
    let perform: (ComposerCommand) -> Void

    @State private var openPanel: Panel?

    /// Só para verificação: permite renderizar a barra com um painel já aberto,
    /// sem clique. Sem isto não há como provar, fora da tela, que as amostras
    /// de cor aparecem inteiras em vez de ficarem debaixo do editor.
    init(reading: BodyReading, openPanel: Panel? = nil, perform: @escaping (ComposerCommand) -> Void) {
        self.reading = reading
        self.perform = perform
        _openPanel = State(initialValue: openPanel)
    }

    enum Panel { case color, highlight }

    var body: some View {
        // Protótipo: `flex-wrap: wrap; gap: 7px; row-gap: 7px`. A quebra existe
        // como rede de segurança para quem arrasta a janela abaixo dos 820 do
        // protótipo. Nos dois tamanhos de janela deste marco os sete grupos
        // somam ~695pt e cabem numa linha — o que os empurrava para a segunda
        // era o carimbo do rascunho, que saiu daqui.
        FlowLayout(spacing: 7, rowSpacing: 7) {
            fontGroup
            marksGroup
            colorGroup
            listGroup
            alignGroup
            insertGroup
            tableButton
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
    ///
    /// Os menus mostram o que a seleção tem. Quando ela mistura duas fontes,
    /// `reading.family` é nulo e o menu fica **sem** escolha marcada, em vez de
    /// mentir apontando a primeira.
    private var fontGroup: some View {
        HStack(spacing: 0) {
            Picker("Fonte", selection: Binding(
                get: { reading.family ?? "" },
                set: { perform(.family($0)) }
            )) {
                if reading.family == nil { Text("—").tag("") }
                ForEach(ComposerFormatting.families, id: \.value) { family in
                    Text(family.label).tag(family.value)
                }
            }
            .frame(width: 112)

            Rectangle()
                .fill(theme.btnLine.color)
                .frame(width: 0.5)

            Picker("Tamanho", selection: Binding(
                get: { reading.size ?? 0 },
                set: { perform(.size($0)) }
            )) {
                if reading.size == nil { Text("—").tag(0.0) }
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
        .fixedSize()
    }

    private var marksGroup: some View {
        SegmentedRow {
            SegmentButton(label: "B", title: "Negrito", on: reading.bold, weight: .bold) {
                perform(.bold)
            }
            SegmentButton(label: "I", title: "Itálico", on: reading.italic, italic: true) {
                perform(.italic)
            }
            SegmentButton(label: "U", title: "Sublinhado", on: reading.underline, underline: true) {
                perform(.underline)
            }
            SegmentButton(label: "S", title: "Riscado", on: reading.strike, strike: true) {
                perform(.strike)
            }
        }
    }

    private var colorGroup: some View {
        SegmentedRow {
            SegmentButton(
                label: "A", title: "Cor da fonte", on: openPanel == .color,
                bar: reading.colorHex.map { ComposerFormatting.color($0, theme: theme) } ?? theme.line.color
            ) {
                openPanel = openPanel == .color ? nil : .color
            }
            SegmentButton(
                label: "▨", title: "Realce", on: openPanel == .highlight,
                bar: reading.highlightHex.flatMap(ComposerFormatting.highlight) ?? theme.line.color
            ) {
                openPanel = openPanel == .highlight ? nil : .highlight
            }
        }
        .overlay(alignment: .topLeading) {
            if openPanel == .color {
                swatches(ComposerFormatting.textColors, selected: reading.colorHex) {
                    perform(.color($0))
                    openPanel = nil
                }
                .offset(y: 30)
            }
        }
        .overlay(alignment: .topTrailing) {
            if openPanel == .highlight {
                swatches(ComposerFormatting.highlights, selected: reading.highlightHex) {
                    perform(.highlight($0))
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
                          on: reading.list == .bulleted) {
                perform(.list(reading.list == .bulleted ? nil : .bulleted))
            }
            SegmentButton(label: "1.", title: "Lista numerada",
                          on: reading.list == .numbered) {
                perform(.list(reading.list == .numbered ? nil : .numbered))
            }
            SegmentButton(
                label: "⇤",
                title: reading.indent > 0
                    ? "Diminuir indentação"
                    : "Diminuir indentação — o parágrafo já está na margem",
                on: false,
                enabled: reading.indent > 0
            ) {
                perform(.indent(-1))
            }
            SegmentButton(label: "⇥", title: "Aumentar indentação", on: false) {
                perform(.indent(1))
            }
        }
    }

    private var alignGroup: some View {
        SegmentedRow {
            SegmentButton(label: "⇐", title: "Alinhar à esquerda",
                          on: reading.alignment == .left) { perform(.align(.left)) }
            SegmentButton(label: "⇔", title: "Centralizar",
                          on: reading.alignment == .center) { perform(.align(.center)) }
            SegmentButton(label: "⇒", title: "Alinhar à direita",
                          on: reading.alignment == .right) { perform(.align(.right)) }
            SegmentButton(
                label: "≡",
                title: "Justificar — indisponível: o alinhamento de parágrafo deste SDK só tem esquerda, centro e direita",
                on: false, enabled: false
            ) {}
        }
    }

    private var insertGroup: some View {
        SegmentedRow {
            SegmentButton(
                label: "↗",
                title: "Inserir hyperlink — indisponível neste marco: falta a folha que pede a URL",
                on: false, enabled: false
            ) {}
            SegmentButton(label: "⌫", title: "Limpar a formatação da seleção", on: false) {
                perform(.clearFormatting)
            }
        }
    }

    private var tableButton: some View {
        SoloToolButton(
            label: "⊞",
            title: "Inserir tabela — indisponível neste marco: AttributedString não tem modelo de tabela",
            on: false, enabled: false
        ) {}
    }

    private func swatches(
        _ list: [(hex: String, name: String)],
        selected: String?,
        pick: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(list, id: \.hex) { swatch in
                Button { pick(swatch.hex) } label: {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(ComposerFormatting.highlight(swatch.hex) ?? theme.surface.color)
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
    /// Falso deixa o botão **apagado e não clicável**. É a única alternativa
    /// aceita a agir sobre a seleção: controle mudo é defeito.
    var enabled = true
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
            .foregroundStyle(foreground)
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
        .disabled(!enabled)
        .help(title)
    }

    private var foreground: Color {
        if !enabled { return theme.ink4.color.opacity(0.55) }
        return on ? theme.accentInk.color : theme.ink2.color
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
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(foreground)
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
        .disabled(!enabled)
        .help(title)
    }

    private var foreground: Color {
        if !enabled { return theme.ink4.color.opacity(0.55) }
        return on ? theme.accentInk.color : theme.ink2.color
    }
}
