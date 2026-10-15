import SwiftUI
import UNICore
import UNIDesign

/// As medidas da direção **Tinta** — `design/IA-Tinta.dc.html`, artboard
/// `leitor`. Fora da `View` pelo motivo de sempre.
enum TintaMetrics {

    /// `gap: 14px` entre o assunto e a tinta; `gap: 9px` dentro dela.
    static let blockGap: CGFloat = 9
    static let flowGap: CGFloat = 14

    /// O versalete: `font-size: 10px; letter-spacing: 0.1em`.
    static let capsSize: CGFloat = 10
    static let capsTracking: CGFloat = 0.1
    static let capsGap: CGFloat = 8
    static let sparkle: CGFloat = 11
    /// "OCULTAR": `font-size: 10px; letter-spacing: 0.06em`.
    static let hideTracking: CGFloat = 0.06

    /// A prosa da IA: `font-size: 15.5px; line-height: 1.55; font-weight: 500`.
    static let proseSize: CGFloat = 15.5
    static let proseLineHeight: CGFloat = 1.55

    /// As tarefas: `gap: 7px; font-size: 13.5px`, bolinha de 14 com traço 1,5.
    static let taskGap: CGFloat = 7
    static let taskSize: CGFloat = 13.5
    static let taskRowGap: CGFloat = 10
    static let bullet: CGFloat = 14
    static let bulletStroke: CGFloat = 1.5
    static let taskActionSize: CGFloat = 12.5

    /// O fio: `height: 1.5px; margin-top: 4px`.
    static let inkLine: CGFloat = 1.5
    static let inkLineTop: CGFloat = 4
    /// A nota: `font-size: 11px`.
    static let noteSize: CGFloat = 11

    /// Os passos, enquanto a IA escreve: `font-size: 11.5px; gap: 12px`.
    static let stepSize: CGFloat = 11.5
    static let stepGap: CGFloat = 12

    // MARK: A barra de resposta com o rascunho da IA

    /// `margin: 12px 20px 18px` do cartão da barra.
    static let draftCardMargin = EdgeInsets(top: 12, leading: 20, bottom: 18, trailing: 20)
    /// `padding: 10px 16px 0` do versalete.
    static let draftCapsPadding = EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16)
    static let draftCapsGap: CGFloat = 8
    /// `padding: 9px 16px 4px; font-size: 13.5px; line-height: 1.6`.
    static let draftBodyPadding = EdgeInsets(top: 9, leading: 16, bottom: 4, trailing: 16)
    static let draftBodySize: CGFloat = 13.5
    static let draftBodyLineHeight: CGFloat = 1.6
    /// `padding: 10px 12px 12px 16px; gap: 8px`.
    static let draftActionPadding = EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 12)
    static let draftActionGap: CGFloat = 8
    static let draftHintSize: CGFloat = 12
}

extension Theme {
    /// A tinta da IA: a tinta do tema puxada **um quarto** para o acento.
    ///
    /// É a conta que reproduz os três valores do desenho de uma vez —
    /// `#2d2f4e` no claro, `#dddafc` no escuro, `#E9DFD4` no clássico — e por
    /// ser conta, e não tabela, ela vale para os 28 temas sem exceção.
    var inkAI: TokenColor { ink.mixing(with: accentInk, amount: 0.25) }
}

/// Uma tarefa que a IA escreve no fluxo do e-mail.
///
/// **Toda tarefa aqui tem lastro**: ou a análise já persistida da mensagem
/// disse que ela pede resposta (e então há prazo e evidência), ou a mensagem
/// trouxe um compromisso detectado. Nenhuma tarefa é inventada do texto na
/// hora de desenhar.
struct ReaderInkTask: Identifiable {
    let id: String
    let text: String
    /// "até qui", "hoje" — `nil` quando a análise não achou prazo.
    var deadline: String?
    var urgent = false
    /// O verbo do botão à direita. `nil` desenha a tarefa sem ação.
    var action: String?
    var run: (() -> Void)?
}

