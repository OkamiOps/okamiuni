import SwiftUI

/// One layer of a CSS `box-shadow`.
public struct ShadowToken: Sendable, Hashable {
    public let x: CGFloat
    public let y: CGFloat
    public let blur: CGFloat
    public let spread: CGFloat
    public let color: TokenColor

    public init(x: CGFloat, y: CGFloat, blur: CGFloat, spread: CGFloat = 0, color: TokenColor) {
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.color = color
    }

    /// SwiftUI blurs with a radius roughly half the CSS blur value.
    public var radius: CGFloat { blur / 2 }
}

/// Which of a theme's families the message body is set in.
public enum BodyFont: String, Sendable, Hashable {
    case serif, sans
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

    public init(name: String?, design: Font.Design) {
        self.name = name
        self.design = design
    }

    public static let system = FontFamily(name: nil, design: .default)

    public func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let name, FontRegistry.isAvailable(name) else {
            return .system(size: size, weight: weight, design: design)
        }
        return .custom(name, size: size).weight(weight)
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
        rowPadding: Insets, subjectWeight: Font.Weight, subjectSize: CGFloat
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

    /// Tracking in points for a small-caps label at a given size.
    public func capsTracking(at size: CGFloat) -> CGFloat { capsTracking * size }
}
