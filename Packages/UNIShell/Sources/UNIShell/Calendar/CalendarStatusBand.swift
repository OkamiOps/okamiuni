import SwiftUI
import UNICore
import UNIDesign

/// Texto da indisponibilidade fora da View para a causa não virar um `if`
/// opaco dentro da grade — e para ser provado sem renderizar uma janela.
enum CalendarStatusCopy {
    static func text(for state: CalendarAvailability) -> String? {
        switch state {
        case .available: nil
        case .loading: "Atualizando a agenda conectada…"
        case .authorizationRequired: "Permita o acesso aos Calendários para mostrar e criar compromissos reais."
        case .unavailable(let reason): reason
        }
    }

    static func action(for state: CalendarAvailability) -> String? {
        if case .authorizationRequired = state { return "Permitir acesso" }
        return nil
    }
}

struct CalendarStatusBand: View {
    @Environment(\.theme) private var theme
    let state: CalendarAvailability
    let requestAccess: () -> Void

    var body: some View {
        guard let text = CalendarStatusCopy.text(for: state) else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(text)
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = CalendarStatusCopy.action(for: state) {
                    Button(action, action: requestAccess)
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                        .focusRing(cornerRadius: theme.radiusSmall)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(theme.surface2.color)
            .hairline(theme.line2, edges: .bottom)
        )
    }
}
