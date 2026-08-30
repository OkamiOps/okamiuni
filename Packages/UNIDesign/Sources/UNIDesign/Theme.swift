import SwiftUI

/// One layer of a CSS `box-shadow`.
public struct ShadowToken: Sendable, Hashable {
    public let x: CGFloat
    public let y: CGFloat
    public let blur: CGFloat
    public let spread: CGFloat
    public let color: TokenColor

    /// `box-shadow: inset ...` — brilho **interno**, na aresta de dentro da
    /// forma. Não é sombra externa e não pode ser desenhado como uma: o CSS
    /// pinta por dentro, e `.shadow()` do SwiftUI pinta por fora, virando um
    /// anel em volta do botão. Nove dos 26 temas usam `inset` no botão, e era
    /// exatamente esse anel que aparecia como "contorno errado".
    public let isInset: Bool

    public init(
        x: CGFloat, y: CGFloat, blur: CGFloat, spread: CGFloat = 0,
        color: TokenColor, isInset: Bool = false
    ) {
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.color = color
        self.isInset = isInset
    }

    /// SwiftUI blurs with a radius roughly half the CSS blur value.
    public var radius: CGFloat { blur / 2 }
}

/// Which of a theme's families the message body is set in.
public enum BodyFont: String, Sendable, Hashable {
    case serif, sans
}

/// A escala tipográfica da interface. Ela é uma preferência do aplicativo,
/// não parte do conteúdo que a pessoa escreve ou recebe.
public enum TypographyPreset: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case compact
    case standard
    case enlarged

    public var id: String { rawValue }

    /// Factores deliberadamente conservadores: ampliado melhora a leitura sem
    /// transformar as janelas compactas em layouts de acessibilidade dinâmica.
    public var scale: CGFloat {
        switch self {
        case .compact: 0.9
        case .standard: 1
        case .enlarged: 1.125
        }
    }
}

/// Padding from the tokens. Its own type rather than SwiftUI's `EdgeInsets`,
/// which is not `Hashable` and would block `Theme`'s synthesis.
public struct Insets: Sendable, Hashable {
    public let top: CGFloat
    public let leading: CGFloat
    public let bottom: CGFloat
    public let trailing: CGFloat

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public var edgeInsets: EdgeInsets {
        EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing)
    }
}

/// A font family from the design, plus the fallback to use until the
/// bundled face is available.
public struct FontFamily: Sendable, Hashable {
    /// Family name as it will be registered once bundled, e.g. `Newsreader`.
    /// `nil` means the design asked for the system face.
    public let name: String?
    public let design: Font.Design
    /// Multiplicador visual aplicado à interface. O nome e o desenho da fonte
    /// continuam sendo os tokens do tema.
    public let scale: CGFloat

    public init(name: String?, design: Font.Design, scale: CGFloat = 1) {
        self.name = name
        self.design = design
        self.scale = scale
    }

    public static let system = FontFamily(name: nil, design: .default)

    public func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let resolvedSize = size * scale
        guard let name, FontRegistry.isAvailable(name) else {
            return .system(size: resolvedSize, weight: weight, design: design)
        }
        return .custom(name, size: resolvedSize).weight(weight)
    }

    /// Aplica uma escala absoluta, para que voltar a `standard` não acumule
    /// transformações sobre uma família já resolvida.
    public func applying(scale: CGFloat) -> FontFamily {
        FontFamily(name: name, design: design, scale: scale)
    }
}

