import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Os três que estavam desabilitados desde a Task W — tabela, hyperlink e
/// justificado — e a ponte que os trouxe.
///
/// Nada aqui lança o app. O que existe é o modelo puro, a projeção em
/// `NSAttributedString`, e um `NSLayoutManager` medindo o desenho fora da tela.
/// Ver a REGRA ABSOLUTA em `task-AF-brief.md`.

// MARK: - Ferramenta de medida

/// Um `NSTextView` TextKit 1 montado igual ao do composer, sem janela, sem foco
/// e sem ponteiro. É o que permite perguntar ao AppKit **onde ele desenhou**
/// cada linha, em vez de olhar um PNG e achar bom.
@MainActor
enum LayoutProbe {
    struct Result {
        /// O retângulo de cada fragmento de linha, na ordem em que saem.
        var fragments: [CGRect]
        /// A largura de fato ocupada por cada linha — não a do fragmento, que
        /// no justificado é sempre a da coluna.
        var used: [CGFloat]
        var container: CGFloat
    }

    static func layout(_ ns: NSAttributedString, width: CGFloat) -> Result {
        let storage = NSTextStorage(attributedString: ns)
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        var fragments: [CGRect] = []
        var used: [CGFloat] = []
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var effective = NSRange()
            fragments.append(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective))
            used.append(layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).width)
            glyph = effective.location + effective.length
        }
        return Result(fragments: fragments, used: used, container: width)
    }
}

private func selection(_ text: AttributedString, _ from: Int, _ to: Int) -> AttributedTextSelection {
    let lower = text.characters.index(text.startIndex, offsetBy: from)
    let upper = text.characters.index(text.startIndex, offsetBy: to)
    return AttributedTextSelection(range: lower..<upper)
}

private func caret(_ text: AttributedString, _ at: Int) -> AttributedTextSelection {
    AttributedTextSelection(insertionPoint: text.characters.index(text.startIndex, offsetBy: at))
}

// MARK: - Tabela

@Suite("Composer — tabela")
@MainActor
struct ComposerTableTests {

    private func twoByTwo() -> AttributedString {
        var text = AttributedString("antes")
        var sel = caret(text, 5)
        ComposerEditor.perform(.table(rows: 2, columns: 2), on: &text, selection: &sel, theme: .tinta)
        return text
    }

    @Test("o modelo ganha quatro células com linha e coluna certas")
    func modelHasFourCells() {
        let text = twoByTwo()
        let cells = RichBody.paragraphs(of: text).compactMap { RichBody.tableCell(of: text, at: $0) }

        #expect(cells.count == 4, "células: \(cells)")
        #expect(cells.map { [$0.row, $0.column] } == [[0, 0], [0, 1], [1, 0], [1, 1]])
        #expect(cells.allSatisfy { $0.rows == 2 && $0.columns == 2 })
        // Uma tabela só: dois números diferentes aqui viram duas grades no
        // desenho, e a de baixo desce para uma linha própria.
        #expect(Set(cells.map(\.table)).count == 1)
        // E o texto que já estava lá continua sendo um parágrafo dele.
        #expect(String(text.characters).hasPrefix("antes\n"))
    }

    /// A prova de que existe **grade**, e não quatro parágrafos vazios: o
    /// `NSLayoutManager` põe duas células na mesma altura e duas na altura de
    /// baixo, com abscissas diferentes.
    @Test("o AppKit desenha duas colunas e duas linhas de verdade")
    func layoutIsAGrid() {
        let ns = ComposerTextKit.nsAttributed(twoByTwo(), theme: .tinta)
        let result = LayoutProbe.layout(ns, width: 600)

        // 1 parágrafo de texto + 4 células.
        #expect(result.fragments.count == 5, "fragmentos: \(result.fragments)")
        let cells = Array(result.fragments.dropFirst())
        let tops = cells.map(\.minY)
        let lefts = cells.map(\.minX)

        #expect(Set(tops).count == 2, "alturas das células: \(tops)")
        #expect(Set(lefts).count == 2, "abscissas das células: \(lefts)")
        // Primeira linha acima da segunda, primeira coluna à esquerda da segunda.
        #expect(tops[0] == tops[1] && tops[2] == tops[3] && tops[0] < tops[2])
        #expect(lefts[0] == lefts[2] && lefts[1] == lefts[3] && lefts[0] < lefts[1])
    }

    @Test("a tabela sobrevive à volta pelo NSTextStorage")
    func tableSurvivesRoundTrip() {
        let text = twoByTwo()
        let back = ComposerTextKit.model(ComposerTextKit.nsAttributed(text, theme: .tinta))
        let cells = RichBody.paragraphs(of: back).compactMap { RichBody.tableCell(of: back, at: $0) }

        #expect(String(back.characters) == String(text.characters))
        #expect(cells.map { [$0.row, $0.column, $0.rows, $0.columns] }
            == [[0, 0, 2, 2], [0, 1, 2, 2], [1, 0, 2, 2], [1, 1, 2, 2]])
    }

    @Test("duas tabelas seguidas não viram uma só")
    func twoTablesStaySeparate() {
        var text = AttributedString("")
        var sel = caret(text, 0)
        ComposerEditor.perform(.table(rows: 1, columns: 2), on: &text, selection: &sel, theme: .tinta)
        var tail = caret(text, text.characters.count)
        ComposerEditor.perform(.table(rows: 1, columns: 3), on: &text, selection: &tail, theme: .tinta)

        let cells = RichBody.paragraphs(of: text).compactMap { RichBody.tableCell(of: text, at: $0) }
        #expect(Set(cells.map(\.table)).count == 2, "tabelas: \(cells.map(\.table))")
        #expect(cells.filter { $0.columns == 2 }.count == 2)
        #expect(cells.filter { $0.columns == 3 }.count == 3)
    }

    @Test("a barra sabe quando o cursor já está dentro de uma tabela")
    func toolbarKnowsWeAreInside() {
        let text = twoByTwo()
        // O último parágrafo é o que veio depois da tabela.
        let inside = ComposerEditor.reading(of: text, selection: caret(text, 6))
        let outside = ComposerEditor.reading(of: text, selection: caret(text, 2))
        #expect(inside.inTable)
        #expect(outside.inTable == false)
    }
}

