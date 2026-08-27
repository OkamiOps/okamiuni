import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O menu de contexto do editor do composer.
///
/// A regra do brief é explícita: o `NSTextView` **já traz** o menu do sistema —
/// recortar, copiar, colar, ortografia, transformações, serviços — e ele não
/// pode ser substituído, só acrescido. Devolver um `NSMenu` novo do delegado
/// jogaria tudo fora, e o diff pareceria igualmente inocente nos dois casos.
///
/// Nada aqui abre menu nem sintetiza evento. `Coordinator.augment(_:)` recebe o
/// `NSMenu` que o AppKit ia mostrar; o teste passa um menu de conteúdo
/// conhecido e lê o que sobrou.
@Suite("Composer — menu de contexto do editor")
@MainActor
struct ComposerContextMenuTests {

    /// Um editor de verdade, montado fora da tela, e o `Coordinator` que é o
    /// delegado dele — o mesmo objeto que o AppKit consultaria num clique.
    private func withCoordinator(
        _ body: AttributedString = AttributedString("Marina, tudo certo."),
        _ work: (ComposerTextView.Coordinator, ComposerNSTextView) -> Void
    ) {
        EditorProbe.withHostedView(
            TableKeyProbe(text: body),
            size: CGSize(width: 480, height: 320), theme: .tinta
        ) { content in
            guard let view = EditorProbe.anyTextView(in: content),
                  let coordinator = view.delegate as? ComposerTextView.Coordinator
            else { return }
            work(coordinator, view)
        }
    }

