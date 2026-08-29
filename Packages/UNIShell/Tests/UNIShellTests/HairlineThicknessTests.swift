import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// As superfícies medidas, por nome. Fora da suíte porque a suíte é
/// `@MainActor` e a lista de argumentos de um `@Test` é lida de fora do ator —
/// a mesma razão de `focusProbeThemes` em `FocusRingTests`. Só os nomes viajam:
/// a descrição de cada sonda carrega closure e não é `Sendable`.
///
/// `probeListMatchesProbes` trava as duas listas juntas, para que acrescentar
/// uma sonda sem medi-la não passe despercebido.
let hairlineProbeIDs = [
    "botao-rodape",
    "botao-solo-barra",
    "grupo-da-barra",
    "seletor-de-tema",
    "divisoria-inferior",
    "botao-ativo-da-trilha",
    "divisoria-lateral",
]

/// A borda tem de chegar **na cor do token**, não numa mistura lavada.
///
/// ## O defeito que estes testes travam
///
/// O dono do projeto reclamou quatro vezes de borda errada. Medido na janela
/// dele, numa tela 1×: a borda do botão saía `rgb(227,225,219)` contra um fundo
/// `233` — seis níveis, quase invisível —, enquanto a divisória do rodapé saía
/// `225`, **mais forte que a própria borda**. O olho lia a divisória como sendo
/// a borda, e a borda como um contorno fantasma.
///
/// A causa é aritmética, não de cor: o protótipo escreve `0.5px` e o navegador
/// não desenha meio pixel — em 1× arredonda para um, em 2× meio pixel CSS já
/// **é** um pixel do dispositivo. Nós desenhávamos meio **ponto** ao pé da
/// letra, que em 1× é um pixel pintado pela metade. Metade da cor do token,
/// metade do fundo: a borda sai clara demais.
///
/// ## Por que a medida é de pixel, e não de olho
///
/// Um PNG de uma borda lavada e um de uma borda cheia são indistinguíveis num
/// print. A diferença aparece ao ler o valor do pixel — e é exatamente essa
/// leitura que descobriu a causa. Estes testes fazem a mesma leitura a cada
/// suíte: varrem uma linha que atravessa a borda, pegam o pixel mais escuro que
/// ela chega a pintar, e exigem que ele esteja perto do token.
///
/// Com meio ponto cravado eles falham. Provado quebrando: ver o relatório da
/// Task AC.
@Suite("Espessura de hairline")
@MainActor
struct HairlineThicknessTests {

    /// Folga de fundo chapado em volta do controle, para que a varredura tenha
    /// onde começar sem esbarrar na beira do bitmap.
    static let pad: CGFloat = 8

    /// Quanto a borda desenhada pode se afastar do token, em níveis de 0–255.
    ///
    /// Oito é folgado para o desenho certo e apertado para o errado, e a
    /// distância entre os dois casos não é de ajuste fino: um pixel cheio cai a
    /// menos de 8 do token, meio pixel cai a mais de 15. Literal de propósito —
    /// derivar isto de `Hairline.thickness(_:)` faria a asserção concordar com
    /// qualquer espessura.
    static let maxLevels = 8.0

    // MARK: - Leitura de pixel

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

    /// Distância entre duas cores no canal que mais diverge, em níveis de 0–255.
    ///
    /// Canal a canal, e não média: uma borda lavada erra os três canais para o
    /// mesmo lado, e a média esconderia metade do erro.
    static func levels(_ a: TokenColor, _ b: TokenColor) -> Double {
        max(abs(a.red - b.red), max(abs(a.green - b.green), abs(a.blue - b.blue))) * 255
    }

    static func describe(_ c: TokenColor) -> String {
        "rgb(\(Int((c.red * 255).rounded())),"
            + "\(Int((c.green * 255).rounded())),"
            + "\(Int((c.blue * 255).rounded())))"
    }

