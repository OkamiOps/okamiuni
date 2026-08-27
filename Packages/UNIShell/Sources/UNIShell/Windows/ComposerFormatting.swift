import AppKit
import CoreText
import SwiftUI
import UNICore
import UNIDesign
import os

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
    ///
    /// Continuam sendo **a escolha rápida** — o menu as põe no topo, num bloco
    /// separado. O que deixou de existir é a limitação: abaixo delas vêm as
    /// instaladas na máquina. Ver `familyGroups`.
    ///
    /// A lista em si mora em `UNICore`, onde o teste a alcança sem `View` por
    /// perto; aqui fica só a forma antiga do par, que o resto do arquivo usa.
    static let families: [(value: String, label: String)] =
        FontCatalog.design.map { (value: $0.value, label: $0.label) }

    /// Protótipo: as sete opções de `SIZE_MAP`.
    static let sizes: [Double] = FontCatalog.sizes

    /// As famílias instaladas nesta máquina, peneiradas e ordenadas.
    ///
    /// `static let` e não propriedade calculada de propósito:
    /// `availableFontFamilies` enumera o catálogo do sistema inteiro, e o
    /// `body` da barra reavalia a cada leitura da seleção. Calculada, a barra
    /// pagaria essa varredura a cada tecla.
    static let installedFamilies: [FontCatalog.Family] =
        FontCatalog.installed(from: NSFontManager.shared.availableFontFamilies)

    /// Os dois blocos do menu de fonte: as seis do design em cima, um
    /// separador, e as instaladas embaixo.
    ///
    /// **Somar, não trocar.** Uma lista alfabética de trezentas entradas
    /// esconde as seis do design no meio das outras, e escolher a fonte do
    /// design deixaria de ser um gesto para virar uma busca.
    static let familyGroups: [ComposerSelect.Group] = {
        var groups: [ComposerSelect.Group] = [
            ComposerSelect.Group(
                title: "Do design",
                options: FontCatalog.design.map {
                    ComposerSelect.Option(value: $0.value, label: $0.label, previewFamily: $0.value)
                }
            )
        ]
        // Uma máquina sem nenhuma família além das seis do design não ganha um
        // cabeçalho "Instaladas" seguido de nada.
        if !installedFamilies.isEmpty {
            groups.append(
                ComposerSelect.Group(
                    title: "Instaladas",
                    options: installedFamilies.map {
                        ComposerSelect.Option(
                            value: $0.value, label: $0.label, previewFamily: $0.value
                        )
                    }
                )
            )
        }
        return groups
    }()

    /// O único bloco do menu de corpo. Protótipo: os sete de `SIZE_MAP`.
    static let sizeGroups: [ComposerSelect.Group] = [
        ComposerSelect.Group(
            title: nil,
            options: sizes.map {
                ComposerSelect.Option(value: String(Int($0)), label: String(Int($0)))
            }
        )
    ]

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
    ///
    /// A altura de linha entra aqui porque ela depende do **corpo** do trecho,
    /// que é justamente o que este `BodyStyle` diz.
    static func project(_ style: BodyStyle, into container: inout AttributeContainer, theme: Theme) {
        container[BodyStyleAttribute.self] = style
        container[AttributeScopes.CoreTextAttributes.LineHeightAttribute.self] = lineHeight(for: style.size)
        container.font = font(for: style, theme: theme)
        container.foregroundColor = color(style.colorHex, theme: theme)
        container.backgroundColor = highlight(style.highlightHex)
        container.underlineStyle = style.underline ? .single : nil
        container.strikethroughStyle = style.strike ? .single : nil
    }
}

// MARK: - Métrica óptica dos glifos da barra

