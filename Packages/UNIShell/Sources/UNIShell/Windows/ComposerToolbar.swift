import AppKit
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
    @Environment(\.displayScale) private var displayScale

    let reading: BodyReading
    let density: Density
    let perform: (ComposerCommand) -> Void
    /// A fronteira editorial é opcional enquanto a composição concreta não
    /// estiver instalada. Mesmo ausente, o botão continua na barra e explica
    /// por que não pode agir.
    let intelligence: ComposerIntelligenceGenerator?
    let intelligenceSourceMessage: Message?
    let intelligenceContext: ComposerIntelligenceContext?
    let applyIntelligence: (ComposerIntelligenceProposal) -> ComposerIntelligenceApplyResult

    @State private var openPanel: Panel?
    @State private var moreOpen: Bool
    @State private var intelligencePhase: ComposerIntelligencePanel.Phase = .ready
    @State private var intelligenceInstruction = ""
    @State private var intelligenceTask: Task<Void, Never>?
    /// A identidade desta barra perante o `NSColorPanel`, que é do app inteiro.
    /// Ver `FreeColorPanel`.
    @State private var colorPanelOwner = UUID()

    /// Só para verificação: permite renderizar a barra com um painel já aberto,
    /// sem clique. Sem isto não há como provar, fora da tela, que as amostras
    /// de cor aparecem inteiras em vez de ficarem debaixo do editor.
    /// `moreOpen` existe pelo mesmo motivo, para a variante compacta.
    init(
        reading: BodyReading,
        density: Density = .window,
        openPanel: Panel? = nil,
        moreOpen: Bool = false,
        intelligence: ComposerIntelligenceGenerator? = nil,
        intelligenceSourceMessage: Message? = nil,
        intelligenceContext: ComposerIntelligenceContext? = nil,
        applyIntelligence: @escaping (ComposerIntelligenceProposal) -> ComposerIntelligenceApplyResult = { _ in .sourceChanged },
        perform: @escaping (ComposerCommand) -> Void
    ) {
        self.reading = reading
        self.density = density
        self.perform = perform
        self.intelligence = intelligence
        self.intelligenceSourceMessage = intelligenceSourceMessage
        self.intelligenceContext = intelligenceContext
        self.applyIntelligence = applyIntelligence
        _openPanel = State(initialValue: openPanel)
        _moreOpen = State(initialValue: moreOpen)
    }

    enum Panel { case color, highlight, link, table, intelligence }

    /// Onde a barra está desenhada.
    ///
    /// **Não são duas barras.** São os mesmos grupos, os mesmos comandos e a
    /// mesma leitura da seleção, arrumados em dois formatos: a janela tem
    /// largura para os sete grupos numa linha; a faixa do leitor não tem, e o
    /// protótipo (tela 01, linha 1207) mostra ali só fonte, corpo, B I U S, cor
    /// e realce, com um `⋯` que abre a segunda linha com o resto.
    enum Density {
        /// Telas 03 e 06, `padding: 9px 18px`, tudo à mostra.
        case window
        /// Tela 01, dentro da faixa de resposta: `padding: 6px 10px`, com `⋯`.
        case band
    }

    var body: some View {
        Group {
            switch density {
            case .window: windowBar
            case .band: bandBar
            }
        }
        .onDisappear {
            intelligenceTask?.cancel()
        }
    }

    /// Protótipo: `flex-wrap: wrap; gap: 7px; row-gap: 7px`. A quebra existe
    /// como rede de segurança para quem arrasta a janela abaixo dos 820 do
    /// protótipo. Nos dois tamanhos de janela deste marco os sete grupos
    /// somam ~695pt e cabem numa linha — o que os empurrava para a segunda
    /// era o carimbo do rascunho, que saiu daqui.
    private var windowBar: some View {
        FlowLayout(spacing: 7, rowSpacing: 7) {
            fontGroup
            marksGroup
            colorGroup
            listGroup
            alignGroup
            linkButton
            clearFormattingButton
            tableButton
            intelligenceButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .bottom)
        .releasesColorPanel(colorPanelOwner)
    }

    /// Protótipo, tela 01: primeira linha `padding: 6px 10px; gap: 7px;
    /// border-bottom: 0.5px solid var(--line2)`; a segunda, quando o `⋯` está
    /// ligado, repete a medida com `background: var(--surface3)`.
    private var bandBar: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: 7, rowSpacing: 7) {
                fontGroup
                marksGroup
                colorGroup
                moreButton
                intelligenceButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline(theme.line2, edges: .bottom)
            // Os painéis de cor e realce descem por cima da segunda linha.
            .zIndex(2)

            if moreOpen {
                FlowLayout(spacing: 7, rowSpacing: 7) {
                    listGroup
                    alignGroup
                    linkButton
                    clearFormattingButton
                    tableButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface3.color)
                .hairline(theme.line2, edges: .bottom)
            }
        }
        .releasesColorPanel(colorPanelOwner)
    }

    /// Protótipo `moreBtnStyle`: `height: 26px; min-width: 30px`, com borda e
    /// fundo no acento enquanto a segunda linha está aberta.
    private var moreButton: some View {
        SoloToolButton(
            label: "⋯",
            title: moreOpen
                ? "Fechar listas, alinhamento, link e tabela"
                : "Listas, alinhamento, link, tabela",
            on: moreOpen
        ) {
            moreOpen.toggle()
        }
    }

    // MARK: - Grupos

    /// Protótipo: os dois `<select>` dentro de um `segWrap` só, separados por
    /// uma divisória vertical de 0.5px, com `width: 112px` e `width: 54px`.
    ///
    /// Os menus mostram o que a seleção tem. Quando ela mistura duas fontes,
    /// `reading.family` é nulo e o controle escreve "—", em vez de mentir
    /// apontando a primeira.
    ///
    /// **Deixou de ser `Picker`.** `pickerStyle(.menu)` é um `NSPopUpButton`: o
    /// controle fechado vinha com a moldura e a seta do macOS por cima do
    /// `segWrap`, o que o dono do projeto relatou como "dropdown usando o
    /// padrao do sistema em vez de custom". `ComposerSelect` desenha o controle
    /// do protótipo e abre um menu nosso. Os 62pt de largura do corpo eram
    /// folga para a seta do sistema; sem ela valem os 54 do protótipo.
    private var fontGroup: some View {
        HStack(spacing: 0) {
            ComposerSelect(
                title: "Fonte",
                selected: reading.family,
                width: 112,
                groups: ComposerFormatting.familyGroups,
                pick: { perform(.family($0)) }
            )

            Rectangle()
                .fill(theme.btnLine.color)
                .frame(width: Hairline.thickness(displayScale))

            ComposerSelect(
                title: "Tamanho",
                selected: reading.size.map { String(Int($0)) },
                width: 54,
                groups: ComposerFormatting.sizeGroups,
                // O menu guarda o corpo como texto para as duas listas terem a
                // mesma forma; a volta para número é aqui, e um valor que não
                // seja número cai no padrão em vez de zerar o corpo.
                pick: { perform(.size(Double($0) ?? BodyStyle.defaultSize)) }
            )
        }
        .frame(height: 26)
        .background(theme.btn.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
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
                swatches(
                    ComposerFormatting.textColors,
                    selected: reading.colorHex,
                    freeTitle: "Outra cor…",
                    pickFree: { perform(.color($0)) }
                ) {
                    perform(.color($0))
                    openPanel = nil
                }
                .offset(y: 30)
            }
        }
        .overlay(alignment: .topTrailing) {
            if openPanel == .highlight {
                swatches(
                    ComposerFormatting.highlights,
                    selected: reading.highlightHex,
                    freeTitle: "Outro realce…",
                    pickFree: { perform(.highlight($0)) }
                ) {
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
            // Vivo desde a Task AF. O que faltava não era o botão: era o
            // editor. `AttributedString.TextAlignment`, que o `TextEditor`
            // usava, tem três casos; `NSParagraphStyle.alignment` tem
            // `.justified`. Ver `BodyAlignment`.
            SegmentButton(label: "≡", title: "Justificar",
                          on: reading.alignment == .justified) { perform(.align(.justified)) }
        }
    }

    /// O protótipo põe `↗` e `⌫` na mesma cápsula (`segInsert`, linha 2119 do
    /// `.dc.html`). Aqui cada um ficou com a própria: quando o `↗` estava
    /// desabilitado, a cápsula com um item apagado e um vivo lia como grupo
    /// inteiro morto — foi o que o dono do projeto relatou sobre o `⌫`, que
    /// "parece desabilitado". Os dois estão vivos desde a Task AF, e a separação
    /// fica porque o `↗` abre painel e o `⌫` age direto: agrupá-los prometeria
    /// que são pares, e não são.
    private var linkButton: some View {
        SoloToolButton(
            label: "↗",
            title: reading.hasLink ? "Editar ou remover o hyperlink" : "Inserir hyperlink",
            on: openPanel == .link
        ) {
            openPanel = openPanel == .link ? nil : .link
        }
        // **`topTrailing`, não `topLeading`.** O `↗` fica a ~180pt da borda
        // direita da janela de 820, e um painel de 268 aberto para a direita
        // sai pela borda: medido no PNG, o botão "Aplicar" ficava decepado ao
        // meio. Abrir para a esquerda é o mesmo gesto do painel de tabela.
        .overlay(alignment: .topTrailing) {
            if openPanel == .link {
                ComposerLinkPanel(
                    current: reading.link,
                    hasSelection: reading.hasSelection,
                    canRemove: reading.hasLink,
                    apply: { url, label in
                        perform(.link(url: url, label: label))
                        openPanel = nil
                    },
                    cancel: { openPanel = nil }
                )
                .offset(y: 30)
            }
        }
        .zIndex(29)
    }

    private var clearFormattingButton: some View {
        SoloToolButton(
            // O protótipo promete "Limpar toda a formatação (inclui listas,
            // indentação e alinhamento)"; o comando deste marco zera estilo de
            // trecho e alinhamento, mas **não** desfaz lista nem recuo. A dica
            // diz o que o botão faz, não o que o protótipo prometeu.
            label: "⌫",
            title: "Limpar a formatação da seleção",
            on: false
        ) {
            perform(.clearFormatting)
        }
    }

    /// Vivo desde a Task AF. `AttributedString` não tem modelo de tabela — o
    /// `NSTextTable` do AppKit tem, e é ele que desenha a grade. Ver
    /// `ComposerTextKit`.
    private var tableButton: some View {
        SoloToolButton(
            label: "⊞",
            // A guarda é a **mesma** que o item do menu de contexto usa, vinda
            // de um lugar só: ver `ComposerTableCommand`.
            title: ComposerTableCommand.title(reading),
            on: openPanel == .table,
            enabled: ComposerTableCommand.isEnabled(reading)
        ) {
            openPanel = openPanel == .table ? nil : .table
        }
        .overlay(alignment: .topTrailing) {
            if openPanel == .table {
                ComposerTablePanel { rows, columns in
                    perform(.table(rows: rows, columns: columns))
                    openPanel = nil
                }
                .offset(y: 30)
            }
        }
        .zIndex(28)
    }

    /// O glifo é o SF Symbol real de Apple Intelligence. Ele está sempre
    /// presente nas duas densidades; só fica apagado quando não existe motor
    /// injetado (ou não há texto/contexto com que agir).
    private var intelligenceButton: some View {
        SoloToolButton(
            label: "",
            symbol: "apple.intelligence",
            title: intelligenceHelp,
            on: openPanel == .intelligence,
            enabled: intelligenceIsEnabled
        ) {
            openPanel = openPanel == .intelligence ? nil : .intelligence
        }
        .overlay(alignment: .topTrailing) {
            if openPanel == .intelligence {
                intelligencePanel(
                    context: intelligenceContext,
                    phase: intelligencePhase,
                    instruction: $intelligenceInstruction,
                    generate: generateIntelligence,
                    apply: applyIntelligenceProposal,
                    cancel: cancelIntelligence
                )
                .offset(y: 32)
            }
        }
        .zIndex(40)
    }

    private var intelligenceIsEnabled: Bool {
        guard intelligence != nil, let intelligenceContext else { return false }
        if !intelligenceContext.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return intelligenceSourceMessage != nil
    }

    private var intelligenceHelp: String {
        if intelligence == nil {
            return "Inteligência de escrita — indisponível: nenhum motor foi conectado"
        }
        if intelligenceContext?.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           intelligenceSourceMessage == nil {
            return "Inteligência de escrita — escreva ou selecione texto primeiro"
        }
        return "Inteligência de escrita"
    }

    private func generateIntelligence(
        _ action: ComposerIntelligenceAction,
        _ instruction: String?
    ) {
        guard let intelligence, let context = intelligenceContext else {
            intelligencePhase = .failure("A inteligência de escrita não está disponível nesta tela.")
            return
        }
        let hasText = !context.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard action == .createReply ? intelligenceSourceMessage != nil : hasText else {
            intelligencePhase = .failure("Escreva ou selecione texto antes de gerar uma prévia.")
            return
        }

        let request = ComposerIntelligenceRequest(
            action: action,
            target: context.target,
            source: context.source,
            instruction: instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceMessage: intelligenceSourceMessage
        )
        intelligenceTask?.cancel()
        intelligencePhase = .loading(action)
        intelligenceTask = Task { @MainActor in
            do {
                let proposal = try await ComposerIntelligence.generate(request, using: intelligence)
                guard !Task.isCancelled else { return }
                intelligencePhase = .preview(proposal)
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                intelligencePhase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                intelligencePhase = .failure(error.localizedDescription)
            }
        }
    }

    private func applyIntelligenceProposal(_ proposal: ComposerIntelligenceProposal) {
        let result = applyIntelligence(proposal)
        switch result {
        case .applied:
            intelligencePhase = .ready
            intelligenceInstruction = ""
            openPanel = nil
        case .sourceChanged, .emptyResult:
            intelligencePhase = .failure(result.errorMessage)
        }
    }

    private func cancelIntelligence() {
        intelligenceTask?.cancel()
        intelligenceTask = nil
        intelligencePhase = .ready
    }

    /// A paleta do protótipo mais o caminho livre.
    ///
    /// As seis amostras são as do design, com o mesmo desenho e a mesma ordem.
    /// O que vem depois da divisória é a parte pedida pelo dono do projeto: o
    /// item que abre o seletor do sistema, onde qualquer cor é escolhível. Ver
    /// `FreeColorPanel`.
    private func swatches(
        _ list: [(hex: String, name: String)],
        selected: String?,
        freeTitle: String,
        pickFree: @escaping (String) -> Void,
        pick: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            swatchRow(list, selected: selected, pick: pick)

            Rectangle()
                .fill(theme.line2.color)
                .frame(height: Hairline.thickness(displayScale))

            FreeColorRow(
                title: freeTitle,
                current: selected.flatMap { ComposerFormatting.highlight($0) },
                // Acende quando a cor que está valendo não é nenhuma das seis:
                // sem isso o painel abriria sem nada marcado e a pessoa não
                // saberia de onde veio a cor aplicada.
                isActive: ColorHex.isCustom(selected ?? "", among: list.map(\.hex))
            ) {
                FreeColorPanel.shared.present(
                    current: selected ?? BodyStyle.defaultColorHex,
                    owner: colorPanelOwner,
                    deliver: pickFree
                )
                openPanel = nil
            }
        }
        .padding(6)
        .frame(width: 6 * 22 + 5 * 4 + 12)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 10)
        .fixedSize()
    }

    /// A fileira das seis do protótipo, exatamente como estava.
    private func swatchRow(
        _ list: [(hex: String, name: String)],
        selected: String?,
        pick: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(list, id: \.hex) { swatch in
                let isSelected = selected == swatch.hex
                // Os 2pt do selecionado são medida de conteúdo — o realce da
                // escolha, que o protótipo engrossa de propósito. Só a borda em
                // repouso é hairline, e só ela segue a escala da tela.
                let border = isSelected ? 2 : Hairline.thickness(displayScale)
                Button { pick(swatch.hex) } label: {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(ComposerFormatting.highlight(swatch.hex) ?? theme.surface.color)
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(
                                    isSelected ? theme.accent.color : theme.line.color,
                                    lineWidth: border
                                )
                        }
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .help(swatch.name)
            }
        }
    }
}

