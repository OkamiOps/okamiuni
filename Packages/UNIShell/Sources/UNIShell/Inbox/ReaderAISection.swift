import SwiftUI
import UNICore
import UNIDesign

/// As medidas do desenho `Leitor-IA2.dc.html` — a IA dentro do leitor.
///
/// Fora da `View` pelo motivo de sempre: medida é dado, e dado se lê e se
/// afirma sem montar janela.
///
/// **O que esta direção corrige.** A "Tinta" escrevia a IA solta no fluxo do
/// e-mail: com dado real ela virava um parágrafo apagado, sem destaque e sem
/// ação, e Rascunhar e Criar evento desapareciam. A faixa colorida que veio
/// depois foi o oposto — a IA gritando por cima da leitura. Aqui o meio-termo
/// do desenho: **em repouso**, uma linha discreta de ações debaixo do assunto;
/// **com resultado**, um cartão com fio de acento à esquerda, o rótulo de quem
/// escreveu, o texto em tinta cheia e sempre o próximo passo como botão.
enum ReaderAIMetrics {

    /// A folga entre os blocos do fluxo de leitura: assunto, remetente,
    /// cartões, corpo. Era `TintaMetrics.flowGap`, e é o mesmo valor.
    static let flowGap: CGFloat = 14

    // MARK: A linha de ações, em repouso

    /// `gap: 2px` entre os botões; `padding: 0 0 11px` e um fio embaixo.
    static let offerGap: CGFloat = 2
    static let offerBottom: CGFloat = 11
    /// A estrela: 14, com `padding: 0 9px 0 1px`.
    static let sparkle: CGFloat = 14
    static let sparkleLeading: CGFloat = 1
    static let sparkleTrailing: CGFloat = 9
    /// Cada ação: `gap: 7px; padding: 6px 10px; font-size: 13px`.
    static let actionGap: CGFloat = 7
    static let actionPaddingH: CGFloat = 10
    static let actionPaddingV: CGFloat = 6
    static let actionSize: CGFloat = 13
    static let actionIcon: CGFloat = 14
    /// "Mais": `gap: 5px; padding: 6px 9px; font-size: 12.5px`.
    static let moreGap: CGFloat = 5
    static let morePaddingH: CGFloat = 9
    static let moreSize: CGFloat = 12.5
    static let moreChevron: CGFloat = 12

    /// O menu do "Mais": `width: 234px; padding: 6px`.
    static let menuWidth: CGFloat = 234
    static let menuPadding: CGFloat = 6
    static let menuRowGap: CGFloat = 10
    static let menuRowPaddingH: CGFloat = 10
    static let menuRowHeight: CGFloat = 32
    static let menuRowSize: CGFloat = 13
    static let menuIcon: CGFloat = 15
    static let menuFootSize: CGFloat = 11.5
    static let menuDot: CGFloat = 6

    // MARK: O cartão do resultado

    /// `border-left: 3px solid accent` — o fio de destaque.
    static let rail: CGFloat = 3
    /// `padding: 13px 16px 12px`, e `gap: 10px` entre os blocos.
    static let cardTop: CGFloat = 13
    static let cardSide: CGFloat = 16
    static let cardBottom: CGFloat = 12
    static let cardGap: CGFloat = 10

    /// O versalete: `font-size: 10px; letter-spacing: 0.11em`, com `gap: 7px`.
    static let capsSize: CGFloat = 10
    static let capsTracking: CGFloat = 0.11
    static let capsGap: CGFloat = 7
    static let capsSparkle: CGFloat = 12
    /// A procedência e o × do canto.
    static let provenanceSize: CGFloat = 11.5
    static let dismissSize: CGFloat = 13

    /// **A prosa é forte**: `font-size: 14.5px; line-height: 1.5;
    /// font-weight: 500`, na tinta cheia do tema. Nunca apagada, nunca com
    /// opacidade baixa — foi exatamente isso que o dono reprovou na Tinta.
    static let proseSize: CGFloat = 14.5
    static let proseLineHeight: CGFloat = 1.5

    /// A linha do estado raso: `font-size: 12px; gap: 7px`.
    static let shallowSize: CGFloat = 12
    static let shallowIcon: CGFloat = 12

    /// As tarefas: `gap: 7px`, texto 13,5/1,45, origem 11,5.
    static let taskGap: CGFloat = 7
    static let taskRowGap: CGFloat = 10
    static let taskSize: CGFloat = 13.5
    static let taskLineHeight: CGFloat = 1.45
    static let taskBox: CGFloat = 15
    static let taskBoxStroke: CGFloat = 1.6
    static let originSize: CGFloat = 11.5

    /// A linha da data achada: `padding: 8px 11px; gap: 10px`.
    static let foundPaddingH: CGFloat = 11
    static let foundPaddingV: CGFloat = 8
    static let foundGap: CGFloat = 10
    static let foundSize: CGFloat = 13
    static let foundIcon: CGFloat = 15
    static let freeSize: CGFloat = 12

