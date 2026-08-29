import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Abre a hierarquia renderizada para leitura, em vez de devolver um bitmap.
///
/// O cursor do `TextEditor` **não sai no desenho**: o `NSTextView` só o pinta
/// quando é o primeiro respondedor, e a janela do harness nunca recebe foco —
/// de propósito, porque dar foco a ela tomaria o teclado de quem está usando a
/// máquina. Então mede-se o cursor onde ele é decidido: o retângulo que o
/// próprio `NSTextView` devolve para um intervalo vazio.
///
/// A janela é a mesma do `Render`: sem borda, a −50.000pt, nunca trazida à
/// frente, fechada no fim.
@MainActor
enum EditorProbe {

    static func withHostedView<V: View>(
        _ view: V, size: CGSize, theme: Theme, _ body: (NSView) -> Void
    ) {
        let root = view
            .theme(theme)
            .environment(\.locale, Locale(identifier: "pt_BR"))
            .frame(width: size.width, height: size.height)

        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        defer { window.close() }
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        content.layoutSubtreeIfNeeded()
        body(content)
    }

    static func textView(in view: NSView, containing needle: String) -> NSTextView? {
        if let text = view as? NSTextView, text.string.contains(needle) { return text }
        for sub in view.subviews {
            if let found = textView(in: sub, containing: needle) { return found }
        }
        return nil
    }

    /// A altura do cursor em cada posição pedida, em pontos.
    static func caretHeights(_ text: NSTextView, at offsets: [Int]) -> [CGFloat] {
        offsets.map {
            text.firstRect(forCharacterRange: NSRange(location: $0, length: 0), actualRange: nil).height
        }
    }

    /// A distância de uma linha para a próxima, em pontos.
    static func baselineSteps(_ text: NSTextView) -> [CGFloat] {
        guard let manager = text.layoutManager, let container = text.textContainer else { return [] }
        manager.ensureLayout(for: container)
        var origins: [CGFloat] = []
        var glyph = 0
        while glyph < manager.numberOfGlyphs {
            var effective = NSRange()
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            origins.append(fragment.minY)
            glyph = effective.location + effective.length
        }
        return zip(origins.dropFirst(), origins).map { $0 - $1 }
    }
}

/// O defeito que este arquivo tranca: o cursor do editor media quase três vezes
/// a altura de maiúscula do texto, e media **coisas diferentes em lugares
/// diferentes da mesma coluna**.
///
/// A causa não era atributo de digitação com corpo grande — medido, o documento
/// do print é um `run` só, de 15pt, e o parágrafo vazio tem exatamente os
/// atributos das linhas escritas. Era `.lineSpacing`, que pendura espaço
/// **depois** de cada fragmento e **não** depois do último. Ver
/// `ComposerBodyFormatting`.
@Suite("Composer — a altura da linha e do cursor")
@MainActor
struct ComposerCaretTests {

