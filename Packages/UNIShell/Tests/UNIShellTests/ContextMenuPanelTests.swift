import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O painel de menu de contexto, medido em pixel.
///
/// ## O defeito que estes testes travam
///
/// Até a Task AN o menu de contexto era o `contextMenu` do SwiftUI, quer dizer,
/// um `NSMenu`: fundo cinza do sistema, realce **rosa** do sistema, tipografia
/// do sistema. O dono do projeto mandou o print — "as actions estão usando
/// ainda o padrao do sistema ao invés de custom" — em cima de uma interface que
/// desenha todos os dropdowns dela.
///
/// Um `NSMenu` não aparece em renderização fora da tela (o `Render` desenha
/// numa janela que nunca é a janela-chave), então não dá para medir "o menu
/// aberto". O que dá, e é o que muda quando o desenho volta a ser do sistema, é
/// medir **o painel que o app desenha**: se ele deixar de existir, ou deixar de
/// sair dos tokens, cada uma destas medidas cai.
///
/// ## Por que quase tudo é medido em `tinta`
///
/// A tolerância de 0,02 por canal é a da suíte inteira, e em `noite` os tokens
/// escuros caem uns dentro dos outros: `accentSoft` (42,35,24) e `line2`
/// (42,37,30) diferem 6 níveis no canal mais divergente. Contar pixels por
/// token ali mediria uma coisa pelo nome da outra. Onde a medida é **relativa**
/// — o apagado do item desabilitado, que compara dois desenhos do mesmo
/// palco — ela roda nos dois temas, porque aí a tolerância não entra.
@Suite("O painel do menu de contexto é desenhado por nós")
@MainActor
struct ContextMenuPanelTests {

    /// Folga em volta do painel. Larga porque a sombra do tema desenha para
    /// fora do painel e não pode encostar na beira do bitmap.
    static let pad: CGFloat = 24

    /// Um menu curto e completo: item com atalho, traço, submenu.
    static let entries: [ContextMenuEntry] = [
        .item(ContextMenuItem("Abrir em janela", .openMessageWindow(messageID: "m1"))),
        .item(ContextMenuItem("Responder", .reply(messageID: "m1"), shortcut: .reply)),
        .separator,
        .submenu(title: "Mover para", items: [
            ContextMenuItem("Depois", .move(messageID: "m1", to: .later))
        ]),
    ]

    /// O palco: o painel encostado no canto superior esquerdo da folga, sobre
    /// `paper` — que é o fundo do app atrás de um menu aberto, e é um token
    /// distinto de `surface` em todos os temas.
    ///
    /// Encostado, e não centrado, pelo mesmo motivo de `HairlineThicknessTests`:
    /// assim "onde a borda começa" é `pad`, e não uma conta que depende da
    /// largura intrínseca do painel.
    static func stage(
        _ entries: [ContextMenuEntry],
        highlighted: Int? = nil,
        theme: Theme,
        size: CGSize
    ) -> some View {
        let level = MenuLevel(entries: entries, highlighted: highlighted)
        return ContextMenuPanel(level: level)
            .frame(
                width: size.width - 2 * pad,
                height: size.height - 2 * pad,
                alignment: .topLeading
            )
            .padding(pad)
            .frame(width: size.width, height: size.height)
            .background(theme.paper.color)
    }

    static let size = CGSize(width: 176 + 2 * pad, height: 160 + 2 * pad)

