import Foundation

/// Qual das três visões da tela 02 está no ar. Protótipo: `st.calView`, com
/// `calTabs: ['dia', 'semana', 'mês']` (linha 2353).
///
/// O nome não é `CalendarView` de propósito: `Calendar` já é um tipo do
/// Foundation que este módulo importa em todo lugar, e um `CalendarView` ao
/// lado dele lê como uma `View` de SwiftUI — que é justamente o que **não** é.
public enum CalendarViewMode: String, Sendable, Hashable, CaseIterable, Identifiable {
    case day = "dia"
    case week = "semana"
    case month = "mês"

    public var id: String { rawValue }

    /// Protótipo: `label: id === 'mês' ? 'Mês' : (id === 'dia' ? 'Dia' : 'Semana')`.
    public var label: String {
        switch self {
        case .day: "Dia"
        case .week: "Semana"
        case .month: "Mês"
        }
    }
}

extension CalendarViewMode {
    /// Quanto um passo de `‹ ›` percorre nesta visão.
    ///
    /// Antes só a visão Dia tinha navegador. Semana e mês ficavam presas na
    /// semana e no mês da âncora, o que o dono do projeto apontou como falta de
    /// lógica — e é.
    public var navigationScope: MonthAgenda.NavigationScope {
        switch self {
        case .day: .day
        case .week: .week
        case .month: .month
        }
    }
}