/// Protótipo `segWrap`: `height: 26px; border-radius: var(--r2); border: 0.5px
/// solid var(--btn-line); background: var(--btn); overflow: hidden`, com as
/// divisórias entre os itens.
struct SegmentedRow<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: 26)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
            }
            .shadow(theme.btnShadow)
            .fixedSize()
    }
}

/// Um item do grupo. Protótipo: `min-width: 28px; padding: 0 5px; font-size: 12px`,
/// com a divisória de 0.5px à esquerda de todos menos do primeiro — aqui ela é
/// desenhada como borda `leading` de cada item, e o primeiro a esconde.
struct SegmentButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
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
    /// Força o anel de foco. Só para verificação fora da tela — ver `FocusRing`.
    var debugFocused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                OpticalGlyph(
                    label: label,
                    family: italic ? theme.serif : theme.sans,
                    size: 12,
                    weight: italic ? .regular : weight,
                    italic: italic
                )
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
                    .frame(width: Hairline.thickness(displayScale))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // O item do grupo não tem cápsula própria: a curva é do grupo inteiro,
        // que recorta as pontas. O anel acompanha — retângulo, recortado junto.
        .focusRing(in: Rectangle(), forced: debugFocused)
        .disabled(!enabled)
        .help(title)
    }

    private var foreground: Color {
        if !enabled { return theme.ink4.color.opacity(0.55) }
        return on ? theme.accentInk.color : theme.ink2.color
    }

}

