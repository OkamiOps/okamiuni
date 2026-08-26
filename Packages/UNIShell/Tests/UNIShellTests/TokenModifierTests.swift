import Testing
import SwiftUI
import UNIDesign
@testable import UNIShell

@Suite("Chrome")
struct TokenModifierTests {

    @Test("as duas áreas de trabalho batem com as abas do protótipo")
    func workspaceTabs() {
        #expect(Workspace.allCases.map(\.label) == ["Caixa", "Agenda"])
    }

    @Test("a barra tem a altura do design")
    func chromeHeight() {
        #expect(WindowChrome.height == 58)
    }

    @Test("o espaço reservado aos semáforos cobre os três botões")
    func trafficLightInset() {
        // Três botões de 12px com 8px de folga, mais a margem da janela.
        #expect(WindowChrome.trafficLightInset >= 68)
    }

    @Test("o texto da busca concorda com o número de contas", arguments: [
        (0, "Buscar"),
        (1, "Buscar na caixa…"),
        (4, "Buscar nas 4 caixas…"),
        (37, "Buscar nas 37 caixas…"),
    ])
    func searchPlaceholderAgrees(count: Int, expected: String) {
        #expect(WindowChrome.searchPlaceholder(count) == expected)
    }
}