// MARK: - Hyperlink

@Suite("Composer — hyperlink")
@MainActor
struct ComposerLinkTests {

    @Test("o link pega só na seleção")
    func linkStaysScoped() {
        var text = AttributedString("Veja o contrato aqui.")
        var sel = selection(text, 6, 15)
        ComposerEditor.perform(
            .link(url: URL(string: "https://okamiuni.com.br/c")!, label: ""),
            on: &text, selection: &sel, theme: .tinta
        )

        #expect(String(text.characters) == "Veja o contrato aqui.")
        #expect(ComposerEditor.reading(of: text, selection: selection(text, 6, 15)).link
            == URL(string: "https://okamiuni.com.br/c"))
        #expect(ComposerEditor.reading(of: text, selection: selection(text, 0, 5)).hasLink == false)
        #expect(ComposerEditor.reading(of: text, selection: selection(text, 16, 21)).hasLink == false)
    }

    @Test("sem seleção, o texto entra junto com o link")
    func linkInsertsItsOwnText() {
        var text = AttributedString("Contrato: ")
        var sel = caret(text, 10)
        ComposerEditor.perform(
            .link(url: URL(string: "https://okamiuni.com.br")!, label: "abrir"),
            on: &text, selection: &sel, theme: .tinta
        )

        #expect(String(text.characters) == "Contrato: abrir")
        #expect(ComposerEditor.reading(of: text, selection: selection(text, 10, 15)).link
            == URL(string: "https://okamiuni.com.br"))
        // E o trecho novo nasce com estilo, senão a barra leria "sem fonte".
        #expect(RichBody.reading(
            of: text, over: [text.characters.index(text.startIndex, offsetBy: 10)..<text.endIndex]
        ).family == BodyStyle.defaultFamily)
    }

    @Test("remover o link não mexe no texto")
    func removingKeepsTheText() {
        var text = AttributedString("Veja o contrato aqui.")
        var sel = selection(text, 6, 15)
        ComposerEditor.perform(
            .link(url: URL(string: "https://okamiuni.com.br")!, label: ""),
            on: &text, selection: &sel, theme: .tinta
        )
        var again = selection(text, 6, 15)
        ComposerEditor.perform(.link(url: nil, label: ""), on: &text, selection: &again, theme: .tinta)

        #expect(String(text.characters) == "Veja o contrato aqui.")
        #expect(ComposerEditor.reading(of: text, selection: selection(text, 6, 15)).hasLink == false)
    }

    @Test("o link chega ao NSAttributedString e volta")
    func linkSurvivesRoundTrip() {
        var text = AttributedString("Veja o contrato aqui.")
        var sel = selection(text, 6, 15)
        let url = URL(string: "https://okamiuni.com.br/c")!
        ComposerEditor.perform(.link(url: url, label: ""), on: &text, selection: &sel, theme: .tinta)

        let ns = ComposerTextKit.nsAttributed(text, theme: .tinta)
        var found: [NSRange] = []
        ns.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            if value as? URL == url { found.append(range) }
        }
        #expect(found == [NSRange(location: 6, length: 9)], "faixas com link: \(found)")

        let back = ComposerTextKit.model(ns)
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 6, 15)).link == url)
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 0, 5)).hasLink == false)
    }

    /// Quem digita `okamiuni.com.br` espera um link. Sem esquema, `URL` monta um
    /// caminho relativo, que não abre nada e não avisa.
    @Test(
        "o endereço digitado ganha esquema quando falta",
        arguments: [
            ("okamiuni.com.br", "https://okamiuni.com.br"),
            ("https://ja.tem", "https://ja.tem"),
            ("marina@okamiuni.com.br", "mailto:marina@okamiuni.com.br"),
            ("mailto:ja@tem", "mailto:ja@tem"),
        ]
    )
    func normalisesTypedAddress(typed: String, expected: String) {
        #expect(ComposerLinkPanel.url(from: typed)?.absoluteString == expected)
    }

    @Test("endereço vazio não vira link")
    func emptyIsNotALink() {
        #expect(ComposerLinkPanel.url(from: "   ") == nil)
    }
}

// MARK: - Justificado

@Suite("Composer — justificado")
@MainActor
struct ComposerJustifyTests {

    private let paragraph = String(repeating: "palavra ", count: 20)

    @Test("o modelo guarda os quatro alinhamentos, justificado inclusive")
    func modelKeepsAllFour() {
        var text = AttributedString("um\ndois\ntres\nquatro")
        for (index, alignment) in BodyAlignment.allCases.enumerated() {
            let offsets = [0, 3, 8, 13]
            var sel = caret(text, offsets[index])
            ComposerEditor.perform(.align(alignment), on: &text, selection: &sel, theme: .tinta)
        }
        let read = RichBody.paragraphs(of: text).map { RichBody.alignment(of: text, at: $0) }
        #expect(read == [.left, .center, .right, .justified], "alinhamentos: \(read)")
    }