/// Um glifo centrado pela **tinta**, não pela caixa de linha.
///
/// O `Text` cru ocupa da ascendente à descendente da fonte, e essa caixa não é
/// simétrica em volta do desenho: centrá-la na cápsula deixa o glifo abaixo do
/// meio. Medido nesta máquina, a 4 amostras por ponto: as letras assentavam
/// 0,125pt a 0,25pt abaixo da linha média da cápsula e os glifos de reserva
/// (`•—`, `≡`, `⇔`, `⇒`) entre 1,125pt e 1,375pt — 3,25pt de dispersão numa
/// fileira que devia ler como uma linha só. É o afundamento que o dono do
/// projeto relatou.
///
/// Aqui a caixa passa a ser a própria tinta, e a guia de alinhamento pendura o
/// centro dela no centro da caixa — **sem supor** onde o SwiftUI põe a linha de
/// base, porque `d[.firstTextBaseline]` responde isso. Depois da mudança todos
/// os glifos ficam a menos de 0,125pt do centro.
///
/// A altura da caixa vira a da tinta de propósito: é o que o protótipo faz com
/// `line-height: 1`, e é o que faz o par glifo + barrinha de cor ficar centrado
/// como coluna, com a folga de 1pt que o `gap: 1px` do protótipo pede (antes
/// eram 4pt, porque a descendente da caixa de linha entrava na conta).
///
/// Vale para **qualquer** glifo de barra, não só os do `SegmentButton`: quem
/// desenhar outra densidade da barra usa isto e já nasce alinhado, em vez de
/// repetir o defeito. Prefira o `init(label:family:size:weight:italic:)`, que
/// resolve as duas faces — a que o SwiftUI desenha e a que o CoreText mede — a
/// partir da mesma `FontFamily`. Pedir uma e medir outra é como o defeito volta.
struct OpticalGlyph: View {
    let label: String
    let font: Font
    /// A mesma face em `NSFont`, para medir.
    let metrics: NSFont

