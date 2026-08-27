import Foundation
import Testing
@testable import UNICore

/// Helpers de índice. Os testes falam em posições de caractere porque é assim
/// que a seleção do usuário se descreve ("da 6ª à 12ª letra"), e converter aqui
/// deixa a asserção legível.
private func range(_ text: AttributedString, _ from: Int, _ to: Int) -> Range<AttributedString.Index> {
    let chars = text.characters
    let lower = chars.index(chars.startIndex, offsetBy: from)
    let upper = chars.index(chars.startIndex, offsetBy: to)
    return lower..<upper
}

private func cursor(_ text: AttributedString, _ at: Int) -> Range<AttributedString.Index> {
    let index = text.characters.index(text.characters.startIndex, offsetBy: at)
    return index..<index
}

/// O estilo caractere a caractere, para a asserção poder travar exatamente
/// quais letras mudaram.
private func bolds(_ text: AttributedString) -> [Bool] {
    var result: [Bool] = []
    let chars = text.characters
    var index = chars.startIndex
    while index < chars.endIndex {
        let next = chars.index(after: index)
        result.append(text[index..<next].runs.first?.attributes[BodyStyleAttribute.self]?.bold ?? false)
        index = next
    }
    return result
}

private func sizes(_ text: AttributedString) -> [Double] {
    var result: [Double] = []
    let chars = text.characters
    var index = chars.startIndex
    while index < chars.endIndex {
        let next = chars.index(after: index)
        result.append(
            text[index..<next].runs.first?.attributes[BodyStyleAttribute.self]?.size
                ?? BodyStyle.defaultSize
        )
        index = next
    }
    return result
}

@Suite("Corpo formatado — o estilo pega só na seleção")
struct RichBodyStyleTests {

    @Test("negrito num intervalo do meio não encosta no resto")
    func boldStaysInsideTheRange() {
        var text = AttributedString("Marina fechado quinta")
        //                           0123456789...
        RichBody.restyle(&text, over: [range(text, 7, 14)]) { $0.bold = true }

        // "Marina " → 7 falsos; "fechado" → 7 verdadeiros; " quinta" → 7 falsos.
        #expect(bolds(text) == Array(repeating: false, count: 7)
                + Array(repeating: true, count: 7)
                + Array(repeating: false, count: 7))
        #expect(String(text.characters) == "Marina fechado quinta")
    }

    @Test("tamanho num intervalo do meio não encosta no resto")
    func sizeStaysInsideTheRange() {
        var text = AttributedString("Marina fechado quinta")
        RichBody.restyle(&text, over: [range(text, 7, 14)]) { $0.size = 24 }

        #expect(sizes(text) == Array(repeating: 15.0, count: 7)
                + Array(repeating: 24.0, count: 7)
                + Array(repeating: 15.0, count: 7))
    }

    @Test("duas formatações em intervalos diferentes convivem")
    func twoRangesKeepTheirOwnStyle() {
        var text = AttributedString("um dois tres")
        RichBody.restyle(&text, over: [range(text, 0, 2)]) { $0.bold = true }
        RichBody.restyle(&text, over: [range(text, 3, 7)]) { $0.italic = true }

        let styles = (0..<12).map { index -> BodyStyle in
            RichBody.style(of: text[range(text, index, index + 1)].runs.first!.attributes)
        }
        #expect(styles.map(\.bold) == [true, true] + Array(repeating: false, count: 10))
        #expect(styles.map(\.italic)
                == [false, false, false, true, true, true, true] + Array(repeating: false, count: 5))
    }

    @Test("intervalo vazio não reescreve nada")
    func emptyRangeDoesNothing() {
        var text = AttributedString("Marina")
        RichBody.restyle(&text, over: [cursor(text, 3)]) { $0.bold = true }
        #expect(bolds(text) == Array(repeating: false, count: 6))
    }

    @Test("limpar formatação devolve o intervalo ao padrão e o resto fica")
    func clearOnlyTheRange() {
        var text = AttributedString("um dois tres")
        RichBody.restyle(&text, over: [range(text, 0, 12)]) { $0.bold = true; $0.size = 32 }
        RichBody.clearFormatting(&text, over: [range(text, 3, 7)])

        #expect(bolds(text) == [true, true, true, false, false, false, false, true, true, true, true, true])
        #expect(sizes(text) == [32, 32, 32, 15, 15, 15, 15, 32, 32, 32, 32, 32])
    }
}