    /// O pixel mais escuro que a varredura encontra. A borda é sempre a coisa
    /// mais escura da janela varrida — é para isso que a janela é escolhida.
    ///
    /// Pixel transparente não conta. O primeiro palco deixava margem sem fundo,
    /// e `colorAt` devolve `rgba(0,0,0,0)` ali: a varredura elegia o vazio como
    /// "a borda mais escura" e o teste falhava por 218 níveis dizendo
    /// `rgb(0,0,0)`. Agora o palco pinta o bitmap inteiro e isto é rede de
    /// segurança — se ainda assim não sobrar pixel opaco, devolve `nil` e o
    /// teste diz que não mediu nada, em vez de medir o vazio.
    static func darkest(_ pixels: Pixels, along scan: [(Int, Int)]) -> TokenColor? {
        var best: TokenColor?
        var bestSum = Double.infinity
        for (x, y) in scan {
            let c = pixels.color(x, y)
            guard c.opacity > 0.99, c.red >= 0 else { continue }
            let sum = c.red + c.green + c.blue
            if sum < bestSum {
                bestSum = sum
                best = c
            }
        }
        return best
    }

    // MARK: - As superfícies medidas

    /// Uma superfície com borda, o token que ela deve pintar, e por onde varrer.
    ///
    /// Identificada por `String` porque o argumento de um `@Test` é lido de fora
    /// do ator: uma `View` ali não compila, e o `Theme` inteiro despejaria os
    /// ~40 tokens dele em cada linha do relatório.
    struct Probe {
        let id: String
        /// Tamanho do palco, já com a folga dos dois lados.
        let size: CGSize
        let token: KeyPath<Theme, TokenColor>
        /// Coordenadas a varrer, em **pontos**, no palco.
        let scan: (CGFloat) -> [(CGFloat, CGFloat)]
    }

    /// Varre uma linha horizontal na meia-altura, da beira do palco até pouco
    /// depois da borda esquerda do controle. Para longe do miolo, onde o texto
    /// é mais escuro que qualquer borda; e na meia-altura, longe do canto
    /// arredondado e da sombra, que no design cai só para baixo (`y: 1`).
    static func leftBorderScan(height: CGFloat) -> (CGFloat) -> [(CGFloat, CGFloat)] {
        { _ in
            let y = height / 2
            return stride(from: 0.0, to: pad + 4, by: 0.25).map { ($0, y) }
        }
    }

    /// Varre uma coluna vertical da beira do palco até pouco depois da borda de
    /// cima do controle, numa coluna `x` que cai dentro dele.
    ///
    /// Existe porque a borda **esquerda** do grupo de botões não é medível: o
    /// primeiro item do grupo desenha a própria divisória `leading` na mesma
    /// coluna, e as duas se somam. Medida ali, a sonda dava 216 com o código
    /// **quebrado** — passava no teste sem provar nada, porque o que ela lia era
    /// a divisória cheia por cima da borda lavada. Em cima não há divisória de
    /// item, nem sombra (a do design cai só para baixo, `y: 1`), nem texto.
    static func topBorderScan(x: CGFloat) -> (CGFloat) -> [(CGFloat, CGFloat)] {
        { _ in stride(from: 0.0, to: pad + 4, by: 0.25).map { (x, $0) } }
    }

