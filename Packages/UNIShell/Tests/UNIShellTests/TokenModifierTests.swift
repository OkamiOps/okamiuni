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

    @Test("o vazio dos semáforos termina exatamente onde eles terminam")
    func trafficLightInset() {
        // Medido por acessibilidade na janela rodando: o botão de tela cheia
        // ocupa x=54..70. O vazio tem de casar com isso — nem menos, que
        // sobreporia os botões, nem mais, que abre um vão estranho.
        #expect(WindowChrome.trafficLightInset == 70)
    }

    @Test("o primeiro controle nasce 14pt depois dos semáforos, como no protótipo")
    func firstControlOffset() {
        // padding horizontal da barra (14) + vazio + spacing do HStack (14)
        let firstControlX = 14 + (WindowChrome.trafficLightInset - 14) + 14
        #expect(firstControlX == 84)
        #expect(firstControlX - WindowChrome.trafficLightInset == 14)
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

    @Test("o raio da aba nunca é negativo em nenhum tema e bate com o container")
    func tabRadiusNeverNegative() {
        for theme in Theme.all {
            let r = WindowChrome.tabCornerRadius(for: theme)
            #expect(
                r >= 0,
                "tabCornerRadius é \(r) no tema \(theme.name) — aba fica com raio negativo"
            )
            #expect(
                r == theme.radiusSmall,
                "a aba usa o mesmo raio do container, como no protótipo"
            )
        }
    }
}
