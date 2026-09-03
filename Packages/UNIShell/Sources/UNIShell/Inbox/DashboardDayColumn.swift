import SwiftUI
import UNICore
import UNIDesign

/// A coluna "Seu dia" do 08 — 248 de largura, eventos **sem caixa**.
///
/// Cada linha é grid 44 + 1fr com hairline embaixo; "Agora" é versalete em
/// accent com a hairline a 50%; prazos escrevem a hora em `warn`; e o bloco
/// sugerido de `DayPlan.replyBlock` é o único com fundo (`surface`, borda
/// **tracejada** `accentLine`) — ele é proposta, não compromisso, e o
/// tracejado é o que diz isso sem rótulo.
struct DashboardDayColumn: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let entries: [DashboardDay.Entry]
    let nextUpLabel: String
    /// "O que você prometeu" — as pendências de hoje.
    let pending: [PendingItem]
    let onOpenEvent: (String) -> Void
    let onRevealMessage: (String) -> Void
    /// "Reservar" — cria o evento pelo comando de agenda existente.
    let onReserve: () -> Void
    /// "Outro horário" — abre o seletor de hora já existente.
    let onPickAnotherTime: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            list
            Spacer(minLength: 0)
            promises
        }
        .padding(.leading, DashboardMetrics.dayLeadingPadding)
        .padding(.top, DashboardMetrics.columnsTopSpacing)
        .frame(
            width: DashboardMetrics.dayWidth + DashboardMetrics.dayLeadingPadding,
            alignment: .topLeading
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seu dia")
    }

    /// "Seu dia" 13/600 + o próximo compromisso em versalete à direita.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Seu dia")
                .font(theme.sans.font(size: DashboardMetrics.dayTitleSize, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Spacer(minLength: 8)
            if !nextUpLabel.isEmpty {
                Text(nextUpLabel)
                    .capsLabel(size: DashboardMetrics.capsSize)
                    .lineLimit(1)
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    line(entry)
                }
                if entries.count <= 1 {
                    Text("Dia livre.")
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(theme.ink4.color)
                        .padding(.vertical, DashboardMetrics.eventVerticalPadding)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .padding(.top, DashboardMetrics.dayListTopSpacing)
    }

    @ViewBuilder
    private func line(_ entry: DashboardDay.Entry) -> some View {
        switch entry {
        case let .event(id, hour, title, sub):
            eventLine(hour: hour, hourTone: theme.ink3.color, title: title, sub: sub)
                .contentShape(Rectangle())
                .onTapGesture { onOpenEvent(id) }
        case .now:
            nowLine
        case let .plan(hour, title, sub):
            planBlock(hour: hour, title: title, sub: sub)
        case let .deadline(id, hour, title, sub):
            eventLine(hour: hour, hourTone: theme.warning.color, title: title, sub: sub)
                .contentShape(Rectangle())
                .onTapGesture { onRevealMessage(id) }
        }
    }

    /// `.ev` — grid 44 + 1fr, hairline `line2` embaixo, sem caixa nenhuma.
    private func eventLine(
        hour: String, hourTone: Color, title: String, sub: String
    ) -> some View {
        HStack(alignment: .top, spacing: DashboardMetrics.eventColumnGap) {
            Text(hour)
                .font(theme.mono.font(size: DashboardMetrics.eventHourSize, weight: .medium))
                .foregroundStyle(hourTone)
                .frame(width: DashboardMetrics.eventHourWidth, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.sans.font(size: DashboardMetrics.eventTitleSize, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineSpacing(DashboardMetrics.eventTitleSize * 0.35)
                    .fixedSize(horizontal: false, vertical: true)
                if !sub.isEmpty {
                    Text(sub)
                        .font(theme.sans.font(size: DashboardMetrics.eventSubSize))
                        .foregroundStyle(theme.ink4.color)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, DashboardMetrics.eventVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(theme.line2, edges: .bottom)
        .accessibilityElement(children: .combine)
    }

    /// "Agora" — versalete em accent e a hairline em accent a 50%.
    private var nowLine: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Agora")
                .capsLabel(size: DashboardMetrics.capsSize)
                .foregroundStyle(theme.accent.color)
            Rectangle()
                .fill(theme.accent.color.opacity(DashboardMetrics.nowLineOpacity))
                .frame(height: Hairline.thickness(displayScale))
        }
        .padding(.vertical, DashboardMetrics.nowVerticalPadding)
        .accessibilityLabel("Agora")
    }

    /// O bloco sugerido — a proposta de agenda, com o tracejado que a
    /// distingue de compromisso de verdade.
    private func planBlock(hour: String, title: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: DashboardMetrics.eventColumnGap) {
            Text(hour)
                .font(theme.mono.font(size: DashboardMetrics.eventHourSize, weight: .medium))
                .foregroundStyle(theme.accentInk.color)
                .frame(width: DashboardMetrics.eventHourWidth, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.sans.font(size: DashboardMetrics.eventTitleSize, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sub)
                    .font(theme.sans.font(size: DashboardMetrics.eventSubSize))
                    .foregroundStyle(theme.ink4.color)
                HStack(spacing: DashboardMetrics.planActionsGap) {
                    Button(action: onReserve) {
                        Text("Reservar")
                            .font(theme.sans.font(
                                size: DashboardMetrics.planActionSize, weight: .semibold
                            ))
                            .foregroundStyle(theme.accent.color)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusRing(cornerRadius: theme.radiusSmall)
                    .accessibilityLabel("Reservar o bloco de respostas")
                    Button(action: onPickAnotherTime) {
                        Text("Outro horário")
                            .font(theme.sans.font(
                                size: DashboardMetrics.planActionSize, weight: .semibold
                            ))
                            .foregroundStyle(theme.ink4.color)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusRing(cornerRadius: theme.radiusSmall)
                }
                .padding(.top, DashboardMetrics.planActionsTopSpacing)
            }
        }
        .padding(DashboardMetrics.planBlockPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(
                    theme.accentLine.color,
                    style: StrokeStyle(
                        lineWidth: Hairline.thickness(displayScale), dash: [3, 3]
                    )
                )
        }
        .padding(.vertical, DashboardMetrics.planBlockVerticalMargin)
        .padding(.horizontal, -DashboardMetrics.planBlockBleed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bloco sugerido de respostas")
    }

    /// "O que você prometeu" — o rodapé com as pendências de hoje.
    private var promises: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("O que você prometeu")
                .capsLabel(size: DashboardMetrics.capsSize)
            if pending.isEmpty {
                Text("Nada em aberto.")
                    .font(theme.sans.font(size: DashboardMetrics.listFooterSize))
                    .foregroundStyle(theme.ink4.color)
            } else {
                ForEach(pending.prefix(3)) { item in
                    Text(item.text)
                        .font(theme.sans.font(size: DashboardMetrics.listFooterSize))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(2)
                }
            }
        }
        .padding(.top, DashboardMetrics.previewFooterTopPadding)
        // A reserva do botão "Perguntar · ⌘J": ele flutua no canto e não
        // empurra nada, então quem se afasta é esta coluna. Sem isto, o
        // rodapé fica debaixo do botão — o defeito que o render da Tarefa 3
        // mostrou.
        .padding(.bottom, DashboardMetrics.askButtonReserve)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(theme.line2, edges: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("O que você prometeu")
    }
}
