import SwiftUI
import UNICore
import UNIDesign

/// As medidas da gaveta (09) e da janela (10), copiadas dos desenhos. Como o
/// `DashboardMetrics`, mora **fora** da `View`: uma `View` é `@MainActor`
/// implícito e um `static` lá dentro estoura quando um teste `nonisolated` o
/// lê.
enum AssistantDrawerMetrics {

    /// "Gaveta (09) — 440 largura · por cima, borda direita".
    static let width: CGFloat = 440
    /// "fundo atrás a 45%".
    static let backdropOpacity: Double = 0.45
    /// "sombra -30 0 80 rgba(0,0,0,.6)".
    static let shadowRadius: CGFloat = 40
    static let shadowX: CGFloat = -30
    static let shadowOpacity: Double = 0.6

    /// Cabeçalho: `padding: 18px 20px 14px; gap: 12px`.
    static let headerPadding = EdgeInsets(top: 18, leading: 20, bottom: 14, trailing: 20)
    static let headerGap: CGFloat = 12
    static let iconSize: CGFloat = 16
    static let titleSize: CGFloat = 13.5
    static let headerActionSize: CGFloat = 15

    /// Linha do contexto: `padding: 10px 20px; gap: 8px; font-size: 11.5px`.
    static let contextPadding = EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
    static let contextGap: CGFloat = 8
    static let contextSize: CGFloat = 11.5

    /// Transcript: `padding: 18px 20px; gap: 16px`.
    static let transcriptPadding = EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)
    static let turnGap: CGFloat = 16
    /// `.q { max-width: 78%; padding: 9px 13px }`; `.a { max-width: 92% }`.
    static let questionMaxWidthRatio: CGFloat = 0.78
    static let answerMaxWidthRatio: CGFloat = 0.92
    static let questionPadding = EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13)
    static let turnTextSize: CGFloat = 13.5

    /// Cartão de ação: `.act { margin-top: 10px; gap: 12px; padding: 10px 12px }`.
    static let cardTopSpacing: CGFloat = 10
    static let cardGap: CGFloat = 12
    static let cardPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let cardTextSize: CGFloat = 12.5
    /// `.go { height: 26px; padding: 0 12px; font-size: 12px }`.
    static let cardButtonHeight: CGFloat = 26
    static let cardButtonPadding: CGFloat = 12
    static let cardActionSize: CGFloat = 12

    /// Chips: `padding: 12px 20px 0; gap: 6px`; chip `height: 26px; padding: 0 11px`.
    static let chipsPadding = EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20)
    static let chipGap: CGFloat = 6
    static let chipHeight: CGFloat = 26
    static let chipPadding: CGFloat = 11
    static let chipTextSize: CGFloat = 12

    /// Campo: `padding: 12px 20px 18px`; caixa `height: 40px; padding: 0 6 0 14`.
    static let fieldPadding = EdgeInsets(top: 12, leading: 20, bottom: 18, trailing: 20)
    static let fieldHeight: CGFloat = 40
    static let fieldLeadingPadding: CGFloat = 14
    static let fieldTrailingPadding: CGFloat = 6
    static let fieldGap: CGFloat = 10
    static let fieldTextSize: CGFloat = 13.5
    /// `⏎` mono 10; o botão ↑ 28 quadrado em accent.
    static let returnHintSize: CGFloat = 10
    static let sendButtonSide: CGFloat = 28
    static let sendGlyphSize: CGFloat = 13

    /// Rodapé: `margin-top: 8px; font-size: 11px`.
    static let footerTopSpacing: CGFloat = 8
    static let footerSize: CGFloat = 11

    static let capsSize: CGFloat = 9.5

    /// A janela destacada (10): 460 × 620.
    static let windowSize = CGSize(width: 460, height: 620)
    static let windowPadding: CGFloat = 18

    /// O deslize da gaveta. Curto, e só isso: "sem efeito além disso".
    static let slide: Animation = .easeOut(duration: 0.18)
}

// MARK: - A gaveta

