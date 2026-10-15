import SwiftUI
import UNICore
import UNIDesign

/// As medidas da gaveta e da janela do assistente na direção **Presença** —
/// `design/IA-Presenca.dc.html`. Como o `DashboardMetrics`, mora **fora** da
/// `View`: uma `View` é `@MainActor` implícito e um `static` lá dentro estoura
/// quando um teste `nonisolated` o lê.
enum AssistantDrawerMetrics {

    /// "Gaveta — 440 largura · por cima, borda direita".
    static let width: CGFloat = 440
    /// "fundo atrás a 45%".
    static let backdropOpacity: Double = 0.45
    /// "sombra -30 0 80 rgba(0,0,0,.6)".
    static let shadowRadius: CGFloat = 40
    static let shadowX: CGFloat = -30
    static let shadowOpacity: Double = 0.6

    /// A janela própria do desenho: `880 × 744`.
    static let windowSize = PresencaMetrics.windowSize

    static let headerActionSize: CGFloat = 15
    static let capsSize: CGFloat = 9.5
    /// O texto de um turno de prosa.
    static let turnTextSize: CGFloat = 13.5
    static let cardTextSize: CGFloat = 12.5
    /// `height: 40px` da caixa do campo no desenho antigo; na Presença a
    /// altura vem do conteúdo (`padding: 10px …`), e este valor é o mínimo.
    static let fieldHeight: CGFloat = 40
    /// O botão ↑ do campo: 32 quadrado na Presença.
    static let sendButtonSide: CGFloat = PresencaMetrics.sendSide
    /// A altura do botão de um item fechado do briefing.
    static let cardButtonHeight: CGFloat = 30

    /// O deslize da gaveta. Curto, e só isso: "sem efeito além disso".
    static let slide: Animation = .easeOut(duration: 0.18)
}

// MARK: - A gaveta

/// A gaveta do assistente, na direção **Presença** —
/// `design/IA-Presenca.dc.html`, artboards `resposta` e `trabalhando`.
///
/// **É overlay, e nada atrás dela se mexe.** O conteúdo da tela fica a 45% de
/// opacidade e no mesmo lugar: uma gaveta que empurra a caixa faz a pessoa
/// perder o parágrafo que estava lendo por ter feito uma pergunta.
///
/// A resposta é um **briefing numerado**, não bolhas de conversa: manchete,
/// recibo dos passos, um fio, e os itens 01/02/03 — com o rascunho morando
/// dentro do item que o pediu. Nenhum item executa sozinho: nem por ⏎ no
/// campo, que só manda a pergunta.
///
/// A gaveta é mais estreita que a janela do desenho (440 contra 880), e as
/// duas diferenças estão nomeadas: o recuo lateral cai de 44 para 20
/// (`PresencaMetrics.gutter(forWidth:)`) e o cabeçalho não escreve o prefixo
/// "falando sobre", que não cabe ao lado dos dois botões de ação. Todo o
/// resto — tipos, pesos, folgas, o orbe — é o mesmo desenho.
struct AssistantDrawer: View {

    @Environment(\.theme) private var theme

    let conversation: AssistantConversation
    let session: AssistantSession
    /// O contexto em uso agora, já resolvido.
    let context: AssistantDrawerContext
    /// O nome do herói do dia, para a primeira pergunta sugerida. `nil` sem herói.
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
            AssistantPresencaHeader(
                conversation: conversation,
                context: context,
                width: AssistantDrawerMetrics.width,
                onSwapContext: onSwapContext,
                trailing: {
                    HStack(spacing: PresencaMetrics.headerGap) {
                        headerButton(
                            "arrow.up.forward.square", L10n.tr("Destacar em janela"),
                            action: onDetach
                        )
                        headerButton("xmark", L10n.tr("Fechar o assistente"), action: onClose)
                    }
                }
            )
            AssistantTranscript(
                conversation: conversation,
                session: session,
                width: AssistantDrawerMetrics.width,
                heroName: heroName,
                onRun: onRun,
                onReveal: onReveal
            )
            .frame(maxHeight: .infinity)
            field
        }
        .frame(width: AssistantDrawerMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.glassWindow.color)
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
        .accessibilityLabel(L10n.tr("Assistente"))
        .task { fieldFocused = true }
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

    private var field: some View {
        AssistantAskField(conversation: conversation, focused: $fieldFocused, showsFooter: true)
    }
}