    /// A prova de que justificar **faz** alguma coisa: no justificado toda linha
    /// menos a última encosta nos dois lados da coluna; à esquerda, nenhuma.
    /// Comparar só o atributo passaria com o AppKit ignorando o pedido.
    @Test("as linhas justificadas encostam nos dois lados da coluna")
    func justifiedLinesAreFlush() {
        func widths(_ alignment: BodyAlignment) -> [CGFloat] {
            var text = AttributedString(paragraph)
            var sel = caret(text, 0)
            ComposerEditor.perform(.align(alignment), on: &text, selection: &sel, theme: .tinta)
            return LayoutProbe.layout(
                ComposerTextKit.nsAttributed(text, theme: .tinta), width: 300
            ).used
        }

        let justified = widths(.justified)
        let left = widths(.left)

        #expect(justified.count >= 3, "linhas: \(justified)")
        #expect(justified.count == left.count)
        // Todas menos a última chegam na coluna inteira.
        #expect(
            justified.dropLast().allSatisfy { abs($0 - 300) < 0.01 },
            "justificado: \(justified)"
        )
        // E à esquerda nenhuma chega — senão o teste passaria com o botão morto.
        #expect(left.allSatisfy { $0 < 300 }, "à esquerda: \(left)")
        #expect(justified != left)
    }

    @Test("justificado sobrevive à volta pelo NSTextStorage")
    func justifySurvivesRoundTrip() {
        var text = AttributedString(paragraph)
        var sel = caret(text, 0)
        ComposerEditor.perform(.align(.justified), on: &text, selection: &sel, theme: .tinta)

        let back = ComposerTextKit.model(ComposerTextKit.nsAttributed(text, theme: .tinta))
        #expect(ComposerEditor.reading(of: back, selection: caret(back, 0)).alignment == .justified)
    }
}

// MARK: - A ponte

@Suite("Composer — o modelo atravessa o NSTextStorage")
@MainActor
struct ComposerBridgeTests {

    /// O que a declaração de escopo fazia no `TextEditor`: impedir que o editor
    /// jogasse fora o `BodyStyleAttribute`, que é a única coisa que sabe dizer
    /// se um trecho está em negrito. Com o `NSTextView` quem garante isso é a
    /// ponte, e a garantia é a mesma.
    @Test("o BodyStyle sobrevive à ida e à volta")
    func bodyStyleSurvives() {
        var text = AttributedString("Marina, fechado quinta.")
        var sel = selection(text, 0, 6)
        ComposerEditor.perform(.bold, on: &text, selection: &sel, theme: .tinta)
        var second = selection(text, 8, 15)
        ComposerEditor.perform(.family("JetBrains Mono"), on: &text, selection: &second, theme: .tinta)
        var third = selection(text, 16, 22)
        ComposerEditor.perform(.size(24), on: &text, selection: &third, theme: .tinta)

        let back = ComposerTextKit.model(ComposerTextKit.nsAttributed(text, theme: .tinta))

        #expect(String(back.characters) == String(text.characters))
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 0, 6)).bold)
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 8, 15)).family
            == "JetBrains Mono")
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 16, 22)).size == 24)
        // E não vazou: o resto continua no padrão.
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 6, 8)).bold == false)
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 6, 8)).size == 15)
    }

    /// A prova de que a fonte de verdade é o `BodyStyle` e não a `NSFont`
    /// desenhada: o mesmo modelo em dois temas dá duas faces, e o modelo de
    /// volta continua dizendo "Newsreader" nos dois.
    @Test("a face desenhada é derivada, e a família continua sendo a do design")
    func drawnFontIsDerived() {
        let text = AttributedString("Marina")
        for theme in [Theme.tinta, Theme.all.first(where: \.isDark) ?? .tinta] {
            let back = ComposerTextKit.model(ComposerTextKit.nsAttributed(text, theme: theme))
            #expect(RichBody.reading(of: back, over: [back.startIndex..<back.endIndex]).family
                == BodyStyle.defaultFamily)
        }
    }

    /// O texto tem de sair caractere por caractere igual, senão a régua UTF-16
    /// do `NSAttributedString` e a de `AttributedString.Index` deixam de casar e
    /// a seleção pula sozinha no meio de um emoji.
    @Test("a régua bate mesmo com caractere fora do plano básico")
    func rulersAgreeOnAstralCharacters() {
        var text = AttributedString("bom 😀 dia")
        var sel = selection(text, 0, 3)
        ComposerEditor.perform(.bold, on: &text, selection: &sel, theme: .tinta)

        let ns = ComposerTextKit.nsAttributed(text, theme: .tinta)
        #expect(ns.string == String(text.characters))
        #expect(ns.length == String(text.characters).utf16.count)

        let back = ComposerTextKit.model(ns)
        #expect(String(back.characters) == String(text.characters))
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 0, 3)).bold)
        #expect(ComposerEditor.reading(of: back, selection: selection(back, 4, 5)).bold == false)
    }
}

// MARK: - Desenho da janela com os três

@Suite("Composer — os três desenhados na janela")
@MainActor
struct ComposerRichRenderTests {

    static let linkLabel = "Contrato assinado"

