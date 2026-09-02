import SwiftUI
import UNIDesign
import UNICore

/// Uma linha de PRIORIDADES — `.prow` do mockup, no idioma da `MessageRow`.
///
/// Flush, sem cartão: barra de tinta da conta encostada na borda esquerda,
/// remetente em sans 13 semibold, hora em mono 11 à direita, assunto no corpo
/// que o tema escolhe, e o chip do motivo **de verdade** embaixo — as seis
/// `DashboardFocus.Reason`, não o "Alta/Média" que o `rankPill` colapsava.
///
/// Fica em arquivo próprio porque o teste da razão a desenha sozinha: uma
/// linha de 500×90 diz mais sobre o chip do que uma tela de 1200×820.
struct DashboardPriorityRow: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let item: DashboardFocus.MailItem
    let tint: Color
    let isUnread: Bool
    let isSelected: Bool
    let today: Date
    /// **Um clique seleciona.** A prévia do meio é que mostra o email, as
    /// ações e o Contexto — a queixa do dono era literal ("ao clicar ele já
    /// abre o modal de uma vez").
    var onSelect: () -> Void = {}
    /// Abrir de verdade: duplo clique aqui, ⏎ na tela.
    var onOpen: () -> Void = {}

    init(
        item: DashboardFocus.MailItem,
        tint: Color,
        isUnread: Bool,
        isSelected: Bool,
        today: Date,
        onSelect: @escaping () -> Void = {},
        onOpen: @escaping () -> Void = {}
    ) {
        self.item = item
        self.tint = tint
        self.isUnread = isUnread
        self.isSelected = isSelected
        self.today = today
        self.onSelect = onSelect
        self.onOpen = onOpen
    }

    private var message: Message { item.message }

    /// `.prow { --rowbg: var(--paper) }`, `.prow.unread` e `.prow.sel` — as
    /// duas em `surface2`. O que distingue a selecionada é a barra de tinta
    /// cheia e o `›` da direita, exatamente como o mockup a distingue.
    private var rowFill: Color {
        if isSelected || isUnread { return theme.surface2.color }
        return theme.paper.color
    }

    var body: some View {
        Button(action: onSelect) {
            content
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 0)
        // O duplo clique **por cima** do botão: o primeiro toque já
        // selecionou, e o segundo abre. `simultaneousGesture` para o clique
        // simples continuar chegando ao botão.
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
        .accessibilityLabel(
            DashboardMetrics.rowAccessibilityLabel(
                sender: message.listHeadline, subject: message.subject, reason: item.reason
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.listHeadline)
                    .font(theme.sans.font(size: DashboardMetrics.senderSize, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                timeStamp
                    .font(theme.mono.font(size: DashboardMetrics.timeSize))
                    .foregroundStyle(theme.ink4.color)
                    .monospacedDigit()
            }
            Text(message.subject)
                .font(theme.body.font(size: theme.subjectSize, weight: theme.subjectWeight))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .padding(.top, DashboardMetrics.subjectTopSpacing)
            DashboardReasonChip(reason: item.reason)
                .padding(.top, DashboardMetrics.chipsTopSpacing)
        }
        .padding(DashboardMetrics.rowPadding.edgeInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowFill)
        // `box-shadow: inset 3px 0 0 …` — a mesma barra da `MessageRow`.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(isSelected ? 1 : DashboardMetrics.accountBarOpacity))
                .frame(width: DashboardMetrics.accountBarWidth)
        }
        // `.prow.sel::after { content: '›' }` — o único enfeite da seleção
        // além da barra de tinta.
        .overlay(alignment: .trailing) {
            if isSelected {
                Text("›")
                    .font(theme.sans.font(size: 15))
                    .foregroundStyle(theme.ink4.color)
                    .padding(.trailing, 12)
                    .accessibilityHidden(true)
            }
        }
        .hairline(theme.line2, edges: .bottom)
    }

    /// O mesmo carimbo da `MessageRow`: hora hoje, "Ontem" ontem, data antes.
    @ViewBuilder
    private var timeStamp: some View {
        switch MessageStamp.of(message.receivedAt, now: today) {
        case .clock:
            Text(message.receivedAt, format: .dateTime.hour().minute())
        case .yesterday:
            Text(DayLabel.yesterday)
        case .dayMonth:
            Text(message.receivedAt, format: .dateTime.day().month(.abbreviated))
        case .dayMonthYear:
            Text(message.receivedAt, format: .dateTime.day().month(.abbreviated).year())
        }
    }
}

/// O chip do motivo — `.chip[data-reason=…]` do mockup, com a geometria do
/// `TintChip` da Caixa (mono 9, tracking 0.06em, raio 4, pad 2/6/1.5).
///
/// Quatro aparências para seis razões: o que se repete é a cor, nunca o
/// rótulo.
struct DashboardReasonChip: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let reason: DashboardFocus.Reason

    var body: some View {
        Text(reason.label)
            .font(theme.mono.font(size: TintChip.fontSize, weight: .medium))
            .tracking(TintChip.trackingEm * TintChip.fontSize)
            .textCase(.uppercase)
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .padding(.bottom, 1.5)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: TintChip.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: TintChip.cornerRadius)
                    .strokeBorder(border, lineWidth: Hairline.thickness(displayScale))
            }
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var ink: Color {
        switch DashboardMetrics.chipRole(for: reason) {
        case .warning: theme.warning.color
        case .lead, .flagged: theme.accentInk.color
        case .quiet: theme.ink3.color
        }
    }

    private var fill: Color {
        switch DashboardMetrics.chipRole(for: reason) {
        case .warning: theme.warning.color.opacity(0.14)
        case .lead: theme.accentSoft.color
        case .flagged: .clear
        case .quiet: theme.surface3.color
        }
    }

    private var border: Color {
        switch DashboardMetrics.chipRole(for: reason) {
        case .warning: theme.warning.color.opacity(0.32)
        case .lead, .flagged: theme.accentLine.color
        case .quiet: theme.line.color
        }
    }
}