/// Onde a **tinta** de um glifo está, em relação à linha de base.
///
/// Existe porque a barra é feita de caracteres num `Text`, e um `Text` ocupa a
/// caixa de linha da fonte — da ascendente à descendente. Centrar essa caixa na
/// cápsula **não** centra o desenho: um `B` de 12pt tem 8,46pt de tinta dentro
/// de uma caixa de 14,13pt, e a caixa não é simétrica em volta dela. Medido
/// nesta máquina, isso deixava os glifos entre 0,3pt e 1,5pt **abaixo** da linha
/// média da cápsula — o afundamento que o dono do projeto relatou.
///
/// A conta tem de ser medida, não deduzida da fonte pedida: metade destes
/// glifos (`⇔`, `⇒`, `≡`, `•—`, `⊞`) não existe na São Francisco e é desenhada
/// por uma face de reserva, com ascendente, descendente e altura de tinta
/// próprias. `CTLine` já resolve a substituição; `CTLineGetImageBounds` devolve
/// a tinta que de fato sai no bitmap.
///
/// `useOpticalBounds` **não** serve aqui: medido, ele devolve a caixa
/// tipográfica de volta, idêntica a `CTLineGetBoundsWithOptions([])`.
struct GlyphInk: Sendable, Hashable {
    /// Distância da linha de base ao centro da tinta, positiva para cima.
    var middle: CGFloat
    /// Altura da tinta.
    var height: CGFloat

    /// O que usar quando o glifo não tem tinta nenhuma (espaço, por exemplo):
    /// nada a corrigir.
    static let none = GlyphInk(middle: 0, height: 0)

    var isEmpty: Bool { height <= 0 }
}

enum GlyphMetrics {
    private struct Key: Hashable {
        let label: String
        let font: String
        let size: CGFloat
    }

    private static let cache = OSAllocatedUnfairLock<[Key: GlyphInk]>(initialState: [:])

    /// A tinta do rótulo desenhado com esta fonte. O resultado é constante para
    /// um par (rótulo, fonte) e o conjunto de rótulos da barra é fixo, então
    /// vale a pena guardar: `body` reavalia a cada leitura da seleção.
    static func ink(of label: String, font: NSFont) -> GlyphInk {
        let key = Key(label: label, font: font.fontName, size: font.pointSize)
        if let known = cache.withLock({ $0[key] }) { return known }
        let measured = measure(label, font: font)
        cache.withLock { $0[key] = measured }
        return measured
    }

    private static func measure(_ label: String, font: NSFont) -> GlyphInk {
        guard !label.isEmpty else { return .none }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: label, attributes: [.font: font])
        )
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return .none }
        let ink = CTLineGetImageBounds(line, context)
        guard ink.height > 0, ink.height.isFinite, ink.midY.isFinite else { return .none }
        return GlyphInk(middle: ink.midY, height: ink.height)
    }

    /// A `NSFont` equivalente ao que `FontFamily.font(size:weight:)` devolve.
    /// Precisa existir porque `Font` do SwiftUI é opaca e não dá para medir.
    static func nsFont(
        _ family: FontFamily, size: CGFloat, weight: NSFont.Weight, italic: Bool
    ) -> NSFont {
        var font: NSFont
        if let name = family.name, FontRegistry.isAvailable(name),
           let custom = NSFont(name: name, size: size) {
            font = custom
        } else {
            font = .systemFont(ofSize: size, weight: weight)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }
}

// MARK: - Altura de linha do corpo

/// A altura de linha do corpo, como atributo do texto.
///
/// O corpo do composer é `font-family: var(--serif); font-size: 16px;
/// line-height: 1.7` no protótipo (linha 961 do `.dc.html`). A primeira
/// tradução disso foi `.lineSpacing(corpo * 0.7)` no editor, e ela produzia o
/// "cursor gigante" que o dono do projeto relatou.
///
/// Medido nesta máquina, com o corpo `"ddadasd\n\ndsd"` do print: `lineSpacing`
/// pendura o espaço **depois** de cada fragmento e **não** depois do último, de
/// modo que o cursor media 28,50pt nas duas primeiras linhas e 18,00pt na
/// última. Não é um valor mal escolhido — é o eixo errado: qualquer
/// `lineSpacing` diferente de zero reproduz a desigualdade, porque o cursor
/// mede o fragmento e o espaçamento infla o fragmento de um lado só.
///
/// Altura de linha de verdade dimensiona a **caixa**, e vale para todo
/// fragmento — o último inclusive.
extension ComposerFormatting {
    /// Protótipo: `line-height: 1.7`.
    static let bodyLineHeight: CGFloat = 1.7

