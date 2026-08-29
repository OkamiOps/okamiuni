import AppKit
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
        #expect(WindowChrome.height == 64)
    }

    @Test("o vazio dos semáforos termina exatamente onde eles terminam")
    func trafficLightInset() {
        // Medido por acessibilidade na janela rodando: o botão de tela cheia
        // ocupa x=54..70. O vazio tem de casar com isso — nem menos, que
        // sobreporia os botões, nem mais, que abre um vão estranho.
        #expect(WindowChrome.trafficLightInset == 70)
    }

    /// A conta com os literais do próprio teste (`14 + (inset - 14) + 14`) é
    /// verdadeira por construção — mudar o padding real da barra, o spacing do
    /// `HStack` ou o vazio do espaçador não move um único valor desta soma,
    /// porque nenhum deles é lido de `WindowChrome.body`. Prova de verdade:
    /// renderizar a barra e medir onde o primeiro controle (o botão da
    /// lateral) de fato começa a pintar.
    @Test("o primeiro controle nasce 12pt depois dos semáforos no novo shell")
    @MainActor
    func firstControlOffset() throws {
        let rep = try #require(
            Render.bitmap(
                WindowChrome(
                    workspace: .constant(.mail),
                    query: .constant(""),
                    accountCount: 1,
                    onToggleSidebar: {},
                    onToggleAgenda: {}
                )
                .environment(ThemeStore()),
                size: CGSize(width: 1000, height: WindowChrome.height),
                theme: .tinta
            )
        )

        // A linha média da barra, onde o botão da lateral desenha a caixa
        // inteira (26×24) sem a curva do canto atrapalhar — ver `centerY`.
        let y = Int(WindowChrome.centerY)
        let background = Theme.tinta.surface2

        var firstControlX: Int?
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99
            else { continue }
            let pixel = TokenColor(
                red: Double(c.redComponent), green: Double(c.greenComponent),
                blue: Double(c.blueComponent), opacity: Double(c.alphaComponent)
            )
            if HairlineThicknessTests.levels(pixel, background) > 6 {
                firstControlX = x
                break
            }
        }

        let x = try #require(
            firstControlX,
            "nenhum pixel diferente do fundo apareceu na linha média da barra"
        )
        #expect(
            abs(x - 82) <= 2,
            "o primeiro controle começou a pintar em x=\(x), não perto de 82"
        )
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
            #expect(r == max(theme.radiusLarge, 17))
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