    /// Um menu do sistema faz-de-conta: o que importa é que **tudo** que entrou
    /// continue lá, na mesma ordem relativa.
    private func systemMenu() -> NSMenu {
        let menu = NSMenu()
        for title in ["Recortar", "Copiar", "Colar"] {
            menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Ortografia e gramática", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Serviços", action: nil, keyEquivalent: ""))
        return menu
    }

    @Test("o menu do sistema sobrevive inteiro, e os nossos itens entram no topo")
    func systemMenuSurvives() throws {
        var titles: [String] = []
        var same = false
        withCoordinator { coordinator, _ in
            let incoming = systemMenu()
            let result = coordinator.augment(incoming)
            same = result === incoming
            titles = result.items.map(\.title)
        }

        // O delegado devolve o **mesmo** menu, não um substituto.
        #expect(same)
        #expect(titles.prefix(3) == ["Colar sem formatação", "Inserir tabela", "Limpar formatação"])
        // E o do sistema continua, na ordem em que chegou.
        #expect(titles.suffix(6) == [
            "Recortar", "Copiar", "Colar", "", "Ortografia e gramática", "Serviços",
        ])
    }

    @Test("«Colar sem formatação» mostra ⇧⌘V, e o editor escuta esse atalho")
    func pastePlainShortcut() throws {
        var equivalent: (String, NSEvent.ModifierFlags)?
        var listens = false
        withCoordinator { coordinator, view in
            let menu = coordinator.augment(self.systemMenu())
            if let item = menu.items.first(where: { $0.title == "Colar sem formatação" }) {
                equivalent = (item.keyEquivalent, item.keyEquivalentModifierMask)
            }
            // O atalho tem de existir fora do menu aberto, senão o rótulo
            // promete o que o app não escuta.
            listens = view.responds(to: #selector(NSTextView.pasteAsPlainText(_:)))
        }

        #expect(equivalent?.0 == "v")
        #expect(equivalent?.1 == [.command, .shift])
        #expect(listens)
    }

    @Test("«Inserir tabela» oferece medidas, e cada uma insere a grade daquele tamanho")
    func insertTableActs() throws {
        var sizes: [String] = []
        var columns = 0
        var rows = 0
        withCoordinator(AttributedString("")) { coordinator, view in
            let menu = coordinator.augment(self.systemMenu())
            let table = menu.items.first { $0.title == "Inserir tabela" }
            sizes = table?.submenu?.items.map(\.title) ?? []

            guard let three = table?.submenu?.items.first(where: { $0.tag == 3 }) else { return }
            coordinator.insertTableFromMenu(three)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            guard let storage = view.textStorage else { return }
            // A grade **como ela é desenhada**, não a contagem de quebras: é a
            // régua que já pegou a tabela quando ela saía em coluna única.
            let layout = LayoutProbe.layout(storage, width: 440)
            columns = Set(layout.fragments.map(\.minX)).count
            rows = Set(layout.fragments.map(\.minY)).count
        }

        #expect(sizes == ["2 × 2", "3 × 3", "4 × 4"])
        #expect(columns == 3)
        #expect(rows == 3)
    }

    @Test("«Limpar formatação» aplica o mesmo comando que o ⌫ da barra")
    func clearFormattingActs() throws {
        // Um corpo em negrito, italico e vermelho — o que o comando tem de zerar.
        var body = AttributedString("proposta")
        var style = BodyStyle.default
        style.bold = true
        style.italic = true
        style.colorHex = "#B03030"
        body[BodyStyleAttribute.self] = style

        var after: BodyStyle?
        withCoordinator(body) { coordinator, view in
            view.setSelectedRange(NSRange(location: 0, length: view.string.count))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))

            coordinator.clearFormattingFromMenu(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            guard let storage = view.textStorage else { return }
            let model = ComposerTextKit.model(storage)
            after = model.runs.first?.attributes[BodyStyleAttribute.self]
        }

        let cleared = try #require(after)
        #expect(!cleared.bold)
        #expect(!cleared.italic)
        #expect(cleared.colorHex == BodyStyle.defaultColorHex)
    }

    /// A regra do marco vale para o menu do editor como para os outros: item
    /// que não faz nada não entra.
    @Test("«Inserir link…» não entra, porque o painel dele é de outra View")
    func noLinkItem() throws {
        var titles: [String] = []
        withCoordinator { coordinator, _ in
            titles = coordinator.augment(self.systemMenu()).items.map(\.title)
        }
        #expect(!titles.contains { $0.lowercased().contains("link") })
    }

    // MARK: - A guarda do «Inserir tabela»

    /// Um corpo com uma grade 2×2 depois de "antes", e o cursor **dentro** da
    /// primeira célula. É a reprodução do relatório, pela porta do menu.
    private func twoByTwo() -> AttributedString {
        var text = AttributedString("antes")
        var sel = AttributedTextSelection(
            insertionPoint: text.characters.index(text.startIndex, offsetBy: 5)
        )
        ComposerEditor.perform(.table(rows: 2, columns: 2), on: &text, selection: &sel, theme: .tinta)
        return text
    }

    /// As coordenadas das células do corpo, como o modelo as guarda.
    private func cells(_ text: AttributedString) -> [[Int]] {
        RichBody.paragraphs(of: text)
            .compactMap { RichBody.tableCell(of: text, at: $0) }
            .map { [$0.row, $0.column, $0.rows, $0.columns] }
    }

    /// O `⊞` da barra recusa com o motivo no `help`; o item do menu de contexto
    /// não recusava nada. Com o cursor numa célula, `RichBody.insertTable`
    /// insere em `paragraph.upperBound` — antes da quebra que carrega a
    /// coordenada da célula — e a grade 2×2 virava 3 colunas × 6 linhas, com o
    /// parágrafo do cursor fora da tabela.
    @Test("dentro de uma célula, «Inserir tabela» fica apagado, com o motivo no toolTip")
    func tableItemIsDisabledInsideACell() throws {
        var enabled: Bool?
        var sizesEnabled: [Bool] = []
        var tip: String?
        withCoordinator(twoByTwo()) { coordinator, view in
            // Cursor na primeira célula: "antes\n" tem seis caracteres.
            view.setSelectedRange(NSRange(location: 6, length: 0))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))

            let menu = coordinator.augment(self.systemMenu())
            let table = menu.items.first { $0.title == "Inserir tabela" }
            enabled = table?.isEnabled
            tip = table?.toolTip
            sizesEnabled = table?.submenu?.items.map(\.isEnabled) ?? []
        }

        #expect(enabled == false)
        #expect(sizesEnabled == [false, false, false])
        #expect(tip == "Inserir tabela — o cursor já está dentro de uma")
    }

    /// E a guarda vale no caminho de ação, não só na aparência do item: pedir a
    /// inserção com o cursor na célula não pode mexer na grade.
    @Test("dentro de uma célula, pedir a inserção não parte a grade")
    func insertingInsideACellIsRefused() throws {
        var before: [[Int]] = []
        var after: [[Int]] = []
        var columns = 0
        var rows = 0
        withCoordinator(twoByTwo()) { coordinator, view in
            view.setSelectedRange(NSRange(location: 6, length: 0))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))

            guard let storage = view.textStorage else { return }
            before = self.cells(ComposerTextKit.model(storage))

            let menu = coordinator.augment(self.systemMenu())
            guard let two = menu.items.first(where: { $0.title == "Inserir tabela" })?
                .submenu?.items.first(where: { $0.tag == 2 }) else { return }
            coordinator.insertTableFromMenu(two)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            after = self.cells(ComposerTextKit.model(storage))
            // E a grade **como ela é desenhada**: 2 colunas × 2 linhas, mais o
            // parágrafo "antes".
            let layout = LayoutProbe.layout(storage, width: 440)
            let cellFragments = Array(layout.fragments.dropFirst())
            columns = Set(cellFragments.map(\.minX)).count
            rows = Set(cellFragments.map(\.minY)).count
        }

        #expect(before == [[0, 0, 2, 2], [0, 1, 2, 2], [1, 0, 2, 2], [1, 1, 2, 2]])
        #expect(after == before, "a grade mudou: \(after)")
        #expect(columns == 2, "colunas desenhadas: \(columns)")
        #expect(rows == 2, "linhas desenhadas: \(rows)")
    }

    /// Fora da tabela o item continua vivo — a guarda não pode virar um item
    /// morto permanente.
    @Test("fora de qualquer célula o item continua clicável")
    func tableItemStaysEnabledOutside() throws {
        var enabled: Bool?
        var sizesEnabled: [Bool] = []
        withCoordinator(AttributedString("um paragrafo comum")) { coordinator, view in
            view.setSelectedRange(NSRange(location: 3, length: 0))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))

            let table = coordinator.augment(self.systemMenu())
                .items.first { $0.title == "Inserir tabela" }
            enabled = table?.isEnabled
            sizesEnabled = table?.submenu?.items.map(\.isEnabled) ?? []
        }
        #expect(enabled == true)
        #expect(sizesEnabled == [true, true, true])
    }
}