@Suite("Corpo formatado — a barra lê o que a seleção tem")
struct RichBodyReadingTests {

    @Test("selecionar um trecho em negrito acende o B")
    func boldSelectionReadsBold() {
        var text = AttributedString("Marina fechado quinta")
        RichBody.restyle(&text, over: [range(text, 7, 14)]) { $0.bold = true }

        #expect(RichBody.reading(of: text, over: [range(text, 7, 14)]).bold)
        #expect(RichBody.reading(of: text, over: [range(text, 0, 7)]).bold == false)
    }

    @Test("seleção meio negrito meio não deixa o B apagado")
    func mixedBoldReadsOff() {
        var text = AttributedString("Marina fechado quinta")
        RichBody.restyle(&text, over: [range(text, 7, 14)]) { $0.bold = true }
        #expect(RichBody.reading(of: text, over: [range(text, 0, 21)]).bold == false)
    }

    @Test("família e corpo saem nulos quando a seleção mistura")
    func mixedFamilyReadsNil() {
        var text = AttributedString("um dois")
        RichBody.restyle(&text, over: [range(text, 0, 2)]) { $0.family = "Georgia"; $0.size = 24 }

        let inside = RichBody.reading(of: text, over: [range(text, 0, 2)])
        #expect(inside.family == "Georgia")
        #expect(inside.size == 24)

        let across = RichBody.reading(of: text, over: [range(text, 0, 7)])
        #expect(across.family == nil)
        #expect(across.size == nil)
    }

    @Test("cor e realce também se leem")
    func colorAndHighlightRead() {
        var text = AttributedString("um dois")
        RichBody.restyle(&text, over: [range(text, 3, 7)]) {
            $0.colorHex = "#8E2020"
            $0.highlightHex = "#FBEFA6"
        }
        let reading = RichBody.reading(of: text, over: [range(text, 3, 7)])
        #expect(reading.colorHex == "#8E2020")
        #expect(reading.highlightHex == "#FBEFA6")
        #expect(RichBody.reading(of: text, over: [range(text, 0, 2)]).highlightHex == BodyStyle.noHighlight)
    }

    @Test("cursor sem seleção lê o estilo do caractere à esquerda")
    func caretInheritsFromTheLeft() {
        var text = AttributedString("Marina fechado")
        RichBody.restyle(&text, over: [range(text, 7, 14)]) { $0.bold = true }

        let inside = RichBody.reading(of: text, over: [cursor(text, 10)])
        #expect(inside.hasSelection == false)
        #expect(inside.bold)

        let before = RichBody.reading(of: text, over: [cursor(text, 3)])
        #expect(before.bold == false)
    }

    @Test("texto vazio lê os padrões do protótipo")
    func emptyTextReadsDefaults() {
        let text = AttributedString("")
        let reading = RichBody.reading(of: text, over: [cursor(text, 0)])
        #expect(reading.family == "Newsreader")
        #expect(reading.size == 15)
        #expect(reading.colorHex == "#241F18")
        #expect(reading.highlightHex == "transparent")
        #expect(reading.alignment == .left)
        #expect(reading.list == nil)
    }
}

@Suite("Corpo formatado — parágrafos, listas e recuo")
struct RichBodyParagraphTests {

    @Test("os parágrafos são os trechos entre quebras, sem a quebra")
    func paragraphSplit() {
        let text = AttributedString("um\ndois\ntres")
        let parts = RichBody.paragraphs(of: text).map { String(text[$0].characters) }
        #expect(parts == ["um", "dois", "tres"])
    }

    @Test("o cursor toca só o parágrafo em que está")
    func caretTouchesOneParagraph() {
        let text = AttributedString("um\ndois\ntres")
        let touched = RichBody.paragraphs(of: text, touchedBy: [cursor(text, 5)])
        #expect(touched.map { String(text[$0].characters) } == ["dois"])
    }