    /// O corpo do enunciado: uma tabela 2×2, um link e um parágrafo justificado.
    ///
    /// Os intervalos saem de **busca**, não de números cravados: um deslocamento
    /// à mão passa despercebido enquanto o texto não muda e vira um índice fora
    /// do fim assim que alguém corrige uma palavra.
    static func body() -> AttributedString {
        let plain = "Marina, segue o resumo do contrato para a reuniao de quinta, com os "
            + "numeros fechados e o prazo que combinamos na semana passada.\n"
            + "\(linkLabel)\n"
        var text = AttributedString(plain)

        func span(_ needle: String) -> AttributedTextSelection? {
            guard let found = plain.range(of: needle),
                  let lower = AttributedString.Index(found.lowerBound, within: text),
                  let upper = AttributedString.Index(found.upperBound, within: text)
            else { return nil }
            return AttributedTextSelection(range: lower..<upper)
        }

        var justify = span("Marina") ?? AttributedTextSelection(insertionPoint: text.startIndex)
        ComposerEditor.perform(.align(.justified), on: &text, selection: &justify, theme: .tinta)

        // Um trecho realçado. Não é enfeite: é a única coisa deste corpo que
        // dá para **contar** no PNG. Sem ele a renderização desta suíte não
        // tinha nada para afirmar além do tamanho que ela mesma pediu.
        if var marked = span("numeros fechados") {
            ComposerEditor.perform(
                .highlight("#FBEFA6"), on: &text, selection: &marked, theme: .tinta
            )
        }

        if var link = span(linkLabel) {
            ComposerEditor.perform(
                .link(url: URL(string: "https://okamiuni.com.br/contrato")!, label: ""),
                on: &text, selection: &link, theme: .tinta
            )
        }

        var table = AttributedTextSelection(insertionPoint: text.endIndex)
        ComposerEditor.perform(.table(rows: 2, columns: 2), on: &text, selection: &table, theme: .tinta)
        return text
    }

    /// Renderiza e **mede**: olhar o PNG e achar bom já deixou passar defeito
    /// neste projeto. O que se mede aqui é o que o desenho tem de mostrar —
    /// a grade em duas colunas, a linha justificada encostada nos dois lados e
    /// o link com a tinta do acento.
    @Test("a janela desenha tabela, link e justificado")
    func windowDrawsAllThree() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let id = try #require(store.messages.first?.id)
        store.setReplyDraft(ReplyDraft(to: [], body: Self.body()), for: id)

