import AppKit
import SwiftUI
import Testing
import UNIDesign
@testable import UNIShell

/// O "contorno duplo" que o dono do projeto relatou três vezes é o anel de foco
/// do macOS: borda nítida, **folga**, segundo anel, nos quatro lados. Ele nunca
/// apareceu numa renderização nossa porque o AppKit só o desenha na
/// **janela-chave** de um app ativo, e a janela do `Render` — a 50.000pt fora da
/// tela — nunca é.
///
/// Estes testes travam o que entrou no lugar dele: um anel do próprio `Theme`,
/// desenhado **dentro** da forma do controle e **encostado** na borda dele.
///
/// Foco não acontece sozinho fora da tela, então o desenho vem do parâmetro
/// `debugFocused`, no mesmo padrão de `ComposerWindow(store:mode:debugOpenPanel:)`.
///
/// Um tema claro e um escuro, por **id**: passar o `Theme` inteiro como argumento
/// faz o relatório do Swift Testing despejar os ~40 tokens dele em cada linha.
/// Dois temas, e não um, para que uma cor literal — o azul do sistema, por
/// exemplo — falhe em pelo menos um. Fora da suíte porque a suíte é `@MainActor`
/// e a lista de argumentos do `@Test` é lida de fora do ator.
let focusProbeThemes = ["tinta", "noite"]

@Suite("Anel de foco")
@MainActor
struct FocusRingTests {

    /// 2× obrigatório: em 1× a borda de 0,5pt e o anel de 1pt viram meio pixel
    /// lavado cada um e o defeito de contorno some. Já enganou uma vez.
    static let scale: CGFloat = 2

    /// Folga entre o controle e a beira da tela de teste. Tem de ser maior que o
    /// transbordo do anel do sistema (~3pt) para que a asserção de sangramento
    /// signifique alguma coisa.
    static let pad: CGFloat = 8

    /// Distância máxima, em pixels de 2×, entre a beira desenhada do controle e
    /// o primeiro pixel do acento. 2pt: uma hairline de 0,5 mais a franja de
    /// antialias das duas bordas. Literal de propósito — ler
    /// `FocusRingMetrics.inset` aqui faria o teste concordar com qualquer valor
    /// que alguém pusesse lá.
    static let maxRingGapPixels = Int(2 * scale)

    static func theme(_ id: String) throws -> Theme {
        try #require(Theme.all.first { $0.id == id }, "tema \(id) sumiu do catálogo")
    }

    // MARK: - Ferramentas

    struct Pixels {
        let rep: NSBitmapImageRep
        var width: Int { rep.pixelsWide }
        var height: Int { rep.pixelsHigh }

