import SwiftUI
import UNIDesign
import UNICore

public struct MessageRow: View {
    /// A barra colorida da conta na borda esquerda da linha.
    /// Protótipo: `box-shadow: inset 3px 0 0 (on ? a.c : soft(a.c, 45))` —
    /// ela existe em **toda** linha, só muda de opacidade quando selecionada.
    ///
    /// A largura é a fina (`UnreadMetrics.quietBarWidth`) na linha lida. Na
    /// não lida ela depende da variante: as que marcam pelo campo engrossam.
    static let accountBarWidth: CGFloat = UnreadMetrics.quietBarWidth

    @Environment(\.theme) private var theme
    let message: Message
    let accountHost: String
    let accountTint: Color
    let isSelected: Bool
    /// Como esta linha marca "não lida". O padrão é o do app inteiro; os
    /// parâmetros nomeados existem para o harness renderizar as três variantes
    /// lado a lado sem mexer no app.
    let emphasis: UnreadEmphasis

    public init(
        message: Message,
        accountHost: String,
        accountTint: Color,
        isSelected: Bool,
        emphasis: UnreadEmphasis = .standard
    ) {
        self.message = message
        self.accountHost = accountHost
        self.accountTint = accountTint
        self.isSelected = isSelected
        self.emphasis = emphasis
    }

    /// A marca vale para a mensagem não lida, e só para ela.
    private var marks: Bool { !message.isRead }

    /// A largura da barra da conta nesta linha.
    private var barWidth: CGFloat {
        marks ? emphasis.barWidth : Self.accountBarWidth
    }

    /// O fundo da linha, antes da seleção.
    ///
    /// A seleção continua mandando quando existe — ela é a resposta a um
    /// clique e não pode ficar atrás de um estado que a pessoa não escolheu.
    /// Fora dela, a não lida das variantes de campo pinta `accentSoft`: um
    /// degrau à frente de `surface`, na mesma família do ponto, e nenhuma cor
    /// de sistema envolvida.
    private var rowBackground: Color {
        if isSelected { return accountTint.opacity(0.10) }
        if marks, emphasis.showsField { return theme.accentSoft.color }
        return .clear
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

    /// A estrela da mensagem sinalizada.
    ///
    /// Fica à **direita**, antes do carimbo de horário, que é onde o Mail põe a
    /// bandeira dele. E fica longe da coluna do ponto de não-lida de propósito:
    /// são dois estados independentes — uma mensagem pode ser lida e
    /// sinalizada, ou não lida e não sinalizada — e empilhar as duas marcas na
    /// mesma coluna faria uma parecer variação da outra.
    ///
    /// Some no instante em que a estrela é desligada, por qualquer caminho:
    /// a linha lê `message.isFlagged` do `MailStore`, que é `@Observable`.
    @ViewBuilder
    private var flagStar: some View {
        if message.isFlagged {
            Image(systemName: "star.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.accent.color)
                .help("Mensagem sinalizada")
                .accessibilityLabel("Sinalizada")
        }
    }

    public var body: some View {
        content
            // Protótipo: `background: soft(a.c, 10)` quando selecionada — a
            // cor da conta, não o accent do tema. A não lida das variantes de
            // campo entra por baixo dessa regra (ver `rowBackground`).
            .background(rowBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(accountTint.opacity(isSelected ? 1 : 0.45))
                    .frame(width: barWidth)
            }
            .overlay(alignment: .topLeading) { unreadDot }
            .hairline(theme.line2, edges: .bottom)
            .contentShape(Rectangle())
    }

    /// O ponto, na coluna que `contentPadding` reservou para ele.
    ///
    /// **Por que `overlay` e não um irmão num `HStack`.** Tentei a coluna como
    /// irmã, e ela é uma irmã gulosa: um `Color.clear` com largura fixa não
    /// opina sobre largura mas aceita toda a altura oferecida, e a linha de
    /// 106pt passou a ocupar os 300 do palco — a barra da conta, que mede a
    /// altura da linha nos testes, foi de 106 para 299. É a mesma família da
    /// `Rectangle` irmã de `docs/decisoes-de-engenharia.md` e do painel do
    /// arraste, e a mesma lição: **a lista não pode pular**.
    ///
    /// Como `overlay`, o ponto não opina sobre nada. A coluna existe do mesmo
    /// jeito — ela é o recuo do conteúdo, e ele desloca de verdade — mas quem a
    /// abre é o `padding`, que é medido pelo conteúdo.
    ///
    /// Ele some no instante em que a mensagem vira lida, por qualquer caminho
    /// — menu de contexto, arraste ou seleção: a linha lê `message.isRead` do
    /// `MailStore`, que é `@Observable`.
    @ViewBuilder
    private var unreadDot: some View {
        if marks, emphasis.showsDot {
            Circle()
                .fill(theme.accent.color)
                .frame(
                    width: UnreadMetrics.dotDiameter,
                    height: UnreadMetrics.dotDiameter
                )
                .offset(
                    x: UnreadMetrics.dotCenterX - UnreadMetrics.dotDiameter / 2,
                    y: UnreadMetrics.dotCenterY - UnreadMetrics.dotDiameter / 2
                )
                .help("Mensagem não lida")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {  // protótipo: margin-top: 3px
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // O remetente — ou o destinatário, em Enviadas. Quem decide é
                // `Message.listHeadline`, no `UNICore`: é regra do produto, e
                // esta linha só a desenha.
                Text(message.listHeadline)
                    .font(theme.sans.font(size: 13, weight: message.isRead ? .regular : .semibold))
                    .tracking(-0.005 * 13)  // letter-spacing: -0.005em a 13pt = -0.065pt
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                flagStar
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
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// O recuo do conteúdo — e, nas variantes com ponto, a coluna dele.
    ///
    /// O texto começa em 24 (20 de coluna + 4) em vez dos 16 de
    /// `rowPadding.leading`. É o deslocamento de layout que o brief autoriza, e
    /// ele vale para **toda** linha da variante, lida ou não: a coluna vazia da
    /// lida é o que impede lidas e não lidas de dançarem para os lados
    /// conforme a caixa se lê.
    private var contentPadding: EdgeInsets {
        var insets = theme.rowPadding.edgeInsets
        if emphasis.showsDot {
            insets.leading = UnreadMetrics.dotColumnWidth + UnreadMetrics.contentInsetWithColumn
        }
        return insets
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