    static let probes: [Probe] = [
        // Windows/ChromeButton.swift — o botão do relato, medido em `rgb(227,225,219)`.
        Probe(
            id: "botao-rodape",
            size: CGSize(width: 240, height: 32 + 2 * pad),
            token: \.btnLine,
            scan: leftBorderScan(height: 32 + 2 * pad)
        ),
        // Windows/ComposerToolbar.swift — o botão solo da barra de formatação.
        Probe(
            id: "botao-solo-barra",
            size: CGSize(width: 30 + 2 * pad, height: 26 + 2 * pad),
            token: \.btnLine,
            scan: leftBorderScan(height: 26 + 2 * pad)
        ),
        // Windows/ComposerToolbar.swift — a moldura de um grupo de botões, medida
        // pela borda de cima: ver `topBorderScan`.
        Probe(
            id: "grupo-da-barra",
            size: CGSize(width: 120, height: 26 + 2 * pad),
            token: \.btnLine,
            scan: topBorderScan(x: pad + 14)
        ),
        // Chrome/ThemePicker.swift — o seletor de tema da barra de título.
        Probe(
            id: "seletor-de-tema",
            size: CGSize(width: 160, height: 26 + 2 * pad),
            token: \.btnLine,
            scan: leftBorderScan(height: 26 + 2 * pad)
        ),
        // Support/TokenModifiers.swift — a divisória de rodapé, a que o dono leu
        // como sendo a borda. Varre uma coluna inteira: o palco é liso fora dela.
        //
        // AS DUAS SONDAS DE DIVISÓRIA NÃO PEGAM O DEFEITO, e é de propósito que
        // estejam aqui assim mesmo. Medidas com meio ponto cravado elas acertam
        // o token na bica: o SwiftUI alinha o quadro de um `Rectangle` cheio à
        // grade de pixels, então a divisória já saía com um pixel inteiro mesmo
        // quando o número dizia 0,5. Quem era lavada era só a borda **traçada**,
        // que o `strokeBorder` desenha com alfa parcial em vez de arredondar.
        //
        // É exatamente a assimetria do relato — divisória forte, borda fantasma —
        // e é o que fazia o olho trocar uma pela outra. Aqui elas travam a cor
        // do token; quem prova a espessura são as quatro sondas de borda.
        Probe(
            id: "divisoria-inferior",
            size: CGSize(width: 60 + 2 * pad, height: 20 + 2 * pad),
            token: \.line2,
            scan: { height in
                stride(from: 0.0, to: height, by: 0.25).map { ((60 + 2 * pad) / 2, $0) }
            }
        ),
        // Support/TokenModifiers.swift — a divisória vertical entre painéis, que
        // é a que recua para dentro para nascer num pixel.
        // Inbox/SidebarRail.swift — a borda do botão de pasta **ativo**, o
        // último `.stroke(` do módulo. `stroke` monta o traçado em cima da
        // borda, metade para cada lado: em 1× a borda saía espalhada em
        // `rgb(224,227,231)` + `rgb(219,226,235)`, e nenhum dos dois é o
        // `accentLine` `rgb(207,216,229)` que o token pede. Com `strokeBorder`
        // ela cai dentro da forma e chega no token.
        //
        // A varredura corta a linha média do primeiro botão ("hoje", que é a
        // pasta ativa por padrão): a trilha tem 72 de largura e o botão 46,
        // então a borda esquerda dele está em `pad + 13`; a altura começa no
        // `padding(.vertical, 14)` da trilha e o botão tem 40.
        Probe(
            id: "botao-ativo-da-trilha",
            size: CGSize(width: SidebarRail.width + 2 * pad, height: 240),
            token: \.accentLine,
            scan: { _ in
                stride(from: 0.0, to: pad + 16, by: 0.25).map { ($0, pad + 14 + 20) }
            }
        ),
        Probe(
            id: "divisoria-lateral",
            size: CGSize(width: 60 + 2 * pad, height: 20 + 2 * pad),
            token: \.line,
            scan: { _ in
                stride(from: 0.0, to: 60 + 2 * pad, by: 0.25).map { ($0, (20 + 2 * pad) / 2) }
            }
        ),
    ]

    static func probe(_ id: String) throws -> Probe {
        try #require(probes.first { $0.id == id }, "sonda \(id) sumiu da lista")
    }

