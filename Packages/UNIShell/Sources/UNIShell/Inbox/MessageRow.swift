import SwiftUI
import UNIDesign
import UNICore

public struct MessageRow: View {
    /// A barra colorida da conta na borda esquerda da linha.
    /// Protótipo: `box-shadow: inset 3px 0 0 (on ? a.c : soft(a.c, 45))` —
    /// ela existe em **toda** linha, só muda de opacidade quando selecionada.
    static let accountBarWidth: CGFloat = 3

    /// O ponto de não-lida.
    ///
    /// **Por que ele existe.** Até esta tarefa a única diferença entre lida e
    /// não-lida era o peso da fonte do remetente (`.semibold` contra
    /// `.regular`). O dono do projeto usou o app e levou tempo demais para
    /// perceber — e ele tem razão: 13pt de diferença de peso é uma pista para
    /// quem já sabe onde olhar. Mail, Gmail e Outlook todos marcam com um
    /// **ponto**, e é a marca que se enxerga sem procurar.
    ///
    /// **O protótipo não decide isto.** Conferido: `MSGS`, em
    /// `design/OkamiUNI - Mail + Agenda.dc.html`, não tem campo de leitura
    /// nenhum — todas as sete linhas desenham o remetente em `font-weight:
    /// 650` e nenhuma delas tem ponto. O negrito do app já era invenção nossa.
    /// Como o protótipo não marca, o desenho é novo, no idioma dele.
    ///
    /// **Onde ele fica.** Na goteira à esquerda, entre a barra da conta (0–3pt)
    /// e o recuo do texto (`rowPadding.leading`, 16pt) — exatamente a coluna em
    /// que o Mail põe o dele. Entra por `overlay`, **não** no fluxo: assim a
    /// geometria da linha não muda em ponto nenhum, e as medidas de
    /// `MessageRowTests` continuam valendo.
    static let unreadDotDiameter: CGFloat = 7
    /// O centro do ponto na horizontal: meio da goteira de 13pt, sobrando 3pt
    /// para a barra da conta e 3pt para o texto.
    static let unreadDotCenterX: CGFloat = 9.5
    /// O centro na vertical, alinhado com a linha do remetente: `rowPadding.top`
    /// (11) mais meia altura de linha de 13pt. Ele marca a mensagem, e o nome
    /// de quem escreveu é onde o olho entra na linha.
    static let unreadDotCenterY: CGFloat = 19

    @Environment(\.theme) private var theme
    let message: Message
    let accountHost: String
    let accountTint: Color
    let isSelected: Bool

    public init(message: Message, accountHost: String, accountTint: Color, isSelected: Bool) {
        self.message = message
        self.accountHost = accountHost
        self.accountTint = accountTint
        self.isSelected = isSelected
    }

    /// O canto direito da primeira linha. Design (`MSGS`): a mensagem de hoje
    /// mostra a hora (`time: '09:42'`), a de ontem mostra o dia
    /// (`time: 'Ontem'`) — a hora só informa quando o dia já está implícito.
    ///
    /// A escolha sai de `dayOffset`, a mesma fonte do cabeçalho de grupo, e não
    /// de uma comparação com o relógio.
    @ViewBuilder
    private var timeStamp: some View {
        if DayLabel.showsClockTime(forOffset: message.dayOffset) {
            Text(message.receivedAt, format: .dateTime.hour().minute())
        } else if let name = DayLabel.name(forOffset: message.dayOffset) {
            Text(name)
        } else {
            Text(message.receivedAt, format: .dateTime.day().month(.abbreviated))
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {  // protótipo: margin-top: 3px
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.from.name)
                    .font(theme.sans.font(size: 13, weight: message.isRead ? .regular : .semibold))
                    .tracking(-0.005 * 13)  // letter-spacing: -0.005em a 13pt = -0.065pt
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                timeStamp
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }

            Text(message.subject)
                .font(theme.body.font(size: theme.subjectSize, weight: theme.subjectWeight))
                .lineSpacing(0.35 * theme.subjectSize)  // line-height 1.35
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)

            Text(message.snippet)
                .font(theme.sans.font(size: 11.5))
                .lineSpacing(0.45 * 11.5)  // line-height 1.45 × 11.5 − 11.5 = 5.175
                .foregroundStyle(theme.ink3.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                TintChip(label: accountHost, tint: accountTint, emphasized: isSelected)
                ForEach(message.tags) { tag in
                    TagChip(tag: tag)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 5)  // 3 do VStack + 5 = os 8 do `margin-top` do protótipo
        }
        .padding(theme.rowPadding.edgeInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Protótipo: `background: soft(a.c, 10)` quando selecionada — a cor da
        // conta, não o accent do tema.
        .background(isSelected ? accountTint.opacity(0.10) : .clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accountTint.opacity(isSelected ? 1 : 0.45))
                .frame(width: Self.accountBarWidth)
        }
        // O ponto de não-lida, na goteira da esquerda. `accent` do tema, nunca
        // cor de sistema. Some no instante em que a mensagem vira lida, por
        // qualquer caminho — menu de contexto, arraste ou seleção: a linha lê
        // `message.isRead` do `MailStore`, que é `@Observable`.
        .overlay(alignment: .topLeading) {
            if !message.isRead {
                Circle()
                    .fill(theme.accent.color)
                    .frame(width: Self.unreadDotDiameter, height: Self.unreadDotDiameter)
                    .offset(
                        x: Self.unreadDotCenterX - Self.unreadDotDiameter / 2,
                        y: Self.unreadDotCenterY - Self.unreadDotDiameter / 2
                    )
                    .help("Mensagem não lida")
            }
        }
        .hairline(theme.line2, edges: .bottom)
        .contentShape(Rectangle())
    }
}

struct TagChip: View {
    @Environment(\.theme) private var theme
    let tag: Tag

    var body: some View {
        let tint = tag.tintHex.flatMap(TokenColor.init(css:)) ?? theme.ink3
        // O protótipo desenha as marcas com o mesmo `chip()` do host da conta.
        TintChip(label: tag.name, tint: tint.color)
    }
}
