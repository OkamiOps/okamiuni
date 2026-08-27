import Foundation
import Testing
@testable import UNICore

/// As três decisões que deixaram de ser "escolha entre seis": as fontes do
/// sistema, a cor livre e a assinatura por conta. Todas puras, todas fora de
/// qualquer `View`, todas chamadas aqui direto.
@Suite("Catálogo de fontes")
struct FontCatalogTests {

    /// A lista de mentira tem, de propósito, uma de cada armadilha: uma família
    /// oculta do sistema, uma que já está entre as seis do design, uma que só
    /// difere por caixa, e três fora de ordem.
    private static let sample = [
        "Zapfino", ".AppleSystemUIFont", "Arial", "georgia", "Avenir",
        ".SF NS", "Helvetica", "Menlo",
    ]

    @Test("as seis do protótipo são as do design, na ordem dele")
    func designList() {
        #expect(FontCatalog.design.map(\.value) == [
            "Newsreader", "-apple-system", "Space Grotesk",
            "Georgia", "Helvetica", "JetBrains Mono",
        ])
        // O rótulo diverge do valor só nesta: `-apple-system` é token de CSS.
        #expect(FontCatalog.design.first { $0.value == "-apple-system" }?.label == "SF Pro")
    }

    @Test("as famílias ocultas do sistema não entram na lista")
    func hiddenFamiliesAreDropped() {
        let installed = FontCatalog.installed(from: Self.sample)
        #expect(!installed.contains { $0.value.hasPrefix(".") })
        #expect(!installed.map(\.value).contains(".AppleSystemUIFont"))
        #expect(!installed.map(\.value).contains(".SF NS"))
    }

    @Test("uma família que já está entre as seis do design não aparece duas vezes")
    func designFamiliesAreNotRepeated() {
        let installed = FontCatalog.installed(from: Self.sample).map(\.value)
        #expect(!installed.contains("Helvetica"))
        // E a comparação ignora caixa: "georgia" instalada é a "Georgia" do
        // design. Sem isso a lista mostraria as duas e elas pareceriam fontes
        // diferentes.
        #expect(!installed.contains("georgia"))
    }

    @Test("a ordem é alfabética de gente, não a que o sistema devolveu")
    func alphabeticalOrder() {
        #expect(FontCatalog.installed(from: Self.sample).map(\.value)
                == ["Arial", "Avenir", "Menlo", "Zapfino"])
    }

    @Test("o controle fechado escreve o rótulo do design, não o token do CSS")
    func closedControlLabel() {
        #expect(FontCatalog.label(for: "-apple-system") == "SF Pro")
        #expect(FontCatalog.label(for: "Newsreader") == "Newsreader")
        // Uma instalada qualquer é o próprio nome — inclusive uma que o design
        // não conhece, que é o caso novo desta tarefa.
        #expect(FontCatalog.label(for: "Zapfino") == "Zapfino")
    }

    @Test("os sete corpos são os do protótipo")
    func sizes() {
        #expect(FontCatalog.sizes == [11, 13, 15, 17, 20, 24, 32])
    }
}

@Suite("Cor livre")
struct ColorHexTests {

    @Test("componentes viram #RRGGBB em maiúsculas, como os tokens do design")
    func formatsHex() {
        #expect(ColorHex.string(red: 0, green: 0, blue: 0) == "#000000")
        #expect(ColorHex.string(red: 1, green: 1, blue: 1) == "#FFFFFF")
        // O terracota do design, de volta ao texto de onde veio. Os
        // componentes são os bytes de `#B4562A` divididos por 255 — a mesma
        // conta que `TokenColor(css:)` faz do outro lado.
        #expect(
            ColorHex.string(red: 180 / 255, green: 86 / 255, blue: 42 / 255) == "#B4562A"
        )
    }

    /// O `NSColorPanel` devolve componentes fora de 0…1 quando a cor vem de um
    /// espaço mais largo que o sRGB. Sem grampear, `Int(1.09 * 255)` daria 277
    /// e o `%02X` escreveria `#115...`, uma cor que ninguém escolheu.
    @Test("componente fora da faixa é grampeado, não estourado")
    func clampsOutOfRange() {
        #expect(ColorHex.string(red: 1.09, green: -0.2, blue: 0.5) == "#FF0080")
        #expect(ColorHex.string(red: .nan, green: 0, blue: 0) == "#000000")
    }

    @Test("uma cor de fora da paleta é reconhecida como livre")
    func recognisesCustomColor() {
        let palette = ["#241F18", "#B4562A", "#8E2020"]
        #expect(ColorHex.isCustom("#123456", among: palette))
        #expect(!ColorHex.isCustom("#B4562A", among: palette))
        // Caixa não decide: o painel devolve maiúsculas e o design escreve
        // maiúsculas, mas um rascunho antigo pode ter minúsculas.
        #expect(!ColorHex.isCustom("#b4562a", among: palette))
        // "Sem realce" não é cor livre — é ausência de realce.
        #expect(!ColorHex.isCustom(BodyStyle.noHighlight, among: palette))
    }
}