    /// O controle de cada sonda, sem palco. O palco é comum e mora em `stage`.
    @ViewBuilder
    static func control(_ id: String, theme: Theme) -> some View {
        switch id {
        case "botao-rodape":
            ChromeButton("Reagendar", appearance: .outlined) {}
        case "botao-solo-barra":
            SoloToolButton(label: "▦", title: "Tabela", on: false) {}
        case "grupo-da-barra":
            SegmentedRow {
                SegmentButton(label: "B", title: "Negrito", on: false) {}
                SegmentButton(label: "I", title: "Itálico", on: false) {}
            }
        case "seletor-de-tema":
            ThemePicker().environment(ThemeStore())
        case "divisoria-inferior":
            Color.clear
                .frame(width: 60, height: 20)
                .hairline(theme.line2, edges: .bottom)
        case "divisoria-lateral":
            Color.clear
                .frame(width: 60, height: 20)
                .hairline(theme.line, edges: .trailing)
        case "botao-ativo-da-trilha":
            // Sem `load()`: as contas não entram, e as quatro pastas — que é
            // o que se mede — não dependem delas. `.today` é a pasta que o
            // store abre, e é a que desenha a borda de acento.
            SidebarRail(store: MailStore(source: InMemoryMailSource.fixtures))
        default:
            EmptyView()
        }
    }

    /// O palco: o controle sobre fundo chapado, encostado no canto superior
    /// esquerdo da folga. Sem isto, "onde a borda começa" não é pergunta de
    /// pixel.
    ///
    /// `.topLeading` é obrigatório, não arrumação: centrado, o controle nasce
    /// numa coluna que depende da largura intrínseca dele, e a varredura teria
    /// de adivinhar onde a borda está. Encostado, ela está sempre em `pad`.
    ///
    /// O fundo vai **por fora** do quadro do tamanho cheio, para pintar o bitmap
    /// inteiro. Um fundo aplicado só ao controle deixa margem transparente, e a
    /// varredura elege o vazio como o pixel mais escuro.
    static func stage<V: View>(_ control: V, theme: Theme, size: CGSize) -> some View {
        control
            .frame(
                width: size.width - 2 * pad,
                height: size.height - 2 * pad,
                alignment: .topLeading
            )
            .padding(pad)
            .frame(width: size.width, height: size.height)
            .background(theme.surface.color)
    }