        var fragments: [CGRect] = []
        var linked: [NSRange] = []
        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .reply(messageID: id)),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { content in
            guard let editor = EditorProbe.textView(in: content, containing: "Contrato assinado"),
                  let layout = editor.layoutManager, let container = editor.textContainer,
                  let storage = editor.textStorage
            else { return }
            layout.ensureLayout(for: container)
            var glyph = 0
            while glyph < layout.numberOfGlyphs {
                var effective = NSRange()
                fragments.append(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective))
                glyph = effective.location + effective.length
            }
            storage.enumerateAttribute(
                .link, in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                if value != nil { linked.append(range) }
            }
        }

        // As quatro células desenham em duas alturas e duas abscissas.
        let cells = fragments.suffix(4)
        #expect(cells.count == 4, "fragmentos do editor: \(fragments)")
        #expect(Set(cells.map(\.minY)).count == 2, "alturas das células: \(cells.map(\.minY))")
        #expect(Set(cells.map(\.minX)).count == 2, "abscissas das células: \(cells.map(\.minX))")

        // O link está lá, e num trecho só.
        #expect(linked.count == 1, "faixas com link: \(linked)")
        #expect(linked.first?.length == Self.linkLabel.utf16.count)

        let rep = try #require(
            Render.snapshot(
                ComposerWindow(store: store, mode: .reply(messageID: id))
                    .environment(ThemeStore()),
                named: "composer-tabela-link-justificado",
                size: CGSize(width: 820, height: 660),
                theme: .tinta
            )
        )
        // A asserção era `rep.pixelsWide == 820`: o número da linha de cima.
        // O realce do corpo é o que prova que o estilo de trecho chegou ao
        // desenho — com `ComposerTextKit` forçado a `BodyStyle.default` este
        // bloco amarelo desaparece e o resto da janela fica igual.
        #expect(
            rep.pixels(matching: "#FBEFA6") > 100,
            "o realce do corpo não saiu no desenho da janela"
        )
    }

    /// A barra com o painel de tabela aberto e com o de link aberto — as duas
    /// portas do harness. Sem elas não há como provar, fora da tela, que os
    /// painéis aparecem **inteiros** em vez de ficarem decepados, que foi o
    /// defeito das amostras de cor.
    @Test("os painéis novos aparecem inteiros por cima do editor")
    func panelsClearTheEditor() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let id = try #require(store.messages.first?.id)

        // O mesmo corpo realçado da outra renderização: o painel abre **por
        // cima** do editor, e o que o teste tem de dizer é que o editor
        // continua desenhando o que desenhava, com o painel inteiro em cima.
        store.setReplyDraft(ReplyDraft(to: [], body: Self.body()), for: id)

        let semPainel = try #require(
            Render.snapshot(
                ComposerWindow(store: store, mode: .reply(messageID: id))
                    .environment(ThemeStore()),
                named: "composer-sem-painel",
                size: CGSize(width: 820, height: 660),
                theme: .tinta
            )
        )

        for (panel, name) in [
            (ComposerToolbar.Panel.table, "composer-painel-tabela"),
            (ComposerToolbar.Panel.link, "composer-painel-link"),
        ] {
            let rep = try #require(
                Render.snapshot(
                    ComposerWindow(store: store, mode: .reply(messageID: id), debugOpenPanel: panel)
                        .environment(ThemeStore()),
                    named: name,
                    size: CGSize(width: 820, height: 660),
                    theme: .tinta
                )
            )
            // A asserção era `rep.pixelsWide == 820` — o número da linha de
            // cima —, e com todo o estilo de trecho apagado ela continuava
            // verdadeira. O realce do corpo é o que cai junto com o estilo.
            #expect(
                rep.pixels(matching: "#FBEFA6") > 100,
                "\(name): o corpo perdeu o realce por trás do painel"
            )
            // E o painel de fato aparece: ele pinta uma área que a janela sem
            // painel não tem.
            #expect(
                rep.pixelsDiffering(from: semPainel) > 2_000,
                "\(name): o painel não mudou nada no desenho"
            )
            // Inteiro dentro da janela: a coluna da direita não pode ter sido
            // pintada pelo painel, que é o sintoma de painel decepado na borda.
            var tocaABorda = false
            for y in 0..<rep.pixelsHigh
            where rep.colorAt(x: rep.pixelsWide - 1, y: y)
                != semPainel.colorAt(x: rep.pixelsWide - 1, y: y) {
                tocaABorda = true
            }
            #expect(!tocaABorda, "\(name): o painel encosta na borda direita da janela")
        }
    }

    /// **A primeira versão deste painel saía pela borda direita da janela.**
    ///
    /// Ele nasceu ancorado em `topLeading`, como as amostras de cor — mas o `↗`
    /// fica a ~180pt da borda e o painel mede 268. No PNG o botão "Aplicar"
    /// aparecia decepado ao meio.
    ///
    /// A medida que pega isso: o "Aplicar" é o único bloco pintado no **acento**
    /// nessa faixa da janela, e um botão inteiro mede mais de 50px de largura.
    /// Cortado, ele media 12. Contar a caixa do painel não serviria — ela
    /// continua "existindo" fora da tela e a caixa não muda de tamanho.
    @Test("o botão do painel de link cabe dentro da janela")
    func linkPanelFitsTheWindow() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let id = try #require(store.messages.first?.id)

        let rep = try #require(
            Render.snapshot(
                ComposerWindow(
                    store: store, mode: .reply(messageID: id), debugOpenPanel: .link
                ).environment(ThemeStore()),
                named: "composer-painel-link",
                size: CGSize(width: 820, height: 660),
                theme: .tinta
            )
        )

        // A borda dos campos, em `btn-line`. Ela é o único traço dessa cor na
        // faixa do painel, e é ela que diz onde o campo **acaba**.
        //
        // Medir a cor de dentro do campo não serviria: em `tinta`, `btn` e
        // `surface` diferem 0,02, e uma tolerância que aceite ruído de desenho
        // aceita as duas como iguais. A armadilha está registrada em
        // `docs/decisoes-de-engenharia.md`.
        let line = Theme.tinta.btnLine
        func isFieldBorder(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return abs(c.redComponent - line.red) < 0.02
                && abs(c.greenComponent - line.green) < 0.02
                && abs(c.blueComponent - line.blue) < 0.02
                && c.alphaComponent > 0.9
        }

        // A faixa do painel: abaixo da barra de formatação, acima do histórico.
        var rightmost = -1
        var rows = 0
        for y in 170..<300 {
            var found = -1
            for x in 0..<rep.pixelsWide where isFieldBorder(x, y) { found = x }
            if found >= 0 { rows += 1; rightmost = max(rightmost, found) }
        }

        #expect(rows > 0, "nenhuma borda de campo encontrada na faixa do painel")
        // Um pixel de folga não basta: o painel tem borda **e** sombra, e
        // encostar já é sinal de que o desenho continua fora da janela.
        #expect(
            rightmost < rep.pixelsWide - 8,
            "a borda direita dos campos vai até x=\(rightmost) numa janela de \(rep.pixelsWide)"
        )
    }
}

// MARK: - Tema e o que o AppKit trouxe

@MainActor
@Observable
final class ThemeBox {
    var theme: Theme = .tinta
}

/// O editor com o tema vindo de fora, para o teste poder trocá-lo **depois** de
/// a vista já estar montada.
private struct ThemeFlipProbe: View {
    let box: ThemeBox
    @State var text: AttributedString
    @State private var selection = AttributedTextSelection()

    var body: some View {
        ComposerTextView(
            text: $text, selection: $selection, theme: box.theme,
            insets: CGSize(width: 10, height: 10)
        )
    }
}

@Suite("Composer — o editor e o tema")
@MainActor
struct ComposerEditorThemeTests {

