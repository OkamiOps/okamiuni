import SwiftUI
import UNICore
import UNIDesign

/// Texto da indisponibilidade fora da View para a causa não virar um `if`
/// opaco dentro da grade — e para ser provado sem renderizar uma janela.
enum CalendarStatusCopy {
    static func text(for state: CalendarAvailability) -> String? {
        switch state {
        case .available: nil
        case .loading: L10n.tr("Atualizando a agenda conectada…")
        case .authorizationRequired: L10n.tr("Permita o acesso aos Calendários para mostrar e criar compromissos reais.")
        case .unavailable(let reason): reason
        }
    }

    static func action(for state: CalendarAvailability) -> String? {
        if case .authorizationRequired = state { return L10n.tr("Permitir acesso") }
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
            // No Vidro a faixa é discreta **dentro** do painel: um azulejo
            // translúcido com a folga da faixa do topo, e não uma segunda
            // superfície opaca atravessando a largura.
            .padding(.horizontal, theme.isGlass ? 14 : 18)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(
                    cornerRadius: theme.isGlass ? 10 : 0, style: .continuous
                )
                .fill(theme.isGlass ? theme.glassTile.color : theme.surface2.color)
            )
            .padding(.horizontal, theme.isGlass ? 14 : 0)
            .padding(.top, theme.isGlass ? 10 : 0)
            .hairline(
                theme.isGlass ? TokenColor(red: 0, green: 0, blue: 0, opacity: 0) : theme.line2,
                edges: .bottom
            )
        )
    }
}
