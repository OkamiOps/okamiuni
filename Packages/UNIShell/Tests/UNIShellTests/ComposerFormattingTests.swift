import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Testes do composer formatado. Nada aqui lança o app: `ComposerEditor` é um
/// `enum` sem `View` em volta, e o layout se mede com `NSHostingView.fittingSize`
/// e com o harness de renderização fora da tela.

private func index(_ text: AttributedString, _ offset: Int) -> AttributedString.Index {
    text.characters.index(text.characters.startIndex, offsetBy: offset)
}

private func selection(_ text: AttributedString, _ from: Int, _ to: Int) -> AttributedTextSelection {
    AttributedTextSelection(range: index(text, from)..<index(text, to))
}

private func caret(_ text: AttributedString, _ at: Int) -> AttributedTextSelection {
    AttributedTextSelection(insertionPoint: index(text, at))
}

private func style(_ text: AttributedString, at offset: Int) -> BodyStyle {
    let lower = index(text, offset)
    let upper = text.characters.index(after: lower)
    return text[lower..<upper].runs.first.map { RichBody.style(of: $0.attributes) } ?? .default
}

private func font(_ text: AttributedString, at offset: Int) -> Font? {
    let lower = index(text, offset)
    let upper = text.characters.index(after: lower)
    return text[lower..<upper].runs.first?.attributes.font
}

@Suite("Composer — a barra age sobre a seleção, não sobre o corpo inteiro")
struct ComposerEditorSelectionTests {

    @Test("negrito na seleção deixa o resto do corpo em paz")
    func boldOnlyTheSelection() {
        var text = AttributedString("Marina fechado quinta")
        var sel = selection(text, 7, 14)

        ComposerEditor.perform(.bold, on: &text, selection: &sel, theme: .tinta)

        #expect(style(text, at: 0).bold == false)
        #expect(style(text, at: 7).bold)
        #expect(style(text, at: 13).bold)
        #expect(style(text, at: 14).bold == false)
        #expect(String(text.characters) == "Marina fechado quinta")
    }

    @Test("a fonte desenhada difere dentro e fora da seleção")
    func projectedFontDiffers() {
        var text = AttributedString("Marina fechado quinta")
        var sel = selection(text, 7, 14)

        ComposerEditor.perform(.size(32), on: &text, selection: &sel, theme: .tinta)

        #expect(style(text, at: 10).size == 32)
        #expect(style(text, at: 0).size == 15)
        // A projeção é o que o SwiftUI desenha. Se ela não acompanhasse o
        // modelo, a barra "funcionaria" e a tela continuaria igual.
        #expect(font(text, at: 10) != nil)
        #expect(font(text, at: 10) != font(text, at: 0))
    }

    @Test("família, cor e realce também param na fronteira da seleção")
    func familyColorHighlightStopAtTheEdge() {
        var text = AttributedString("um dois tres")
        var sel = selection(text, 3, 7)

        ComposerEditor.perform(.family("Georgia"), on: &text, selection: &sel, theme: .tinta)
        ComposerEditor.perform(.color("#8E2020"), on: &text, selection: &sel, theme: .tinta)
        ComposerEditor.perform(.highlight("#FBEFA6"), on: &text, selection: &sel, theme: .tinta)

        #expect(style(text, at: 4).family == "Georgia")
        #expect(style(text, at: 4).colorHex == "#8E2020")
        #expect(style(text, at: 4).highlightHex == "#FBEFA6")

        #expect(style(text, at: 0).family == "Newsreader")
        #expect(style(text, at: 0).colorHex == "#241F18")
        #expect(style(text, at: 0).highlightHex == "transparent")
        #expect(style(text, at: 9).colorHex == "#241F18")
    }