@Suite("Assinatura por conta")
struct SignatureTests {

    @Test("cada conta traz a sua, e nenhuma vem vazia nas fixtures")
    func fixturesCarrySignatures() {
        #expect(Fixtures.accounts.allSatisfy { !$0.signature.isEmpty })
        // Duas contas diferentes assinam diferente — é o que a legenda da tela
        // 06 promete. Um teste de "não está vazio" passaria com as quatro
        // iguais.
        let distinct = Set(Fixtures.accounts.map(\.signature))
        #expect(distinct.count == Fixtures.accounts.count)
    }

    @Test("a assinatura entra no fim, depois de uma linha em branco")
    func appendsAfterBlankLine() {
        var body = AttributedString("Combinado.")
        Signature.insert("Ricardo Alves", into: &body)
        #expect(String(body.characters) == "Combinado.\n\nRicardo Alves")
    }

    @Test("num corpo vazio a assinatura começa na primeira linha")
    func emptyBodyGetsNoSeparator() {
        var body = AttributedString("")
        Signature.insert("Ricardo", into: &body)
        #expect(String(body.characters) == "Ricardo")
    }

    @Test("o espaço em branco do fim sai antes, em vez de somar linhas vazias")
    func trimsTrailingWhitespace() {
        var body = AttributedString("Combinado.\n\n\n   ")
        Signature.insert("Ricardo", into: &body)
        #expect(String(body.characters) == "Combinado.\n\nRicardo")
    }

    @Test("clicar duas vezes não assina duas vezes")
    func doesNotDoubleSign() {
        var body = AttributedString("Combinado.")
        Signature.insert("Ricardo Alves", into: &body)
        let once = String(body.characters)
        Signature.insert("Ricardo Alves", into: &body)
        #expect(String(body.characters) == once)
        #expect(!Signature.canInsert("Ricardo Alves", into: once))
    }

    @Test("conta sem assinatura não insere nada")
    func emptySignatureInsertsNothing() {
        var body = AttributedString("Combinado.")
        Signature.insert("", into: &body)
        Signature.insert("   \n ", into: &body)
        #expect(String(body.characters) == "Combinado.")
        #expect(!Signature.canInsert("", into: "Combinado."))
    }

    /// O trecho novo precisa nascer com estilo, senão a barra lê a assinatura
    /// como "sem família" e o menu de fonte fica em branco quando o cursor
    /// passa por ela.
    @Test("a assinatura nasce com o estilo do fim do corpo, sem herdar realce")
    func inheritsStyleFromTheEnd() {
        var body = AttributedString("Combinado.")
        var big = BodyStyle.default
        big.size = 24
        big.family = "Georgia"
        big.highlightHex = "#FBEFA6"
        body[BodyStyleAttribute.self] = big

        let inherited = Signature.style(endingIn: body)
        #expect(inherited.size == 24)
        #expect(inherited.family == "Georgia")
        #expect(inherited.highlightHex == BodyStyle.noHighlight)

        Signature.insert("Ricardo", into: &body, style: inherited)
        let tail = try? #require(body.runs.last)
        #expect(tail?.attributes[BodyStyleAttribute.self]?.size == 24)
    }

    @Test("o resto do corpo mantém os atributos que tinha")
    func keepsExistingRuns() {
        var body = AttributedString("Negrito")
        var bold = BodyStyle.default
        bold.bold = true
        body[BodyStyleAttribute.self] = bold
        body.append(AttributedString("   "))

        Signature.insert("Ricardo", into: &body)
        #expect(String(body.characters) == "Negrito\n\nRicardo")
        // O corte do espaço em branco não pode reconstruir a partir da String:
        // isso apagaria o negrito do trecho que ficou.
        let first = body.runs.first
        #expect(first?.attributes[BodyStyleAttribute.self]?.bold == true)
    }
}