    /// Não basta o editor nascer com o tema certo: trocar de tema com a janela
    /// aberta tem de repintar. O `NSTextStorage` guarda `NSColor` **resolvido**,
    /// não um token — quem não reescreve fica com as cores do tema antigo até a
    /// próxima tecla.
    ///
    /// O que se mede aqui é a borda da célula de tabela e a cor do cursor, e
    /// não a tinta do texto: a tinta do corpo é `BodyStyle.defaultColorHex`,
    /// uma literal do design que **não** muda com o tema — quem muda é o que o
    /// editor pinta a partir do `Theme`.
    @Test("trocar o tema com o editor montado repinta o editor")
    func themeChangeRepaints() throws {
        let dark = try #require(Theme.all.filter(\.isDark).first)
        let box = ThemeBox()

        var body = AttributedString("celula")
        var sel = AttributedTextSelection(insertionPoint: body.startIndex)
        ComposerEditor.perform(.table(rows: 1, columns: 1), on: &body, selection: &sel, theme: .tinta)

        var borders: [NSColor?] = []
        var carets: [NSColor?] = []

        EditorProbe.withHostedView(
            ThemeFlipProbe(box: box, text: body),
            size: CGSize(width: 360, height: 200), theme: .tinta
        ) { content in
            guard let editor = EditorProbe.textView(in: content, containing: "celula"),
                  let storage = editor.textStorage
            else { return }

            func sample() {
                carets.append(editor.insertionPointColor.usingColorSpace(.sRGB))
                var border: NSColor?
                storage.enumerateAttribute(
                    .paragraphStyle, in: NSRange(location: 0, length: storage.length)
                ) { value, _, _ in
                    guard let style = value as? NSParagraphStyle,
                          let block = style.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first
                    else { return }
                    border = block.borderColor(for: .minY)?.usingColorSpace(.sRGB)
                }
                borders.append(border)
            }

            sample()
            box.theme = dark
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            content.layoutSubtreeIfNeeded()
            sample()
        }

        #expect(borders.count == 2 && carets.count == 2, "não deu para amostrar o editor")
        let first = try #require(borders.first ?? nil)
        let second = try #require(borders.last ?? nil)
        #expect(first != second, "borda da célula antes \(first) e depois \(second)")
        // E a borda de depois é a `line` do tema escuro, não uma qualquer.
        let expected = try #require(dark.line.nsColor.usingColorSpace(.sRGB))
        #expect(abs(second.redComponent - expected.redComponent) < 0.01)
        #expect(carets[0] != carets[1], "cursor antes \(carets[0] as Any) e depois \(carets[1] as Any)")
    }

    /// O que o `TextEditor` não dava e o `NSTextView` dá. O dono do projeto vai
    /// notar estes antes de notar a tabela, então eles ficam travados por teste
    /// em vez de virarem uma frase no relatório.
    @Test("o editor traz desfazer, ortografia, link automático e menu de contexto")
    func appKitAffordancesAreOn() throws {
        var found: ComposerNSTextView?
        EditorProbe.withHostedView(
            BodyProbe(text: AttributedString("Marina, fechado quinta.")),
            size: CGSize(width: 420, height: 160), theme: .tinta
        ) { content in
            found = EditorProbe.textView(in: content, containing: "Marina") as? ComposerNSTextView
        }
        let editor = try #require(found, "o editor não apareceu na hierarquia")

        #expect(editor.allowsUndo)
        #expect(editor.isContinuousSpellCheckingEnabled)
        #expect(editor.isGrammarCheckingEnabled)
        #expect(editor.isAutomaticLinkDetectionEnabled)
        #expect(editor.isEditable)
        #expect(editor.isRichText)
        // O menu de contexto padrão do macOS — cortar, copiar, colar, procurar.
        #expect(editor.menu(for: NSEvent()) != nil || editor.menu != nil)

        // E o que fica **desligado** de propósito: substituição automática muda
        // o que a pessoa escreveu e tornaria a medida de texto não reprodutível.
        #expect(editor.isAutomaticQuoteSubstitutionEnabled == false)
        #expect(editor.isAutomaticDashSubstitutionEnabled == false)
        #expect(editor.isAutomaticTextReplacementEnabled == false)

        // TextKit 1: é o caminho que tem `NSTextTable`, e é o que responde às
        // perguntas de medida deste projeto.
        #expect(editor.layoutManager != nil)
        #expect(editor.textLayoutManager == nil)
    }
}

// MARK: - As teclas dentro da tabela

/// O editor sozinho, com um corpo dado, para as teclas serem exercitadas pelo
/// **mesmo caminho** que o teclado usa — `insertNewline(_:)`, `insertTab(_:)`,
/// `insertBacktab(_:)` — sem sintetizar evento nenhum e sem lançar o app.
struct TableKeyProbe: View {
    @Environment(\.theme) private var theme
    @State var text: AttributedString
    @State private var selection = AttributedTextSelection()

    var body: some View {
        ComposerTextView(
            text: $text, selection: $selection, theme: theme,
            insets: CGSize(width: 10, height: 10)
        )
        .background(theme.surface.color)
    }
}

@MainActor
extension EditorProbe {
    /// O `NSTextView` da hierarquia, sem precisar de texto para procurar: uma
    /// tabela recém-inserida é só quebras de linha.
    static func anyTextView(in view: NSView) -> ComposerNSTextView? {
        if let text = view as? ComposerNSTextView { return text }
        for sub in view.subviews {
            if let found = anyTextView(in: sub) { return found }
        }
        return nil
    }
}

@Suite("Composer — as teclas dentro da tabela")
@MainActor
struct ComposerTableKeysTests {

    /// Uma grade 2×2 com uma palavra em cada célula.
    static func filled() -> AttributedString {
        var text = AttributedString("")
        var sel = AttributedTextSelection(insertionPoint: text.startIndex)
        ComposerEditor.perform(.table(rows: 2, columns: 2), on: &text, selection: &sel, theme: .tinta)
        // Do fim para o começo: escrever na primeira célula moveria as outras.
        for (offset, word) in [(0, "um"), (1, "dois"), (2, "tres"), (3, "quatro")].reversed() {
            var piece = AttributedString(word)
            piece[BodyStyleAttribute.self] = .default
            text.insert(piece, at: text.characters.index(text.startIndex, offsetBy: offset))
        }
        return text
    }