    /// Os próximos passos: `gap: 8px; font-size: 12.5px`, forte `8px 14px` e
    /// leve `8px 13px`.
    static let stepsGap: CGFloat = 8
    static let buttonSize: CGFloat = 12.5
    static let buttonPaddingV: CGFloat = 8
    static let buttonPaddingStrong: CGFloat = 14
    static let buttonPaddingLight: CGFloat = 13

    // MARK: O cartão do evento

    /// A pastilha do dia: `width: 46px`, "QUI" em 9 e o número em 18.
    static let dayBadge: CGFloat = 46
    static let dayWeekdaySize: CGFloat = 9
    static let dayWeekdayTracking: CGFloat = 0.08
    static let dayNumberSize: CGFloat = 18
    static let eventRowGap: CGFloat = 13
    static let eventTitleSize: CGFloat = 15
    static let eventDetailSize: CGFloat = 12.5
    static let adjustPaddingH: CGFloat = 12
    static let adjustPaddingV: CGFloat = 7

    // MARK: O cartão do rascunho

    /// `padding: 11px 16px 10px` do versalete.
    static let draftHeadTop: CGFloat = 11
    static let draftHeadBottom: CGFloat = 10
    /// `padding: 0 16px 10px; gap: 8px` do corpo.
    static let draftBodyBottom: CGFloat = 10
    static let draftBodyGap: CGFloat = 8
    static let draftBodySize: CGFloat = 13.5
    static let draftBodyLineHeight: CGFloat = 1.6
    static let draftHintSize: CGFloat = 11.5
    /// `padding: 10px 16px 12px` do pé, com um fio em cima.
    static let draftFootTop: CGFloat = 10
    static let draftFootBottom: CGFloat = 12
    static let draftFootSize: CGFloat = 13
    /// O segmentado do tom: `padding: 2px`, cada opção `4px 11px`, 11,5.
    static let tonePadding: CGFloat = 2
    static let tonePaddingH: CGFloat = 11
    static let tonePaddingV: CGFloat = 4
    static let toneSize: CGFloat = 11.5

    /// Os passos, enquanto a IA escreve.
    static let stepSize: CGFloat = 11.5
    static let stepGap: CGFloat = 12
}

// MARK: - As ações da IA no leitor

/// O que a IA sabe fazer **com este e-mail** — e por qual rota cada coisa sai.
///
/// As três primeiras ficam na linha de repouso; as quatro de baixo moram no
/// "Mais". Nenhuma delas é botão mudo: a que não tem caminho próprio sai pela
/// mesma rota de pergunta do assistente, com o prompt adequado.
enum ReaderAIAction: String, CaseIterable, Identifiable {
    case resumir, rascunhar, evento
    case tarefas, traduzir, tom, termos

    var id: String { rawValue }

    /// As três da linha de repouso, na ordem do desenho.
    static let offer: [ReaderAIAction] = [.resumir, .rascunhar, .evento]
    /// As quatro do "Mais", na ordem do desenho.
    static let more: [ReaderAIAction] = [.tarefas, .traduzir, .tom, .termos]

    var title: String {
        switch self {
        case .resumir: L10n.tr("Resumir")
        case .rascunhar: L10n.tr("Rascunhar resposta")
        case .evento: L10n.tr("Criar evento")
        case .tarefas: L10n.tr("Tirar as tarefas")
        case .traduzir: L10n.tr("Traduzir")
        case .tom: L10n.tr("Mudar o tom")
        case .termos: L10n.tr("Explicar os termos")
        }
    }

    var symbol: String {
        switch self {
        case .resumir: "text.alignleft"
        case .rascunhar: "square.and.pencil"
        case .evento: "calendar.badge.plus"
        case .tarefas: "checklist"
        case .traduzir: "character.bubble"
        case .tom: "slider.horizontal.3"
        case .termos: "questionmark.circle"
        }
    }

    /// A dica da direita — o idioma para quem traduz, vazio no resto.
    var hint: String {
        self == .traduzir ? AppLanguage.selected.resolved.nativeName : ""
    }

    /// A pergunta que sai pela rota do assistente, ou `nil` quando a ação tem
    /// caminho próprio (rascunho, evento, tom).
    ///
    /// Vinha do `ReaderIntelligencePopover`, que saiu junto com o painel
    /// flutuante. O texto é o mesmo: trocá-lo mudaria a resposta de quem já
    /// usa o app, e o que esta tarefa muda é o desenho, não o prompt.
    var question: String? {
        switch self {
        case .resumir:
            "Resuma esta conversa com foco no que eu preciso saber e decidir."
        case .tarefas:
            "Liste pendências, responsáveis e prazos confirmados nesta conversa, um item por linha."
        case .traduzir:
            "Traduza este e-mail para \(AppLanguage.selected.resolved.nativeName), "
                + "mantendo o tom e a formatação. Não resuma: traduza o texto inteiro."
        case .termos:
            "Explique, em uma linha cada, os termos técnicos, siglas e jargões "
                + "deste e-mail que alguém de fora da área não entenderia."
        case .rascunhar, .evento, .tom:
            nil
        }
    }

