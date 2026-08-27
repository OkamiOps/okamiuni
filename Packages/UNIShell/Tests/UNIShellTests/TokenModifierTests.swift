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

@Suite("Hairline")
struct HairlineTests {

    /// O protótipo escreve `0.5px`, mas o navegador não desenha meio pixel: em
    /// 1× arredonda para um, em 2× meio pixel CSS já **é** um pixel do
    /// dispositivo. Nos dois casos o design mostra uma linha cheia de um pixel.
    ///
    /// Meio **ponto** ao pé da letra é outra coisa: em 1× é um pixel pintado
    /// pela metade, e foi o que lavou a borda dos botões para `rgb(227,225,219)`
    /// onde o design mostra `rgb(218,214,206)`.
    @Test("a espessura é um pixel do dispositivo em qualquer escala", arguments: [
        (CGFloat(1), CGFloat(1.0)),
        (CGFloat(2), CGFloat(0.5)),
        (CGFloat(3), CGFloat(1.0 / 3.0)),
    ])
    func thicknessIsOneDevicePixel(scale: CGFloat, expected: CGFloat) {
        #expect(abs(Hairline.thickness(scale) - expected) < 1e-9)
        #expect(abs(Hairline.thickness(scale) * scale - 1) < 1e-9)
    }

    /// Escala zero ou negativa não existe numa tela, mas chega aqui se alguém
    /// renderizar num contexto sem tela. Dividir por ela daria infinito.
    @Test("escala inválida cai num ponto em vez de infinito")
    func degenerateScaleFallsBack() {
        #expect(Hairline.thickness(0) == 1)
        #expect(Hairline.thickness(-2) == 1)
    }

    @Test("cada borda desenha do lado certo e no eixo certo")
    func alignmentAndAxis() {
        #expect(Hairline.alignment(for: .leading) == .leading)
        #expect(Hairline.alignment(for: .trailing) == .trailing)
        #expect(Hairline.alignment(for: .top) == .top)
        #expect(Hairline.alignment(for: .bottom) == .bottom)

        #expect(Hairline.isVertical(.leading))
        #expect(Hairline.isVertical(.trailing))
        #expect(Hairline.isVertical(.top) == false)
        #expect(Hairline.isVertical(.bottom) == false)
    }
}
