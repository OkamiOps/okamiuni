import SwiftUI
import AppKit

/// A color from the design tokens, stored as sRGB components so it stays
/// `Sendable` and usable from both SwiftUI and AppKit.
public struct TokenColor: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }

    /// Relative luminance (WCAG). Used to tell light themes from dark ones.
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Razão de contraste WCAG entre duas cores sólidas.
    ///
    /// Os papéis semânticos do catálogo são opacos. Manter o cálculo aqui,
    /// junto da luminância, evita que testes e componentes inventem versões
    /// ligeiramente diferentes da mesma regra.
    public func contrastRatio(with other: TokenColor) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension TokenColor {
    /// Parses `#RGB`, `#RRGGBB`, `#RRGGBBAA` and `rgba(r,g,b,a)`.
    /// Returns `nil` rather than a silent black so bad tokens surface in tests.
    public init?(css: String) {
        let s = css.trimmingCharacters(in: .whitespaces)

        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            func byte(_ i: Int, _ len: Int) -> Double? {
                let start = hex.index(hex.startIndex, offsetBy: i * len)
                let end = hex.index(start, offsetBy: len)
                guard end <= hex.endIndex else { return nil }
                var chunk = String(hex[start..<end])
                if len == 1 { chunk += chunk }
                guard let v = UInt8(chunk, radix: 16) else { return nil }
                return Double(v) / 255
            }
            switch hex.count {
            case 3:
                guard let r = byte(0, 1), let g = byte(1, 1), let b = byte(2, 1) else { return nil }
                self.init(red: r, green: g, blue: b)
            case 6:
                guard let r = byte(0, 2), let g = byte(1, 2), let b = byte(2, 2) else { return nil }
                self.init(red: r, green: g, blue: b)
            case 8:
                guard let r = byte(0, 2), let g = byte(1, 2), let b = byte(2, 2), let a = byte(3, 2)
                else { return nil }
                self.init(red: r, green: g, blue: b, opacity: a)
            default:
                return nil
            }
            return
        }

        guard s.hasPrefix("rgba(") || s.hasPrefix("rgb(") else { return nil }
        let inner = s.drop { $0 != "(" }.dropFirst().dropLast()
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 3,
              let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2])
        else { return nil }
        let a = parts.count > 3 ? (Double(parts[3]) ?? 1) : 1
        self.init(red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}