    static func measure(_ id: String, theme: Theme, scale: CGFloat) throws -> TokenColor {
        let probe = try probe(id)
        let rep = try #require(
            Render.snapshot(
                stage(control(id, theme: theme), theme: theme, size: probe.size),
                named: "hairline-\(id)-\(theme.id)-\(Int(scale))x",
                size: probe.size,
                theme: theme,
                scale: scale
            ),
            "a sonda \(id) não renderizou"
        )
        let pixels = Pixels(rep: rep)
        let scan = probe.scan(probe.size.height).map {
            (min(Int($0.0 * scale), pixels.width - 1), min(Int($0.1 * scale), pixels.height - 1))
        }
        return try #require(
            darkest(pixels, along: scan),
            "a varredura da sonda \(id) não achou um pixel opaco sequer"
        )
    }

    // MARK: - A asserção

    /// Uma sonda acrescentada à lista de descrições mas não à de nomes nunca
    /// seria medida, e a suíte continuaria verde sem olhar para ela.
    @Test("a lista de nomes cobre todas as sondas descritas")
    func probeListMatchesProbes() {
        #expect(Self.probes.map(\.id) == hairlineProbeIDs)
    }

    /// Em 1× é onde o defeito mora: meio ponto vira um pixel pela metade, e a
    /// borda sai lavada. É a tela do dono do projeto.
    @Test("em 1× a borda chega na cor do token", arguments: hairlineProbeIDs)
    func borderReachesTokenAt1x(id: String) throws {
        try check(id: id, scale: 1)
    }

    /// Em 2× meio ponto já era um pixel cheio, então este não pega o defeito
    /// original — ele pega o oposto: a correção não pode ter engordado a linha
    /// para dois pixels numa tela Retina.
    @Test("em 2× a borda chega na cor do token", arguments: hairlineProbeIDs)
    func borderReachesTokenAt2x(id: String) throws {
        try check(id: id, scale: 2)
    }

    private func check(id: String, scale: CGFloat) throws {
        let theme = Theme.tinta
        let probe = try Self.probe(id)
        let expected = theme[keyPath: probe.token]
        let drawn = try Self.measure(id, theme: theme, scale: scale)
        let off = Self.levels(drawn, expected)
        #expect(
            off <= Self.maxLevels,
            """
            \(id) em \(Int(scale))×: a borda mais escura é \(Self.describe(drawn)), \
            e o token é \(Self.describe(expected)) — \(Int(off.rounded())) níveis de \
            diferença. Borda lavada é meio ponto desenhado ao pé da letra; \
            ver `Hairline.thickness(_:)`.
            """
        )
    }

    /// A outra metade do relato: a divisória saía **mais forte** que a borda, e
    /// o olho trocava uma pela outra. Depois da correção as duas pintam o
    /// próprio token, e a ordem volta a ser a do design — `line2` é mais claro
    /// que `btnLine`, então a divisória tem de ficar mais clara que a borda.
    ///
    /// Compara os dois **desenhos**, não os dois tokens: comparar tokens seria
    /// verdadeiro por construção e passaria com qualquer espessura.
    @Test("a divisória não desenha mais forte que a borda do botão")
    func dividerIsLighterThanButtonBorder() throws {
        let theme = Theme.tinta
        let border = try Self.measure("botao-rodape", theme: theme, scale: 1)
        let divider = try Self.measure("divisoria-inferior", theme: theme, scale: 1)

        let borderSum = border.red + border.green + border.blue
        let dividerSum = divider.red + divider.green + divider.blue
        #expect(
            dividerSum > borderSum,
            """
            a divisória \(Self.describe(divider)) desenha mais forte que a borda \
            \(Self.describe(border)) — foi assim que o dono leu uma pela outra.
            """
        )
    }
}

/// **Onde** a divisória cai, não só de que cor ela é.
///
/// A sonda de cor não pega este defeito: ela varre a faixa toda e pergunta pelo
/// pixel mais escuro, que é `--line` esteja ele encostado na borda ou um pixel
/// para dentro. Estes testes perguntam pela coluna exata.
///
/// O defeito: `HairlineModifier` deslocava a faixa de `-thickness` nas bordas de
/// fim, resto da época em que a espessura era meio ponto. Medido em 1× na barra
/// lateral, x=234 era `--line` e x=235 — o último pixel do painel — era
/// `surface2`: a divisória descolava do vizinho, onde o protótipo a encosta.
@Suite("Posição da hairline")
@MainActor
struct HairlinePositionTests {

    typealias Pixels = HairlineThicknessTests.Pixels
    static let pad = HairlineThicknessTests.pad
    static let maxLevels = HairlineThicknessTests.maxLevels

    static let panel = CGSize(width: 60, height: 20)

    /// O painel encostado no canto superior esquerdo da folga, sobre fundo
    /// chapado: assim "o último pixel do painel" é uma coluna sabida —
    /// `pad + largura - 1`.
    static func stage(_ edges: Edge.Set, theme: Theme) -> some View {
        Color.clear
            .frame(width: panel.width, height: panel.height)
            .hairline(theme.line, edges: edges)
            .padding(pad)
            .frame(
                width: panel.width + 2 * pad,
                height: panel.height + 2 * pad,
                alignment: .topLeading
            )
            .background(theme.surface.color)
    }