/// A gaveta do assistente — `design/09-assistente-gaveta.dc.html`.
///
/// **É overlay, e nada atrás dela se mexe.** O conteúdo da tela fica a 45% de
/// opacidade e no mesmo lugar: uma gaveta que empurra a caixa faz a pessoa
/// perder o parágrafo que estava lendo por ter feito uma pergunta.
///
/// Toda proposta da resposta vira um cartão, e **nenhum cartão executa
/// sozinho**: nem por ⏎ no campo, que só manda a pergunta.
struct AssistantDrawer: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let conversation: AssistantConversation
    let session: AssistantSession
    /// O contexto em uso agora, já resolvido.
    let context: AssistantDrawerContext
    /// O nome do herói do dia, para o primeiro chip. `nil` sem herói.
    let heroName: String?
    let onSwapContext: () -> Void
    let onDetach: () -> Void
    let onClose: () -> Void
    let onRun: (AssistantProposalCard) -> Void
    let onReveal: (String) -> Void

    /// O foco vai para o campo ao abrir, e volta para onde estava ao fechar —
    /// quem devolve é `InboxScreen`, que sabe de onde veio.
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            contextRow
            transcript
            chips
            field
        }
        .frame(width: AssistantDrawerMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface.color)
        .hairline(theme.btnLine, edges: .leading)
        .shadow(
            color: .black.opacity(AssistantDrawerMetrics.shadowOpacity),
            radius: AssistantDrawerMetrics.shadowRadius,
            x: AssistantDrawerMetrics.shadowX,
            y: 0
        )
        // O foco vai para o campo ao abrir; ao fechar, volta para onde estava.
        .background(GuardaEDevolveOFoco())
        .accessibilityIdentifier("assistant-drawer")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistente")
        .task { fieldFocused = true }
    }

    // MARK: Cabeçalho

    private var header: some View {
        HStack(spacing: AssistantDrawerMetrics.headerGap) {
            Image(systemName: "bubble.left")
                .font(.system(size: AssistantDrawerMetrics.iconSize, weight: .medium))
                .foregroundStyle(theme.accent.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(AssistantDrawerCopy.title)
                    .font(theme.sans.font(
                        size: AssistantDrawerMetrics.titleSize, weight: .semibold
                    ))
                    .foregroundStyle(theme.ink.color)
                // O destino de verdade, lido da conversa — não texto fixo. A
                // legenda que promete "neste Mac" com o Grok escolhido é o
                // defeito da §1.2, e ele não volta por aqui.
                Text(destinationLabel)
                    .capsLabel(size: AssistantDrawerMetrics.capsSize)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            headerButton(
                "arrow.up.forward.square", "Destacar em janela", action: onDetach
            )
            headerButton("xmark", "Fechar o assistente", action: onClose)
        }
        .padding(AssistantDrawerMetrics.headerPadding)
        .hairline(theme.line, edges: .bottom)
    }

    private var destinationLabel: String {
        let destino = conversation.destination
        let detalhe = destino.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detalhe.isEmpty ? destino.label : "\(destino.label) · \(detalhe)"
    }

    private func headerButton(
        _ symbol: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: AssistantDrawerMetrics.headerActionSize, weight: .medium))
                .foregroundStyle(theme.ink3.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel(label)
    }

    // MARK: Contexto

    private var contextRow: some View {
        HStack(spacing: AssistantDrawerMetrics.contextGap) {
            Text(AssistantDrawerCopy.contextPrefix)
                .font(theme.sans.font(size: AssistantDrawerMetrics.contextSize))
                .foregroundStyle(theme.ink3.color)
            Text(context.label)
                .font(theme.sans.font(
                    size: AssistantDrawerMetrics.contextSize, weight: .semibold
                ))
                .foregroundStyle(theme.ink.color)
            Spacer(minLength: 8)
            Button(action: onSwapContext) {
                Text(AssistantDrawerCopy.swapLabel)
                    .capsLabel(size: AssistantDrawerMetrics.capsSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .accessibilityLabel("Trocar o contexto da conversa")
        }
        .padding(AssistantDrawerMetrics.contextPadding)
        .hairline(theme.line2, edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Falando sobre \(context.label)")
    }

    // MARK: Conversa

    private var transcript: some View {
        AssistantTranscript(
            conversation: conversation,
            session: session,
            width: AssistantDrawerMetrics.width,
            padding: AssistantDrawerMetrics.transcriptPadding,
            onRun: onRun,
            onReveal: onReveal
        )
        .frame(maxHeight: .infinity)
    }

    // MARK: Chips

    private var chips: some View {
        FlowLayout(spacing: AssistantDrawerMetrics.chipGap) {
            ForEach(AssistantDrawerCopy.chips(heroName: heroName), id: \.self) { texto in
                Button { conversation.ask(texto) } label: {
                    Text(texto)
                        .font(theme.sans.font(size: AssistantDrawerMetrics.chipTextSize))
                        .foregroundStyle(theme.ink2.color)
                        .padding(.horizontal, AssistantDrawerMetrics.chipPadding)
                        .frame(height: AssistantDrawerMetrics.chipHeight)
                        .background(theme.surface2.color)
                        // Raio `radiusSmall`, e não a cápsula do mockup: a
                        // tabela do 08 fecha a questão com "Raios só r2".
                        // Divergência registrada no relatório.
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(
                                    theme.btnLine.color,
                                    lineWidth: Hairline.thickness(displayScale)
                                )
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .disabled(conversation.isLoading)
            }
        }
        .padding(AssistantDrawerMetrics.chipsPadding)
    }

    // MARK: Campo

    private var field: some View {
        AssistantAskField(conversation: conversation, focused: $fieldFocused, showsFooter: true)
            .padding(AssistantDrawerMetrics.fieldPadding)
    }
}

// MARK: - O campo, partilhado pela gaveta e pela janela

struct AssistantAskField: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let conversation: AssistantConversation
    var focused: FocusState<Bool>.Binding
    let showsFooter: Bool

    private var draft: Binding<String> {
        Binding(get: { conversation.draft }, set: { conversation.draft = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AssistantDrawerMetrics.footerTopSpacing) {
            HStack(spacing: AssistantDrawerMetrics.fieldGap) {
                TextField(AssistantDrawerCopy.placeholder, text: draft)
                    .textFieldStyle(.plain)
                    .font(theme.sans.font(size: AssistantDrawerMetrics.fieldTextSize))
                    .foregroundStyle(theme.ink.color)
                    .focused(focused)
                    // ⏎ **manda a pergunta**, e nada mais. Nenhuma proposta é
                    // executada por tecla: a §4 inteira depende disso.
                    .onSubmit { conversation.submit() }
                    .accessibilityLabel(AssistantDrawerCopy.placeholder)
                Text("⏎")
                    .font(theme.mono.font(size: AssistantDrawerMetrics.returnHintSize))
                    .foregroundStyle(theme.ink4.color)
                    .accessibilityHidden(true)
                Button(action: conversation.submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: AssistantDrawerMetrics.sendGlyphSize, weight: .bold))
                        .foregroundStyle(theme.onAccent.color)
                        .frame(
                            width: AssistantDrawerMetrics.sendButtonSide,
                            height: AssistantDrawerMetrics.sendButtonSide
                        )
                        .background(theme.accent.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .disabled(!conversation.canSend)
                .accessibilityLabel("Mandar a pergunta")
            }
            .padding(.leading, AssistantDrawerMetrics.fieldLeadingPadding)
            .padding(.trailing, AssistantDrawerMetrics.fieldTrailingPadding)
            .frame(height: AssistantDrawerMetrics.fieldHeight)
            .background(theme.surface2.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        theme.btnLine.color, lineWidth: Hairline.thickness(displayScale)
                    )
            }

            if showsFooter {
                Text(AssistantDrawerCopy.footer)
                    .font(theme.sans.font(size: AssistantDrawerMetrics.footerSize))
                    .foregroundStyle(theme.ink4.color)
            }
        }
    }
}

// MARK: - A conversa, partilhada pela gaveta e pela janela

struct AssistantTranscript: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let conversation: AssistantConversation
    let session: AssistantSession
    let width: CGFloat
    let padding: EdgeInsets
    let onRun: (AssistantProposalCard) -> Void
    let onReveal: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AssistantDrawerMetrics.turnGap) {
                ForEach(conversation.messages) { turno in
                    turnView(turno)
                }
                if conversation.isLoading { loading }
                if let falha = conversation.failure {
                    AssistantFailureBand(
                        failure: falha, onRetry: conversation.retry, onOpenSettings: {}
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func turnView(_ turno: AssistantMessage) -> some View {
        if turno.speaker == .user {
            Text(turno.text)
                .font(theme.sans.font(size: AssistantDrawerMetrics.turnTextSize))
                .foregroundStyle(theme.ink.color)
                .padding(AssistantDrawerMetrics.questionPadding)
                .background(theme.accentSoft.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            theme.accentLine.color, lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .frame(
                    maxWidth: width * AssistantDrawerMetrics.questionMaxWidthRatio,
                    alignment: .trailing
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Você: \(turno.text)")
        } else {
            VStack(alignment: .leading, spacing: AssistantDrawerMetrics.cardTopSpacing) {
                Text(turno.text)
                    .font(theme.sans.font(size: AssistantDrawerMetrics.turnTextSize))
                    .foregroundStyle(theme.ink.color)
                    .lineSpacing(AssistantDrawerMetrics.turnTextSize * 0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(turno.cards) { cartao in
                    AssistantProposalCardView(
                        card: cartao,
                        isDone: session.isDone(cartao.id),
                        hasUndo: session.hasUndo,
                        onRun: { onRun(cartao) },
                        onReveal: { cartao.secondaryMessageID.map(onReveal) }
                    )
                }
            }
            .frame(
                maxWidth: width * AssistantDrawerMetrics.answerMaxWidthRatio,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(conversation.scope.loadingLabel(for: conversation.destination))
                .font(theme.sans.font(size: AssistantDrawerMetrics.cardTextSize))
                .foregroundStyle(theme.ink3.color)
        }
        .accessibilityLabel("Respondendo à pergunta")
    }
}

// MARK: - O cartão

/// Um cartão de ação sob o turno. O botão primário aplica a leva inteira; o
/// secundário só mostra.
///
/// Depois do clique ele vira "Feito", com "Desfazer" ao lado **enquanto o
/// recibo da leva dele estiver de pé** — prometer um desfazer que sumiu, ou
/// que desfaria outra coisa, é pior do que não prometer nenhum. O "Feito"
/// fica: voltar a mostrar o botão convidaria a executar a leva duas vezes.
struct AssistantProposalCardView: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let card: AssistantProposalCard
    let isDone: Bool
    /// O recibo **desta leva** ainda está de pé. Sem ele o cartão diz
    /// "Feito" e nada mais: prometer "Desfazer" em cima do recibo de outra
    /// coisa é o defeito C1.
    let hasUndo: Bool
    let onRun: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: AssistantDrawerMetrics.cardGap) {
            Text(card.displayText)
                .font(theme.sans.font(size: AssistantDrawerMetrics.cardTextSize))
                .foregroundStyle(theme.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isDone {
                Text(AssistantDrawerCopy.done)
                    .font(theme.sans.font(
                        size: AssistantDrawerMetrics.cardActionSize, weight: .semibold
                    ))
                    .foregroundStyle(theme.ink3.color)
                if hasUndo {
                    Text(AssistantDrawerCopy.undo)
                        .font(theme.sans.font(
                            size: AssistantDrawerMetrics.cardActionSize, weight: .semibold
                        ))
                        .foregroundStyle(theme.accentInk.color)
                        .accessibilityLabel("Desfazer pela barra de retorno")
                }
            } else {
                Button(action: onRun) {
                    Text(card.verb)
                        .font(theme.sans.font(
                            size: AssistantDrawerMetrics.cardActionSize, weight: .semibold
                        ))
                        .foregroundStyle(theme.onAccent.color)
                        .padding(.horizontal, AssistantDrawerMetrics.cardButtonPadding)
                        .frame(height: AssistantDrawerMetrics.cardButtonHeight)
                        .background(theme.accent.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .accessibilityLabel("\(card.verb): \(card.text)")
                if let secundario = card.secondary {
                    Button(action: onReveal) {
                        Text(secundario)
                            .font(theme.sans.font(
                                size: AssistantDrawerMetrics.cardActionSize, weight: .semibold
                            ))
                            .foregroundStyle(theme.ink4.color)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusRing(cornerRadius: theme.radiusSmall)
                    .accessibilityLabel("\(secundario): \(card.text)")
                }
            }
        }
        .padding(AssistantDrawerMetrics.cardPadding)
        .background(theme.surface2.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(card.rationale)
    }
}

// MARK: - O foco que volta

/// Guarda quem tinha o foco de teclado quando esta view apareceu e o devolve
/// quando ela sai.
///
/// Foco é AppKit, e não há como fazer isto só com `@FocusState`: o `FocusState`
/// da gaveta sabe **tirar** o foco de onde estava, e não sabe para onde
/// devolvê-lo. Sem isto, fechar a gaveta com Esc deixa a janela sem primeiro
/// respondedor — e a tecla seguinte não vai a lugar nenhum, que é a definição
/// de teclado morto.
///
/// A regra da devolução: só devolve se **a gaveta** ainda for a dona do foco.
/// Se a pessoa clicou noutro lugar antes de fechar, quem manda é o clique.
struct GuardaEDevolveOFoco: NSViewRepresentable {

    @MainActor
    final class Coordinator {
        weak var janela: NSWindow?
        weak var anterior: NSResponder?
        var guardou = false

        /// A conta, separada do AppKit para o teste poder aferi-la: devolve
        /// o foco a quem o tinha, a menos que ele já tenha ido para fora da
        /// gaveta.
        static func devolve(
            anterior: NSResponder?, atual: NSResponder?, dentroDaGaveta: Bool
        ) -> NSResponder? {
            guard let anterior, anterior !== atual, dentroDaGaveta else { return nil }
            return anterior
        }

        func devolveOFoco() {
            guard let janela else { return }
            let atual = janela.firstResponder
            let dentro = (atual as? NSView)?.isDescendant(of: janela.contentView ?? NSView())
                ?? (atual === janela)
            guard let alvo = Self.devolve(
                anterior: anterior, atual: atual, dentroDaGaveta: dentro
            ) else { return }
            janela.makeFirstResponder(alvo)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.guardou, let janela = nsView.window else { return }
        context.coordinator.guardou = true
        context.coordinator.janela = janela
        context.coordinator.anterior = janela.firstResponder
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.devolveOFoco() }
    }
}
