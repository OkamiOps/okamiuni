import SwiftUI
import UNICore
import UNIDesign

/// Uma linha do dashboard 08 — `.row` do mockup.
///
/// Sem caixa, sem chip, sem barra lateral: o ponto da conta (8ø), três linhas
/// de texto e a linha `↳` da proposta, com as ações **em texto** à direita.
/// A única cor de fundo que uma linha ganha é a seleção (`surface2`), que
/// sangra 22 para cada lado — e é fundo, não borda.
///
/// **Clicar seleciona; ⏎ ou 2× clique abre.** "Enviar" aqui nunca envia: a
/// linha mostra o rascunho truncado, e o ruling de 2026-09-03 manda a
/// confirmação de uma linha aparecer no lugar da proposta antes de qualquer
/// coisa sair — quem decide isso é o `DashboardScreen`, que arma
/// `isConfirmingSend`.
struct DashboardRow: View {

    @Environment(\.theme) private var theme

    let row: DayPlan.Row
    let tint: Color
    let accountMark: String
    let usedAgenda: Bool
    let isSelected: Bool
    /// A confirmação de uma linha está armada para esta linha.
    let isConfirmingSend: Bool
    let today: Date
    let onSelect: () -> Void
    let onOpen: () -> Void
    /// A ação primária da proposta (Enviar/Depois/Arquivar e aprender).
    let onPrimary: () -> Void
    /// A secundária (Editar/Agora/Manter).
    let onSecondary: () -> Void
    /// O "Enviar" da confirmação — este sim envia.
    let onConfirmSend: () -> Void
    /// O "Cancelar" da confirmação.
    let onCancelSend: () -> Void

    /// "Jack Whitmore" — e o endereço só quando não há nome.
    private var senderName: String {
        let nome = row.item.message.from.name.trimmingCharacters(in: .whitespaces)
        return nome.isEmpty ? row.item.message.from.address : nome
    }