    /// A pergunta livre que extrai o compromisso, quando a mensagem não trouxe
    /// nenhum detectado. A resposta volta em **uma linha**, e quem a lê é o
    /// `AppointmentPhrase` — o mesmo leitor determinístico da folha de novo
    /// compromisso. A IA acha a frase; a gramática local acha a data.
    static let eventExtraction = """
        Qual compromisso este e-mail propõe? Responda em uma linha só, no formato
        "<título> <dia> <hora>" — por exemplo "Call de revisão do contrato quinta 15h".
        Use apenas o que está escrito no e-mail. Se ele não propõe nenhum encontro
        com dia e hora, responda exatamente "nenhum".
        """

    /// A resposta que diz "não há evento aqui".
    static let noEvent = "nenhum"
}

// MARK: - O evento que a IA propôs

/// O compromisso que a IA tirou **deste** e-mail, à espera de um clique.
///
/// Guarda a mensagem de origem pelo mesmo motivo que `AgendaAddReceipt`: o
/// leitor troca de mensagem sem fechar nada, e uma proposta sem dono apareceria
/// colada na mensagem seguinte.
struct ReaderEventProposal: Identifiable {
    let id = UUID()
    let messageID: String
    let event: DetectedEvent
    /// "do que este e-mail diz", "tirado de “quinta às 15h”".
    let provenance: String
    /// A frase que a folha de compromisso recebe ao "Ajustar" — a mesma que o
    /// `AppointmentPhrase` leu para chegar aqui.
    let phrase: String
}

// MARK: - A oferta em repouso