    /// A grade **como ela é desenhada**: quantas colunas, quantas linhas, e
    /// onde cada fragmento caiu. É a régua que já pegou a tabela na primeira
    /// vez, e é a que pega esta.
    static func grid(_ model: AttributedString, width: CGFloat = 460)
        -> (columns: [CGFloat], rows: [CGFloat], fragments: [CGRect])
    {
        let result = LayoutProbe.layout(
            ComposerTextKit.nsAttributed(model, theme: .tinta), width: width
        )
        return (
            Set(result.fragments.map(\.minX)).sorted(),
            Set(result.fragments.map(\.minY)).sorted(),
            result.fragments
        )
    }

    /// Roda uma tecla no editor de verdade e devolve o modelo que sobrou.
    ///
    /// O cursor é posto **depois** da palavra pedida, ou **antes** dela com
    /// `caretBefore`. A espera entre pôr o cursor e apertar a tecla não é
    /// enfeite: é ela que deixa o SwiftUI reescrever os atributos de digitação,
    /// que é onde metade deste conserto mora.
    static func press(
        _ body: AttributedString, _ key: (ComposerNSTextView) -> Void,
        caretAfter needle: String? = nil, caretBefore before: String? = nil
    ) -> (model: AttributedString, caret: Int, plain: String) {
        var model = body
        var caret = -1
        var plain = ""
        EditorProbe.withHostedView(
            TableKeyProbe(text: body),
            size: CGSize(width: 480, height: 380), theme: .tinta
        ) { content in
            guard let view = EditorProbe.anyTextView(in: content) else { return }
            let text = view.string as NSString
            let at = text.range(of: needle ?? before ?? "")
            guard at.location != NSNotFound else { return }
            let location = needle != nil ? at.location + at.length : at.location
            view.setSelectedRange(NSRange(location: location, length: 0))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))

