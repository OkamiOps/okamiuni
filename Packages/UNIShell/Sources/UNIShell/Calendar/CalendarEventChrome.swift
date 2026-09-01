import SwiftUI
import UNIDesign
import UNICore

/// Compromisso cancelado: continua no dia, mas em cinza — senão parece
/// que ainda vale.
///
/// O fundo **não** é `color.opacity`: pastel do EventKit a 45% no branco
/// some, e o texto na mesma cor some junto. O fill é mistura opaca com o
/// papel; o texto é a tinta escurecida até contrastar.
enum CalendarEventChrome {
    /// Cartão opaco: um pouco da tinta da agenda no papel. Não mistura
    /// contra preto — isso deixava o Termin de Odette azul-escuro com
    /// texto azul-escuro por cima.
    static func fillSwatch(_ tint: TokenColor?, cancelled: Bool, theme: Theme) -> TokenColor {
        if cancelled {
            return theme.ink4.mixing(with: theme.surface, amount: theme.isDark ? 0.82 : 0.90)
        }
        let pigment = tint ?? theme.accent
        return pigment.mixing(with: theme.surface, amount: theme.isDark ? 0.62 : 0.58)
    }

    static func fill(_ tint: TokenColor?, cancelled: Bool, theme: Theme) -> Color {
        fillSwatch(tint, cancelled: cancelled, theme: theme).color
    }

    static func ink(_ tint: TokenColor?, cancelled: Bool, theme: Theme) -> Color {
        if cancelled { return theme.ink4.color }
        let card = fillSwatch(tint, cancelled: false, theme: theme)
        return (tint ?? theme.accent)
            .ensuringContrast(against: card, minimum: 4.5)
            .color
    }

    static func bar(_ tint: TokenColor?, cancelled: Bool, theme: Theme) -> Color {
        if cancelled { return theme.ink4.color.opacity(0.55) }
        return (tint ?? theme.accent).color
    }

    static func border(cancelled: Bool, theme: Theme) -> Color {
        cancelled ? theme.ink4.color.opacity(0.45) : .clear
    }

    static func title(_ text: String, cancelled: Bool) -> Text {
        let base = Text(text)
        return cancelled ? base.strikethrough() : base
    }
}
