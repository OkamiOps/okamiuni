import Testing
import SwiftUI
@testable import UNIDesign

@Suite("Theme catalogue")
struct ThemeCatalogueTests {

    @Test("every theme from the design is present")
    func catalogueIsComplete() {
        #expect(Theme.all.count == 26)
    }

    @Test("theme ids are unique")
    func idsAreUnique() {
        let ids = Set(Theme.all.map(\.id))
        #expect(ids.count == Theme.all.count)
    }

    @Test("named() finds every theme and rejects unknown ids")
    func lookupWorks() {
        for theme in Theme.all {
            #expect(Theme.named(theme.id)?.id == theme.id)
        }
        #expect(Theme.named("nao-existe") == nil)
    }

    @Test("the default is the design's default")
    func defaultIsTinta() {
        #expect(Theme.default.id == "tinta")
    }

    @Test("light and dark are classified from the paper colour", arguments: [
        ("tinta", false), ("linho", false), ("papel", false), ("clinico", false),
        ("whitex", false), ("reboot", false), ("corsaluz", false), ("ambar", false),
        ("noite", true), ("grafite", true), ("okami", true), ("neon", true),
        ("blackbox", true), ("contraste", true), ("override", true), ("comando", true),
    ])
    func darknessIsCorrect(id: String, expectedDark: Bool) throws {
        let theme = try #require(Theme.named(id))
        #expect(theme.isDark == expectedDark)
    }

    @Test("every colour component stays in range")
    func colorsInRange() {
        for theme in Theme.all {
            let colors = [
                theme.paper, theme.surface, theme.surface2, theme.surface3,
                theme.ink, theme.ink2, theme.ink3, theme.ink4,
                theme.line, theme.line2,
                theme.accent, theme.accentInk, theme.accentSoft, theme.accentLine,
                theme.onAccent, theme.btn, theme.btnLine,
            ]
            for c in colors {
                #expect((0...1).contains(c.red), "\(theme.id) red out of range")
                #expect((0...1).contains(c.green), "\(theme.id) green out of range")
                #expect((0...1).contains(c.blue), "\(theme.id) blue out of range")
                #expect((0...1).contains(c.opacity), "\(theme.id) opacity out of range")
            }
        }
    }

    @Test("text has usable contrast against its surface")
    func inkContrastsWithSurface() {
        for theme in Theme.all {
            let delta = abs(theme.ink.luminance - theme.surface.luminance)
            #expect(delta > 0.3, "\(theme.id): ink barely separates from surface")
        }
    }

    @Test("metrics are sane")
    func metricsAreSane() {
        for theme in Theme.all {
            #expect(theme.radiusSmall >= 0, "\(theme.id)")
            #expect(theme.radiusLarge >= 0, "\(theme.id)")
            #expect(theme.subjectSize > 8 && theme.subjectSize < 32, "\(theme.id)")
            #expect(theme.rowPadding.top > 0, "\(theme.id)")
            #expect(theme.capsTracking > 0, "\(theme.id)")
        }
    }

    @Test("tinta matches the values in the prototype")
    func tintaIsFaithful() {
        let t = Theme.tinta
        #expect(t.name == "Tinta")
        #expect(t.isDark == false)
        #expect(t.paper == TokenColor(css: "#FFFFFF"))
        #expect(t.surface == TokenColor(css: "#FFFFFF"))
        #expect(t.ink == TokenColor(css: "#222222"))
        #expect(t.accent == TokenColor(css: "#1456F0"))
        #expect(t.radiusSmall == 8)
        #expect(t.radiusLarge == 13)
        #expect(t.subjectSize == 13)
        #expect(t.subjectWeight == .semibold)
        #expect(t.serif.name == "Space Grotesk")
        #expect(t.mono.name == "IBM Plex Mono")
        #expect(t.sans.name == "Inter")
        #expect(t.bodyFont == .sans)
    }

    @Test("shadow layers keep x, y and blur in the right order")
    func shadowOrder() throws {
        let inner = try #require(Theme.tinta.btnShadow.first)
        #expect(inner.x == 0)
        #expect(inner.y == 1)
        #expect(inner.blur == 2)

        #expect(Theme.tinta.shadow.count == 2)
        let drop = Theme.tinta.shadow[0]
        #expect(drop.x == 0)
        #expect(drop.y == 24)
        #expect(drop.blur == 64)

        let hairline = Theme.tinta.shadow[1]
        #expect(hairline.spread == 0.5)
    }

    @Test("okami's oklch accent converts to the expected orange")
    func okamiAccent() throws {
        let okami = try #require(Theme.named("okami"))
        // oklch(72% 0.19 45) -> #FF7527
        #expect(abs(okami.accent.red - 1.0) < 0.01)
        #expect(abs(okami.accent.green - 0.459) < 0.01)
        #expect(abs(okami.accent.blue - 0.153) < 0.01)
    }

