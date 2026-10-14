import SwiftUI
import UNICore
import UNIDesign

/// A linha da lista no shell **Vidro**.
///
/// Ela não é a `MessageRow` com um `if` dentro, e isso é deliberado: os 26
/// temas opacos continuam desenhando a linha de sempre, byte a byte, porque
/// nenhuma linha daquele arquivo foi tocada. O que muda aqui é o que o
/// protótipo pede (`Caixa-Vidro-Final.dc.html`, `sc-for list="{{waiting}}"`):
///
/// - **sem chips.** O chip do host e as etiquetas saem; no lugar delas, um
///   ponto de 7pt com a cor da conta antes do nome do remetente.
/// - **uma linha de IA** em acento, com ✦, quando a triagem guardada tem algo
///   a dizer — ver `InboxWaitingLine`.
/// - **seleção como cartão elevado**: branco com sombra no claro, branco a 8%
///   no escuro, raio 12. Sem a barra de tinta na borda esquerda.
struct GlassMessageRow: View {
    @Environment(\.theme) private var theme

    let message: Message
    let accountTint: Color
    let isSelected: Bool
    let conversationCount: Int
    let unread: Bool
    let today: Date
    let isChecked: Bool
    let onToggleCheck: (() -> Void)?
    /// A frase de acento, já decidida por `InboxWaitingLine`. `nil` é linha
    /// sem ✦ — e é o caso comum.
    let aiLine: String?
    /// A linha de "MAIS CEDO": remetente, assunto e hora, sem a prévia.
    ///
    /// O protótipo desenha as duas seções com densidades diferentes de
    /// propósito — a de cima é o trabalho de agora e ganha a prévia; a de
    /// baixo é o que já passou e cabe em duas linhas. A frase da IA sobrevive
    /// quando existe: um prazo não deixa de valer por a mensagem ser de ontem.
    var compact = false

    /// O raio do cartão da linha selecionada. Protótipo: `border-radius: 12px`.
    static let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(accountTint)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(message.listHeadline)
                        .font(theme.sans.font(size: 13.5, weight: unread ? .bold : .medium))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    countBadge
                    Spacer(minLength: 4)
                    if message.isFlagged {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.accent.color)
                            .accessibilityLabel(L10n.tr("Sinalizada"))
                    }
                    timeStamp
                        .font(theme.mono.font(size: 10))
                        .foregroundStyle(theme.ink3.color)
                }

                Text(message.subject)
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)

                if !compact {
                    Text(message.snippet)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }

                if let aiLine {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                        Text(aiLine)
                            .font(theme.sans.font(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(theme.accentInk.color)
                    .padding(.top, 2)
                    .accessibilityLabel(aiLine)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 9 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(isSelected ? Self.selectedFill(isDark: theme.isDark) : Color.clear)
                .shadow(
                    color: isSelected && !theme.isDark
                        ? Color(red: 40 / 255, green: 40 / 255, blue: 90 / 255).opacity(0.10)
                        : .clear,
                    radius: 5, x: 0, y: 2
                )
        }
        .contentShape(Rectangle())
    }

    /// Protótipo: `sel: '#ffffff'` no claro, `rgba(255,255,255,0.08)` no
    /// escuro. No claro o cartão é opaco de propósito — é ele que se destaca
    /// do vidro atrás; no escuro, uma camada de luz sobre o mesmo vidro.
    static func selectedFill(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.08) : Color.white
    }

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

    @ViewBuilder
    private var countBadge: some View {
        if conversationCount > 1 {
            Text(String(conversationCount))
                .font(theme.mono.font(size: 10, weight: .semibold))
                .foregroundStyle(theme.ink3.color)
                .accessibilityLabel(L10n.tr("\(conversationCount) mensagens nesta conversa"))
        }
    }

    /// O círculo cheio do protótipo: a cor da conta por fundo e as iniciais em
    /// branco. Clicar marca a conversa, como na linha clássica.
    @ViewBuilder
    private var avatar: some View {
        if let onToggleCheck {
            Button(action: onToggleCheck) { avatarFace }
                .buttonStyle(.plain)
                .help(isChecked ? L10n.tr("Desmarcar conversa") : L10n.tr("Marcar conversa"))
                .accessibilityLabel(isChecked ? L10n.tr("Desmarcar conversa") : L10n.tr("Marcar conversa"))
                .accessibilityAddTraits(isChecked ? .isSelected : [])
        } else {
            avatarFace.accessibilityHidden(true)
        }
    }

    private var avatarFace: some View {
        Group {
            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
            } else {
                Text(message.from.initials)
                    .font(theme.sans.font(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(theme.onAccent.color)
        .frame(width: 36, height: 36)
        .background(isChecked ? theme.accent.color : accountTint)
        .clipShape(Circle())
        .contentShape(Circle())
    }
}
