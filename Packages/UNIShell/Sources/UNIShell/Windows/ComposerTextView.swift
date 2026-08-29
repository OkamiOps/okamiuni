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
    /// Um contador que, ao mudar, põe o cursor **aqui**.
    ///
    /// Existe para o "Responder" do topo do leitor: ele expande a faixa e o
    /// cursor já tem de estar no campo — pedir para a pessoa clicar de novo no
    /// que ela acabou de abrir é um passo a mais por nada. É um contador, e não
    /// um `Bool`, porque dois pedidos seguidos ("Responder" duas vezes) são
    /// dois pedidos, e um `Bool` que já era `true` não avisaria o segundo.
    ///
    /// Zero é "ninguém pediu", e é o padrão: a janela 03 e todo teste que não
    /// passa nada continuam sem mexer no foco de ninguém.
    var focusToken: Int = 0

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

        view.stepCell = { [weak coordinator = context.coordinator] delta in
            coordinator?.stepCell(by: delta) ?? false
        }

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

        // O pedido de foco do "Responder". `makeFirstResponder` age dentro da
        // janela do próprio app — não mexe em teclado nem em mouse do sistema,
        // e numa janela fora da tela (o harness dos testes) não faz nada.
        if focusToken != context.coordinator.focusToken {
            context.coordinator.focusToken = focusToken
            if focusToken > 0 { view.window?.makeFirstResponder(view) }
        }
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
        /// O último pedido de foco já atendido — ver `ComposerTextView.focusToken`.
        var focusToken = 0

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
            // **Os blocos de tabela vêm junto.** O que se digita herda estes
            // atributos, e o `NSTextStorage` uniformiza o estilo de parágrafo
            // ao arrumar os atributos — um estilo sem `textBlocks` entrando por
            // aqui arrancaria a célula de dentro da grade na primeira tecla.
            paragraph.textBlocks = view.tableBlocksAtCaret()
            attributes[.paragraphStyle] = paragraph
            view.typingAttributes = attributes
        }

        // MARK: Tabela

        /// Tab (`+1`) e Shift-Tab (`-1`) dentro da tabela.
        ///
        /// Devolve `false` fora de tabela, e aí o `NSTextView` faz o que sempre
        /// fez com a tecla — inserir tabulação, ou passar o foco adiante.
        func stepCell(by delta: Int) -> Bool {
            guard let view = textView, let storage = view.textStorage else { return false }
            let model = settled ?? ComposerTextKit.model(storage)
            let plain = String(model.characters)
            guard let caret = ComposerTextKit.modelRange(
                view.selectedRange(), in: model, plain: plain
            )?.lowerBound else { return false }
            guard let cell = RichBody.cell(of: model, at: caret) else { return false }

            // Há vizinha: só o cursor anda.
            if let target = RichBody.neighbouringCell(of: model, at: caret, by: delta) {
                if let range = ComposerTextKit.nsRange(
                    target.lowerBound..<target.lowerBound, in: model, plain: plain
                ) {
                    view.setSelectedRange(range)
                }
                return true
            }

            // Shift-Tab na primeira célula não faz nada — sair da tabela por
            // aqui seria surpresa. Tab na última cria uma linha, que é o que
            // Mail, Outlook e Gmail fazem.
            guard delta > 0 else { return true }

            var grown = model
            guard let offset = RichBody.appendTableRow(
                &grown, table: cell.table, style: RichBody.style(of: caretAttributes(model, at: caret))
            ) else { return true }

            let start = grown.characters.index(grown.startIndex, offsetBy: offset)
            parent.text = grown
            parent.selection = AttributedTextSelection(insertionPoint: start)
            parent.onEdit?()
            return true
        }

        /// Os atributos sob o cursor, para a linha nova nascer com o estilo da
        /// célula de onde se veio.
        private func caretAttributes(
            _ model: AttributedString, at index: AttributedString.Index
        ) -> AttributeContainer {
            let characters = model.characters
            guard characters.startIndex < characters.endIndex else { return AttributeContainer() }
            let probe = index > characters.startIndex ? characters.index(before: index) : index
            guard probe < characters.endIndex else { return AttributeContainer() }
            return model[probe..<characters.index(after: probe)].runs.first?.attributes
                ?? AttributeContainer()
        }

        // MARK: Menu de contexto do editor

        /// **Acrescenta ao menu do sistema; nunca o substitui.**
        ///
        /// O `NSTextView` já traz recortar, copiar, colar, ortografia,
        /// transformações, fala e serviços — é metade do motivo de ter trocado
        /// o `TextEditor` por ele. Devolver um `NSMenu` novo jogaria tudo isso
        /// fora. Aqui o menu que chega é o do AppKit, e os nossos itens entram
        /// **no topo**, seguidos de um separador: um comando do editor
        /// enterrado depois de "Serviços" não seria achado por ninguém.
        ///
        /// "Inserir link…" ficou **de fora**. O painel de link é `@State` de
        /// `ComposerToolbar`, uma `View` irmã desta — não há como abri-lo
        /// daqui sem mudar a interface da barra e das duas telas que a
        /// hospedam. Um item que não abrisse o painel seria botão mudo.
        func textView(
            _ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int
        ) -> NSMenu? {
            augment(menu)
        }

        /// A montagem, separada do `NSEvent` que o `NSTextViewDelegate` exige.
        ///
        /// A separação não é estética: assim o teste chama isto com um `NSMenu`
        /// e nada mais. Construir um `NSEvent` só para chamar o delegado
        /// pareceria evento sintético num projeto cuja regra é não ter nenhum,
        /// e o evento não entra em decisão nenhuma aqui.
        @discardableResult
        func augment(_ menu: NSMenu) -> NSMenu {
            var index = 0

            let paste = NSMenuItem(
                title: "Colar sem formatação",
                action: #selector(pastePlainFromMenu(_:)),
                keyEquivalent: "v"
            )
            paste.keyEquivalentModifierMask = [.command, .shift]
            paste.target = self
            menu.insertItem(paste, at: index); index += 1

            // A mesma guarda do `⊞` da barra, pela mesma expressão: com o
            // cursor dentro de uma célula, inserir aqui parte a grade (a 2×2
            // virava 3×6, com o parágrafo do cursor fora da tabela). O item
            // fica apagado com o motivo no `toolTip`, em vez de sumir — a
            // recusa tem de se explicar.
            let reading = ComposerEditor.reading(of: parent.text, selection: parent.selection)
            let allowed = ComposerTableCommand.isEnabled(reading)
            let table = NSMenuItem(title: "Inserir tabela", action: nil, keyEquivalent: "")
            table.isEnabled = allowed
            table.toolTip = ComposerTableCommand.title(reading)
            let sizes = NSMenu(title: "Inserir tabela")
            // `NSMenu` reabilita item por item sozinho quando o alvo responde
            // ao seletor; desligar o automatismo é o que faz `isEnabled` valer.
            sizes.autoenablesItems = false
            // Sem painel de escolha aqui: o `↗`/grade da barra é que tem o
            // seletor por arraste. O menu oferece as medidas que se pede na
            // prática, e cada uma insere de verdade.
            for side in [2, 3, 4] {
                let entry = NSMenuItem(
                    title: "\(side) × \(side)",
                    action: #selector(insertTableFromMenu(_:)),
                    keyEquivalent: ""
                )
                entry.tag = side
                entry.target = self
                entry.isEnabled = allowed
                sizes.addItem(entry)
            }
            table.submenu = sizes
            menu.insertItem(table, at: index); index += 1

            let clear = NSMenuItem(
                title: "Limpar formatação",
                action: #selector(clearFormattingFromMenu(_:)),
                keyEquivalent: ""
            )
            clear.target = self
            menu.insertItem(clear, at: index); index += 1

            menu.insertItem(.separator(), at: index)
            return menu
        }

        @objc func pastePlainFromMenu(_ sender: Any?) {
            textView?.pasteAsPlainText(sender)
        }

        @objc func clearFormattingFromMenu(_ sender: Any?) {
            run(.clearFormatting)
        }

        @objc func insertTableFromMenu(_ sender: NSMenuItem) {
            // O item já nasce apagado dentro de uma célula; esta é a mesma
            // guarda no caminho de ação, para um menu montado antes de o cursor
            // entrar na tabela não conseguir parti-la mesmo assim.
            let reading = ComposerEditor.reading(of: parent.text, selection: parent.selection)
            guard ComposerTableCommand.isEnabled(reading) else { return }
            let side = max(1, sender.tag)
            run(.table(rows: side, columns: side))
        }

        /// O mesmo caminho que a barra de formatação usa. Nada de uma segunda
        /// implementação: o menu e a barra têm de aplicar o mesmo comando, ou
        /// divergem no primeiro conserto.
        func run(_ command: ComposerCommand) {
            var text = parent.text
            var selection = parent.selection
            ComposerEditor.perform(
                command, on: &text, selection: &selection, theme: parent.theme
            )
            parent.text = text
            parent.selection = selection
            parent.onEdit?()
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

    /// Tab e Shift-Tab dentro da tabela. Ligado pelo `Coordinator`; devolve
    /// `false` quando o cursor não está numa célula, e aí vale o comportamento
    /// padrão do `NSTextView`.
    var stepCell: ((Int) -> Bool)?

    /// Os blocos de tabela do parágrafo em que o cursor está.
    func tableBlocksAtCaret() -> [NSTextBlock] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let at = min(max(0, selectedRange().location), storage.length - 1)
        let style = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil)
        return (style as? NSParagraphStyle)?.textBlocks ?? []
    }

    /// **Enter dentro de uma célula cria linha na célula, não fora dela.**
    ///
    /// O padrão do `NSTextView` é inserir um parágrafo que **não** herda os
    /// `textBlocks` do anterior: a partir dali o conteúdo sai da tabela e a
    /// grade se desmonta. Foi o defeito que o dono do projeto relatou usando —
    /// *"na tabela ao dar enter ele quebra a tabela toda"*.
    ///
    /// A quebra passa a carregar o estilo de parágrafo do parágrafo corrente,
    /// blocos inclusive. Quem junta os dois parágrafos numa célula só é o
    /// `ComposerTextKit`, que partilha um `NSTextTableBlock` por coordenada.
    ///
    /// Para **sair** da tabela o caminho é mover o cursor para fora dela, como
    /// em Mail, Outlook e Gmail. Enter nunca foi a porta de saída.
    override func insertNewline(_ sender: Any?) {
        let blocks = tableBlocksAtCaret()
        guard !blocks.isEmpty, let storage = textStorage else {
            super.insertNewline(sender)
            return
        }
        let at = min(max(0, selectedRange().location), storage.length - 1)
        guard let current = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil)
            as? NSParagraphStyle else {
            super.insertNewline(sender)
            return
        }

        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: "\n") else { return }
        var attributes = typingAttributes
        attributes[.paragraphStyle] = current
        storage.replaceCharacters(
            in: range, with: NSAttributedString(string: "\n", attributes: attributes)
        )
        setSelectedRange(NSRange(location: range.location + 1, length: 0))
        didChangeText()
    }

    /// ⇧⌘V cola sem formatação.
    ///
    /// O equivalente escrito no item do menu de contexto não basta: `NSMenu` de
    /// contexto só dispara equivalente enquanto está **aberto**. Sem isto o
    /// item mostraria um atalho que o app não escuta — a versão tipográfica do
    /// botão mudo, e a regra deste marco vale para o atalho também.
    ///
    /// Só intercepta a combinação exata. Qualquer outra segue para o AppKit,
    /// que é quem responde por ⌘C, ⌘V, ⌘Z e o resto.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        if event.modifierFlags.intersection(relevant) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteAsPlainText(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertTab(_ sender: Any?) {
        if stepCell?(1) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if stepCell?(-1) == true { return }
        super.insertBacktab(sender)
    }
}