    /// O corpo exato do print do dono do projeto: uma linha, um parágrafo
    /// vazio, outra linha. Semeado pelo modelo, sem tocar na janela.
    private func window() async throws -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let id = try #require(store.messages.first?.id)
        store.setReplyDraft(ReplyDraft(text: "ddadasd\n\ndsd"), for: id)
        return store
    }

    /// `line-height: 1.7` sobre o corpo de 15pt. A literal está travada: tirar
    /// o número do próprio `ComposerFormatting.lineHeight(for:)` daria um teste
    /// verdadeiro por construção, que passaria com qualquer altura.
    static let expectedBox: CGFloat = 25.5

    @Test("o cursor tem a mesma altura na coluna inteira")
    func caretIsUniform() async throws {
        let store = try await window()
        let id = try #require(store.messages.first?.id)
        var heights: [CGFloat] = []

        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .reply(messageID: id)),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { content in
            guard let editor = EditorProbe.textView(in: content, containing: "ddadasd") else { return }
            // 0 = primeira linha; 8 = o parágrafo vazio do print; 12 = fim da última.
            heights = EditorProbe.caretHeights(editor, at: [0, 8, 12])
        }

        #expect(heights.count == 3, "o editor não apareceu na hierarquia")
        #expect(
            heights.allSatisfy { abs($0 - Self.expectedBox) < 0.01 },
            "alturas do cursor: \(heights) — deviam ser \(Self.expectedBox) nas três posições"
        )
    }

    @Test("a coluna anda 1,7 vez o corpo, como o protótipo pede")
    func rhythmMatchesTheDesign() async throws {
        let store = try await window()
        let id = try #require(store.messages.first?.id)
        var steps: [CGFloat] = []

        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .reply(messageID: id)),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { content in
            guard let editor = EditorProbe.textView(in: content, containing: "ddadasd") else { return }
            steps = EditorProbe.baselineSteps(editor)
        }

        #expect(!steps.isEmpty, "o editor não apareceu na hierarquia")
        // Protótipo, linha 961 do `.dc.html`: `line-height: 1.7`.
        #expect(
            steps.allSatisfy { abs($0 - Self.expectedBox) < 0.01 },
            "passos entre linhas: \(steps) — deviam ser \(Self.expectedBox)"
        )
    }

    /// **A faixa do leitor tinha o mesmo defeito, e ninguém tinha medido.**
    ///
    /// Ela ficou no `.lineSpacing(0.65 × 15)` quando a janela saiu dele — o
    /// mesmo eixo errado, a mesma consequência. Medido no commit `2c351d1`, com
    /// exatamente este corpo: cursor de **25,50pt** no índice 0, **35,25pt** no
    /// parágrafo vazio e **11,50pt** no fim da última linha, com passo de
    /// 35,25pt — proporção 2,35 sobre o corpo, não os 1,7 do protótipo.
    ///
    /// Três alturas diferentes na mesma coluna, e ninguém tinha medido: a Task
    /// AA travou a janela e a faixa ficou para trás. É por isso que as duas
    /// passam a usar o mesmo editor.
    @Test("o cursor da faixa do leitor tem a mesma altura da janela")
    func bandCaretMatchesTheWindow() async throws {
        let store = try await window()
        let message = try #require(store.messages.first)
        var heights: [CGFloat] = []
        var steps: [CGFloat] = []

        EditorProbe.withHostedView(
            QuickReplyBand(store: store, message: message, onPromote: { _ in }, expandRequest: 1),
            size: CGSize(width: 720, height: 520), theme: .tinta
        ) { content in
            guard let editor = EditorProbe.textView(in: content, containing: "ddadasd") else { return }
            heights = EditorProbe.caretHeights(editor, at: [0, 8, 12])
            steps = EditorProbe.baselineSteps(editor)
        }

        #expect(heights.count == 3, "o editor da faixa não apareceu na hierarquia")
        #expect(
            heights.allSatisfy { abs($0 - Self.expectedBox) < 0.01 },
            "alturas do cursor na faixa: \(heights) — deviam ser \(Self.expectedBox)"
        )
        #expect(!steps.isEmpty)
        #expect(
            steps.allSatisfy { abs($0 - Self.expectedBox) < 0.01 },
            "passos na faixa: \(steps) — deviam ser \(Self.expectedBox)"
        )
    }
}

/// A altura de linha onde ela passou a morar: o `NSParagraphStyle` que o
/// `NSTextView` desenha.
///
/// Antes da Task AF a caixa vinha de `AttributeScopes.CoreTextAttributes`, por
/// uma `AttributedTextValueConstraint` do SwiftUI — e não podia vir do
/// `NSParagraphStyle` porque a restrição exige `Sendable` no valor do atributo
/// e a conformidade de `NSParagraphStyle` a `Sendable` é indisponível no macOS.
/// Sem `TextEditor` não há restrição, e a caixa volta para
/// `minimumLineHeight`/`maximumLineHeight`, que é onde a plataforma a põe.
///
/// **Os números não mudaram**: 25,50pt no corpo padrão, 54,40pt em corpo 32.
@Suite("Composer — a altura de linha no estilo de parágrafo")
struct ComposerLineHeightTests {

