import SwiftUI
import UNICore
import UNIDesign

/// A coluna do meio do tríptico — `.preview` do mockup `design/07-dashboard.html`.
///
/// ## Por que não é o `ReaderPane`
///
/// A folha de leitura (`DashboardMailSheet`) **é** o `ReaderPane`, e continua
/// sendo: abrir de verdade é ⏎ ou duplo clique, e ali não há segundo leitor.
/// Esta coluna é outra coisa. O `ReaderPane` é a superfície inteira da Caixa —
/// barra de ações, faixa de triagem, TL;DR, anexos, convite com RSVP, pilha de
/// conversa, corpo em `WKWebView` e faixa de resposta rápida com barra de
/// formatação. Nada disso cabe em 380pt, e a metade que coubesse chegaria
/// truncada: o corpo HTML sozinho pede a largura de um email, e o `WKWebView`
/// não encolhe sem reflow. Espremê-lo aqui não daria "o leitor menor" — daria
/// o leitor cortado, que é a "área morta" que esta tela veio matar.
///
/// Então esta coluna é **deliberadamente um resumo**, e o mockup a desenha
/// como tal: remetente, hora, assunto, chips, trecho do corpo, as quatro ações
/// e o bloco Contexto. Nenhuma peça do leitor é reimplementada aqui — o que se
/// repete é tipografia em token, e as ações saem pela mesma porta
/// (`ContextCommand`) que a Caixa usa.
struct DashboardPreviewPane: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    /// O item selecionado na lista. `nil` desenha `.pv-empty`.
    let item: DashboardFocus.MailItem?
    let focus: DashboardFocus
    let today: Date
    /// A máquina de estado única: é dela que vem o rascunho, por `draftReply()`.
    let conversation: AssistantConversation
    let onOpen: () -> Void
    let onCommand: (ContextCommand) -> Void
    /// "Usar" — grava o rascunho na resposta e abre a leitura, onde a faixa de
    /// resposta rápida já o encontra.
    let onUseDraft: (Message, String) -> Void
    /// "Editar" — o mesmo rascunho, na janela 03.
    let onEditDraft: (Message, String) -> Void

    /// A mensagem **hidratada**, e não a do item da lista.
    ///
    /// `DashboardFocus` guarda cada linha por
    /// `Message.withoutHeavyPayload()` — sem corpo, sem HTML, sem anexo —,
    /// porque a lista não precisa de nada disso e copiar tudo a cada clique
    /// era o tranco. A prévia precisa: lida pelo item, ela mostrava para
    /// sempre o `snippet` de uma linha, que é a queixa "cadê o conteúdo?".
    /// `store.message(_:)` devolve a mesma mensagem com o corpo do
    /// `bodyStore` — inclusive o que a busca sob demanda acabou de trazer.
    private var message: Message? {
        guard let item else { return nil }
        return store.message(item.id) ?? item.message
    }

    /// O turno `.draft` mais recente. É ele que nasce **dentro** da prévia,
    /// colado no email — nunca um bloco de texto solto no meio da tela.
    private var draftText: String? {
        conversation.messages.last { $0.kind == .draft && $0.speaker == .assistant }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let item, let message {
                body(for: item, message: message)
            } else {
                empty
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, DashboardMetrics.previewLeadingPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .hairline(theme.line, edges: .leading)
        // O corpo do email chega por demanda, pela mesma porta do leitor. A
        // espera aparece na barra fina do chrome (ver `ChromeWorkload`), e
        // não numa segunda animação aqui.
        .task(id: message?.id) {
            guard let message, DashboardPreviewBody.needsBody(message) else { return }
            await store.loadBodyIfNeeded(message.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prévia da mensagem selecionada")
    }

    /// `.pv-top` — "Prévia · zoho" à esquerda, "enter ou 2× clique abre" à
    /// direita. A dica é a única documentação de que clicar não abre.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(headerLabel)
                .capsLabel(size: DashboardMetrics.capsSize)
            Spacer(minLength: 8)
            if message != nil {
                Text("enter ou 2× clique abre")
                    .font(theme.mono.font(size: DashboardMetrics.previewHintSize))
                    .tracking(0.08 * DashboardMetrics.previewHintSize)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.ink4.color)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, DashboardMetrics.previewTopBottomPadding)
    }

    private var headerLabel: String {
        guard let message, let host = store.account(message.accountID)?.host, !host.isEmpty else {
            return "Prévia"
        }
        return "Prévia · \(host)"
    }

    /// `.pv-body` — o cabeçalho do email fixo, o **corpo** ocupando o que
    /// sobra da coluna, e as ações com o Contexto (ou o rascunho) embaixo.
    ///
    /// **Divergência deliberada do mockup**, registrada em
    /// `barra-report.md`: ali o trecho é um `-webkit-line-clamp` de oito
    /// linhas, porque o mockup tem um lorem que sempre as preenche. Na caixa
    /// de verdade o email tem cinco linhas ou duzentas, e o clamp devolvia uma
    /// frase com 400pt de vazio embaixo. O corpo agora é a peça elástica da
    /// coluna e rola por dentro quando é longo.
    private func body(for item: DashboardFocus.MailItem, message: Message) -> some View {
        let corpo = DashboardPreviewBody.state(
            for: message, load: store.bodyLoad(for: message.id), agora: today
        )
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.listHeadline)
                    .font(
                        theme.sans.font(
                            size: DashboardMetrics.previewSenderSize, weight: .semibold
                        )
                    )
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(stamp(message))
                    .font(theme.mono.font(size: DashboardMetrics.previewTimeSize))
                    .foregroundStyle(theme.ink4.color)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text(message.subject)
                .font(
                    theme.serif.font(size: DashboardMetrics.previewSubjectSize, weight: .medium)
                )
                .foregroundStyle(theme.ink.color)
                .lineSpacing(DashboardMetrics.previewSubjectSize * 0.3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DashboardMetrics.previewSubjectTopSpacing)

            HStack(spacing: DashboardMetrics.previewChipsSpacing) {
                DashboardReasonChip(reason: item.reason)
                if !message.isRead {
                    DashboardReasonChip(reason: .unread)
                }
            }
            .padding(.top, DashboardMetrics.previewChipsTopSpacing)

            // **A fronteira.** De um lado, quem mandou e sobre o quê; do outro,
            // o que está escrito. Antes disto os dois se encostavam com o mesmo
            // espaçamento de qualquer parágrafo, e o olho tinha de descobrir
            // sozinho onde o cabeçalho acabava.
            Rectangle()
                .fill(theme.line.color)
                .frame(
                    height: Hairline.thickness(displayScale)
                        * DashboardMetrics.previewHeaderRuleScale
                )
                .padding(.top, DashboardMetrics.previewHeaderRuleSpacing)
                .accessibilityHidden(true)

            excerptBlock(corpo)

            actions(message)

            if let text = draftText {
                ScrollView {
                    draftBlock(text, message: message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                contextBlock(message)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, DashboardMetrics.previewBodyTopPadding)
        .hairline(theme.line2, edges: .top)
    }

    /// `.pv-x` — o corpo do email. Elástico: come a altura que sobra da
    /// coluna e rola por dentro. Com o rascunho colado embaixo ele encolhe
    /// para o teto compacto, que é o que o mockup fazia com o clamp de três
    /// linhas — o rascunho é o que a pessoa pediu, e ganha o espaço.
    @ViewBuilder
    private func excerptBlock(_ corpo: DashboardPreviewBody.State) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // **A ordem é a da pergunta.** Primeiro o que este email exige de
            // você (quando a análise sabe), depois o resumo do que ele diz, e
            // só então o texto. As duas primeiras peças ficam **fora** da área
            // rolável: são as que não podem sumir para cima.
            if let pedido = corpo.pedido {
                pedidoBlock(pedido)
            }
            if let resumo = corpo.resumo {
                resumoBlock(resumo)
            }
            if corpo.corpo.isEmpty {
                Text(corpo.isWaiting ? "Carregando o email…" : "Sem texto.")
                    .font(theme.sans.font(size: DashboardMetrics.previewExcerptSize))
                    .foregroundStyle(theme.ink3.color)
            } else {
                CorpoRolavel(corpo: corpo.corpo)
            }
            if let causa = corpo.failure {
                Button("Tentar de novo") { Task { await retryBody() } }
                    .buttonStyle(.plain)
                    .capsLabel(size: DashboardMetrics.capsSize)
                    .foregroundStyle(theme.accentInk.color)
                    .focusRing(cornerRadius: theme.radiusSmall)
                    .padding(.top, 6)
                    .help(causa)
                    .accessibilityHint(causa)
            }
        }
        // O corpo é a peça elástica da coluna: ele fica com toda a altura que
        // sobra depois do cabeçalho do email, das ações e do Contexto, e rola
        // por dentro quando o texto é maior do que isso.
        //
        // **Sem medir o conteúdo.** A tentação era abraçar o texto curto com a
        // altura medida, como o transcript do dashboard faz. Aqui isso trava:
        // a medida realimenta o próprio teto da `ScrollView`, o quadro nunca
        // para de mudar, e o harness — que fotografa até a tela estabilizar —
        // gira para sempre. Um teto elástico é determinístico.
        .frame(
            maxHeight: draftText == nil ? .infinity : DashboardMetrics.previewBodyCompactHeight,
            alignment: .top
        )
        .padding(.top, DashboardMetrics.previewExcerptTopSpacing)
    }

    /// **O que este email pede de você**, em um selo de uma linha.
    ///
    /// É a primeira coisa da coluna porque é a primeira pergunta de quem abre
    /// o email: "isto exige alguma coisa de mim, e até quando?". O prazo entra
    /// no mesmo selo — a data estava a duas telas de distância, no cartão de
    /// compromisso do leitor. Urgente troca o acento suave pelo acento cheio,
    /// que é o único lugar da prévia onde ele aparece: se tudo grita, nada
    /// grita.
    ///
    /// Só existe quando a análise já rodou. Sem `MessageTriage` não há selo —
    /// nada aqui é adivinhado por heurística de texto.
    private func pedidoBlock(_ pedido: PedidoDoEmail) -> some View {
        HStack(spacing: 6) {
            Image(systemName: pedido.urgente ? "exclamationmark.circle.fill" : "arrow.turn.up.left")
                .font(.system(size: DashboardMetrics.capsSize, weight: .bold))
                .accessibilityHidden(true)
            // O versalete é escrito à mão, e **não** com `capsLabel`: aquele
            // modificador pinta `ink3` por dentro, e cor pedida por fora não o
            // vence. Foi assim que a primeira renderização saiu com o selo
            // cinza sobre laranja, ilegível — o oposto do que ele existe para
            // fazer. Mesma escrita da etiqueta de razão (`DashboardReasonChip`).
            Text(pedido.rotulo)
                .font(theme.mono.font(size: DashboardMetrics.capsSize, weight: .semibold))
                .tracking(theme.capsTracking(at: DashboardMetrics.capsSize))
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(pedido.urgente ? theme.paper.color : theme.accentInk.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(pedido.urgente ? theme.accent.color : theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .padding(.bottom, DashboardMetrics.previewPedidoSpacing)
        .help(pedido.evidencia ?? pedido.rotulo)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Este email \(pedido.rotulo.lowercased())")
    }

    /// O resumo da análise, no topo e em duas linhas no máximo.
    ///
    /// Deliberadamente **não** é o cartão do leitor (`ReaderPane.summaryCard`):
    /// aquele tem legenda de procedência, cartão de compromisso e RSVP, e nada
    /// disso cabe em 380pt. Aqui é a frase, marcada pelo acento à esquerda para
    /// não se confundir com o corpo.
    private func resumoBlock(_ resumo: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Resumo")
                .capsLabel(size: DashboardMetrics.capsSize)
                .foregroundStyle(theme.accentInk.color)
            Text(resumo)
                .font(
                    theme.sans.font(
                        size: DashboardMetrics.previewExcerptSize, weight: .semibold
                    )
                )
                .foregroundStyle(theme.ink.color)
                .lineSpacing(DashboardMetrics.previewExcerptSize * 0.35)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.accent.color)
                .frame(width: DashboardMetrics.draftBarWidth)
                .accessibilityHidden(true)
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: theme.radiusSmall,
                topTrailingRadius: theme.radiusSmall
            )
        )
        .padding(.bottom, DashboardMetrics.previewExcerptTopSpacing)
        .accessibilityLabel("Resumo. \(resumo)")
    }

    private func retryBody() async {
        guard let message else { return }
        await store.retryBody(message.id)
    }

    /// `.pv-acts` — "Gerar resposta" é o **primário**; Responder, Arquivar e
    /// Depois ao lado. As três últimas saem pela porta da Caixa.
    private func actions(_ message: Message) -> some View {
        FlowRow(spacing: DashboardMetrics.previewActionSpacing) {
            ChromeButton(
                appearance: .accent,
                height: DashboardMetrics.previewActionHeight,
                horizontalPadding: DashboardMetrics.previewActionPadding,
                labelSize: DashboardMetrics.previewActionSize,
                action: { conversation.draftReply() },
                label: { Text("Gerar resposta") }
            )
            .disabled(conversation.isLoading)
            .help("Pede um rascunho de resposta para este email")

            previewAction("Responder") { onCommand(.reply(messageID: message.id)) }
            previewAction("Arquivar") {
                onCommand(.move(messageID: message.id, to: .archived))
            }
            previewAction("Depois") { onCommand(.move(messageID: message.id, to: .later)) }
        }
        // **O piso das ações.** Régua em cima e fundo de `paper` embaixo: o
        // corpo que rola passa por trás do véu e morre aqui, e nunca meia
        // linha de texto atrás de um botão.
        .padding(.top, DashboardMetrics.previewActionsTopSpacing)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper.color)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.line2.color)
                .frame(height: Hairline.thickness(displayScale))
                .accessibilityHidden(true)
        }
    }

    private func previewAction(_ title: String, action: @escaping () -> Void) -> some View {
        ChromeButton(
            appearance: .outlined,
            height: DashboardMetrics.previewActionHeight,
            horizontalPadding: DashboardMetrics.previewActionPadding,
            labelSize: DashboardMetrics.previewActionSize,
            action: action,
            label: { Text(title) }
        )
    }

    /// `.pv-ctx` — o que o app já sabe. Some quando não sabe nada: um bloco
    /// "Contexto" com nada dentro é a área morta de volta.
    @ViewBuilder
    private func contextBlock(_ message: Message) -> some View {
        let linhas = DashboardPreviewContext.lines(
            for: message,
            agenda: store.visibleAgenda,
            pending: focus.pending,
            messages: store.messages
        )
        if !linhas.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Contexto")
                    .capsLabel(size: DashboardMetrics.capsSize)
                    .padding(.bottom, DashboardMetrics.contextLabelBottomSpacing)
                ForEach(linhas) { linha in
                    HStack(alignment: .firstTextBaseline, spacing: DashboardMetrics.contextItemSpacing) {
                        Circle()
                            .fill(accountTint(message.accountID).color)
                            .frame(
                                width: DashboardMetrics.contextDotSide,
                                height: DashboardMetrics.contextDotSide
                            )
                            .offset(y: -1)
                            .accessibilityHidden(true)
                        Text(linha.text)
                            .font(theme.sans.font(size: DashboardMetrics.contextTextSize))
                            .foregroundStyle(theme.ink2.color)
                            .lineSpacing(DashboardMetrics.contextTextSize * 0.45)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, DashboardMetrics.contextItemVerticalPadding)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, DashboardMetrics.contextTopPadding)
            .hairline(theme.line2, edges: .top)
            .padding(.top, DashboardMetrics.contextTopSpacing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Contexto")
        }
    }

    /// `.draft` — **dentro** da prévia, colado no email, com barra de acento à
    /// esquerda e ação embaixo. Nunca um bloco de texto solto no meio da tela.
    private func draftBlock(_ text: String, message: Message) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rascunho · \(conversation.destination.label)")
                .capsLabel(size: DashboardMetrics.capsSize)
                .foregroundStyle(theme.accentInk.color)
                .padding(.bottom, DashboardMetrics.draftLabelBottomSpacing)
            // Prosa de email: asterisco ali é literal, e por isso não passa
            // pelo Markdown — a mesma regra do turno `.draft` do transcript.
            Text(text)
                .font(theme.serif.font(size: DashboardMetrics.draftTextSize))
                .foregroundStyle(theme.ink.color)
                .lineSpacing(DashboardMetrics.draftTextSize * 0.6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DashboardMetrics.previewActionSpacing) {
                ChromeButton(
                    appearance: .accent,
                    height: DashboardMetrics.draftActionHeight,
                    horizontalPadding: DashboardMetrics.previewActionPadding,
                    labelSize: DashboardMetrics.draftActionSize,
                    action: { onUseDraft(message, text) },
                    label: { Text("Usar") }
                )
                .help("Grava o rascunho na resposta e abre o email")
                draftAction("Editar") { onEditDraft(message, text) }
                draftAction("Descartar") { conversation.clear() }
            }
            .padding(.top, DashboardMetrics.draftActionsTopSpacing)
        }
        .padding(DashboardMetrics.draftPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.accent.color)
                .frame(width: DashboardMetrics.draftBarWidth)
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: theme.radiusSmall,
                topTrailingRadius: theme.radiusSmall
            )
        )
        .padding(.top, DashboardMetrics.draftTopSpacing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rascunho gerado")
    }

    private func draftAction(_ title: String, action: @escaping () -> Void) -> some View {
        ChromeButton(
            appearance: .outlined,
            height: DashboardMetrics.draftActionHeight,
            horizontalPadding: DashboardMetrics.previewActionPadding,
            labelSize: DashboardMetrics.draftActionSize,
            action: action,
            label: { Text(title) }
        )
    }

    /// `.pv-empty`.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Nada selecionado.")
                .font(theme.serif.font(size: DashboardMetrics.freeRailTitleSize))
                .foregroundStyle(theme.ink.color)
            Text("Clique em uma prioridade para ver a prévia e as ações aqui.")
                .font(theme.sans.font(size: DashboardMetrics.freeRailTextSize))
                .foregroundStyle(theme.ink3.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(theme.line2, edges: .top)
    }

    // MARK: - Peças

    /// `.pv-from .t` — "hoje 09:42", o carimbo da lista com o dia por extenso.
    private func stamp(_ message: Message) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        switch MessageStamp.of(message.receivedAt, now: today) {
        case .clock:
            formatter.dateFormat = "'hoje' HH:mm"
        case .yesterday:
            formatter.dateFormat = "'ontem' HH:mm"
        case .dayMonth:
            formatter.dateFormat = "dd/MM HH:mm"
        case .dayMonthYear:
            formatter.dateFormat = "dd/MM/yy"
        }
        return formatter.string(from: message.receivedAt)
    }

    private func accountTint(_ accountID: String) -> TokenColor {
        guard let account = store.account(accountID) else { return theme.ink3 }
        let hex = theme.isDark ? account.tintDarkHex : account.tintLightHex
        return TokenColor(css: hex) ?? theme.ink3
    }
}

