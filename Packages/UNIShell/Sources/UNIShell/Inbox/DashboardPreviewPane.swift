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

    private var message: Message? { item?.message }

    /// O turno `.draft` mais recente. É ele que nasce **dentro** da prévia,
    /// colado no email — nunca um bloco de texto solto no meio da tela.
    private var draftText: String? {
        conversation.messages.last { $0.kind == .draft && $0.speaker == .assistant }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let item, let message {
                ScrollView {
                    body(for: item, message: message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                empty
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, DashboardMetrics.previewLeadingPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .hairline(theme.line, edges: .leading)
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

    private func body(for item: DashboardFocus.MailItem, message: Message) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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

            Text(excerpt(message))
                .font(theme.serif.font(size: DashboardMetrics.previewExcerptSize))
                .foregroundStyle(theme.ink2.color)
                .lineSpacing(DashboardMetrics.previewExcerptSize * 0.6)
                .lineLimit(
                    draftText == nil
                        ? DashboardMetrics.previewExcerptLines
                        : DashboardMetrics.previewExcerptLinesWithDraft
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DashboardMetrics.previewExcerptTopSpacing)
                .textSelection(.enabled)

            actions(message)

            if let text = draftText {
                draftBlock(text, message: message)
            } else {
                contextBlock(message)
            }
        }
        .padding(.top, DashboardMetrics.previewBodyTopPadding)
        .hairline(theme.line2, edges: .top)
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
        .padding(.top, DashboardMetrics.previewActionsTopSpacing)
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

    /// `.pv-x` — o trecho do corpo. O corpo em texto quando ele já está
    /// hidratado, o `snippet` quando não: a prévia não dispara busca de corpo
    /// nenhuma, porque ela muda a cada seta na lista.
    private func excerpt(_ message: Message) -> String {
        let corpo = message.body
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !corpo.isEmpty { return corpo }
        return message.snippet
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