        func color(_ x: Int, _ y: Int) -> TokenColor {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                return TokenColor(red: -1, green: -1, blue: -1)
            }
            return TokenColor(
                red: Double(c.redComponent),
                green: Double(c.greenComponent),
                blue: Double(c.blueComponent),
                opacity: Double(c.alphaComponent)
            )
        }
    }

    static func near(_ a: TokenColor, _ b: TokenColor, tolerance: Double = 0.03) -> Bool {
        abs(a.red - b.red) <= tolerance
            && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance
    }

    /// Onde os dois bitmaps diferem, em pixels. `nil` = desenhos idênticos.
    static func diffBox(_ a: Pixels, _ b: Pixels) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<min(a.height, b.height) {
            for x in 0..<min(a.width, b.width) where !near(a.color(x, y), b.color(x, y), tolerance: 0.004) {
                if var current = box {
                    current.minX = min(current.minX, x)
                    current.minY = min(current.minY, y)
                    current.maxX = max(current.maxX, x)
                    current.maxY = max(current.maxY, y)
                    box = current
                } else {
                    box = (x, y, x, y)
                }
            }
        }
        return box
    }

    /// Põe o controle numa tela com folga conhecida e fundo chapado, para que
    /// "transbordou" e "deixou folga" sejam perguntas de pixel.
    static func stage<V: View>(_ control: V, theme: Theme, width: CGFloat, height: CGFloat) -> some View {
        control
            .padding(pad)
            .frame(width: width, height: height)
            .background(theme.surface.color)
    }

    static func render<V: View>(
        _ view: V, named name: String, theme: Theme, width: CGFloat, height: CGFloat
    ) throws -> Pixels {
        let rep = try #require(
            Render.snapshot(
                view, named: name,
                size: CGSize(width: width, height: height),
                theme: theme, scale: scale
            )
        )
        return Pixels(rep: rep)
    }

    // MARK: - O anel não cresce para fora do controle

    /// A forma do print: o anel do sistema sai **para fora** do controle, nos
    /// quatro lados. O nosso não pode sair de jeito nenhum.
    ///
    /// A tela tem exatamente a altura do botão mais `pad` em cima e embaixo, de
    /// modo que as duas faixas de `pad` são território fora do controle. Se o
    /// anel transbordasse, esses pixels mudariam entre focado e não focado.
    @Test("o anel de foco não pinta um pixel fora do botão", arguments: focusProbeThemes)
    func ringStaysInsideChromeButton(themeID: String) throws {
        let theme = try Self.theme(themeID)
        let buttonHeight: CGFloat = 32
        let width: CGFloat = 240
        let height = buttonHeight + 2 * Self.pad

        func stage(_ focused: Bool) -> some View {
            Self.stage(
                ChromeButton(
                    "Reagendar", appearance: .outlined,
                    height: buttonHeight, debugFocused: focused
                ) {},
                theme: theme, width: width, height: height
            )
        }

        let off = try Self.render(
            stage(false), named: "foco-chrome-\(theme.id)-sem", theme: theme,
            width: width, height: height
        )
        let on = try Self.render(
            stage(true), named: "foco-chrome-\(theme.id)-com", theme: theme,
            width: width, height: height
        )

        let box = try #require(Self.diffBox(off, on), "o foco não desenhou nada")

        let band = Int(Self.pad * Self.scale)
        #expect(box.minY >= band, "o anel subiu \(band - box.minY)px acima do botão")
        #expect(box.maxY < on.height - band, "o anel desceu abaixo do botão")
        #expect(box.minX >= band, "o anel saiu pela esquerda do botão")
        #expect(box.maxX < on.width - band, "o anel saiu pela direita do botão")
    }

    /// O mesmo para os dois compartilhados da barra de formatação.
    @Test("o anel do botão solo da barra também fica dentro")
    func ringStaysInsideSoloToolButton() throws {
        let theme = Theme.tinta
        let width: CGFloat = 30 + 2 * Self.pad
        let height: CGFloat = 26 + 2 * Self.pad

        func stage(_ focused: Bool) -> some View {
            Self.stage(
                SoloToolButton(label: "▦", title: "Tabela", on: false, debugFocused: focused) {},
                theme: theme, width: width, height: height
            )
        }

        let off = try Self.render(stage(false), named: "foco-solo-sem", theme: theme, width: width, height: height)
        let on = try Self.render(stage(true), named: "foco-solo-com", theme: theme, width: width, height: height)

        let box = try #require(Self.diffBox(off, on), "o foco não desenhou nada")
        let band = Int(Self.pad * Self.scale)
        #expect(box.minX >= band)
        #expect(box.minY >= band)
        #expect(box.maxX < on.width - band)
        #expect(box.maxY < on.height - band)
    }

    @Test("o anel do item de grupo também fica dentro")
    func ringStaysInsideSegmentButton() throws {
        let theme = Theme.tinta
        let width: CGFloat = 28 + 2 * Self.pad
        let height: CGFloat = 26 + 2 * Self.pad

        func stage(_ focused: Bool) -> some View {
            Self.stage(
                SegmentButton(label: "B", title: "Negrito", on: false, debugFocused: focused) {}
                    .frame(height: 26),
                theme: theme, width: width, height: height
            )
        }

        let off = try Self.render(stage(false), named: "foco-segmento-sem", theme: theme, width: width, height: height)
        let on = try Self.render(stage(true), named: "foco-segmento-com", theme: theme, width: width, height: height)

        let box = try #require(Self.diffBox(off, on), "o foco não desenhou nada")
        let band = Int(Self.pad * Self.scale)
        #expect(box.minX >= band)
        #expect(box.minY >= band)
        #expect(box.maxX < on.width - band)
        #expect(box.maxY < on.height - band)
    }

    // MARK: - O anel encosta na borda, sem folga

    /// A assinatura do defeito não é "tem dois traços" — é **traço, folga,
    /// traço**. Então a pergunta não é quantos traços há, é **a que distância**
    /// da beira do controle o segundo começa.
    ///
    /// O teste varre uma linha da altura média do botão, da esquerda para o
    /// meio: acha onde o desenho do botão começa (primeira coluna que sai do
    /// fundo da tela) e onde o acento começa. A distância entre as duas tem de
    /// caber em **1pt** — a espessura de uma hairline. É literal de propósito:
    /// ler `FocusRingMetrics.inset` aqui faria o teste concordar com qualquer
    /// valor que alguém pusesse lá.
    ///
    /// A altura média evita o canto arredondado, e a lateral evita a sombra,
    /// que no design cai só para baixo (`y: 1`).
    @Test("o anel encosta na borda do botão, sem folga", arguments: focusProbeThemes)
    func ringTouchesTheBorder(themeID: String) throws {
        let theme = try Self.theme(themeID)
        let buttonHeight: CGFloat = 32
        let width: CGFloat = 240
        let height = buttonHeight + 2 * Self.pad

        let on = try Self.render(
            Self.stage(
                ChromeButton(
                    "Reagendar", appearance: .outlined,
                    height: buttonHeight, debugFocused: true
                ) {},
                theme: theme, width: width, height: height
            ),
            named: "foco-encosta-\(theme.id)", theme: theme, width: width, height: height
        )

        let row = on.height / 2
        // Apertada: em `tinta` o fundo da tela (`surface`) e o miolo do botão
        // (`btn`, branco) diferem só 0,02. Com a tolerância folgada de `near`
        // os dois passam por iguais e a varredura não acha beira nenhuma.
        let edgeTolerance = 0.008

        var firstInk: Int?
        var firstAccent: Int?
        for x in 0..<(on.width / 2) {
            let c = on.color(x, row)
            if firstInk == nil, !Self.near(c, theme.surface, tolerance: edgeTolerance) { firstInk = x }
            if firstAccent == nil, Self.near(c, theme.accent) { firstAccent = x }
        }

        let edge = try #require(firstInk, "a linha do meio nunca sai do fundo da tela")
        let ring = try #require(firstAccent, "a linha do meio nunca encontra o acento")

        let gap = ring - edge
        #expect(gap >= 0)
        #expect(
            gap <= Self.maxRingGapPixels,
            "o anel começa a \(Double(gap) / Double(Self.scale))pt da beira do botão; borda, folga e anel é o contorno duplo do print"
        )
    }

    // MARK: - O anel é do tema, não do sistema

    /// Um azul de sistema cravado passaria no teste de geometria. Este exige a
    /// cor do `Theme` — e em dois temas, para que uma literal falhe num deles.
    @Test("o anel usa o acento do tema", arguments: focusProbeThemes)
    func ringUsesThemeAccent(themeID: String) throws {
        let theme = try Self.theme(themeID)
        let buttonHeight: CGFloat = 32
        let width: CGFloat = 240
        let height = buttonHeight + 2 * Self.pad

        func stage(_ focused: Bool) -> some View {
            Self.stage(
                ChromeButton(
                    "Reagendar", appearance: .outlined,
                    height: buttonHeight, debugFocused: focused
                ) {},
                theme: theme, width: width, height: height
            )
        }

        let off = try Self.render(
            stage(false), named: "foco-cor-\(theme.id)-sem", theme: theme, width: width, height: height
        )
        let on = try Self.render(
            stage(true), named: "foco-cor-\(theme.id)-com", theme: theme, width: width, height: height
        )

        // A borda do botão está a 0–0,5pt do topo dele e o anel a 0,5–1,5pt.
        // Em 2× isso são os pixels 1 a 3 abaixo do topo; a janela de busca leva
        // um pixel de folga para cada lado por causa do arredondamento do layout.
        let top = Int(Self.pad * Self.scale)
        let window = (top ..< top + Int(
            (FocusRingMetrics.inset + FocusRingMetrics.thickness + 1) * Self.scale
        ))
        let column = on.width / 2

        let accent = theme.accent
        #expect(
            window.contains { Self.near(on.color(column, $0), accent) },
            "nenhum pixel do acento \(theme.id) na borda de cima do botão focado"
        )
        #expect(
            !window.contains { Self.near(off.color(column, $0), accent) },
            "o botão sem foco já tinha o acento na borda — o teste não prova nada"
        )
    }
}
