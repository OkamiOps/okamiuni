import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// O editor do corpo — **um `NSTextView`**, que é o que Mail e Outlook usam por
/// baixo.
///
/// ## Por que deixou de ser `TextEditor`
///
/// Três controles da barra estavam desabilitados desde a Task W, com o motivo
/// escrito no `help`, e não por preguiça: `AttributedString` num `TextEditor`
/// não tem modelo de tabela, o atributo de alinhamento do CoreText só tem
/// esquerda/centro/direita, e não havia como pintar um `.link`. Os três são
/// limite do **tipo**, não da implementação — e o dono do projeto tem razão em
/// cobrar, porque Gmail e Outlook, que ele deu como régua, têm os três.
///
/// O `NSTextView` resolve os três de uma vez, e traz de graça o que nós não
/// tínhamos: desfazer/refazer de verdade (a pilha do AppKit, com agrupamento
/// por palavra), verificação ortográfica contínua, arrastar-e-soltar de texto
/// e de arquivo, detecção automática de link ao digitar, e o menu de contexto
/// padrão do macOS — cortar/copiar/colar, "Procurar", "Buscar com…",
/// transformações de texto, fala.
///
/// ## O que **não** mudou
///
/// O modelo. O corpo continua sendo `AttributedString` com `BodyStyleAttribute`
/// como fonte de verdade, `ComposerEditor.perform` continua sendo quem aplica
/// cada comando sobre a seleção, e `RichBody` continua puro, em `UNICore`, fora
/// de qualquer `View`. O que mudou foi só o alvo da projeção — ver
/// `ComposerTextKit`.
///
/// ## TextKit 1, de propósito
///
/// A vista é construída à mão com `NSLayoutManager`, e não pelo `NSTextView()`
/// de conveniência, porque `NSTextTable` é TextKit 1. Medido nesta máquina: uma
/// grade 2×2 num `NSLayoutManager` sai em quatro fragmentos numa grade de
/// verdade (dois em `y=7`, dois em `y=39`); o caminho do `NSTextLayoutManager`
/// não tem `textBlocks`. É também o que mantém `firstRect(forCharacterRange:)`
/// e `lineFragmentRect(forGlyphAt:)` funcionando, que é como este projeto mede
/// o cursor sem lançar o app.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: AttributedString
    @Binding var selection: AttributedTextSelection
    let theme: Theme
    /// A folga interna, em pontos. Vai para o `textContainerInset`, e não para
    /// um `.padding` do SwiftUI, senão o clique fora do texto não põe o cursor.
    var insets: CGSize
    /// Falso quando o editor cresce com o conteúdo (a 03, dentro da `ScrollView`
    /// da janela); verdadeiro quando a altura é imposta de fora e o texto rola
    /// por dentro (a 06 e a faixa do leitor).
    var scrolls: Bool = true
    /// Chamado depois de cada edição do usuário, para quem precisa carimbar
    /// rascunho. A barra não passa por aqui: ela muda o modelo direto.
    var onEdit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let view = ComposerNSTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = insets

        // O que o AppKit faz e nós não tínhamos.
        view.allowsUndo = true
        view.isContinuousSpellCheckingEnabled = true
        view.isGrammarCheckingEnabled = true
        view.isAutomaticLinkDetectionEnabled = true
        view.displaysLinkToolTips = true
        // Substituição automática fica **desligada**: um composer que troca
        // aspas e traços sozinho muda o que a pessoa escreveu, e este projeto
        // mede texto em teste — aspa curva entrando sem pedir tornaria a
        // medida não reprodutível.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = scrolls
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = view

        context.coordinator.textView = view
        context.coordinator.push(text, theme: theme, into: view)
        context.coordinator.applySelection(selection, in: text, to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        scroll.hasVerticalScroller = scrolls
        view.textContainerInset = insets
        view.linkTextAttributes = Coordinator.linkAttributes(theme)
        view.insertionPointColor = theme.ink.nsColor
        view.selectedTextAttributes = [.backgroundColor: theme.accentSoft.nsColor]

        // Só reescreve o documento quando o modelo mudou por fora — um comando
        // da barra, a semeadura, ou a troca de tema. Reescrever a cada tecla
        // apagaria a pilha de desfazer do AppKit e mataria a composição do IME
        // no meio de uma palavra acentuada.
        if context.coordinator.needsPush(text, theme: theme) {
            context.coordinator.push(text, theme: theme, into: view)
            context.coordinator.applySelection(selection, in: text, to: view)
        } else if context.coordinator.selectionChangedOutside(selection, in: text, view: view) {
            context.coordinator.applySelection(selection, in: text, to: view)
        }
        context.coordinator.applyTypingAttributes(selection, in: text, theme: theme, to: view)
    }

    /// A altura ideal é a do texto desenhado, para o editor da 03 crescer dentro
    /// da `ScrollView` da janela em vez de ficar preso numa caixa fixa com barra
    /// de rolagem própria.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        guard let view = nsView.documentView as? ComposerNSTextView,
              let layout = view.layoutManager, let container = view.textContainer
        else { return nil }
        let width = proposal.width ?? nsView.bounds.width
        if let height = proposal.height { return CGSize(width: width, height: height) }
        container.size = CGSize(
            width: max(0, width - insets.width * 2), height: .greatestFiniteMagnitude
        )
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return CGSize(width: width, height: used + insets.height * 2)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?

        /// O último modelo que **saiu** daqui, nas duas direções: o que foi
        /// escrito no `NSTextStorage` e o que foi devolvido ao `@State`.
        /// `updateNSView` compara com ele para saber se a mudança veio de fora.
        private var settled: AttributedString?
        private var settledTheme: Theme?
        private var pushing = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        static func linkAttributes(_ theme: Theme) -> [NSAttributedString.Key: Any] {
            [
                .foregroundColor: theme.accent.nsColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
        }

        func needsPush(_ model: AttributedString, theme: Theme) -> Bool {
            settled != model || settledTheme != theme
        }

        func push(_ model: AttributedString, theme: Theme, into view: ComposerNSTextView) {
            guard let storage = view.textStorage else { return }
            pushing = true
            defer { pushing = false }
            let rendered = ComposerTextKit.nsAttributed(model, theme: theme)
            // Passa pelo `shouldChangeText` para o desfazer do AppKit registrar
            // o comando da barra como **um** passo. Sem isso, formatar e apertar
            // ⌘Z desfaria a digitação anterior em vez da formatação.
            let whole = NSRange(location: 0, length: storage.length)
            if view.shouldChangeText(in: whole, replacementString: rendered.string) {
                storage.setAttributedString(rendered)
                view.didChangeText()
            } else {
                storage.setAttributedString(rendered)
            }
            settled = model
            settledTheme = theme
        }

        // MARK: Seleção

        func applySelection(
            _ selection: AttributedTextSelection, in model: AttributedString,
            to view: ComposerNSTextView
        ) {
            guard let range = Self.nsRange(of: selection, in: model) else { return }
            let clamped = NSRange(
                location: min(range.location, view.textStorage?.length ?? 0),
                length: 0
            )
            let safe = NSMaxRange(range) <= (view.textStorage?.length ?? 0) ? range : clamped
            if view.selectedRange() != safe { view.setSelectedRange(safe) }
        }

        func selectionChangedOutside(
            _ selection: AttributedTextSelection, in model: AttributedString,
            view: ComposerNSTextView
        ) -> Bool {
            guard let range = Self.nsRange(of: selection, in: model) else { return false }
            return view.selectedRange() != range
        }

        /// O intervalo do `NSTextView` como o modelo o entende. Uma seleção
        /// esparsa vira o intervalo que a envolve: o `NSTextView` deste marco
        /// tem uma seleção só.
        static func nsRange(
            of selection: AttributedTextSelection, in model: AttributedString
        ) -> NSRange? {
            let plain = String(model.characters)
            let spans = ComposerEditor.ranges(selection, in: model)
            guard let first = spans.first else { return nil }
            let lower = spans.dropFirst().reduce(first.lowerBound) { min($0, $1.lowerBound) }
            let upper = spans.dropFirst().reduce(first.upperBound) { max($0, $1.upperBound) }
            return ComposerTextKit.nsRange(lower..<upper, in: model, plain: plain)
        }

        static func selection(
            _ range: NSRange, in model: AttributedString
        ) -> AttributedTextSelection {
            let plain = String(model.characters)
            guard let span = ComposerTextKit.modelRange(range, in: model, plain: plain) else {
                return AttributedTextSelection(insertionPoint: model.startIndex)
            }
            return span.isEmpty
                ? AttributedTextSelection(insertionPoint: span.lowerBound)
                : AttributedTextSelection(range: span)
        }

        // MARK: Atributos de digitação

        /// O que o próximo caractere vai herdar. Sem isto, apertar **B** com o
        /// cursor solto e digitar sairia em texto normal: o modelo guarda a
        /// intenção nos atributos de digitação da seleção, e o `NSTextView` tem
        /// os dele, separados.
        func applyTypingAttributes(
            _ selection: AttributedTextSelection, in model: AttributedString,
            theme: Theme, to view: ComposerNSTextView
        ) {
            let reading = ComposerEditor.reading(of: model, selection: selection)
            guard !reading.hasSelection else { return }
            let style = BodyStyle(
                family: reading.family ?? BodyStyle.defaultFamily,
                size: reading.size ?? BodyStyle.defaultSize,
                bold: reading.bold,
                italic: reading.italic,
                underline: reading.underline,
                strike: reading.strike,
                colorHex: reading.colorHex ?? BodyStyle.defaultColorHex,
                highlightHex: reading.highlightHex ?? BodyStyle.noHighlight
            )
            var attributes = ComposerTextKit.characterAttributes(style, theme: theme)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = ComposerTextKit.nsAlignment(reading.alignment ?? .left)
            let box = ComposerFormatting.lineHeight(for: style.size)
            paragraph.minimumLineHeight = box
            paragraph.maximumLineHeight = box
            attributes[.paragraphStyle] = paragraph
            view.typingAttributes = attributes
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !pushing, let view = textView, let storage = view.textStorage else { return }
            let model = ComposerTextKit.model(storage)
            settled = model
            settledTheme = parent.theme
            parent.text = model
            parent.selection = Self.selection(view.selectedRange(), in: model)
            parent.onEdit?()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !pushing, let view = textView else { return }
            let model = settled ?? parent.text
            let next = Self.selection(view.selectedRange(), in: model)
            if Self.nsRange(of: next, in: model) != Self.nsRange(of: parent.selection, in: model) {
                parent.selection = next
            }
        }
    }
}

/// O `NSTextView` do composer.
///
/// Existe como subclasse por uma coisa só: o fundo é do tema e o AppKit desenha
/// o dele por baixo do texto quando `drawsBackground` fica ligado. Aqui ele
/// fica desligado e quem pinta é a `View` do SwiftUI em volta, como no resto do
/// app — cor vem do `Theme`, nunca de literal.
final class ComposerNSTextView: NSTextView {
    override var acceptsFirstResponder: Bool { isEditable }
}