    init(label: String, font: Font, metrics: NSFont) {
        self.label = label
        self.font = font
        self.metrics = metrics
    }

    init(
        label: String,
        family: FontFamily,
        size: CGFloat,
        weight: Font.Weight = .regular,
        italic: Bool = false
    ) {
        self.label = label
        let base = family.font(size: size, weight: weight)
        self.font = italic ? base.italic() : base
        self.metrics = GlyphMetrics.nsFont(
            family, size: size, weight: weight.nsWeight, italic: italic
        )
    }

    var body: some View {
        let ink = GlyphMetrics.ink(of: label, font: metrics)
        Text(label)
            .font(font)
            .fixedSize()
            .alignmentGuide(VerticalAlignment.center) { dimension in
                guard !ink.isEmpty else { return dimension[VerticalAlignment.center] }
                return dimension[VerticalAlignment.firstTextBaseline] - ink.middle
            }
            .frame(height: ink.isEmpty ? nil : ink.height)
    }
}

extension Font.Weight {
    /// O peso equivalente em AppKit, para pedir a `NSFont` que vai ser medida.
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

/// O botão da tabela, que fica sozinho fora dos grupos.
/// Protótipo: `width: 30px; height: 26px`.
struct SoloToolButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let label: String
    var symbol: String? = nil
    let title: String
    let on: Bool
    var enabled = true
    /// Força o anel de foco. Só para verificação fora da tela — ver `FocusRing`.
    var debugFocused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    OpticalGlyph(label: label, family: theme.sans, size: 12)
                }
            }
                .foregroundStyle(foreground)
                .frame(width: 30, height: 26)
                .background(on ? theme.accentSoft.color : theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            on ? theme.accent.color : theme.btnLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .shadow(theme.btnShadow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, forced: debugFocused)
        .disabled(!enabled)
        .help(title)
    }

    private var foreground: Color {
        if !enabled { return theme.ink4.color.opacity(0.55) }
        return on ? theme.accentInk.color : theme.ink2.color
    }
}


extension View {
    /// Desliga a entrega do `NSColorPanel` quando esta barra sai de cena.
    ///
    /// O painel é do app inteiro e sobrevive à janela que o abriu. Sem isto,
    /// fechar o composer e mexer na roda depois mandaria cor para um rascunho
    /// que não existe mais.
    func releasesColorPanel(_ owner: UUID) -> some View {
        onDisappear { FreeColorPanel.shared.stop(owner: owner) }
    }
}