// MARK: - O cabeçalho da Presença

/// "● Assistente · falando sobre **o seu dia** · trocar … gpt-5.6-luna".
///
/// Uma peça só, partilhada pela gaveta e pela janela: o desenho é o mesmo nos
/// dois lugares, e duas cópias divergiriam no primeiro ajuste de folga.
struct AssistantPresencaHeader<Trailing: View>: View {

    @Environment(\.theme) private var theme

    let conversation: AssistantConversation
    let context: AssistantDrawerContext
    let width: CGFloat
    /// Este cabeçalho **é** a barra de título da janela? Então ele reserva o
    /// vão dos semáforos nativos e põe o conteúdo na linha deles. O desenho
    /// pinta as três bolinhas à esquerda porque lá não existe janela de
    /// verdade; aqui existe, e a regra da casa é a de `WindowTitleBar`.
    var reservaSemaforos = false
    let onSwapContext: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    /// O prefixo só cabe na janela larga — ver a nota de `AssistantDrawer`.
    private var showsPrefix: Bool { width >= 700 }

    private var destinationLabel: String {
        let destino = conversation.destination
        let detalhe = destino.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detalhe.isEmpty ? destino.label : "\(destino.label) · \(detalhe)"
    }

    var body: some View {
        // O alinhador dos semáforos **só** entra quando este cabeçalho é a
        // barra da janela: na gaveta ele moveria os botões da janela
        // principal, que não é dele.
        if reservaSemaforos {
            linha.trafficLightsInWindowHeader()
        } else {
            linha
        }
    }

    private var linha: some View {
        HStack(spacing: PresencaMetrics.headerGap) {
            AssistantOrb(side: PresencaMetrics.headerOrb)
            Text(AssistantDrawerCopy.title)
                .font(theme.sans.font(size: PresencaMetrics.titleSize, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .fixedSize()
            if showsPrefix {
                Text(AssistantDrawerCopy.contextPrefix)
                    .font(theme.sans.font(size: PresencaMetrics.contextSize))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize()
            }
            Text(context.label)
                .font(theme.sans.font(size: PresencaMetrics.contextSize, weight: .semibold))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
            Button(action: onSwapContext) {
                Text(AssistantDrawerCopy.swapLabel)
                    .font(theme.sans.font(size: PresencaMetrics.swapSize, weight: .medium))
                    .foregroundStyle(theme.accentInk.color)
                    .fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .accessibilityLabel(L10n.tr("Trocar o contexto da conversa"))
            Spacer(minLength: PresencaMetrics.headerGap)
            Text(destinationLabel)
                .font(theme.mono.font(size: PresencaMetrics.modelSize))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
                .truncationMode(.tail)
            trailing()
        }
        .padding(PresencaMetrics.headerPadding)
        .padding(
            .leading,
            reservaSemaforos
                ? TrafficLightLayout.windowContentInset - PresencaMetrics.headerPadding.leading
                : 0
        )
        .frame(height: reservaSemaforos ? TrafficLightLayout.windowBarHeight : nil)
        .hairline(theme.line, edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Falando sobre \(context.label)"))
    }
}

// MARK: - O campo, partilhado pela gaveta e pela janela

/// `margin: 14px 24px 8px` com o orbe pequeno à esquerda, o campo, "⌘J" e o
/// botão ↑ de 32 em acento.
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PresencaMetrics.fieldGap) {
                AssistantOrb(side: PresencaMetrics.fieldOrb)
                TextField(AssistantDrawerCopy.placeholder, text: draft)
                    .textFieldStyle(.plain)
                    .font(theme.sans.font(size: PresencaMetrics.fieldTextSize))
                    .foregroundStyle(theme.ink.color)
                    .focused(focused)
                    // ⏎ **manda a pergunta**, e nada mais. Nenhuma proposta é
                    // executada por tecla: a §4 inteira depende disso.
                    .onSubmit { conversation.submit() }
                    .accessibilityLabel(AssistantDrawerCopy.placeholder)
                Text("⌘J")
                    .font(theme.mono.font(size: PresencaMetrics.fieldHintSize))
                    .foregroundStyle(theme.ink4.color)
                    .accessibilityHidden(true)
                Button(action: conversation.submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: PresencaMetrics.sendGlyph, weight: .bold))
                        .foregroundStyle(theme.onAccent.color)
                        .frame(
                            width: PresencaMetrics.sendSide,
                            height: PresencaMetrics.sendSide
                        )
                        .background(theme.accent.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .disabled(!conversation.canSend)
                .accessibilityLabel(L10n.tr("Mandar a pergunta"))
            }
            .padding(PresencaMetrics.fieldPadding)
            .frame(minHeight: AssistantDrawerMetrics.fieldHeight)
            .background(theme.surface2.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusLarge)
                    .strokeBorder(
                        theme.btnLine.color, lineWidth: Hairline.thickness(displayScale)
                    )
            }
            .padding(PresencaMetrics.fieldMargin)

            if showsFooter {
                Text(AssistantDrawerCopy.footer)
                    .font(theme.sans.font(size: PresencaMetrics.footerSize))
                    .foregroundStyle(theme.ink4.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PresencaMetrics.fieldMargin.leading)
                    .padding(.bottom, PresencaMetrics.footerBottom)
            }
        }
    }
}

