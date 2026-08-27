import SwiftUI
import UNIDesign

/// O estado da barra de formatação. No Marco 1 o corpo da mensagem é texto
/// simples: família e corpo chegam ao editor, o resto acende o botão e para aí.
/// O protótipo faz `document.execCommand` num `contentEditable`, que não tem
/// equivalente direto no `TextEditor` — quando o corpo virar `AttributedString`
/// editável, é este struct que ganha o resto.
struct ComposerFormatting: Equatable {
    /// Protótipo: `FMT_DEFAULTS`.
    var fontName: String = "Newsreader"
    var size: CGFloat = 15
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var list: ListKind?
    var align: TextAlignment = .leading
    var colorHex: String = "#241F18"
    var highlightHex: String = "transparent"

    enum ListKind: Equatable { case bulleted, numbered }

    /// Protótipo: `FONT_VALUES`, com os rótulos que o `<select>` mostra.
    static let families: [(value: String, label: String)] = [
        ("Newsreader", "Newsreader"),
        ("-apple-system", "SF Pro"),
        ("Space Grotesk", "Space Grotesk"),
        ("Georgia", "Georgia"),
        ("Helvetica", "Helvetica"),
        ("JetBrains Mono", "JetBrains Mono"),
    ]

    /// Protótipo: as sete opções de `SIZE_MAP`.
    static let sizes: [CGFloat] = [11, 13, 15, 17, 20, 24, 32]

    static let textColors: [(hex: String, name: String)] = [
        ("#241F18", "Texto"), ("#B4562A", "Terracota"), ("#8E2020", "Vermelho"),
        ("#2F4B7C", "Azul"), ("#4C6B45", "Verde"), ("#6C6D80", "Cinza"),
    ]

    static let highlights: [(hex: String, name: String)] = [
        ("transparent", "Sem realce"), ("#FBEFA6", "Amarelo"), ("#CFEBD6", "Verde"),
        ("#FBD9CF", "Coral"), ("#D6E3F7", "Azul"), ("#EBDDF7", "Lilás"),
    ]

    /// A fonte que o editor usa. A família escolhida é do protótipo e pode não
    /// estar instalada: `FontFamily` já cai no sistema sozinha nesse caso.
    func editorFont(theme: Theme) -> Font {
        let family: FontFamily
        switch fontName {
        case "Newsreader": family = theme.serif
        case "-apple-system": family = .system
        case "JetBrains Mono": family = theme.mono
        default: family = FontFamily(name: fontName, design: .default)
        }
        return family.font(size: size, weight: bold ? .bold : .regular)
    }
}