    @Test("alinhar pega o parágrafo tocado e só ele")
    func alignTouchedParagraphOnly() {
        var text = AttributedString("um\ndois\ntres")
        RichBody.align(&text, over: [cursor(text, 5)], to: .center)

        let alignments = RichBody.paragraphs(of: text).map { RichBody.alignment(of: text, at: $0) }
        #expect(alignments == [.left, .center, .left])
        #expect(RichBody.reading(of: text, over: [cursor(text, 5)]).alignment == .center)
        #expect(RichBody.reading(of: text, over: [range(text, 0, 12)]).alignment == nil)
    }

    @Test("lista com marcador entra e sai dos parágrafos tocados")
    func bulletToggles() {
        var text = AttributedString("um\ndois\ntres")
        RichBody.setList(&text, over: [range(text, 0, 7)], to: .bulleted)
        #expect(String(text.characters) == "• um\n• dois\ntres")

        RichBody.setList(&text, over: [range(text, 0, 11)], to: nil)
        #expect(String(text.characters) == "um\ndois\ntres")
    }

    @Test("lista numerada renumera de 1 dentro do bloco")
    func numberedRenumbers() {
        var text = AttributedString("um\ndois\ntres")
        RichBody.setList(&text, over: [range(text, 0, 12)], to: .numbered)
        #expect(String(text.characters) == "1. um\n2. dois\n3. tres")
    }

    @Test("trocar de marcador para número não empilha os dois prefixos")
    func markerSwapDoesNotStack() {
        var text = AttributedString("um\ndois")
        RichBody.setList(&text, over: [range(text, 0, 7)], to: .bulleted)
        RichBody.setList(&text, over: [range(text, 0, 11)], to: .numbered)
        #expect(String(text.characters) == "1. um\n2. dois")
    }

    @Test("a lista se lê de volta, e mistura vira mistura")
    func listReads() {
        var text = AttributedString("um\ndois")
        RichBody.setList(&text, over: [cursor(text, 0)], to: .bulleted)

        #expect(RichBody.reading(of: text, over: [cursor(text, 0)]).list == .bulleted)
        // "• um\ndois" — nove caracteres depois do marcador entrar.
        #expect(String(text.characters).count == 9)
        let across = RichBody.reading(of: text, over: [range(text, 0, 9)])
        #expect(across.list == nil)
        #expect(across.listMixed)
    }

    @Test("recuo entra em quatro espaços e sai igual, sem passar de zero")
    func indentInAndOut() {
        var text = AttributedString("um\ndois")
        RichBody.indent(&text, over: [range(text, 0, 7)], by: 1)
        #expect(String(text.characters) == "    um\n    dois")

        RichBody.indent(&text, over: [range(text, 0, 15)], by: 1)
        #expect(String(text.characters) == "        um\n        dois")

        RichBody.indent(&text, over: [range(text, 0, 23)], by: -1)
        RichBody.indent(&text, over: [range(text, 0, 15)], by: -1)
        RichBody.indent(&text, over: [range(text, 0, 7)], by: -1)
        #expect(String(text.characters) == "um\ndois")
    }

    @Test("recuo preserva o marcador da lista, na ordem recuo-depois-marcador")
    func indentKeepsTheBullet() {
        var text = AttributedString("um")
        RichBody.setList(&text, over: [cursor(text, 0)], to: .bulleted)
        RichBody.indent(&text, over: [cursor(text, 0)], by: 1)
        #expect(String(text.characters) == "    • um")

        let read = RichBody.prefix(of: "    • um")
        #expect(read == RichBody.Prefix(indent: 1, list: .bulleted, length: 6))
    }

    @Test("o estilo do parágrafo passa para o marcador que ele ganha")
    func markerInheritsParagraphStyle() {
        var text = AttributedString("um")
        RichBody.restyle(&text, over: [range(text, 0, 2)]) { $0.bold = true; $0.size = 24 }
        RichBody.setList(&text, over: [cursor(text, 0)], to: .bulleted)

        #expect(String(text.characters) == "• um")
        #expect(bolds(text) == [true, true, true, true])
        #expect(sizes(text) == [24, 24, 24, 24])
    }
}