/// **A linha de ações debaixo do assunto** — o estado de repouso do desenho.
///
/// Sem faixa colorida, sem brilho e sem caixa: a estrela do acento, três
/// verbos e o "Mais", fechados por um fio. É o que a IA oferece antes de
/// alguém pedir nada — e, por não ter superfície própria, ela não disputa a
/// leitura com o e-mail.
///
/// Um desenho só para os 28 temas: o que muda é o acento e a linha do tema,
/// nunca a estrutura.
struct ReaderAIOfferRow: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    /// A ação está disponível agora? Indisponível desenha apagada, com o
    /// motivo no `help` — nunca um botão que recusa em silêncio.
    let isEnabled: (ReaderAIAction) -> Bool
    /// Por que a ação está indisponível, para o `help`.
    let reason: (ReaderAIAction) -> String
    let run: (ReaderAIAction) -> Void
    /// "ChatGPT · GPT-5.1" — quem responde, no pé do menu.
    let provider: String
    @Binding var moreOpen: Bool

    var body: some View {
        HStack(spacing: ReaderAIMetrics.offerGap) {
            Image(systemName: "sparkles")
                .font(.system(size: ReaderAIMetrics.sparkle, weight: .regular))
                .foregroundStyle(theme.accentInk.color)
                .padding(.leading, ReaderAIMetrics.sparkleLeading)
                .padding(.trailing, ReaderAIMetrics.sparkleTrailing)
                .accessibilityHidden(true)

            ForEach(Array(ReaderAIAction.offer.enumerated()), id: \.element.id) { indice, acao in
                action(acao, strong: indice == 0)
            }

            Spacer(minLength: ReaderAIMetrics.offerGap)

            moreButton
        }
        .padding(.bottom, ReaderAIMetrics.offerBottom)
        .hairline(theme.line, edges: .bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("A IA neste e-mail"))
    }

    /// `font-weight: 600` e tinta cheia na primeira; 500 e `ink2` nas outras.
    /// É assim que o desenho diz qual é a ação óbvia sem pintar fundo nenhum.
    private func action(_ acao: ReaderAIAction, strong: Bool) -> some View {
        let habilitada = isEnabled(acao)
        return Button { run(acao) } label: {
            HStack(spacing: ReaderAIMetrics.actionGap) {
                Image(systemName: acao.symbol)
                    .font(.system(size: ReaderAIMetrics.actionIcon, weight: .medium))
                Text(acao.title)
                    .font(theme.sans.font(
                        size: ReaderAIMetrics.actionSize,
                        weight: strong ? .semibold : .medium
                    ))
            }
            .foregroundStyle(
                (!habilitada ? theme.ink4 : (strong ? theme.ink : theme.ink2)).color
            )
            .padding(.horizontal, ReaderAIMetrics.actionPaddingH)
            .padding(.vertical, ReaderAIMetrics.actionPaddingV)
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .disabled(!habilitada)
        .help(habilitada ? acao.title : reason(acao))
        .accessibilityLabel(acao.title)
    }

    private var moreButton: some View {
        Button { moreOpen.toggle() } label: {
            HStack(spacing: ReaderAIMetrics.moreGap) {
                Text(L10n.tr("Mais"))
                    .font(theme.sans.font(size: ReaderAIMetrics.moreSize, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: ReaderAIMetrics.moreChevron, weight: .semibold))
            }
            .foregroundStyle(theme.ink3.color)
            .padding(.horizontal, ReaderAIMetrics.morePaddingH)
            .padding(.vertical, ReaderAIMetrics.actionPaddingV)
            .background(
                (moreOpen ? theme.accentSoft : TokenColor(red: 0, green: 0, blue: 0, opacity: 0)).color
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help(L10n.tr("Mais ações de IA neste e-mail"))
        .accessibilityLabel(L10n.tr("Mais ações de IA"))
        .popover(isPresented: $moreOpen, arrowEdge: .bottom) {
            ReaderAIMenu(
                actions: ReaderAIAction.more,
                provider: provider,
                isEnabled: isEnabled,
                reason: reason,
                run: { acao in
                    moreOpen = false
                    run(acao)
                }
            )
        }
    }
}

/// O menu de ações da IA: uma por linha, e quem responde no pé.
///
/// Dois donos, mesma lista: o "Mais" da linha de repouso mostra as quatro de
/// baixo, e a pastilha "✦ IA ⌥⌘J" do cabeçalho mostra as sete — de lá não há
/// linha de oferta ao lado para completar o resto.
struct ReaderAIMenu: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let actions: [ReaderAIAction]
    let provider: String
    let isEnabled: (ReaderAIAction) -> Bool
    let reason: (ReaderAIAction) -> String
    let run: (ReaderAIAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(actions) { acao in
                menuRow(acao)
            }
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
            HStack(spacing: ReaderAIMetrics.capsGap) {
                Circle()
                    .fill(theme.success.color)
                    .frame(width: ReaderAIMetrics.menuDot, height: ReaderAIMetrics.menuDot)
                    .accessibilityHidden(true)
                Text(provider)
                    .font(theme.sans.font(size: ReaderAIMetrics.menuFootSize))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, ReaderAIMetrics.menuRowPaddingH)
            .padding(.bottom, 4)
        }
        .padding(ReaderAIMetrics.menuPadding)
        .frame(width: ReaderAIMetrics.menuWidth)
        .background(theme.glassElevated.color)
        .accessibilityIdentifier("reader-ai-more-menu")
    }

    private func menuRow(_ acao: ReaderAIAction) -> some View {
        let habilitada = isEnabled(acao)
        return Button { run(acao) } label: {
            HStack(spacing: ReaderAIMetrics.menuRowGap) {
                Image(systemName: acao.symbol)
                    .font(.system(size: ReaderAIMetrics.menuIcon - 2, weight: .medium))
                    .foregroundStyle((habilitada ? theme.ink3 : theme.ink4).color)
                    .frame(width: ReaderAIMetrics.menuIcon)
                Text(acao.title)
                    .font(theme.sans.font(size: ReaderAIMetrics.menuRowSize))
                    .foregroundStyle((habilitada ? theme.ink : theme.ink4).color)
                Spacer(minLength: ReaderAIMetrics.stepsGap)
                if !acao.hint.isEmpty {
                    Text(acao.hint)
                        .font(theme.sans.font(size: ReaderAIMetrics.menuFootSize))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, ReaderAIMetrics.menuRowPaddingH)
            .frame(height: ReaderAIMetrics.menuRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .disabled(!habilitada)
        .help(habilitada ? acao.title : reason(acao))
        .accessibilityLabel(acao.title)
    }
}

// MARK: - A casca dos cartões

/// O cartão da IA: superfície do tema, **fio de acento à esquerda** e o
/// contorno de sempre. É o que dá presença ao resultado sem faixa colorida.
///
/// `glassCard` e `line` são tokens, não cores de vidro: nos 26 temas opacos
/// eles caem em `surface` e `line`, e o cartão continua sendo o mesmo objeto.
struct ReaderAICardShell: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.glassCard.color)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(theme.accent.color)
                    .frame(width: ReaderAIMetrics.rail)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                    .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
            }
    }
}

extension View {
    /// Veste o cartão da IA — ver `ReaderAICardShell`.
    func readerAICard() -> some View {
        modifier(ReaderAICardShell())
    }
}

/// O versalete do cartão: ✦ + "RESUMO · ESCRITO PELA IA", a procedência e o ×.
struct ReaderAICaps: View {
    @Environment(\.theme) private var theme