    @Test("o realce apagado some do texto em vez de virar cor de fundo")
    func clearingHighlightRemovesTheAttribute() {
        var text = AttributedString("um dois")
        var sel = selection(text, 0, 7)

        ComposerEditor.perform(.highlight("#FBEFA6"), on: &text, selection: &sel, theme: .tinta)
        #expect(text.runs.first?.attributes.backgroundColor != nil)

        ComposerEditor.perform(.highlight("transparent"), on: &text, selection: &sel, theme: .tinta)
        #expect(text.runs.allSatisfy { $0.attributes.backgroundColor == nil })
    }

    /// Escrever um atributo parte os runs, e nesta máquina isso fazia
    /// `AttributedTextSelection.indices(in:)` degradar para um ponto de
    /// inserção. Sem `transform(updating:)`, o segundo clique da barra caía nos
    /// atributos de digitação: a seleção do usuário sumia entre um botão e o
    /// seguinte, e nada mudava na tela.
    @Test("dois comandos seguidos pegam na mesma seleção")
    func selectionSurvivesTheFirstCommand() {
        var text = AttributedString("um dois tres")
        var sel = selection(text, 3, 7)

        ComposerEditor.perform(.bold, on: &text, selection: &sel, theme: .tinta)
        ComposerEditor.perform(.italic, on: &text, selection: &sel, theme: .tinta)
        ComposerEditor.perform(.color("#8E2020"), on: &text, selection: &sel, theme: .tinta)

        #expect(style(text, at: 4).bold)
        #expect(style(text, at: 4).italic)
        #expect(style(text, at: 4).colorHex == "#8E2020")
        #expect(style(text, at: 0).italic == false)
        #expect(style(text, at: 9).colorHex == "#241F18")
    }

    @Test("limpar formatação limpa a seleção e preserva o resto")
    func clearOnlyTheSelection() {
        var text = AttributedString("um dois tres")
        var all = selection(text, 0, 12)
        ComposerEditor.perform(.bold, on: &text, selection: &all, theme: .tinta)

        var middle = selection(text, 3, 7)
        ComposerEditor.perform(.clearFormatting, on: &text, selection: &middle, theme: .tinta)

        #expect(style(text, at: 0).bold)
        #expect(style(text, at: 4).bold == false)
        #expect(style(text, at: 9).bold)
    }
}

@Suite("Composer — sem seleção, vale para o que vier em seguida")
struct ComposerEditorTypingTests {

    @Test("negrito com o cursor solto não mexe no texto")
    func caretBoldLeavesTextAlone() {
        var text = AttributedString("Marina")
        var sel = caret(text, 3)

        ComposerEditor.perform(.bold, on: &text, selection: &sel, theme: .tinta)

        #expect(String(text.characters) == "Marina")
        #expect((0..<6).allSatisfy { style(text, at: $0).bold == false })
    }

    @Test("negrito com o cursor solto entra nos atributos de digitação")
    func caretBoldLandsOnTypingAttributes() {
        var text = AttributedString("Marina")
        var sel = caret(text, 3)

        ComposerEditor.perform(.bold, on: &text, selection: &sel, theme: .tinta)

        let typing = sel.typingAttributes(in: text)
        #expect(typing[BodyStyleAttribute.self]?.bold == true)
        #expect(typing.font != nil)
    }

    @Test("a barra mostra o que a digitação vai receber")
    func toolbarReadsTypingAttributes() {
        var text = AttributedString("Marina")
        var sel = caret(text, 3)

        ComposerEditor.perform(.size(24), on: &text, selection: &sel, theme: .tinta)

        let reading = ComposerEditor.reading(of: text, selection: sel)
        #expect(reading.hasSelection == false)
        #expect(reading.size == 24)
    }
}

@Suite("Composer — a barra lê o estado da seleção")
struct ComposerToolbarReadingTests {

    @Test("selecionar um trecho em negrito acende o B")
    func selectingBoldLightsB() {
        var text = AttributedString("Marina fechado quinta")
        var sel = selection(text, 7, 14)
        ComposerEditor.perform(.bold, on: &text, selection: &sel, theme: .tinta)

        #expect(ComposerEditor.reading(of: text, selection: selection(text, 7, 14)).bold)
        #expect(ComposerEditor.reading(of: text, selection: selection(text, 0, 6)).bold == false)
        // Seleção que mistura não pode acender: seria mentira.
        #expect(ComposerEditor.reading(of: text, selection: selection(text, 0, 21)).bold == false)
    }