/// Uma fileira que quebra a linha quando os botões não cabem — `flex-wrap:
/// wrap` do `.pv-acts`. Sem ela, os quatro botões da prévia saem cortados na
/// coluna de 380.
struct FlowRow: Layout {

    let spacing: CGFloat

    init(spacing: CGFloat) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let largura = proposal.width ?? .infinity
        let linhas = arrange(subviews: subviews, in: largura)
        let altura = linhas.reduce(CGFloat(0)) { $0 + $1.height } +
            spacing * CGFloat(max(0, linhas.count - 1))
        let usada = linhas.map(\.width).max() ?? 0
        return CGSize(width: min(usada, largura), height: altura)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for linha in arrange(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for indice in linha.indices {
                let tamanho = subviews[indice].sizeThatFits(.unspecified)
                subviews[indice].place(
                    at: CGPoint(x: x, y: y), proposal: ProposedViewSize(tamanho)
                )
                x += tamanho.width + spacing
            }
            y += linha.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Line] {
        var linhas: [Line] = []
        var atual = Line()
        for (indice, subview) in subviews.enumerated() {
            let tamanho = subview.sizeThatFits(.unspecified)
            let proposta = atual.indices.isEmpty
                ? tamanho.width
                : atual.width + spacing + tamanho.width
            if !atual.indices.isEmpty, proposta > width {
                linhas.append(atual)
                atual = Line()
                atual.indices = [indice]
                atual.width = tamanho.width
                atual.height = tamanho.height
            } else {
                atual.indices.append(indice)
                atual.width = proposta
                atual.height = max(atual.height, tamanho.height)
            }
        }
        if !atual.indices.isEmpty { linhas.append(atual) }
        return linhas
    }
}