// MARK: - A conversa, partilhada pela gaveta e pela janela

/// O briefing: a pergunta como linha de dossiê, a resposta como manchete mais
/// itens numerados, e o estado "trabalhando" enquanto o motor pensa.
struct AssistantTranscript: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let conversation: AssistantConversation
    let session: AssistantSession
    let width: CGFloat
    /// O nome do herói do dia, para a primeira pergunta sugerida.
    var heroName: String?
    let onRun: (AssistantProposalCard) -> Void
    let onReveal: (String) -> Void

    private var gutter: CGFloat { PresencaMetrics.gutter(forWidth: width) }

    var body: some View {
        // A altura livre é o que faz o estado "trabalhando" ficar **no meio**,
        // como no desenho: ele cresce até o que sobra entre a pergunta e o
        // campo, e se centra ali.
        GeometryReader { proxy in
            corpo(alturaLivre: proxy.size.height)
        }
    }

    private func corpo(alturaLivre: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PresencaMetrics.briefingGap) {
                ForEach(conversation.messages) { turno in
                    turnView(turno)
                }
                if conversation.isLoading {
                    // O título é a legenda do trabalho inteiro ("Lendo o seu
                    // dia…"); os passos são o que já foi feito. Pôr o passo
                    // atual nos dois lugares escrevia a mesma frase duas vezes.
                    AssistantWorkingState(
                        steps: session.steps,
                        title: conversation.scope.loadingLabel(
                            for: conversation.destination
                        )
                    )
                    .frame(
                        minHeight: max(
                            220,
                            alturaLivre - CGFloat(conversation.messages.count) * 44
                                - PresencaMetrics.questionTop * 2
                        )
                    )
                }
                if let falha = conversation.failure {
                    AssistantFailureBand(
                        failure: falha, onRetry: conversation.retry, onOpenSettings: {}
                    )
                }
                if !conversation.isLoading { followUps }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, gutter)
            .padding(.top, PresencaMetrics.questionTop)
            .padding(.bottom, PresencaMetrics.briefingTop)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func turnView(_ turno: AssistantMessage) -> some View {
        if turno.speaker == .user {
            AssistantQuestionLine(text: turno.text, at: turno.at)
        } else {
            AssistantBriefingTurn(
                turn: turno,
                // O recibo é da **última** ida, e só a última resposta pode
                // reivindicá-lo: pendurá-lo em turnos antigos faria a tela
                // dizer que aqueles passos aconteceram agora.
                receipt: turno.id == conversation.messages.last?.id
                    ? session.lastReceipt : nil,
                session: session,
                onRun: onRun,
                onReveal: onReveal
            )
        }
    }

    /// "pergunte mais: …" — as perguntas de partida do 09, agora em linha, no
    /// idioma do desenho (texto de acento, sem pastilha).
    private var followUps: some View {
        // O rótulo entra **dentro** do mesmo fluxo das perguntas: na janela
        // larga tudo cabe numa linha, como no desenho, e na gaveta de 440 o
        // excedente desce sozinho em vez de ser cortado.
        FlowLayout(spacing: PresencaMetrics.followUpGap, rowSpacing: 6) {
            Text(L10n.tr("pergunte mais:"))
                .font(theme.sans.font(size: PresencaMetrics.followUpSize))
                .foregroundStyle(theme.ink3.color)
            ForEach(AssistantDrawerCopy.chips(heroName: heroName), id: \.self) { texto in
                Button { conversation.ask(texto) } label: {
                    Text(texto)
                        .font(theme.sans.font(
                            size: PresencaMetrics.followUpSize, weight: .medium
                        ))
                        .foregroundStyle(theme.accentInk.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .disabled(conversation.isLoading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Um turno de resposta

/// A resposta como briefing: manchete, a prosa que sobra, o recibo dos passos,
/// o fio, e os itens numerados.
struct AssistantBriefingTurn: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let turn: AssistantMessage
    let receipt: AssistantRunReceipt?
    let session: AssistantSession
    let onRun: (AssistantProposalCard) -> Void
    let onReveal: (String) -> Void

    /// A manchete e o resto. A primeira linha da resposta é a manchete do
    /// desenho; o que vem depois continua prosa, no corpo de sempre.
    private var partes: (headline: String, rest: String) {
        AssistantBriefingTurn.split(turn.text)
    }

    nonisolated static func split(_ text: String) -> (headline: String, rest: String) {
        let limpo = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quebra = limpo.firstIndex(where: \.isNewline) else { return (limpo, "") }
        let cabeca = String(limpo[limpo.startIndex..<quebra])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resto = String(limpo[limpo.index(after: quebra)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cabeca, resto)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PresencaMetrics.briefingGap) {
            if turn.kind == .draft {
                // Rascunho é prosa de email: asterisco ali é literal, e ele
                // não passa pelo renderizador de Markdown.
                Text(L10n.tr("RASCUNHO PRONTO"))
                    .font(theme.mono.font(
                        size: PresencaMetrics.draftCapsSize, weight: .semibold
                    ))
                    .tracking(PresencaMetrics.draftCapsSize * PresencaMetrics.draftCapsTracking)
                    .foregroundStyle(theme.accentInk.color)
                Text(turn.text)
                    .font(theme.sans.font(size: PresencaMetrics.draftBodySize))
                    .lineSpacing(
                        PresencaMetrics.draftBodySize
                            * (PresencaMetrics.draftBodyLineHeight - 1.2)
                    )
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(partes.headline)
                    .font(theme.sans.font(size: PresencaMetrics.headlineSize, weight: .bold))
                    .tracking(PresencaMetrics.headlineSize * PresencaMetrics.headlineTracking)
                    .lineSpacing(
                        PresencaMetrics.headlineSize
                            * (PresencaMetrics.headlineLineHeight - 1.2)
                    )
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !partes.rest.isEmpty {
                    AssistantMarkdown(
                        text: partes.rest,
                        style: .prose(size: PresencaMetrics.proseSize)
                    )
                }
            }

            if let receipt, !receipt.isEmpty {
                AssistantReceiptRow(receipt: receipt)
            }

            let cartoes = turn.cards
            if !cartoes.isEmpty {
                Rectangle()
                    .fill(theme.line.color)
                    .frame(height: Hairline.thickness(displayScale))
                ForEach(Array(cartoes.enumerated()), id: \.element.id) { indice, cartao in
                    AssistantBriefingItem(
                        number: indice + 1,
                        card: cartao,
                        isDone: session.isDone(cartao.id),
                        hasUndo: session.hasUndo,
                        onRun: { onRun(cartao) },
                        onReveal: { cartao.secondaryMessageID.map(onReveal) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Assistente: \(turn.text)"))
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
