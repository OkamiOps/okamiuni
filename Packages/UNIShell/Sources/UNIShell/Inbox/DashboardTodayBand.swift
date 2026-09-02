import SwiftUI
import UNICore
import UNIDesign

/// A faixa **HOJE** — `.digest` do mockup `design/07-dashboard.html`.
///
/// Substitui o briefing em prosa e não tem botão para gerar coisa nenhuma: ela
/// está pronta quando a tela abre, porque sai da triagem que a `DashboardFocus`
/// já fez. Cada linha é clicável e seleciona uma mensagem de verdade; o
/// excedente, à direita, diz quanto ficou fora da lista.
struct DashboardTodayBand: View {

    @Environment(\.theme) private var theme

    let lines: [DashboardTodayLine]
    let restLabel: String?
    let onSelect: (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DashboardMetrics.todaySpacing) {
            Text("Hoje")
                .capsLabel(size: DashboardMetrics.capsSize)
                .layoutPriority(1)
            ForEach(lines) { line in
                item(line)
            }
            Spacer(minLength: 12)
            if let restLabel {
                Text(restLabel)
                    .font(theme.sans.font(size: DashboardMetrics.todayTextSize))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
        }
        .padding(DashboardMetrics.todayPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: [.top, .bottom])
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hoje")
    }

    @ViewBuilder
    private func item(_ line: DashboardTodayLine) -> some View {
        let conteudo = HStack(spacing: DashboardMetrics.todayDotSpacing) {
            Circle()
                .fill(dot(line.tone))
                .frame(
                    width: DashboardMetrics.todayDotSide,
                    height: DashboardMetrics.todayDotSide
                )
                .accessibilityHidden(true)
            Text(line.text)
                .font(
                    theme.sans.font(size: DashboardMetrics.todayTextSize, weight: .semibold)
                )
                .foregroundStyle(line.tone == .quiet ? theme.ink3.color : theme.ink2.color)
                .lineLimit(1)
        }
        .fixedSize()

        if let messageID = line.messageID {
            Button { onSelect(messageID) } label: { conteudo }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .help("Mostra esta mensagem na prévia")
                .accessibilityLabel(line.text)
        } else {
            conteudo
        }
    }

    private func dot(_ tone: DashboardTodayLine.Tone) -> Color {
        switch tone {
        case .warning: theme.warning.color
        case .accent: theme.accent.color
        case .quiet: theme.ink4.color
        }
    }
}