    @Test("seleção que mistura fontes deixa o menu sem escolha marcada")
    func mixedFamilyLeavesThePickerBlank() {
        var text = AttributedString("um dois")
        var sel = selection(text, 0, 2)
        ComposerEditor.perform(.family("Georgia"), on: &text, selection: &sel, theme: .tinta)

        #expect(ComposerEditor.reading(of: text, selection: selection(text, 0, 2)).family == "Georgia")
        #expect(ComposerEditor.reading(of: text, selection: selection(text, 0, 7)).family == nil)
    }

    @Test("o recuo lido desabilita o ⇤ na margem e o libera depois de recuar")
    func outdentAvailability() {
        var text = AttributedString("um")
        var sel = caret(text, 0)
        #expect(ComposerEditor.reading(of: text, selection: sel).indent == 0)

        ComposerEditor.perform(.indent(1), on: &text, selection: &sel, theme: .tinta)
        #expect(String(text.characters) == "    um")
        #expect(ComposerEditor.reading(of: text, selection: caret(text, 0)).indent == 1)
    }

    @Test("lista e alinhamento voltam na leitura")
    func listAndAlignmentRead() {
        var text = AttributedString("um\ndois")
        var sel = caret(text, 0)

        ComposerEditor.perform(.list(.bulleted), on: &text, selection: &sel, theme: .tinta)
        #expect(String(text.characters) == "• um\ndois")
        #expect(ComposerEditor.reading(of: text, selection: caret(text, 0)).list == .bulleted)
        #expect(ComposerEditor.reading(of: text, selection: caret(text, 6)).list == nil)

        var second = caret(text, 6)
        ComposerEditor.perform(.align(.center), on: &text, selection: &second, theme: .tinta)
        #expect(ComposerEditor.reading(of: text, selection: caret(text, 6)).alignment == .center)
        #expect(ComposerEditor.reading(of: text, selection: caret(text, 0)).alignment == .left)
    }
}

@Suite("Composer — a barra cabe numa linha")
@MainActor
struct ComposerToolbarLayoutTests {

    /// A altura que a faixa mede na largura dada. Sem janela visível: um
    /// `NSHostingView` solto responde `fittingSize` só com layout.
    private func toolbarHeight(width: CGFloat) -> CGFloat {
        let toolbar = ComposerToolbar(reading: .blank, perform: { _ in })
            .theme(.tinta)
            .frame(width: width)
        let host = NSHostingView(rootView: toolbar)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Uma linha: 26 de botão + 9 de folga em cima e embaixo + o fio de 0.5.
    /// Duas linhas passariam dos 70.
    private let oneRowCeiling: CGFloat = 46

    @Test("na janela de resposta (820) a barra fica em uma linha")
    func replyWindowOneRow() {
        #expect(toolbarHeight(width: 820) <= oneRowCeiling)
    }

    @Test("na janela de mensagem nova (820) a barra fica em uma linha")
    func newWindowOneRow() {
        #expect(toolbarHeight(width: 820) <= oneRowCeiling)
    }

    @Test("em larguras maiores continua em uma linha")
    func widerStaysOneRow() {
        #expect(toolbarHeight(width: 1100) <= oneRowCeiling)
        #expect(toolbarHeight(width: 1440) <= oneRowCeiling)
    }

    /// Sem isto o teto acima passaria mesmo se a medida estivesse presa num
    /// valor fixo. Numa largura estreita a faixa **tem** de crescer.
    @Test("estreitando de verdade, a faixa cresce — a medida não é constante")
    func narrowActuallyWraps() {
        #expect(toolbarHeight(width: 420) > oneRowCeiling)
    }
}

@Suite("Composer — o escopo de atributos do corpo")
struct ComposerScopeTests {