    var body: some View {
        HStack(alignment: .top, spacing: DashboardMetrics.rowColumnGap) {
            // `.row .dot` — o ponto da conta, na coluna de 18.
            Circle()
                .fill(tint)
                .frame(
                    width: DashboardMetrics.rowDotSide,
                    height: DashboardMetrics.rowDotSide
                )
                .padding(.top, DashboardMetrics.rowDotTopSpacing)
                .frame(width: DashboardMetrics.rowLeadingWidth, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                l1
                subject
                proposalLine
                    .padding(.top, DashboardMetrics.proposalTopSpacing)
            }
        }
        .padding(.top, DashboardMetrics.rowTopPadding)
        .padding(.bottom, DashboardMetrics.rowBottomPadding)
        .padding(.horizontal, DashboardMetrics.selectionBleed)
        .background(isSelected ? theme.surface2.color : .clear)
        .padding(.horizontal, -DashboardMetrics.selectionBleed)
        .hairline(theme.line2, edges: .bottom)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DashboardMetrics.rowAccessibilityLabel(
            sender: row.item.message.from.display,
            subject: row.item.message.subject,
            reason: row.item.reason,
            account: accountMark
        ))
    }

    /// `.row .l1` — remetente 13/600, conta em mono caps, hora à direita.
    private var l1: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // O nome, não o `display` (que anexa o endereço): a linha já
            // tem conta, hora e assunto — o endereço inteiro empurraria tudo.
            Text(senderName)
                .font(theme.sans.font(size: DashboardMetrics.rowSenderSize, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
            Text(accountMark)
                .font(theme.mono.font(size: DashboardMetrics.rowAccountSize))
                .tracking(0.08 * DashboardMetrics.rowAccountSize)
                .textCase(.uppercase)
                .foregroundStyle(theme.ink4.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            timeStamp
                .font(theme.mono.font(size: DashboardMetrics.rowTimeSize))
                .foregroundStyle(theme.ink4.color)
        }
    }

    /// O mesmo carimbo da `MessageRow`: hora hoje, "Ontem" ontem, data antes.
    @ViewBuilder
    private var timeStamp: some View {
        let recebido = row.item.message.receivedAt
        switch MessageStamp.of(recebido, now: today) {
        case .clock:
            Text(recebido, format: .dateTime.hour().minute())
        case .yesterday:
            Text(DayLabel.yesterday)
        case .dayMonth:
            Text(recebido, format: .dateTime.day().month(.abbreviated))
        case .dayMonthYear:
            Text(recebido, format: .dateTime.day().month(.abbreviated).year())
        }
    }

    /// `.row .subj` — 15/500, uma linha.
    private var subject: some View {
        Text(row.item.message.subject)
            .font(theme.sans.font(size: DashboardMetrics.rowSubjectSize, weight: .medium))
            .foregroundStyle(theme.ink.color)
            .lineLimit(1)
            .padding(.top, DashboardMetrics.rowSubjectTopSpacing)
    }

    // MARK: - A linha `↳`

    @ViewBuilder
    private var proposalLine: some View {
        if isConfirmingSend {
            confirmation
        } else {
            proposal
        }
    }

    private var proposal: some View {
        HStack(alignment: .firstTextBaseline, spacing: DashboardMetrics.proposalGap) {
            arrow
            proposalText
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }

    /// A confirmação de uma linha, **no lugar** da proposta: "Enviar para
    /// jack@…? Enviar · Cancelar". Só o Enviar daqui envia.
    private var confirmation: some View {
        HStack(alignment: .firstTextBaseline, spacing: DashboardMetrics.proposalGap) {
            arrow
            Text(DashboardMetrics.sendConfirmationLabel(
                address: row.item.message.from.address
            ))
            .font(theme.sans.font(size: DashboardMetrics.proposalTextSize))
            .foregroundStyle(theme.ink.color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DashboardMetrics.proposalActionGap) {
                actionButton("Enviar", tone: theme.accent.color, action: onConfirmSend)
                actionButton("Cancelar", tone: theme.ink3.color, action: onCancelSend)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirmar envio")
    }

    /// `↳` em accent quando é rascunho pronto; `ink4` quando é só sugestão.
    private var arrow: some View {
        Text("↳")
            .font(theme.mono.font(size: DashboardMetrics.proposalTextSize))
            .foregroundStyle(
                row.proposal.isReadyDraft ? theme.accent.color : theme.ink4.color
            )
            .accessibilityHidden(true)
    }

    /// O texto da proposta, fatiado como o mockup pinta: negrito 500 `ink`,
    /// corrente `ink2`, itálico `ink3`.
    private var proposalText: some View {
        let segments = DashboardMetrics.proposalSegments(
            text: row.proposal.text,
            isReadyDraft: row.proposal.isReadyDraft,
            usedAgenda: usedAgenda
        )
        var texto = Text("")
        for (indice, segment) in segments.enumerated() {
            let separador = indice == 0 ? "" : " "
            switch segment {
            case let .strong(s):
                texto = texto + Text(separador + s)
                    .font(theme.sans.font(size: DashboardMetrics.proposalTextSize, weight: .medium))
                    .foregroundStyle(theme.ink.color)
            case let .plain(s):
                texto = texto + Text(separador + s)
                    .font(theme.sans.font(size: DashboardMetrics.proposalTextSize))
                    .foregroundStyle(theme.ink2.color)
            case let .note(s):
                texto = texto + Text(separador + s)
                    .font(theme.sans.font(size: DashboardMetrics.proposalTextSize).italic())
                    .foregroundStyle(theme.ink3.color)
            }
        }
        return texto
            .lineSpacing(DashboardMetrics.proposalTextSize * 0.45)
            .lineLimit(2)
    }

    /// As ações da proposta, **em texto**: primária em accent, secundária em
    /// ink3. `keep` não tem ação — só o porquê.
    @ViewBuilder
    private var actions: some View {
        switch row.proposal {
        case .sendDraft:
            HStack(spacing: DashboardMetrics.proposalActionGap) {
                actionButton("Enviar", tone: theme.accent.color, action: onPrimary)
                actionButton("Editar", tone: theme.ink3.color, action: onSecondary)
            }
        case .later:
            HStack(spacing: DashboardMetrics.proposalActionGap) {
                actionButton(
                    DashboardMetrics.laterActionLabel,
                    tone: theme.accent.color, action: onPrimary
                )
                actionButton("Agora", tone: theme.ink3.color, action: onSecondary)
            }
        case .archiveAndLearn:
            HStack(spacing: DashboardMetrics.proposalActionGap) {
                actionButton("Arquivar e aprender", tone: theme.accent.color, action: onPrimary)
                actionButton("Manter", tone: theme.ink3.color, action: onSecondary)
            }
        case .keep:
            EmptyView()
        }
    }

    private func actionButton(
        _ label: String, tone: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.sans.font(size: DashboardMetrics.proposalActionSize, weight: .semibold))
                .foregroundStyle(tone)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}