    /// A caixa de linha de um trecho deste corpo.
    ///
    /// **`.exact`, não `.multiple`.** `multiple(factor:)` multiplica a caixa
    /// **natural** da fonte, não o corpo pedido; medido, a caixa natural de uma
    /// face de 15pt é 18,00pt, então `multiple(factor: 1.7)` daria 30,60pt —
    /// proporção 2,04 sobre o corpo, e não os 1,7 do CSS. `exact(points:)` a
    /// partir do tamanho do run dá exatamente a semântica de `line-height`.
    static func lineHeight(for size: Double) -> AttributedString.LineHeight {
        .exact(points: CGFloat(size) * bodyLineHeight)
    }
}

/// O que o `TextEditor` aplica ao corpo a cada edição.
///
/// Precisa ser uma **restrição**, e não só a escrita em `project(_:into:theme:)`,
/// porque `project` só roda quando a barra manda um comando. Um rascunho
/// recém-semeado é `AttributedString(texto)` sem atributo nenhum, e o primeiro
/// caractere digitado numa janela nova também nasce sem — foi exatamente esse o
/// caso do print do dono. A restrição alcança os dois: o SwiftUI a aplica a
/// **todo** run, sempre, sem a janela precisar normalizar nada na mão.
///
/// Foi por aqui que a altura de linha deixou de ser `NSParagraphStyle`.
/// `AttributedTextValueConstraint` exige `AttributeKey.Value: Sendable`, e a
/// conformidade de `NSParagraphStyle` a `Sendable` é **explicitamente
/// indisponível** no macOS:
///
/// ```
/// error: conformance of 'NSParagraphStyle' to 'Sendable' is unavailable in macOS
/// ```
///
/// `AttributedString.LineHeight` é `Sendable`, mora no mesmo escopo do CoreText
/// de onde já sai o alinhamento, e diz a mesma coisa. Não há motivo para descer
/// ao `NSParagraphStyle` — e, se houvesse, a restrição não compilaria.
struct ComposerBodyFormatting: AttributedTextFormattingDefinition {
    typealias Scope = AttributeScopes.UNIComposerAttributes

    var body: some AttributedTextFormattingDefinition<Scope> {
        LineHeight()
    }

    /// **A restrição é um piso, não uma reescrita.**
    ///
    /// Medido: o `AttributeContainerProxy` que o `constrain` recebe só enxerga
    /// o **próprio** atributo. Ler `BodyStyleAttribute` ou a fonte de dentro
    /// dele devolve `nil` mesmo quando o run os tem — a sonda imprimiu
    /// `bodyStyle=nil font=nil` sobre um trecho de corpo 32. Ou seja: a
    /// restrição não tem como calcular a altura a partir do tamanho do trecho.
    ///
    /// Por isso ela só escreve quando **não há** altura nenhuma, e o valor que
    /// escreve é o do corpo padrão. Quem sabe o tamanho é a barra, e é
    /// `project(_:into:theme:)` que escreve a altura certa quando um comando
    /// passa. Se a restrição sobrescrevesse, um trecho de corpo 32 perderia a
    /// caixa de 54,40pt e voltaria para a de 25,50pt a cada tecla — foi o que
    /// aconteceu na primeira versão, e há teste para isso.
    struct LineHeight: AttributedTextValueConstraint {
        typealias Scope = AttributeScopes.UNIComposerAttributes
        typealias AttributeKey = AttributeScopes.CoreTextAttributes.LineHeightAttribute

        func constrain(_ container: inout Attributes) {
            guard container[AttributeKey.self] == nil else { return }
            container[AttributeKey.self] = ComposerFormatting.lineHeight(for: BodyStyle.defaultSize)
        }
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
///
/// `lineHeight` entrou pelo mesmo motivo: é nele que mora a altura de linha do
/// corpo, e um atributo fora do escopo é descartado a cada edição.
extension AttributeScopes {
    struct UNIComposerAttributes: AttributeScope {
        let bodyStyle: BodyStyleAttribute
        let lineHeight: AttributeScopes.CoreTextAttributes.LineHeightAttribute
        let swiftUI: AttributeScopes.SwiftUIAttributes
    }
}