    static func pixels(_ edges: Edge.Set, named name: String, theme: Theme) throws -> Pixels {
        let size = CGSize(width: panel.width + 2 * pad, height: panel.height + 2 * pad)
        return Pixels(rep: try #require(
            Render.snapshot(stage(edges, theme: theme), named: name, size: size, theme: theme)
        ))
    }

    @Test("a divisória vertical é o último pixel do painel, não o penúltimo")
    func trailingSitsOnTheLastPixel() throws {
        let theme = Theme.tinta
        let pixels = try Self.pixels(.trailing, named: "hairline-pos-trailing", theme: theme)
        let y = Int(Self.pad + Self.panel.height / 2)
        let last = Int(Self.pad + Self.panel.width) - 1

        let onLast = pixels.color(last, y)
        let before = pixels.color(last - 1, y)
        #expect(
            HairlineThicknessTests.levels(onLast, theme.line) <= Self.maxLevels,
            """
            o último pixel do painel (x=\(last)) é \
            \(HairlineThicknessTests.describe(onLast)) e devia ser a divisória \
            \(HairlineThicknessTests.describe(theme.line)) — a faixa está recuada \
            para dentro e descolou do vizinho.
            """
        )
        #expect(
            HairlineThicknessTests.levels(before, theme.surface) <= Self.maxLevels,
            """
            x=\(last - 1) é \(HairlineThicknessTests.describe(before)) — a divisória \
            engordou para dois pixels em vez de andar um para fora.
            """
        )
    }

    @Test("a divisória horizontal é a última linha do painel, não a penúltima")
    func bottomSitsOnTheLastPixel() throws {
        let theme = Theme.tinta
        let pixels = try Self.pixels(.bottom, named: "hairline-pos-bottom", theme: theme)
        let x = Int(Self.pad + Self.panel.width / 2)
        let last = Int(Self.pad + Self.panel.height) - 1

        #expect(
            HairlineThicknessTests.levels(pixels.color(x, last), theme.line) <= Self.maxLevels,
            "a última linha do painel (y=\(last)) não é a divisória"
        )
        #expect(
            HairlineThicknessTests.levels(pixels.color(x, last - 1), theme.surface)
                <= Self.maxLevels,
            "y=\(last - 1) devia continuar sendo o painel"
        )
    }
}

/// O rodapé da barra de pastas era o único traço da tela fora do idioma da
/// hairline: um `Divider()` do sistema, que pinta a cor de separador dele
/// (medido, `rgb(202,199,192)`) onde `--line` é `rgb(224,221,213)` — 22 níveis
/// mais escuro, e o `.background` pedido fica **atrás** do traço em vez de
/// substituí-lo.
@Suite("Divisória do rodapé da barra de pastas")
@MainActor
struct FolderSidebarFooterTests {

    /// Varre de baixo para cima numa coluna que só o fundo e a divisória
    /// ocupam: o rodapé tem `padding(16)`, então em x=8 não há texto nem
    /// bolinha. O primeiro pixel que não é `surface2` subindo do fundo é a
    /// divisória do rodapé.
    @Test("a divisória do rodapé pinta o token da linha, não o separador do sistema")
    func footerDividerUsesTheToken() async throws {
        let theme = Theme.tinta
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let size = CGSize(width: PaneLayout.expandedSidebarWidth, height: 700)
        let pixels = HairlineThicknessTests.Pixels(rep: try #require(
            Render.snapshot(
                FolderSidebar(store: store),
                named: "barra-rodape-divisoria", size: size, theme: theme
            )
        ))

        var found: (y: Int, color: TokenColor)?
        for y in stride(from: pixels.height - 1, through: 0, by: -1) {
            let c = pixels.color(8, y)
            guard c.opacity > 0.99 else { continue }
            if HairlineThicknessTests.levels(c, theme.surface2) > 2 {
                found = (y, c)
                break
            }
        }

        let hit = try #require(found, "nada além do fundo na coluna x=8 — a divisória sumiu")
        #expect(
            HairlineThicknessTests.levels(hit.color, theme.line)
                <= HairlineThicknessTests.maxLevels,
            """
            a divisória do rodapé (y=\(hit.y)) é \
            \(HairlineThicknessTests.describe(hit.color)) e o token `--line` é \
            \(HairlineThicknessTests.describe(theme.line)) — é o `Divider()` do \
            sistema pintando a cor dele.
            """
        )
    }
}
