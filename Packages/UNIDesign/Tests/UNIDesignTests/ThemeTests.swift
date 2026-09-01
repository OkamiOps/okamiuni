import Testing
import SwiftUI
import Foundation
@testable import UNIDesign

@Suite("Theme catalogue")
struct ThemeCatalogueTests {

    @Test("os três presets têm escalas ordenadas e padrão neutro")
    func typographyPresetsAreOrdered() {
        #expect(TypographyPreset.allCases == [.compact, .standard, .enlarged])
        #expect(TypographyPreset.compact.scale < TypographyPreset.standard.scale)
        #expect(TypographyPreset.standard.scale == 1)
        #expect(TypographyPreset.enlarged.scale > TypographyPreset.standard.scale)
    }

    @Test("a escala preserva os tokens do tema e atinge as três famílias")
    func applyingTypographyPreservesThemeTokens() {
        let base = Theme.tinta
        let enlarged = base.applyingTypography(.enlarged)

        #expect(enlarged.id == base.id)
        #expect(enlarged.paper == base.paper)
        #expect(enlarged.accent == base.accent)
        #expect(enlarged.subjectSize == base.subjectSize)
        #expect(enlarged.typographyScale == TypographyPreset.enlarged.scale)
        #expect(enlarged.serif.scale == TypographyPreset.enlarged.scale)
        #expect(enlarged.sans.scale == TypographyPreset.enlarged.scale)
        #expect(enlarged.mono.scale == TypographyPreset.enlarged.scale)
        #expect(
            enlarged.applyingTypography(.standard).sans.scale == 1,
            "voltar ao padrão não pode acumular a escala anterior"
        )
    }

    @Test("tema e tamanho do texto persistem de modo independente")
    @MainActor
    func themeAndTypographyPersistIndependently() throws {
        let name = "TypographyPresetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let first = ThemeStore(defaults: defaults)
        first.select(try #require(Theme.named("okami")))
        first.selectTypography(.enlarged)

        let restored = ThemeStore(defaults: defaults)
        #expect(restored.theme.id == "okami")
        #expect(restored.typographyPreset == .enlarged)
        #expect(restored.theme.typographyScale == TypographyPreset.enlarged.scale)

        restored.select(Theme.tinta)
        #expect(restored.typographyPreset == .enlarged)

        restored.selectTypography(.compact)
        #expect(restored.theme.id == "tinta")
    }

    @Test("valor salvo inválido volta ao tamanho padrão")
    @MainActor
    func invalidSavedTypographyFallsBack() throws {
        let name = "TypographyPresetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("gigante-inexistente", forKey: "okamiuni.typography-preset")

        let store = ThemeStore(defaults: defaults)
        #expect(store.typographyPreset == .standard)
        #expect(store.theme.typographyScale == 1)
    }

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

    @Test("todo papel de texto atende contraste AA sobre a superfície")
    func textRolesMeetAAContrast() {
        for theme in Theme.all {
            for (name, color) in [
                ("ink", theme.ink), ("ink2", theme.ink2),
                ("ink3", theme.ink3), ("ink4", theme.ink4),
            ] {
                #expect(
                    color.contrastRatio(with: theme.surface) >= 4.5,
                    "\(theme.id): \(name)/surface abaixo de 4.5:1"
                )
            }
        }
    }

    @Test("ações e texto de destaque mantêm contraste sem depender do tema")
    func accentRolesStayUsable() {
        for theme in Theme.all {
            #expect(
                theme.onAccent.contrastRatio(with: theme.accent) >= 4.5,
                "\(theme.id): onAccent/accent abaixo de 4.5:1"
            )
            #expect(
                theme.accentInk.contrastRatio(with: theme.accentSoft) >= 4.5,
                "\(theme.id): accentInk/accentSoft abaixo de 4.5:1"
            )
            #expect(
                theme.accent.contrastRatio(with: theme.surface) >= 3,
                "\(theme.id): accent/surface abaixo de 3:1 para foco e ícones"
            )
        }
    }

    @Test("temas escuros separam superfícies sem virar uma grade de linhas claras")
    func darkThemesHaveFunctionalHierarchy() {
        let expectedDark = Set([
            "noite", "grafite", "okami", "vapor", "neon", "sinal", "blackbox",
            "magenta", "neural", "corsa", "brutalnoite", "contraste", "comando",
            "override",
        ])
        let darkThemes = Theme.all.filter(\.isDark)
        #expect(Set(darkThemes.map(\.id)) == expectedDark)

        for theme in darkThemes {
            let structuralLine = theme.line.contrastRatio(with: theme.surface)
            let detailLine = theme.line2.contrastRatio(with: theme.surface)
            let buttonLine = theme.btnLine.contrastRatio(with: theme.btn)
            let selectionLine = theme.accentLine.contrastRatio(with: theme.accentSoft)
            let raisedSurface = theme.surface2.contrastRatio(with: theme.surface)
            let panelSurface = theme.surface3.contrastRatio(with: theme.surface)

            // Estes são contratos de conforto visual, não mínimos WCAG. Foco,
            // texto e ícones são validados separadamente; hairlines decorativas
            // precisam orientar sem formar a grade branca vista no app real.
            #expect(
                (1.25 ... 2).contains(structuralLine),
                "\(theme.id): line/surface fora da faixa suave"
            )
            #expect(
                (1.08 ... 1.45).contains(detailLine),
                "\(theme.id): line2/surface fora da faixa de hairline"
            )
            #expect(
                structuralLine >= detailLine + 0.08,
                "\(theme.id): line e line2 perderam a hierarquia"
            )
            #expect(
                (1.35 ... 2.5).contains(buttonLine),
                "\(theme.id): btnLine/btn agressivo ou invisível"
            )
            #expect(
                (1.5 ... 2.5).contains(selectionLine),
                "\(theme.id): accentLine/accentSoft agressivo ou invisível"
            )
            if theme.id == "okami" {
                #expect(
                    (1.0 ... 1.25).contains(raisedSurface),
                    "\(theme.id): surface2/surface perdeu a transição suave"
                )
                #expect(
                    (1.10 ... 1.45).contains(panelSurface),
                    "\(theme.id): surface3/surface perdeu a transição suave"
                )
            } else {
                #expect(
                    (1.08 ... 1.25).contains(raisedSurface),
                    "\(theme.id): surface2/surface perdeu a transição suave"
                )
                #expect(
                    (1.18 ... 1.45).contains(panelSurface),
                    "\(theme.id): surface3/surface perdeu a transição suave"
                )
            }
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

    @Test("tinta mantém o conjunto canônico do tema padrão")
    func tintaMatchesCanonicalTokens() {
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
        // oklch(72% 0.19 45) -> #FF7527  — Heat Orange do design system
        #expect(abs(okami.accent.red - 1.0) < 0.01)
        #expect(abs(okami.accent.green - 0.459) < 0.01)
        #expect(abs(okami.accent.blue - 0.153) < 0.01)
    }

    @Test("okami segue a paleta Onyx/Bone do design system")
    func okamiMatchesDesignSystem() throws {
        let okami = try #require(Theme.named("okami"))
        #expect(okami.paper == TokenColor(css: "#060609")!)
        #expect(okami.surface == TokenColor(css: "#0B0B12")!)
        #expect(okami.surface2 == TokenColor(css: "#08080E")!)
        #expect(okami.surface3 == TokenColor(css: "#1A1A26")!)
        #expect(okami.ink == TokenColor(css: "#E2E3EC")!)
        #expect(okami.ink2 == TokenColor(css: "#B9BAC8")!)
        #expect(okami.ink3 == TokenColor(css: "#8A8B9E")!)
        #expect(okami.ink4 == TokenColor(css: "#7B7C90")!)
        #expect(okami.line == TokenColor(css: "#252636")!)
        #expect(okami.onAccent == TokenColor(css: "#060609")!)
        #expect(okami.mono.name == "JetBrains Mono")
        #expect(okami.sans.name == "Space Grotesk")
        #expect(okami.radiusSmall == 2)
        #expect(okami.capsTracking == 0.18)
        #expect(okami.focus == okami.enter)
        #expect(okami.activity == okami.enter)
        #expect(okami.danger == okami.remove)
        #expect(okami.enter.green > 0.8)
        #expect(okami.enter.blue > 0.8)
        #expect(okami.remove.red > 0.9)
        #expect(okami.remove.blue > 0.7)
        #expect(okami.focus != okami.accent)
        #expect(okami.link == okami.enter)
        #expect(okami.live == okami.enter)
        #expect(okami.infoSoft != okami.accentSoft)
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

@Suite("Semantic status colours")
struct SemanticStatusColorTests {

    @Test("os papéis de status se adaptam entre temas claros e escuros")
    func statusColorsAdaptToThemeAppearance() {
        let light = Theme.tinta
        let dark = Theme.noite

        #expect(light.isDark == false)
        #expect(dark.isDark == true)
        #expect(light.danger != dark.danger)
        #expect(light.success != dark.success)
        #expect(light.warning != dark.warning)
        #expect(light.info != dark.info)
        #expect(light.enter != dark.enter)
        #expect(light.remove != dark.remove)
    }

    @Test("os papéis de status têm contraste AA sobre papel e superfície")
    func statusColorsMeetAAContrastOnThemeSurfaces() {
        let roles: [(name: String, color: KeyPath<Theme, TokenColor>)] = [
            ("danger", \.danger),
            ("success", \.success),
            ("warning", \.warning),
            ("info", \.info),
        ]

        for theme in Theme.all {
            for role in roles {
                let status = theme[keyPath: role.color]
                for (name, background) in [("paper", theme.paper), ("surface", theme.surface)] {
                    #expect(
                        status.contrastRatio(with: background) >= 4.5,
                        "\(theme.id) \(role.name) on \(name) must meet AA text contrast"
                    )
                }
            }
        }
    }

    @Test("ciano do Entrar e magenta do Remover contrastam com a tinta de cima")
    func enterAndRemoveMeetAAOnTheirFill() {
        for theme in Theme.all {
            #expect(
                theme.onEnter.contrastRatio(with: theme.enter) >= 4.5,
                "\(theme.id) onEnter on enter"
            )
            #expect(
                theme.onRemove.contrastRatio(with: theme.remove) >= 4.5,
                "\(theme.id) onRemove on remove"
            )
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

    @Test("pastel contra branco ganha contraste ao escurecer")
    func pastelGainsContrastOnWhite() throws {
        let pastel = try #require(TokenColor(css: "#A4C2F4"))
        let white = try #require(TokenColor(css: "#FFFFFF"))
        #expect(pastel.contrastRatio(with: white) < 4.5)
        let ink = pastel.ensuringContrast(against: white)
        #expect(ink.contrastRatio(with: white) >= 4.5)
        #expect(ink.luminance < pastel.luminance)
    }

    @Test("mistura 0 é a origem, 1 é o destino")
    func mixingEnds() throws {
        let red = try #require(TokenColor(css: "#FF0000"))
        let blue = try #require(TokenColor(css: "#0000FF"))
        #expect(red.mixing(with: blue, amount: 0) == red)
        #expect(red.mixing(with: blue, amount: 1) == blue)
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

    @Test("a razão WCAG usa a fórmula de luminância relativa")
    func contrastRatioUsesWCAGFormula() throws {
        let white = try #require(TokenColor(css: "#FFFFFF"))
        let black = try #require(TokenColor(css: "#000000"))
        #expect(abs(white.contrastRatio(with: black) - 21) < 0.001)
        #expect(white.contrastRatio(with: white) == 1)
        #expect(black.contrastRatio(with: white) == white.contrastRatio(with: black))
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