    let caps: String
    let provenance: String
    /// `nil` desenha o cartão sem o × — é o caso do evento proposto, que tem
    /// "Descartar" no pé.
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: ReaderAIMetrics.capsGap) {
            Image(systemName: "sparkles")
                .font(.system(size: ReaderAIMetrics.capsSparkle, weight: .semibold))
                .foregroundStyle(theme.accentInk.color)
                .accessibilityHidden(true)
            Text(caps)
                .font(theme.mono.font(size: ReaderAIMetrics.capsSize, weight: .semibold))
                .tracking(ReaderAIMetrics.capsSize * ReaderAIMetrics.capsTracking)
                .foregroundStyle(theme.accentInk.color)
                .lineLimit(1)
            Spacer(minLength: ReaderAIMetrics.capsGap)
            if !provenance.isEmpty {
                Text(provenance)
                    .font(theme.sans.font(size: ReaderAIMetrics.provenanceSize))
                    .foregroundStyle(theme.ink4.color)
                    .lineLimit(1)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: ReaderAIMetrics.dismissSize, weight: .medium))
                        .foregroundStyle(theme.ink3.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .help(L10n.tr("Dispensar o que a IA escreveu"))
                .accessibilityLabel(L10n.tr("Dispensar o que a IA escreveu"))
            }
        }
    }
}

// MARK: - Os botões do desenho

