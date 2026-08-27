import SwiftUI
import UNICore
import UNIDesign

/// O catálogo da barra de formatação e a **projeção** do modelo em atributos
/// que o SwiftUI entende.
///
/// A fonte de verdade do corpo é `BodyStyle`, em `UNICore`. Aqui só se traduz:
/// `BodyStyle` → `\.font`, `\.foregroundColor`, `\.backgroundColor`,
/// `\.underlineStyle`, `\.strikethroughStyle`.
///
/// A tradução tem de existir porque `Font` do SwiftUI é **opaca**: dá para
/// escrever, não para perguntar se está em negrito. Sem o `BodyStyle` por baixo,
/// a barra nunca conseguiria acender o B ao selecionar um trecho já negrito —
/// e barra que só escreve é meia barra.
///
/// Isto é um `enum` sem `View` em volta de propósito: `View` é `@MainActor`
/// implícito no Swift 6 e lógica pura pendurada nela trapa em teste nonisolated.
enum ComposerFormatting {

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
    static let sizes: [Double] = [11, 13, 15, 17, 20, 24, 32]

    static let textColors: [(hex: String, name: String)] = [
        ("#241F18", "Texto"), ("#B4562A", "Terracota"), ("#8E2020", "Vermelho"),
        ("#2F4B7C", "Azul"), ("#4C6B45", "Verde"), ("#6C6D80", "Cinza"),
    ]

    static let highlights: [(hex: String, name: String)] = [
        ("transparent", "Sem realce"), ("#FBEFA6", "Amarelo"), ("#CFEBD6", "Verde"),
        ("#FBD9CF", "Coral"), ("#D6E3F7", "Azul"), ("#EBDDF7", "Lilás"),
    ]

    /// A família escolhida é do protótipo e pode não estar instalada:
    /// `FontFamily` já cai no sistema sozinha nesse caso.
    static func family(_ name: String, theme: Theme) -> FontFamily {
        switch name {
        case "Newsreader": return theme.serif
        case "-apple-system": return .system
        case "JetBrains Mono": return theme.mono
        default: return FontFamily(name: name, design: .default)
        }
    }

    static func font(for style: BodyStyle, theme: Theme) -> Font {
        let base = family(style.family, theme: theme)
            .font(size: style.size, weight: style.bold ? .bold : .regular)
        return style.italic ? base.italic() : base
    }

    static func color(_ hex: String, theme: Theme) -> Color {
        TokenColor(css: hex)?.color ?? theme.ink.color
    }

    /// `transparent` é ausência de realce, não uma cor — devolve nulo para o
    /// atributo ser **removido** em vez de pintado.
    static func highlight(_ hex: String) -> Color? {
        hex == BodyStyle.noHighlight ? nil : TokenColor(css: hex)?.color
    }

    /// Escreve num contêiner de atributos tudo que o SwiftUI precisa para
    /// desenhar este estilo — inclusive o próprio `BodyStyle`, que é o que
    /// permite ler o estado de volta.
    static func project(_ style: BodyStyle, into container: inout AttributeContainer, theme: Theme) {
        container[BodyStyleAttribute.self] = style
        container.font = font(for: style, theme: theme)
        container.foregroundColor = color(style.colorHex, theme: theme)
        container.backgroundColor = highlight(style.highlightHex)
        container.underlineStyle = style.underline ? .single : nil
        container.strikethroughStyle = style.strike ? .single : nil
    }
}

/// O que um botão da barra pede. A barra não sabe editar texto — ela emite um
/// destes e o composer aplica. Assim a barra é testável sem editor por perto.
enum ComposerCommand: Equatable, Sendable {
    case family(String)
    case size(Double)
    case bold
    case italic
    case underline
    case strike
    case color(String)
    case highlight(String)
    /// Nulo desliga a lista.
    case list(ListKind?)
    case align(AttributedString.TextAlignment)
    /// `+1` recua, `-1` volta.
    case indent(Int)
    case clearFormatting
}

/// O escopo de atributos do corpo do composer.
///
/// Sem isto o `TextEditor` limparia o `BodyStyleAttribute` por não conhecê-lo,
/// e o modelo se perderia no primeiro caractere digitado.
extension AttributeScopes {
    struct UNIComposerAttributes: AttributeScope {
        let bodyStyle: BodyStyleAttribute
        let swiftUI: AttributeScopes.SwiftUIAttributes
    }
}