/// A complete resolved theme: every token the UI needs, with no fallbacks left
/// to compute at render time.
public struct Theme: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let note: String
    public let isDark: Bool

    // Surfaces, back to front.
    public let paper: TokenColor
    public let surface: TokenColor
    public let surface2: TokenColor
    public let surface3: TokenColor

    // Text, strongest to faintest.
    public let ink: TokenColor
    public let ink2: TokenColor
    public let ink3: TokenColor
    public let ink4: TokenColor

    // Dividers.
    public let line: TokenColor
    public let line2: TokenColor

    // Accent.
    public let accent: TokenColor
    public let accentInk: TokenColor
    public let accentSoft: TokenColor
    public let accentLine: TokenColor
    public let onAccent: TokenColor

    // Controls.
    public let btn: TokenColor
    public let btnLine: TokenColor
    public let btnShadow: [ShadowToken]
    public let shadow: [ShadowToken]

    // Type.
    public let serif: FontFamily
    public let sans: FontFamily
    public let mono: FontFamily
    public let bodyFont: BodyFont
    /// Escala visual resolvida para os caminhos AppKit que precisam medir
    /// fontes e alturas de linha, além do SwiftUI.
    public let typographyScale: CGFloat

    // Metrics.
    public let radiusSmall: CGFloat   // --r2
    public let radiusLarge: CGFloat   // --r3
    public let capsTracking: CGFloat  // --caps, in em
    public let rowPadding: Insets     // --rowpad
    public let subjectWeight: Font.Weight
    public let subjectSize: CGFloat

    public init(
        id: String, name: String, note: String, isDark: Bool,
        paper: TokenColor, surface: TokenColor, surface2: TokenColor, surface3: TokenColor,
        ink: TokenColor, ink2: TokenColor, ink3: TokenColor, ink4: TokenColor,
        line: TokenColor, line2: TokenColor,
        accent: TokenColor, accentInk: TokenColor, accentSoft: TokenColor,
        accentLine: TokenColor, onAccent: TokenColor,
        btn: TokenColor, btnLine: TokenColor,
        btnShadow: [ShadowToken], shadow: [ShadowToken],
        serif: FontFamily, sans: FontFamily, mono: FontFamily, bodyFont: BodyFont,
        radiusSmall: CGFloat, radiusLarge: CGFloat, capsTracking: CGFloat,
        rowPadding: Insets, subjectWeight: Font.Weight, subjectSize: CGFloat,
        typographyScale: CGFloat = 1
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.isDark = isDark
        self.paper = paper
        self.surface = surface
        self.surface2 = surface2
        self.surface3 = surface3
        self.ink = ink
        self.ink2 = ink2
        self.ink3 = ink3
        self.ink4 = ink4
        self.line = line
        self.line2 = line2
        self.accent = accent
        self.accentInk = accentInk
        self.accentSoft = accentSoft
        self.accentLine = accentLine
        self.onAccent = onAccent
        self.btn = btn
        self.btnLine = btnLine
        self.btnShadow = btnShadow
        self.shadow = shadow
        self.serif = serif
        self.sans = sans
        self.mono = mono
        self.bodyFont = bodyFont
        self.typographyScale = typographyScale
        self.radiusSmall = radiusSmall
        self.radiusLarge = radiusLarge
        self.capsTracking = capsTracking
        self.rowPadding = rowPadding
        self.subjectWeight = subjectWeight
        self.subjectSize = subjectSize
    }
}

extension Theme {
    /// The family the message body is set in.
    public var body: FontFamily { bodyFont == .serif ? serif : sans }

    /// Status roles stay readable on a theme's paper and primary surface.
    /// They intentionally adapt as text colours, rather than inheriting an
    /// accent whose contrast and meaning vary from one theme to the next.
    public var danger: TokenColor {
        isDark
            ? TokenColor(red: 255 / 255, green: 177 / 255, blue: 194 / 255)
            : TokenColor(red: 176 / 255, green: 0 / 255, blue: 32 / 255)
    }

    public var success: TokenColor {
        isDark
            ? TokenColor(red: 140 / 255, green: 232 / 255, blue: 177 / 255)
            : TokenColor(red: 0 / 255, green: 109 / 255, blue: 58 / 255)
    }

    public var warning: TokenColor {
        isDark
            ? TokenColor(red: 255 / 255, green: 217 / 255, blue: 139 / 255)
            : TokenColor(red: 128 / 255, green: 86 / 255, blue: 0 / 255)
    }

    public var info: TokenColor {
        isDark
            ? TokenColor(red: 169 / 255, green: 199 / 255, blue: 255 / 255)
            : TokenColor(red: 0 / 255, green: 87 / 255, blue: 184 / 255)
    }

    /// Tracking in points for a small-caps label at a given size.
    public func capsTracking(at size: CGFloat) -> CGFloat { capsTracking * size }

    /// Resolve a escala de interface sem alterar os tokens de cor, métrica ou
    /// identidade do tema. Os temas gerados continuam sendo a base canônica.
    public func applyingTypography(_ preset: TypographyPreset) -> Theme {
        Theme(
            id: id, name: name, note: note, isDark: isDark,
            paper: paper, surface: surface, surface2: surface2, surface3: surface3,
            ink: ink, ink2: ink2, ink3: ink3, ink4: ink4,
            line: line, line2: line2,
            accent: accent, accentInk: accentInk, accentSoft: accentSoft,
            accentLine: accentLine, onAccent: onAccent,
            btn: btn, btnLine: btnLine,
            btnShadow: btnShadow, shadow: shadow,
            serif: serif.applying(scale: preset.scale),
            sans: sans.applying(scale: preset.scale),
            mono: mono.applying(scale: preset.scale),
            bodyFont: bodyFont,
            radiusSmall: radiusSmall, radiusLarge: radiusLarge,
            capsTracking: capsTracking, rowPadding: rowPadding,
            subjectWeight: subjectWeight, subjectSize: subjectSize,
            typographyScale: preset.scale
        )
    }
}