    /// Os estilos de parágrafo do corpo desenhado, um por trecho, na ordem — e
    /// o quanto do texto eles cobrem. A cobertura importa: um parágrafo vazio
    /// sem estilo nenhum não apareceria nesta lista e o teste passaria sem ver
    /// que a linha em branco ficou de fora, que é o defeito exato do print.
    private func paragraphStyles(_ ns: NSAttributedString) -> (styles: [NSParagraphStyle], covered: Int) {
        var styles: [NSParagraphStyle] = []
        var covered = 0
        ns.enumerateAttribute(
            .paragraphStyle, in: NSRange(location: 0, length: ns.length)
        ) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            styles.append(style)
            covered += range.length
        }
        return (styles, covered)
    }

    /// O caso do print: corpo semeado como texto puro, sem atributo nenhum.
    /// Nada roda antes dele — nem a barra, nem uma restrição. Quem tem de
    /// alcançá-lo é a própria projeção.
    @Test("a projeção alcança texto sem atributo nenhum, linha em branco inclusive")
    func projectionReachesPlainText() {
        let plain = AttributedString("semeado sem atributo\n\nsegunda linha")
        #expect(plain.runs.allSatisfy { $0.attributes[BodyStyleAttribute.self] == nil })

        let ns = ComposerTextKit.nsAttributed(plain, theme: .tinta)
        let (styles, covered) = paragraphStyles(ns)

        #expect(covered == ns.length, "\(covered) de \(ns.length) caracteres com estilo de parágrafo")
        #expect(!styles.isEmpty)
        #expect(
            styles.allSatisfy { $0.minimumLineHeight == 25.5 && $0.maximumLineHeight == 25.5 },
            "caixas: \(styles.map { ($0.minimumLineHeight, $0.maximumLineHeight) })"
        )
    }

    /// O erro que a primeira versão da restrição cometeu: ela devolvia a caixa
    /// do corpo padrão para todo trecho, e um pedaço de corpo 32 perdia a caixa
    /// de 54,40pt a cada tecla. A projeção nova lê o corpo do próprio trecho.
    @Test("um trecho de outro corpo mantém a caixa dele")
    func sizedRunKeepsItsBox() {
        var text = AttributedString("grande")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        ComposerEditor.perform(.size(32), on: &text, selection: &selection, theme: .tinta)

        let ns = ComposerTextKit.nsAttributed(text, theme: .tinta)
        let (styles, covered) = paragraphStyles(ns)

        #expect(covered == ns.length)
        // 32 × 1,7. Literal travada de propósito.
        #expect(
            styles.allSatisfy { $0.minimumLineHeight == 54.4 && $0.maximumLineHeight == 54.4 },
            "caixas: \(styles.map { $0.minimumLineHeight })"
        )
    }

    /// Altura de linha, alinhamento e tabela são **todos** `NSParagraphStyle`.
    /// Um estilo novo sobrescreve o anterior inteiro, então quem escreve tem de
    /// escrever os três juntos: se a altura chegasse depois, os botões
    /// `⇐ ⇔ ⇒ ≡` parariam de funcionar sem nenhum erro aparecer.
    @Test("a altura de linha não apaga o alinhamento")
    func lineHeightKeepsAlignment() {
        var text = AttributedString("uma linha\noutra linha")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        ComposerEditor.perform(.align(.center), on: &text, selection: &selection, theme: .tinta)

        #expect(ComposerEditor.reading(of: text, selection: selection).alignment == .center)

        let (styles, covered) = paragraphStyles(ComposerTextKit.nsAttributed(text, theme: .tinta))
        #expect(covered == NSAttributedString(string: String(text.characters)).length)
        #expect(styles.allSatisfy { $0.alignment == .center })
        #expect(styles.allSatisfy { $0.minimumLineHeight == 25.5 })
    }
}