    /// A versão anterior deste teste recalculava a própria definição de
    /// `Theme.body` (`bodyFont == .serif ? serif : sans`) e comparava com ela
    /// mesma — verdadeiro por construção, passaria com qualquer família errada.
    /// É o padrão tautológico registrado em `docs/decisoes-de-engenharia.md`.
    ///
    /// A versão que vale trava a família que cada tema realmente usa, extraída
    /// do protótipo. Um erro no gerador de temas cai aqui.
    @Test("cada tema usa a família de corpo que o design manda", arguments: [
        ("tinta", "Inter"), ("linho", "Newsreader"), ("barro", "Newsreader"),
        ("noite", "Newsreader"), ("grafite", "Newsreader"), ("vapor", "Newsreader"),
        ("papel", "Newsreader"), ("aura", "Newsreader"), ("ambar", "Newsreader"),
        ("okami", "Space Grotesk"), ("brutal", "Space Grotesk"), ("neon", "Space Grotesk"),
        ("clinico", "Space Grotesk"), ("nexus", "Space Grotesk"), ("sinal", "Space Grotesk"),
        ("whitex", "Space Grotesk"), ("blackbox", "Space Grotesk"),
        ("brutalnoite", "Space Grotesk"), ("contraste", "Space Grotesk"),
        ("magenta", "Inter"), ("neural", "Inter"), ("corsa", "Inter"),
        ("corsaluz", "Inter"), ("reboot", "Inter"), ("override", "Inter"),
        ("comando", "Inter Tight"),
    ])
    func bodyFamilyMatchesTheDesign(id: String, family: String) throws {
        let theme = try #require(Theme.named(id))
        #expect(theme.body.name == family)
    }

    /// O redesenho usa Inter no tema padrão; os temas alternativos preservam a
    /// tipografia que já tinham.
    @Test("só o tema padrão migra o corpo para sans")
    func onlyDefaultThemeUsesSansForBody() {
        for theme in Theme.all {
            #expect(theme.bodyFont == (theme.id == "tinta" ? .sans : .serif), "\(theme.id)")
        }
    }
}

@Suite("TokenColor parsing")
struct TokenColorTests {

    @Test("parses the hex forms")
    func hexForms() throws {
        #expect(TokenColor(css: "#FFF") == TokenColor(red: 1, green: 1, blue: 1))
        #expect(TokenColor(css: "#000000") == TokenColor(red: 0, green: 0, blue: 0))

        let half = try #require(TokenColor(css: "#FF000080"))
        #expect(half.red == 1)
        #expect(abs(half.opacity - 0.502) < 0.005)
    }

    @Test("parses rgb and rgba")
    func rgbForms() throws {
        let opaque = try #require(TokenColor(css: "rgb(255, 0, 0)"))
        #expect(opaque.red == 1)
        #expect(opaque.opacity == 1)

        let alpha = try #require(TokenColor(css: "rgba(40,38,32,0.24)"))
        #expect(abs(alpha.opacity - 0.24) < 0.001)
    }

    @Test("rejects junk instead of silently returning black", arguments: [
        "", "hotpink", "#GG0000", "#12345", "oklch(72% 0.19 45)",
    ])
    func rejectsJunk(input: String) {
        #expect(TokenColor(css: input) == nil)
    }

    @Test("luminance orders light above dark")
    func luminanceOrders() throws {
        let white = try #require(TokenColor(css: "#FFFFFF"))
        let mid = try #require(TokenColor(css: "#808080"))
        let black = try #require(TokenColor(css: "#000000"))
        #expect(white.luminance > mid.luminance)
        #expect(mid.luminance > black.luminance)
        #expect(abs(white.luminance - 1) < 0.001)
        #expect(abs(black.luminance) < 0.001)
    }
}

@Suite("Sombras inset")
struct InsetShadowTests {

    /// O defeito: o gerador jogava fora a palavra `inset` e emitia a camada
    /// como sombra externa. `.shadow()` do SwiftUI só pinta para fora, então
    /// o brilho interno virava um anel em volta do botão — o "contorno errado"
    /// que apareceu em todos os botões dos temas afetados.
    @Test("os temas que o design manda inset chegam marcados", arguments: [
        "okami", "neon", "sinal", "blackbox", "magenta", "neural", "comando", "override",
    ])
    func insetThemesAreMarked(id: String) throws {
        let theme = try #require(Theme.named(id))
        #expect(theme.btnShadow.contains { $0.isInset },
                "\(id): o design pede inset e o token não marcou")
    }

    @Test("os temas que o design manda sombra externa não vêm marcados", arguments: [
        "tinta", "linho", "barro", "noite", "grafite", "papel", "clinico", "nexus",
        "aura", "whitex", "reboot", "ambar", "vapor",
    ])
    func outerThemesAreNotMarked(id: String) throws {
        let theme = try #require(Theme.named(id))
        #expect(theme.btnShadow.allSatisfy { !$0.isInset },
                "\(id): sombra externa marcada como inset")
    }

    @Test("corsa e corsaluz não têm sombra de botão nenhuma")
    func noneMeansEmpty() throws {
        for id in ["corsa", "corsaluz"] {
            let theme = try #require(Theme.named(id))
            #expect(theme.btnShadow.isEmpty, "\(id)")
        }
    }

    /// `inset 0 1px 0` tem desfoque zero: é uma linha, não um borrão. Se o
    /// gerador voltar a confundir a ordem dos comprimentos, isto acusa.
    @Test("o inset dos temas escuros é uma linha de 1pt sem desfoque")
    func insetGeometry() throws {
        let okami = try #require(Theme.named("okami"))
        let layer = try #require(okami.btnShadow.first { $0.isInset })
        #expect(layer.x == 0)
        #expect(layer.y == 1)
        #expect(layer.blur == 0)
    }
}