/// **A IA escreve no próprio e-mail** — `design/IA-Tinta.dc.html`.
///
/// Sem caixa, sem painel e sem balão: versalete, a prosa na tinta da IA, as
/// tarefas em linha, o fio de tinta e a nota que diz o que aquilo é. Fica
/// entre o assunto e o remetente, dentro do fluxo de leitura, porque é ali
/// que alguém lê antes de decidir se vai ler o resto.
///
/// Um desenho só para os 28 temas: o que o vidro tem de diferente é o halo do
/// orbe e o brilho do botão, e isso sai de `theme.isGlass`. Estrutura, tipos,
/// pesos e folgas são os mesmos em todos.
struct ReaderInkSection: View {

    @Environment(\.theme) private var theme

    /// A prosa da IA: o resumo persistido, ou a última resposta ao vivo.
    let prose: String?
    /// De onde ela veio — "neste Mac", "Codex · ChatGPT".
    let provenance: String
    let tasks: [ReaderInkTask]
    /// A IA está escrevendo agora.
    let isWorking: Bool
    /// Os passos que ela já deu nesta ida, e o que faz agora.
    let steps: [String]
    let onHide: () -> Void

    private var caps: some View {
        HStack(spacing: TintaMetrics.capsGap) {
            Image(systemName: "sparkles")
                .font(.system(size: TintaMetrics.sparkle, weight: .semibold))
                .foregroundStyle(theme.accentInk.color)
                .accessibilityHidden(true)
            Text(L10n.tr("RESUMO E TAREFAS"))
                .font(theme.mono.font(size: TintaMetrics.capsSize, weight: .semibold))
                .tracking(TintaMetrics.capsSize * TintaMetrics.capsTracking)
                .foregroundStyle(theme.accentInk.color)
            Spacer(minLength: TintaMetrics.capsGap)
            Button(action: onHide) {
                Text(L10n.tr("OCULTAR"))
                    .font(theme.mono.font(size: TintaMetrics.capsSize, weight: .semibold))
                    .tracking(TintaMetrics.capsSize * TintaMetrics.hideTracking)
                    .foregroundStyle(theme.ink4.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .help(ReaderPane.recolherResumo)
            .accessibilityLabel(ReaderPane.recolherResumo)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TintaMetrics.blockGap) {
            caps

            if isWorking {
                trabalhando
            }

            if let prose, !prose.isEmpty {
                Text(prose)
                    .font(theme.sans.font(size: TintaMetrics.proseSize, weight: .medium))
                    .lineSpacing(
                        TintaMetrics.proseSize * (TintaMetrics.proseLineHeight - 1.2)
                    )
                    .foregroundStyle(theme.inkAI.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !tasks.isEmpty {
                VStack(alignment: .leading, spacing: TintaMetrics.taskGap) {
                    ForEach(tasks) { tarefa in
                        taskRow(tarefa)
                    }
                }
            }

            AssistantInkLine(height: TintaMetrics.inkLine)
                .padding(.top, TintaMetrics.inkLineTop)

            Text(nota)
                .font(theme.sans.font(size: TintaMetrics.noteSize))
                .foregroundStyle(theme.ink4.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Resumo e tarefas, escrito pela IA"))
    }

    /// A frase do desenho, com a procedência real dentro dela: "escrito pela
    /// IA (neste Mac) · não faz parte do e-mail · some quando você responder".
    ///
    /// As duas coisas que ela precisa dizer: isto **não** é texto da mensagem,
    /// e **quem** escreveu — que com o opt-in remoto ligado não é este Mac.
    private var nota: String {
        L10n.tr(
            "escrito pela IA (\(provenance)) · não faz parte do e-mail · some quando você responder"
        )
    }

    /// Enquanto a IA escreve: os passos cumpridos com ✓ e o atual com o
    /// brilho correndo. Nenhuma linha "pendente" — ver `AssistantWorkingState`.
    private var trabalhando: some View {
        HStack(spacing: TintaMetrics.stepGap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { indice, passo in
                if indice == steps.count - 1 {
                    AssistantShimmerText(text: passo, size: TintaMetrics.stepSize)
                } else {
                    AssistantStepCheck(text: passo, size: TintaMetrics.stepSize)
                }
            }
            if steps.isEmpty {
                AssistantShimmerText(
                    text: L10n.tr("lendo este e-mail…"), size: TintaMetrics.stepSize
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func taskRow(_ tarefa: ReaderInkTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TintaMetrics.taskRowGap) {
            Circle()
                .strokeBorder(theme.accentInk.color, lineWidth: TintaMetrics.bulletStroke)
                .frame(width: TintaMetrics.bullet, height: TintaMetrics.bullet)
                .offset(y: 2)
                .accessibilityHidden(true)
            Text(tarefa.text)
                .font(theme.sans.font(size: TintaMetrics.taskSize))
                .foregroundStyle(theme.inkAI.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: TintaMetrics.taskRowGap)
            if let prazo = tarefa.deadline {
                Text(prazo)
                    .font(theme.mono.font(size: TintaMetrics.noteSize, weight: .medium))
                    .foregroundStyle((tarefa.urgent ? theme.warning : theme.ink4).color)
                    .fixedSize()
            }
            if let acao = tarefa.action, let run = tarefa.run {
                Button(action: run) {
                    Text(acao)
                        .font(theme.sans.font(
                            size: TintaMetrics.taskActionSize, weight: .semibold
                        ))
                        .foregroundStyle(theme.accentInk.color)
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .accessibilityLabel("\(acao): \(tarefa.text)")
            }
        }
    }
}

// MARK: - O menu do ✦ IA

/// O que o ✦ IA abre: as ações do desenho, uma por linha.
///
/// O resultado **não volta para cá**: ele é escrito no próprio e-mail (ver
/// `ReaderInkSection`) ou vai para a barra de resposta, quando é rascunho. O
/// menu é só a porta de entrada — é o que o desenho pede, e é o que tira o
/// painel flutuante do caminho da leitura.
struct ReaderInkMenu: View {

    @Environment(\.theme) private var theme

    /// As sete entradas do desenho, na ordem dele.
    enum Entry: String, CaseIterable, Identifiable {
        case resumir, traduzir, rascunhar, tom, tarefas, evento, termos

        var id: String { rawValue }

        var title: String {
            switch self {
            case .resumir: L10n.tr("Resumir")
            case .traduzir: L10n.tr("Traduzir")
            case .rascunhar: L10n.tr("Rascunhar resposta")
            case .tom: L10n.tr("Mudar o tom")
            case .tarefas: L10n.tr("Extrair tarefas")
            case .evento: L10n.tr("Criar evento")
            case .termos: L10n.tr("Explicar termos")
            }
        }

        var symbol: String {
            switch self {
            case .resumir: "text.alignleft"
            case .traduzir: "character.bubble"
            case .rascunhar: "square.and.pencil"
            case .tom: "slider.horizontal.3"
            case .tarefas: "checklist"
            case .evento: "calendar.badge.plus"
            case .termos: "questionmark.circle"
            }
        }

        /// A pergunta que sai pela mesma rota do campo — ou `nil` quando a
        /// entrada tem caminho próprio (rascunho, tom, evento).
        var question: String? {
            switch self {
            case .resumir: ReaderIntelligencePopover.Action.summary.question
            case .traduzir: ReaderIntelligencePopover.Action.translate.question
            case .tarefas: ReaderIntelligencePopover.Action.pending.question
            case .termos: ReaderIntelligencePopover.Action.terms.question
            case .rascunhar, .tom, .evento: nil
            }
        }

        /// A dica da direita — o idioma para quem traduz, vazio no resto.
        var hint: String {
            self == .traduzir ? AppLanguage.selected.resolved.nativeName : ""
        }
    }

    /// Quais entradas estão disponíveis agora, e o que cada clique faz.
    let isEnabled: (Entry) -> Bool
    let run: (Entry) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Entry.allCases) { entrada in
                row(entrada)
            }
        }
        .padding(6)
        .frame(width: 252)
        .background(theme.glassElevated.color)
        .accessibilityIdentifier("reader-ink-menu")
    }

    private func row(_ entry: Entry) -> some View {
        let habilitada = isEnabled(entry)
        return Button { run(entry) } label: {
            HStack(spacing: 11) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accentInk.color)
                    .frame(width: 17)
                Text(entry.title)
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(theme.ink.color)
                Spacer(minLength: 8)
                if !entry.hint.isEmpty {
                    Text(entry.hint)
                        .font(theme.sans.font(size: 11))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .disabled(!habilitada)
        .accessibilityLabel(entry.title)
    }
}

// MARK: - O rascunho na barra de resposta

/// O rascunho da IA **onde ele já morava**: a barra de resposta recolhida.
///
/// Versalete com o tom em uso, "MUDAR O TOM" e "DESCARTAR"; a prosa do
/// rascunho; e os dois botões. "Revisar e enviar" abre a resposta inteira —
/// nada sai sem revisão, que é a regra da §4 e a promessa do desenho.
struct ReaderInkDraftBar: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let draft: String
    let tone: AssistantDraftTone
    /// O seletor de tom. É `Binding` porque o menu do ✦ IA também o abre: dois
    /// botões, um só estado.
    @Binding var tonesOpen: Bool
    /// `nil` desabilita a troca de tom — é o que acontece sem motor de IA.
    let onTone: ((AssistantDraftTone) -> Void)?
    let onDiscard: () -> Void
    /// "Abrir em janela": o composer cheio, com este rascunho dentro.
    let onPromote: () -> Void
    /// "Revisar e enviar": abre a resposta aqui, com o cursor no texto.
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: TintaMetrics.draftCapsGap) {
                Text(L10n.tr("RASCUNHO DA IA · TOM \(tone.caps)"))
                    .font(theme.mono.font(size: TintaMetrics.capsSize, weight: .semibold))
                    .tracking(TintaMetrics.capsSize * TintaMetrics.capsTracking)
                    .foregroundStyle(theme.accentInk.color)
                    .lineLimit(1)
                if onTone != nil {
                    capsButton(L10n.tr("MUDAR O TOM")) { tonesOpen.toggle() }
                        .popover(isPresented: $tonesOpen, arrowEdge: .top) { tonePicker }
                }
                Spacer(minLength: TintaMetrics.draftCapsGap)
                capsButton(L10n.tr("DESCARTAR"), action: onDiscard)
            }
            .padding(TintaMetrics.draftCapsPadding)

            Text(draft)
                .font(theme.sans.font(size: TintaMetrics.draftBodySize))
                .lineSpacing(
                    TintaMetrics.draftBodySize * (TintaMetrics.draftBodyLineHeight - 1.2)
                )
                .foregroundStyle(theme.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TintaMetrics.draftBodyPadding)
                .contentShape(Rectangle())
                .onTapGesture(perform: onReview)
                .textSelection(.enabled)

            HStack(spacing: TintaMetrics.draftActionGap) {
                Text(L10n.tr("clique no texto para editar"))
                    .font(theme.sans.font(size: TintaMetrics.draftHintSize))
                    .foregroundStyle(theme.ink4.color)
                Spacer(minLength: TintaMetrics.draftActionGap)
                PresencaOutlineButton(title: L10n.tr("Abrir em janela"), action: onPromote)
                PresencaPrimaryButton(title: L10n.tr("Revisar e enviar"), action: onReview)
            }
            .padding(TintaMetrics.draftActionPadding)
        }
        .background(theme.glassCard.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(
                    theme.accentLine.color, lineWidth: Hairline.thickness(displayScale)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Rascunho da IA, tom \(tone.label)"))
    }

    /// Os três tons do desenho da Mesa, no idioma da Tinta: texto, sem
    /// pastilha, e o que está em uso em acento.
    private var tonePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AssistantDraftTone.allCases) { opcao in
                Button {
                    tonesOpen = false
                    onTone?(opcao)
                } label: {
                    HStack(spacing: 8) {
                        Text(opcao.label)
                            .font(theme.sans.font(
                                size: 13, weight: opcao == tone ? .semibold : .regular
                            ))
                            .foregroundStyle((opcao == tone ? theme.accentInk : theme.ink2).color)
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .accessibilityAddTraits(opcao == tone ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(width: 180)
        .background(theme.glassElevated.color)
    }

    private func capsButton(
        _ title: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.mono.font(size: TintaMetrics.capsSize, weight: .semibold))
                .tracking(TintaMetrics.capsSize * TintaMetrics.hideTracking)
                .foregroundStyle(theme.ink4.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel(title)
    }
}