    static func render(
        _ entries: [ContextMenuEntry],
        highlighted: Int? = nil,
        theme: Theme,
        named: String
    ) throws -> NSBitmapImageRep {
        try #require(
            Render.snapshot(
                stage(entries, highlighted: highlighted, theme: theme, size: size),
                named: named, size: size, theme: theme
            ),
            "o painel \(named) não renderizou"
        )
    }

    // MARK: - Fundo e borda

    /// O painel é chapado no token `surface`, como o do seletor de tema do
    /// protótipo. Um `NSMenu` pinta o cinza translúcido do sistema, e nenhum
    /// pixel dele cai no token.
    ///
    /// A medida é a **fração** do miolo que está no token, e não um pixel a
    /// dedo: fração não depende de onde o texto caiu.
    @Test("o fundo do painel é o token do tema, não o cinza do sistema")
    func backgroundIsTheToken() throws {
        let theme = Theme.tinta
        let rep = try Self.render(Self.entries, theme: theme, named: "menu-painel-fundo")

        let inside = Self.interior(90)
        let hit = Self.count(rep, matching: theme.surface, in: inside)
        let fraction = Double(hit) / Double(inside.x.count * inside.y.count)
        #expect(fraction > 0.8, "só \(fraction) do painel está em `surface`")
    }

    /// A borda é `line`, num pixel do dispositivo, `strokeBorder` — nunca
    /// `.stroke`, que sai lavado em 1×. A coluna medida é a da borda esquerda,
    /// abaixo do canto arredondado.
    @Test("a borda do painel chega no token, em 1× e em 2×", arguments: [
        ("tinta", 1.0), ("tinta", 2.0), ("noite", 1.0), ("noite", 2.0),
    ])
    func borderReachesTheToken(themeID: String, scale: CGFloat) throws {
        let theme = try #require(Theme.all.first { $0.id == themeID })
        let rep = try #require(
            Render.snapshot(
                Self.stage(Self.entries, theme: theme, size: Self.size),
                named: "menu-painel-borda-\(themeID)-\(Int(scale))x",
                size: Self.size, theme: theme, scale: scale
            )
        )
        let pixels = HairlineThicknessTests.Pixels(rep: rep)
        let column = Int(Self.pad * scale)
        // Bem abaixo do canto: `radiusLarge` não passa de 14 em tema nenhum.
        let scan = stride(from: (Self.pad + 20) * scale, to: (Self.pad + 60) * scale, by: 1)
            .map { (column, Int($0)) }
        let drawn = try #require(
            HairlineThicknessTests.darkest(pixels, along: scan),
            "não sobrou pixel opaco na coluna da borda"
        )
        // Em tema escuro a borda é mais **clara** que o fundo; o que a coluna
        // tem, escura ou clara, é só a borda — nada mais é desenhado em x=pad.
        let distance = HairlineThicknessTests.levels(drawn, theme.line)
        let saw = HairlineThicknessTests.describe(drawn)
        let want = HairlineThicknessTests.describe(theme.line)
        #expect(
            distance < HairlineThicknessTests.maxLevels,
            "a borda saiu \(saw) e o token `line` é \(want)"
        )
    }

    // MARK: - Realce

    /// O realce da linha sob o ponteiro é `accentSoft` — o mesmo do painel do
    /// `ComposerSelect`, que é o idioma aprovado. O `NSMenu` pinta o realce do
    /// sistema, que não é token nenhum.
    @Test("a linha realçada pinta o acento do tema")
    func highlightUsesTheAccent() throws {
        let theme = Theme.tinta
        let cold = try Self.render(Self.entries, theme: theme, named: "menu-painel-frio")
        let hot = try Self.render(
            Self.entries, highlighted: 1, theme: theme, named: "menu-painel-realce"
        )

        let coldPixels = Self.count(cold, matching: theme.accentSoft, in: Self.interior(90))
        let hotPixels = Self.count(hot, matching: theme.accentSoft, in: Self.interior(90))
        #expect(coldPixels < 50, "sem ponteiro o painel já tinha \(coldPixels) de acento")
        #expect(
            hotPixels > 1500,
            "a linha realçada pintou só \(hotPixels) pixels em `accentSoft`"
        )

        // E a tinta do rótulo realçado vira `accentInk`. Sem isto, um realce
        // que só mudasse o fundo passaria pela metade.
        #expect(
            Self.count(hot, matching: theme.accentInk, in: Self.interior(90))
                > Self.count(cold, matching: theme.accentInk, in: Self.interior(90))
        )
    }

    /// Item apagado não recebe realce nem quando é ele o índice realçado — é o
    /// que `.disabled` e a guarda do `onHover` garantem.
    @Test("item apagado não acende")
    func disabledNeverHighlights() throws {
        let theme = Theme.tinta
        let entries: [ContextMenuEntry] = [
            .item(ContextMenuItem("Apagado", .copy("x"), isEnabled: false))
        ]
        let rep = try Self.render(
            entries, highlighted: 0, theme: theme, named: "menu-painel-apagado-realce"
        )
        #expect(Self.count(rep, matching: theme.accentSoft, in: Self.interior(30)) < 50)
    }

    // MARK: - Item desabilitado

    /// O rótulo apagado é `ink4`; o normal é `ink`. A medida é **relativa** —
    /// o mesmo palco desenhado duas vezes, com e sem o estado —, então ela vale
    /// em tema claro e escuro sem depender de qual token é o mais escuro.
    @Test("o item desabilitado desenha apagado", arguments: ["tinta", "noite"])
    func disabledIsFaded(themeID: String) throws {
        let theme = try #require(Theme.all.first { $0.id == themeID })
        let live = try Self.render(
            [.item(ContextMenuItem("Arquivar", .copy("x")))],
            theme: theme, named: "menu-item-vivo-\(themeID)"
        )
        let dead = try Self.render(
            [.item(ContextMenuItem("Arquivar", .copy("x"), isEnabled: false))],
            theme: theme, named: "menu-item-apagado-\(themeID)"
        )
        let liveInk = try #require(Self.extreme(live, against: theme.surface))
        let deadInk = try #require(Self.extreme(dead, against: theme.surface))

        // Os dois lados são afirmados contra o **token**, e não um contra o
        // outro. A diferença importa e foi medida: com `.disabled` no lugar de
        // `allowsHitTesting`, a opacidade que o SwiftUI aplica sozinho apagava
        // o rótulo o bastante para uma comparação relativa passar mesmo com a
        // tinta `ink4` arrancada do código. Ver a nota em `ContextMenuPanel`.
        let sawLive = HairlineThicknessTests.describe(liveInk)
        let sawDead = HairlineThicknessTests.describe(deadInk)
        let wantDead = HairlineThicknessTests.describe(theme.ink4)
        #expect(
            HairlineThicknessTests.levels(liveInk, theme.ink) < Self.inkLevels,
            "o rótulo vivo saiu \(sawLive), e `ink` é \(HairlineThicknessTests.describe(theme.ink))"
        )
        #expect(
            HairlineThicknessTests.levels(deadInk, theme.ink4) < Self.inkLevels,
            "o rótulo apagado saiu \(sawDead), e `ink4` é \(wantDead)"
        )
    }

    /// Quanto a tinta desenhada de um rótulo pode se afastar do token.
    ///
    /// Mais folgado que o das bordas (8) porque um glifo de 12,5pt é
    /// suavizado: nem o pixel mais cheio de uma haste chega ao valor puro. O
    /// que ele **não** faz é chegar perto do token errado — `ink` e `ink4`
    /// estão a 139 níveis um do outro em `tinta` e a 133 em `noite`.
    static let inkLevels = 24.0

    /// O miolo do painel: dois pontos para dentro da borda de cada lado, e só
    /// até onde o painel dos menus medidos aqui chega em altura.
    ///
    /// A janela importa. Fora do painel o palco é `paper` **com a sombra do
    /// tema por cima**, e em `tinta` esse degradê passa exatamente por
    /// `line2` (235,232,226): contando o bitmap inteiro, um painel **sem**
    /// separador nenhum acusava 4.454 pixels de divisória. Medida fora da
    /// janela certa, a prova do separador media a sombra.
    /// `height` é quanto do painel entra na conta, em pontos, contados do topo
    /// dele. Cada chamada passa uma altura que cabe **dentro** do painel que
    /// desenhou — um menu de duas linhas mede menos que um de quatro, e medir
    /// além do rodapé traz a sombra de volta para dentro da amostra.
    static func interior(_ height: Int) -> (x: Range<Int>, y: Range<Int>) {
        (x: Int(pad) + 2..<Int(pad) + 174, y: Int(pad) + 2..<Int(pad) + height)
    }

    static func count(
        _ rep: NSBitmapImageRep,
        matching token: TokenColor,
        in region: (x: Range<Int>, y: Range<Int>)
    ) -> Int {
        var hit = 0
        for y in region.y {
            for x in region.x {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - token.red) < 0.02,
                   abs(c.greenComponent - token.green) < 0.02,
                   abs(c.blueComponent - token.blue) < 0.02 {
                    hit += 1
                }
            }
        }
        return hit
    }

    /// O pixel do painel que **mais** se afasta do fundo — o miolo de uma
    /// haste do rótulo. É a tinta desenhada, medida sem cravar onde a letra
    /// caiu.
    static func extreme(_ rep: NSBitmapImageRep, against surface: TokenColor) -> TokenColor? {
        let pixels = HairlineThicknessTests.Pixels(rep: rep)
        var best: TokenColor?
        var bestDistance = 0.0
        for y in Int(pad) + 2..<Int(pad) + 30 {
            for x in Int(pad) + 2..<Int(pad) + 174 {
                let c = pixels.color(x, y)
                guard c.opacity > 0.99, c.red >= 0 else { continue }
                let distance = HairlineThicknessTests.levels(c, surface)
                if distance > bestDistance {
                    bestDistance = distance
                    best = c
                }
            }
        }
        return best
    }

    // MARK: - Separador

    /// `ContextMenuEntry.separator` desenha a divisória em `line2`, o mesmo
    /// traço do painel do `ComposerSelect` — e não o traço do sistema.
    @Test("o separador é a divisória em hairline do design")
    func separatorIsAHairline() throws {
        let theme = Theme.tinta
        let withRule = try Self.render(
            [.item(ContextMenuItem("A", .copy("a"))),
             .separator,
             .item(ContextMenuItem("B", .copy("b")))],
            theme: theme, named: "menu-separador"
        )
        let without = try Self.render(
            [.item(ContextMenuItem("A", .copy("a"))),
             .item(ContextMenuItem("B", .copy("b")))],
            theme: theme, named: "menu-sem-separador"
        )
        #expect(Self.count(withRule, matching: theme.line2, in: Self.interior(50)) > 100)
        #expect(Self.count(without, matching: theme.line2, in: Self.interior(50)) < 20)
    }

    // MARK: - O menu de verdade

    /// O painel montado com o menu que a linha de mensagem realmente abre.
    /// Renderizar não prova rótulo — a leitura é humana, no PNG —, mas prova
    /// que a lista inteira desenha sem estourar e sem sumir.
    @Test("o menu da linha de mensagem desenha inteiro")
    func realMenuDraws() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first)
        let entries = ContextMenus.messageRow(message)
        let rep = try Self.render(
            entries, highlighted: 0, theme: .tinta, named: "menu-linha-mensagem"
        )
        #expect(Self.count(rep, matching: Theme.tinta.surface, in: Self.interior(90)) > 5000)
        #expect(Self.count(rep, matching: Theme.tinta.accentSoft, in: Self.interior(90)) > 1500)
    }
}