            key(view)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))

            caret = view.selectedRange().location
            plain = view.string
            if let storage = view.textStorage { model = ComposerTextKit.model(storage) }
        }
        return (model, caret, plain)
    }

    // MARK: Enter

    /// **O defeito que o dono relatou usando.** Medido antes do conserto, com
    /// esta grade e uma quebra no meio de "dois": o redesenho saía com
    /// **quatro** colunas — `minX` em 9, 162, 239 e 315 — no lugar de duas
    /// (9 e 239). A linha de cima virava três células e o `NSTextTable`
    /// recalculava as larguras. A causa era um `NSTextTableBlock` novo por
    /// parágrafo; o `NSTextTable` só junta numa célula os parágrafos que
    /// partilham a **mesma instância** de bloco.
    @Test("Enter dentro de uma célula não desmonta a grade")
    func enterKeepsTheGrid() {
        let before = Self.grid(Self.filled())
        #expect(before.columns.count == 2, "colunas antes: \(before.columns)")
        #expect(before.rows.count == 2, "linhas antes: \(before.rows)")

        let after = Self.press(Self.filled(), { $0.insertNewline(nil) }, caretAfter: "do")

        #expect(after.plain == "um\ndo\nis\ntres\nquatro\n", "texto: \(after.plain.debugDescription)")

        let grid = Self.grid(after.model)
        // Continuam **duas** colunas. É esta a asserção que falhava.
        #expect(grid.columns.count == 2, "colunas depois: \(grid.columns)")
        #expect(grid.columns == before.columns, "as colunas mudaram de lugar: \(grid.columns)")

        // E a célula editada ficou mais alta: a segunda linha da grade desceu.
        #expect(grid.rows.count == 3, "alturas depois: \(grid.rows)")
        let rowTwoBefore = before.rows[1]
        let rowTwoAfter = grid.rows[2]
        #expect(
            rowTwoAfter > rowTwoBefore,
            "a linha de baixo devia descer: \(rowTwoBefore) → \(rowTwoAfter)"
        )
        // As duas células da linha de baixo continuam lado a lado, na mesma altura.
        let bottom = grid.fragments.filter { $0.minY == rowTwoAfter }
        #expect(Set(bottom.map(\.minX)).count == 2, "linha de baixo: \(bottom.map(\.minX))")
    }

    @Test("Enter dentro da célula mantém os dois parágrafos na mesma célula")
    func enterStaysInTheSameCell() {
        let after = Self.press(Self.filled(), { $0.insertNewline(nil) }, caretAfter: "do")
        let cells = RichBody.paragraphs(of: after.model).map {
            RichBody.tableCell(of: after.model, at: $0)
        }
        // 6 parágrafos: quatro células, uma delas partida em duas, mais o
        // parágrafo que vem depois da tabela.
        #expect(cells.map { $0.map { [$0.row, $0.column] } ?? [] }
            == [[0, 0], [0, 1], [0, 1], [1, 0], [1, 1], []], "células: \(cells)")
    }

    /// **O caso que separa os dois consertos.** Com o cursor no meio da
    /// célula, o `NSTextStorage` já herdava o bloco do parágrafo ao arrumar os
    /// atributos, e só o bloco partilhado bastava. No **começo** da célula não:
    /// medido sem os guardas, o parágrafo novo saía sem célula nenhuma e ia
    /// para a largura toda da coluna — `[0,0], [], [0,1], …` com as colunas em
    /// `0, 9, 239` no lugar de `9, 239`. A tabela partida em duas, que é
    /// exatamente o relato.
    @Test("Enter no começo da célula também fica dentro dela")
    func enterAtCellStartStaysInside() {
        let after = Self.press(Self.filled(), { $0.insertNewline(nil) }, caretBefore: "dois")

        let cells = RichBody.paragraphs(of: after.model).map {
            RichBody.tableCell(of: after.model, at: $0)
        }
        #expect(cells.map { $0.map { [$0.row, $0.column] } ?? [] }
            == [[0, 0], [0, 1], [0, 1], [1, 0], [1, 1], []], "células: \(cells)")

        let grid = Self.grid(after.model)
        #expect(grid.columns.count == 2, "colunas: \(grid.columns)")
        // Nada encostado na margem: um parágrafo fora da tabela desenharia em 0.
        #expect(grid.columns.allSatisfy { $0 > 0 }, "colunas: \(grid.columns)")
    }

    @Test("fora da tabela, Enter continua sendo Enter")
    func enterOutsideIsUnchanged() {
        let after = Self.press(
            AttributedString("primeira linha\nsegunda"), { $0.insertNewline(nil) },
            caretAfter: "primeira"
        )
        #expect(after.plain == "primeira\n linha\nsegunda", "texto: \(after.plain.debugDescription)")
        #expect(RichBody.paragraphs(of: after.model).count == 3)
    }

    // MARK: Tab

    @Test("Tab vai para a próxima célula")
    func tabMovesForward() {
        let after = Self.press(Self.filled(), { $0.insertTab(nil) }, caretAfter: "um")
        #expect(after.plain == "um\ndois\ntres\nquatro\n", "Tab não pode escrever tabulação")
        // "um\n" ocupa 0..2; a célula (0,1) começa em 3.
        #expect(after.caret == 3, "cursor em \(after.caret), esperado 3 (começo de \"dois\")")
    }

    @Test("Shift-Tab volta para a célula anterior")
    func backtabMovesBack() {
        let after = Self.press(Self.filled(), { $0.insertBacktab(nil) }, caretAfter: "dois")
        #expect(after.plain == "um\ndois\ntres\nquatro\n")
        #expect(after.caret == 0, "cursor em \(after.caret), esperado 0 (começo de \"um\")")
    }

    @Test("Shift-Tab na primeira célula não sai da tabela nem escreve nada")
    func backtabOnFirstCellHoldsStill() {
        let after = Self.press(Self.filled(), { $0.insertBacktab(nil) }, caretAfter: "um")
        #expect(after.plain == "um\ndois\ntres\nquatro\n")
        #expect(after.caret == 2, "cursor em \(after.caret), esperado 2 (onde estava)")
    }

    /// Tab na última célula cria linha — é o que Mail, Outlook e Gmail fazem, e
    /// é como se cresce uma tabela sem voltar ao botão da barra.
    @Test("Tab na última célula cria uma linha nova")
    func tabOnLastCellAddsARow() {
        let after = Self.press(Self.filled(), { $0.insertTab(nil) }, caretAfter: "quatro")

        #expect(after.plain == "um\ndois\ntres\nquatro\n\n\n", "texto: \(after.plain.debugDescription)")

        let cells = RichBody.paragraphs(of: after.model).compactMap {
            RichBody.tableCell(of: after.model, at: $0)
        }
        #expect(cells.count == 6, "células: \(cells.map { [$0.row, $0.column] })")
        #expect(cells.map { [$0.row, $0.column] }
            == [[0, 0], [0, 1], [1, 0], [1, 1], [2, 0], [2, 1]])
        // E **todas** passam a saber que a grade tem três linhas.
        #expect(cells.allSatisfy { $0.rows == 3 }, "rows: \(cells.map(\.rows))")
        #expect(Set(cells.map(\.table)).count == 1)

        // O cursor foi para a primeira célula nova.
        #expect(after.caret == 20, "cursor em \(after.caret)")

        // E o desenho tem três linhas de duas colunas.
        let grid = Self.grid(after.model)
        #expect(grid.columns.count == 2, "colunas: \(grid.columns)")
        #expect(grid.rows.count == 3, "linhas: \(grid.rows)")
    }

    @Test("fora da tabela, Tab continua sendo Tab")
    func tabOutsideIsUnchanged() {
        let after = Self.press(
            AttributedString("sem tabela"), { $0.insertTab(nil) }, caretAfter: "sem"
        )
        #expect(after.plain.contains("\t"), "texto: \(after.plain.debugDescription)")
    }

    /// O PNG para olhar: a grade depois de um Enter numa célula e de um Tab que
    /// criou a terceira linha. A medida está nos testes acima; isto é para o
    /// olho conferir que a borda fecha e que a célula alta não empurra a
    /// vizinha.
    @Test("a grade editada desenha inteira")
    func editedGridRenders() throws {
        var body = Self.press(Self.filled(), { $0.insertNewline(nil) }, caretAfter: "do").model
        RichBody.appendTableRow(&body, table: 0)

        let rep = try #require(
            Render.snapshot(
                BodyProbe(text: body).environment(ThemeStore()),
                named: "composer-tabela-editada",
                size: CGSize(width: 520, height: 260),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 520)

        let grid = Self.grid(body, width: 520 - 34)
        #expect(grid.columns.count == 2, "colunas: \(grid.columns)")
        #expect(grid.rows.count == 4, "linhas: \(grid.rows)")
    }
}