    /// `constrain` é o que o `TextEditor` aplica ao texto a cada edição:
    /// atributo fora do escopo declarado é **descartado**. Este teste prova que
    /// `attributedTextFormattingDefinition(UNIComposerAttributes.self)` no
    /// editor é carga, não enfeite.
    @Test("o escopo do composer preserva o BodyStyle que o editor descartaria")
    func scopeKeepsBodyStyle() {
        var text = AttributedString("Marina")
        var sel = selection(text, 0, 6)
        ComposerEditor.perform(.bold, on: &text, selection: &sel, theme: .tinta)
        #expect(style(text, at: 0).bold)

        var kept = text
        AttributedTextFormatting.EmptyDefinition<AttributeScopes.UNIComposerAttributes>()
            .constrain(&kept)
        #expect(kept.runs.first?.attributes[BodyStyleAttribute.self]?.bold == true)

        // E sem o escopo do composer o atributo some — que era o destino do
        // modelo antes desta declaração existir.
        var dropped = text
        AttributedTextFormatting.EmptyDefinition<AttributeScopes.SwiftUIAttributes>()
            .constrain(&dropped)
        #expect(dropped.runs.first?.attributes[BodyStyleAttribute.self] == nil)
    }
}

/// O mesmo editor do composer, com um corpo já formatado, para o harness poder
/// desenhar texto rico sem a janela inteira em volta — e sem lançar o app.
private struct BodyProbe: View {
    @Environment(\.theme) private var theme
    @State var text: AttributedString
    @State private var selection = AttributedTextSelection()

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .attributedTextFormattingDefinition(AttributeScopes.UNIComposerAttributes.self)
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .font(theme.serif.font(size: BodyStyle.defaultSize))
            .lineSpacing(BodyStyle.defaultSize * 0.7)
            .foregroundStyle(theme.ink.color)
            .padding(17)
            .background(theme.surface.color)
    }
}

@Suite("Composer — renderização das duas janelas")
@MainActor
struct ComposerRenderTests {

    /// Um corpo em que cada linha recebeu um comando diferente da barra, sobre
    /// um trecho diferente. Se a formatação ainda pegasse no corpo inteiro,
    /// como antes da Task W, o PNG sairia todo igual.
    @Test("um corpo com formatação por trecho desenha cada trecho do seu jeito")
    func formattedBodyRenders() throws {
        var text = AttributedString(
            "Marina, fechado quinta.\nO SLA fica em horario comercial.\nQualquer coisa me chame."
        )
        func mark(_ from: Int, _ to: Int, _ command: ComposerCommand) {
            var sel = selection(text, from, to)
            ComposerEditor.perform(command, on: &text, selection: &sel, theme: .tinta)
        }
        mark(0, 6, .bold)
        mark(8, 15, .color("#8E2020"))
        mark(16, 22, .highlight("#FBEFA6"))
        mark(24, 30, .size(24))
        mark(31, 55, .italic)
        mark(31, 55, .underline)
        mark(57, 81, .family("JetBrains Mono"))
        mark(57, 81, .strike)
        mark(57, 57, .align(.right))

        let rep = try #require(
            Render.snapshot(
                BodyProbe(text: text).environment(ThemeStore()),
                named: "composer-corpo-formatado",
                size: CGSize(width: 620, height: 200),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 620)
    }

    @Test("as duas janelas renderizam no tamanho do protótipo")
    func bothWindowsRender() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let reply = try #require(
            Render.snapshot(
                ComposerWindow(store: store, mode: .reply(messageID: "m1"))
                    .environment(ThemeStore()),
                named: "composer-03-resposta",
                size: CGSize(width: 820, height: 660),
                theme: .tinta
            )
        )
        #expect(reply.pixelsWide == 820)

        let new = try #require(
            Render.snapshot(
                ComposerWindow(store: store, mode: .new(accountID: nil))
                    .environment(ThemeStore()),
                named: "composer-06-nova",
                size: CGSize(width: 820, height: 620),
                theme: .tinta
            )
        )
        #expect(new.pixelsHigh == 620)
    }
}