/// O botão forte do cartão: acento cheio, `8px 14px`, 12,5/600.
struct ReaderAIStrongButton: View {
    @Environment(\.theme) private var theme

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: ReaderAIMetrics.buttonSize, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, ReaderAIMetrics.buttonPaddingStrong)
                .padding(.vertical, ReaderAIMetrics.buttonPaddingV)
                .background(theme.accent.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// O botão leve: sem fundo, contorno de `line2`, `8px 13px`, 12,5/500.
struct ReaderAILightButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: ReaderAIMetrics.buttonSize, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .padding(.horizontal, ReaderAIMetrics.buttonPaddingLight)
                .padding(.vertical, ReaderAIMetrics.buttonPaddingV)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            theme.line2.color, lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// "Descartar": texto só, `ink3`, 12,5.
struct ReaderAIPlainButton: View {
    @Environment(\.theme) private var theme

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: ReaderAIMetrics.buttonSize, weight: .medium))
                .foregroundStyle(theme.ink3.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

// MARK: - O próximo passo

/// Um próximo passo do cartão. **Todo cartão tem pelo menos um**: um resultado
/// que não oferece o que fazer em seguida é o defeito que esta direção veio
/// consertar.
struct ReaderAIStep: Identifiable {
    let id: String
    let title: String
    var strong = false
    let run: () -> Void
}

// MARK: - Uma tarefa escrita pela IA

/// Uma tarefa que o cartão lista em "O QUE SOBRA PARA VOCÊ".
///
/// **Toda tarefa aqui tem lastro**: ou a análise já persistida da mensagem
/// disse que ela pede resposta (e então há prazo e evidência), ou a mensagem
/// trouxe um compromisso detectado. Nenhuma é inventada do texto na hora de
/// desenhar.
struct ReaderAITask: Identifiable {
    let id: String
    let text: String
    /// "3º parágrafo", "até qui" — de onde ela saiu.
    var origin: String?
    var urgent = false
}

// MARK: - O cartão do resultado

/// **O resultado da IA, com presença e calmo** — `Leitor-IA2`, estados
/// `resumo` e `raso`.
///
/// Fio de acento à esquerda, o rótulo de quem escreveu, o texto em tinta cheia
/// e, sempre, o próximo passo. No e-mail sem nada a fazer (o estado raso) ele
/// **diz isso**: "procurei prazos, tarefas e eventos — não há nenhum neste
/// e-mail", e ainda assim oferece Rascunhar e Perguntar.
struct ReaderAIResultCard: View {

    @Environment(\.theme) private var theme

    let caps: String
    let prose: String?
    let provenance: String
    /// A IA está escrevendo agora: os passos cumpridos e o atual.
    let isWorking: Bool
    let steps: [String]
    /// A frase do estado raso, ou `nil` quando há o que fazer.
    let shallowNote: String?
    let tasks: [ReaderAITask]
    /// A data achada no texto, quando há uma e ela ainda não está na agenda.
    let foundDate: (text: String, note: String, free: String?)?
    let nextSteps: [ReaderAIStep]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ReaderAIMetrics.cardGap) {
            ReaderAICaps(caps: caps, provenance: provenance, onDismiss: onDismiss)

            if isWorking {
                working
            }

            if let prose, !prose.isEmpty {
                Text(prose)
                    .font(theme.sans.font(size: ReaderAIMetrics.proseSize, weight: .medium))
                    .lineSpacing(
                        ReaderAIMetrics.proseSize * (ReaderAIMetrics.proseLineHeight - 1.2)
                    )
                    .tracking(ReaderAIMetrics.proseSize * -0.005)
                    // **Tinta cheia.** `ink`, e não `ink2`, `ink3` nem
                    // `opacity`: o texto da IA é para ler.
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if let shallowNote {
                HStack(spacing: ReaderAIMetrics.capsGap) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: ReaderAIMetrics.shallowIcon, weight: .medium))
                        .accessibilityHidden(true)
                    Text(shallowNote)
                        .font(theme.sans.font(size: ReaderAIMetrics.shallowSize))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.ink4.color)
            }

            if !tasks.isEmpty {
                taskList
            }

            if let foundDate {
                found(foundDate)
            }

            if !nextSteps.isEmpty {
                HStack(spacing: ReaderAIMetrics.stepsGap) {
                    ForEach(nextSteps) { passo in
                        if passo.strong {
                            ReaderAIStrongButton(title: passo.title, action: passo.run)
                        } else {
                            ReaderAILightButton(title: passo.title, action: passo.run)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, ReaderAIMetrics.cardTop)
        .padding(.bottom, ReaderAIMetrics.cardBottom)
        .padding(.leading, ReaderAIMetrics.cardSide + ReaderAIMetrics.rail)
        .padding(.trailing, ReaderAIMetrics.cardSide)
        .readerAICard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Resumo escrito pela IA"))
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: ReaderAIMetrics.taskGap) {
            Text(L10n.tr("O QUE SOBRA PARA VOCÊ"))
                .font(theme.mono.font(size: ReaderAIMetrics.capsSize, weight: .semibold))
                .tracking(ReaderAIMetrics.capsSize * ReaderAIMetrics.capsTracking)
                .foregroundStyle(theme.ink4.color)
            ForEach(tasks) { tarefa in
                HStack(alignment: .firstTextBaseline, spacing: ReaderAIMetrics.taskRowGap) {
                    RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75)
                        .strokeBorder(
                            theme.line2.color, lineWidth: ReaderAIMetrics.taskBoxStroke
                        )
                        .frame(width: ReaderAIMetrics.taskBox, height: ReaderAIMetrics.taskBox)
                        .offset(y: 2)
                        .accessibilityHidden(true)
                    Text(tarefa.text)
                        .font(theme.sans.font(size: ReaderAIMetrics.taskSize))
                        .lineSpacing(
                            ReaderAIMetrics.taskSize * (ReaderAIMetrics.taskLineHeight - 1.2)
                        )
                        .foregroundStyle(theme.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: ReaderAIMetrics.taskRowGap)
                    if let origem = tarefa.origin {
                        Text(origem)
                            .font(theme.sans.font(size: ReaderAIMetrics.originSize))
                            .foregroundStyle((tarefa.urgent ? theme.warning : theme.ink4).color)
                            .fixedSize()
                    }
                }
            }
        }
    }

    /// A data que a IA achou no texto, com o veredito da agenda ao lado.
    private func found(_ data: (text: String, note: String, free: String?)) -> some View {
        HStack(spacing: ReaderAIMetrics.foundGap) {
            Image(systemName: "calendar")
                .font(.system(size: ReaderAIMetrics.foundIcon, weight: .medium))
                .foregroundStyle(theme.accentInk.color)
                .accessibilityHidden(true)
            Text(data.text)
                .font(theme.sans.font(size: ReaderAIMetrics.foundSize, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(data.note)
                .font(theme.sans.font(size: ReaderAIMetrics.foundSize))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
            Spacer(minLength: ReaderAIMetrics.capsGap)
            if let livre = data.free {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: ReaderAIMetrics.freeSize, weight: .bold))
                    Text(livre)
                        .font(theme.sans.font(size: ReaderAIMetrics.freeSize))
                }
                .foregroundStyle(theme.success.color)
                .fixedSize()
            }
        }
        .padding(.horizontal, ReaderAIMetrics.foundPaddingH)
        .padding(.vertical, ReaderAIMetrics.foundPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
    }

    /// Enquanto a IA escreve: os passos cumpridos com ✓ e o atual com o brilho
    /// correndo. Nenhuma linha "pendente" — ver `AssistantWorkingState`.
    private var working: some View {
        HStack(spacing: ReaderAIMetrics.stepGap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { indice, passo in
                if indice == steps.count - 1 {
                    AssistantShimmerText(text: passo, size: ReaderAIMetrics.stepSize)
                } else {
                    AssistantStepCheck(text: passo, size: ReaderAIMetrics.stepSize)
                }
            }
            if steps.isEmpty {
                AssistantShimmerText(
                    text: L10n.tr("lendo este e-mail…"), size: ReaderAIMetrics.stepSize
                )
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - O cartão do evento

/// **O evento tirado deste e-mail** — `Leitor-IA2`, estado `evento`.
///
/// A pastilha do dia, o título e a hora, a trilha do dia com a faixa nova
/// tracejada (a mesma `DayFreeBusyStrip` da folha de novo compromisso: a
/// agenda é real, nada aqui é exemplo) e os botões. "Ajustar" abre a folha de
/// compromisso com a frase já dentro; "Adicionar à agenda" cria pelo caminho
/// de sempre, com "Desfazer".
struct ReaderAIEventCard: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    /// O compromisso proposto, e de onde ele saiu.
    let event: DetectedEvent
    let provenance: String
    let weekday: String
    let dayNumber: String
    let timeRange: String
    /// O dia, contado como `AgendaItem.dayOffset`.
    let dayOffset: Int
    let onAdjust: () -> Void
    let onAdd: () -> Void
    /// "Avisar a Marina": um rascunho de resposta, pela rota de sempre.
    let notifyTitle: String?
    let onNotify: (() -> Void)?
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ReaderAIMetrics.capsGap + 4) {
            ReaderAICaps(
                caps: L10n.tr("EVENTO · TIRADO DESTE E-MAIL"),
                provenance: provenance,
                onDismiss: nil
            )

            HStack(spacing: ReaderAIMetrics.eventRowGap) {
                dayBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.label)
                        .font(theme.sans.font(
                            size: ReaderAIMetrics.eventTitleSize, weight: .semibold
                        ))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(timeRange)
                        .font(theme.sans.font(size: ReaderAIMetrics.eventDetailSize))
                        .foregroundStyle(theme.ink2.color)
                        .lineLimit(1)
                }
                Spacer(minLength: ReaderAIMetrics.stepsGap)
                Button(action: onAdjust) {
                    Text(L10n.tr("Ajustar"))
                        .font(theme.sans.font(
                            size: ReaderAIMetrics.eventDetailSize, weight: .medium
                        ))
                        .foregroundStyle(theme.ink2.color)
                        .padding(.horizontal, ReaderAIMetrics.adjustPaddingH)
                        .padding(.vertical, ReaderAIMetrics.adjustPaddingV)
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(
                                    theme.line2.color,
                                    lineWidth: Hairline.thickness(displayScale)
                                )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .fixedSize()
                .help(L10n.tr("Abre a folha de compromisso com este evento, para ajustar"))
                .accessibilityLabel(L10n.tr("Ajustar o evento"))
            }

            DayFreeBusyStrip(
                store: store,
                dayOffset: dayOffset,
                day: Calendar.current.startOfDay(for: event.start),
                startMinute: Self.minute(event.start),
                endMinute: Self.minute(event.end)
            )

            HStack(spacing: ReaderAIMetrics.stepsGap) {
                ReaderAIStrongButton(title: L10n.tr("Adicionar à agenda"), action: onAdd)
                if let notifyTitle, let onNotify {
                    ReaderAILightButton(title: notifyTitle, action: onNotify)
                }
                Spacer(minLength: ReaderAIMetrics.stepsGap)
                ReaderAIPlainButton(title: L10n.tr("Descartar"), action: onDiscard)
            }
            .padding(.top, 1)
        }
        .padding(.top, ReaderAIMetrics.cardTop)
        .padding(.bottom, ReaderAIMetrics.cardBottom)
        .padding(.leading, ReaderAIMetrics.cardSide + ReaderAIMetrics.rail)
        .padding(.trailing, ReaderAIMetrics.cardSide)
        .readerAICard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Evento proposto pela IA"))
    }

    /// `QUI` sobre o acento e o `16` embaixo, numa pastilha de 46.
    private var dayBadge: some View {
        VStack(spacing: 0) {
            Text(weekday)
                .font(theme.mono.font(size: ReaderAIMetrics.dayWeekdaySize, weight: .bold))
                .tracking(ReaderAIMetrics.dayWeekdaySize * ReaderAIMetrics.dayWeekdayTracking)
                .foregroundStyle(theme.onAccent.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(theme.accent.color)
            Text(dayNumber)
                .font(theme.sans.font(size: ReaderAIMetrics.dayNumberSize, weight: .bold))
                .foregroundStyle(theme.ink.color)
                .padding(.top, 3)
                .padding(.bottom, 5)
        }
        .frame(width: ReaderAIMetrics.dayBadge)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
        }
        .accessibilityHidden(true)
    }

    /// Minuto de parede, lido do calendário — a mesma técnica de
    /// `DetectedEventConversion`, e pela mesma razão de fuso.
    static func minute(_ date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

// MARK: - O cartão do rascunho

/// **O rascunho que a IA escreveu** — `Leitor-IA2`, estado `rascunho`.
///
/// Atracado no fim do e-mail, como o desenho o põe: o versalete com para quem
/// é, o segmentado do tom, a prosa do rascunho e três saídas. "Enviar
/// revisando" abre a barra de resposta com o texto dentro e o cursor nele —
/// **nada sai sem revisão**; "Abrir no compositor" leva o mesmo rascunho para
/// a janela cheia.
struct ReaderAIDraftCard: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    /// "RASCUNHO · PARA MARINA".
    let caps: String
    let draft: String
    let tone: AssistantDraftTone
    /// `nil` desabilita a troca de tom — é o que acontece sem motor de IA.
    let onTone: ((AssistantDraftTone) -> Void)?
    let hint: String
    let onReview: () -> Void
    let onPromote: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ReaderAIMetrics.capsGap) {
                Image(systemName: "sparkles")
                    .font(.system(size: ReaderAIMetrics.capsSparkle, weight: .semibold))
                    .foregroundStyle(theme.accentInk.color)
                    .accessibilityHidden(true)
                Text(caps)
                    .font(theme.mono.font(size: ReaderAIMetrics.capsSize, weight: .semibold))
                    .tracking(ReaderAIMetrics.capsSize * ReaderAIMetrics.capsTracking)
                    .foregroundStyle(theme.accentInk.color)
                    .lineLimit(1)
                Spacer(minLength: ReaderAIMetrics.capsGap)
                if onTone != nil {
                    tonePicker
                }
            }
            .padding(.top, ReaderAIMetrics.draftHeadTop)
            .padding(.bottom, ReaderAIMetrics.draftHeadBottom)
            .padding(.leading, ReaderAIMetrics.cardSide + ReaderAIMetrics.rail)
            .padding(.trailing, ReaderAIMetrics.cardSide)

            VStack(alignment: .leading, spacing: ReaderAIMetrics.draftBodyGap) {
                Text(draft)
                    .font(theme.sans.font(size: ReaderAIMetrics.draftBodySize))
                    .lineSpacing(
                        ReaderAIMetrics.draftBodySize * (ReaderAIMetrics.draftBodyLineHeight - 1.2)
                    )
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if !hint.isEmpty {
                    Text(hint)
                        .font(theme.sans.font(size: ReaderAIMetrics.draftHintSize))
                        .foregroundStyle(theme.ink4.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, ReaderAIMetrics.draftBodyBottom)
            .padding(.leading, ReaderAIMetrics.cardSide + ReaderAIMetrics.rail)
            .padding(.trailing, ReaderAIMetrics.cardSide)
            .contentShape(Rectangle())
            .onTapGesture(perform: onReview)

            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))

            HStack(spacing: ReaderAIMetrics.stepsGap) {
                Button(action: onReview) {
                    Text(L10n.tr("Enviar revisando"))
                        .font(theme.sans.font(
                            size: ReaderAIMetrics.draftFootSize, weight: .semibold
                        ))
                        .foregroundStyle(theme.onAccent.color)
                        .padding(.horizontal, 15)
                        .padding(.vertical, ReaderAIMetrics.buttonPaddingV)
                        .background(theme.accent.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
                .fixedSize()
                .help(L10n.tr("Abre a resposta com este rascunho dentro, para revisar antes de enviar"))

                Button(action: onPromote) {
                    Text(L10n.tr("Abrir no compositor"))
                        .font(theme.sans.font(
                            size: ReaderAIMetrics.draftFootSize, weight: .medium
                        ))
                        .foregroundStyle(theme.ink2.color)
                        .padding(.horizontal, ReaderAIMetrics.buttonPaddingLight)
                        .padding(.vertical, ReaderAIMetrics.buttonPaddingV)
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(
                                    theme.line2.color,
                                    lineWidth: Hairline.thickness(displayScale)
                                )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .fixedSize()
                .help(L10n.tr("Leva este rascunho para a janela do compositor"))

                Spacer(minLength: ReaderAIMetrics.stepsGap)
                ReaderAIPlainButton(title: L10n.tr("Descartar"), action: onDiscard)
            }
            .padding(.top, ReaderAIMetrics.draftFootTop)
            .padding(.bottom, ReaderAIMetrics.draftFootBottom)
            .padding(.leading, ReaderAIMetrics.cardSide + ReaderAIMetrics.rail)
            .padding(.trailing, ReaderAIMetrics.cardSide)
        }
        .readerAICard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Rascunho da IA, tom \(tone.label)"))
    }

    /// Os três tons numa calha: `padding: 2px`, o escolhido em cima.
    private var tonePicker: some View {
        HStack(spacing: 0) {
            ForEach(AssistantDraftTone.allCases) { opcao in
                Button { onTone?(opcao) } label: {
                    Text(opcao.label)
                        .font(theme.sans.font(
                            size: ReaderAIMetrics.toneSize,
                            weight: opcao == tone ? .semibold : .medium
                        ))
                        .foregroundStyle((opcao == tone ? theme.ink : theme.ink3).color)
                        .padding(.horizontal, ReaderAIMetrics.tonePaddingH)
                        .padding(.vertical, ReaderAIMetrics.tonePaddingV)
                        .background(
                            (opcao == tone ? theme.glassCard : TokenColor(
                                red: 0, green: 0, blue: 0, opacity: 0
                            )).color
                        )
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75))
                        .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall * 0.75)
                .accessibilityLabel(L10n.tr("Tom \(opcao.label)"))
                .accessibilityAddTraits(opcao == tone ? .isSelected : [])
            }
        }
        .padding(ReaderAIMetrics.tonePadding)
        .background(theme.glassSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Tom do rascunho"))
    }
}
