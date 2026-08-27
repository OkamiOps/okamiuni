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
}

@Suite("Composer — a altura de linha como atributo")
struct ComposerLineHeightTests {

    /// O caso do print: corpo semeado como texto puro, sem atributo nenhum, e o
    /// primeiro caractere digitado numa janela nova. A restrição é o único
    /// caminho que alcança os dois — `project(_:into:theme:)` só roda quando a
    /// barra manda um comando.
    @Test("a restrição alcança texto sem atributo nenhum")
    func constraintReachesPlainText() {
        var plain = AttributedString("semeado sem atributo\n\nsegunda linha")
        #expect(plain.runs.allSatisfy {
            $0.attributes[AttributeScopes.CoreTextAttributes.LineHeightAttribute.self] == nil
        })

        ComposerBodyFormatting().constrain(&plain)

        #expect(plain.runs.allSatisfy {
            $0.attributes[AttributeScopes.CoreTextAttributes.LineHeightAttribute.self]
                == .exact(points: 25.5)
        }, "runs: \(plain.runs.map { $0.attributes[AttributeScopes.CoreTextAttributes.LineHeightAttribute.self] })")
    }

    /// O erro que a primeira versão desta restrição cometeu: ela recalculava a
    /// altura a cada edição e, como o contêiner que ela recebe **não** enxerga o
    /// `BodyStyle` do trecho, devolvia a caixa do corpo padrão. Um trecho de
    /// corpo 32 perdia a caixa de 54,40pt e voltava para a de 25,50pt.
    @Test("a restrição não derruba a caixa de um trecho de outro corpo")
    func constraintDoesNotClobberPerRunSize() {
        var text = AttributedString("grande")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        ComposerEditor.perform(.size(32), on: &text, selection: &selection, theme: .tinta)

        ComposerBodyFormatting().constrain(&text)

        // 32 × 1,7. Literal travada de propósito.
        #expect(text.runs.allSatisfy {
            $0.attributes[AttributeScopes.CoreTextAttributes.LineHeightAttribute.self]
                == .exact(points: 54.4)
        }, "runs: \(text.runs.map { $0.attributes[AttributeScopes.CoreTextAttributes.LineHeightAttribute.self] })")
    }

    /// Altura de linha e alinhamento são os dois atributos de parágrafo do
    /// corpo, e desaguam no mesmo `NSParagraphStyle` quando o editor converte.
    /// Se um apagasse o outro, os botões `⇐ ⇔ ⇒` parariam de funcionar sem
    /// nenhum erro aparecer.
    @Test("a altura de linha não apaga o alinhamento")
    func lineHeightKeepsAlignment() {
        var text = AttributedString("uma linha\noutra linha")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        ComposerEditor.perform(.align(.center), on: &text, selection: &selection, theme: .tinta)
        ComposerBodyFormatting().constrain(&text)

        #expect(ComposerEditor.reading(of: text, selection: selection).alignment == .center)
        #expect(text.runs.allSatisfy {
            $0.attributes[AttributeScopes.CoreTextAttributes.LineHeightAttribute.self] != nil
        })
    }
}
