import SwiftUI
import UNICore
import UNIDesign

/// A prévia do 08 — a coluna de 360 com o **cartão do rascunho antes de
/// tudo**.
///
/// A ordem é a decisão: quem abre o dashboard veio decidir "envio ou não", e
/// por isso o rascunho pronto aparece acima do resumo do email. "O que ele
/// escreveu" vem depois, com o resumo da análise e o corpo inteiro dobrado em
/// "Ler o email inteiro · N linhas" (o `CorpoLegivelView` de sempre).
///
/// **Aqui o Enviar envia de verdade** — o rascunho está inteiro na tela, a
/// pessoa o viu, e o clique dela sai pela fila de saída normal
/// (`DashboardSend`, com `In-Reply-To`). Nenhum caminho desta coluna fala com
/// a IA por conta própria; "Gerar resposta" é o único que fala, e só por
/// clique.
struct DashboardPreviewColumn: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    /// O item selecionado na lista (ou a primeira linha). `nil` = coluna vazia.
    let item: DashboardFocus.MailItem?
    let today: Date
    /// O rascunho antecipado desta mensagem, quando a fila já o escreveu.
    let readyDraft: ReadyDraft?
    /// A máquina de estado do "Gerar resposta" — nada aqui dispara sozinho.
    let conversation: AssistantConversation
    /// Enviar (direto — ver o cabeçalho). O texto vai junto para o teste
    /// poder afirmar o que saiu.
    let onSendDraft: (Message, String) -> Void
    /// Editar abre o composer com o rascunho (`ComposerSeed.reply`).
    let onEditDraft: (Message, String) -> Void
    /// Descartar → `discardReadyDraft`.
    let onDiscardDraft: (Message) -> Void
    let onCommand: (ContextCommand) -> Void

    /// "Ler o email inteiro" aberto. Estado da tela: nada disso volta ao
    /// modelo, e trocar de mensagem fecha a dobra (ver o `.id` no corpo).
    @State private var bodyExpanded = false

    init(
        store: MailStore,
        item: DashboardFocus.MailItem?,
        today: Date,
        readyDraft: ReadyDraft? = nil,
        conversation: AssistantConversation,
        onSendDraft: @escaping (Message, String) -> Void = { _, _ in },
        onEditDraft: @escaping (Message, String) -> Void = { _, _ in },
        onDiscardDraft: @escaping (Message) -> Void = { _ in },
        onCommand: @escaping (ContextCommand) -> Void = { _ in }
    ) {
        self.store = store
        self.item = item
        self.today = today
        self.readyDraft = readyDraft
        self.conversation = conversation
        self.onSendDraft = onSendDraft
        self.onEditDraft = onEditDraft
        self.onDiscardDraft = onDiscardDraft
        self.onCommand = onCommand
    }

    /// O carimbo curto do cabeçalho da prévia. Formato fixo: `Locale.current`
    /// mentiria no bundle de teste (ver a nota em `Render.bitmap`).
    private static let horaCurta: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("ddMMHm")
        return formatter
    }()

    /// A mensagem **hidratada** — a da lista vem sem corpo de propósito.
    private var message: Message? {
        guard let item else { return nil }
        return store.message(item.id) ?? item.message
    }

    /// O texto do cartão: o rascunho antecipado primeiro; sem ele, o turno
    /// `.draft` que "Gerar resposta" acabou de produzir.
    private var draftText: String? {
        if let readyDraft { return readyDraft.text }
        return conversation.messages.last {
            $0.kind == .draft && $0.speaker == .assistant
        }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message {
                content(message)
            } else {
                empty
            }
        }
        .padding(.leading, DashboardMetrics.previewLeadingPadding)
        .padding(.top, DashboardMetrics.columnsTopSpacing)
        .frame(maxHeight: .infinity, alignment: .top)
        .linkConfirmation()
        .task(id: message?.id) {
            bodyExpanded = false
            guard let message, DashboardPreviewBody.needsBody(message) else { return }
            await store.loadBodyIfNeeded(message.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Prévia da mensagem selecionada"))
    }

    private var empty: some View {
        Text(L10n.tr("Nada selecionado."))
            .font(theme.sans.font(size: 12))
            .foregroundStyle(theme.ink4.color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func content(_ message: Message) -> some View {
        let state = DashboardPreviewBody.state(
            for: message, load: store.bodyLoad(for: message.id), agora: today
        )
        return VStack(alignment: .leading, spacing: 0) {
            header(message)
            subjectLine(message)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let draftText {
                        draftCard(message, text: draftText)
                            .padding(.top, DashboardMetrics.draftCardTopSpacing)
                        wrote(message, state: state)
                            .padding(.top, DashboardMetrics.wroteTopSpacing)
                    } else {
                        noDraft(message, state: state)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            footer(message)
        }
    }

    /// Remetente 13/600 · conta mono 10 caps · hora mono 11 à direita.
    private func header(_ message: Message) -> some View {
        let conta = store.account(message.accountID)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(message.from.name.isEmpty ? message.from.address : message.from.name)
                .font(theme.sans.font(size: DashboardMetrics.previewSenderSize, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
            Text(DashboardMetrics.accountMark(
                host: conta?.host ?? "", address: conta?.address ?? ""
            ))
            .font(theme.mono.font(size: DashboardMetrics.previewAccountSize))
            .tracking(0.08 * DashboardMetrics.previewAccountSize)
            .foregroundStyle(theme.ink4.color)
            Spacer(minLength: 8)
            // "27/08 14:12", como o mockup — curto e em mono.
            Text(Self.horaCurta.string(from: message.receivedAt))
                .font(theme.mono.font(size: DashboardMetrics.previewTimeSize))
                .foregroundStyle(theme.ink4.color)
        }
    }

    /// Assunto 17/500.
    private func subjectLine(_ message: Message) -> some View {
        Text(message.subject)
            .font(theme.sans.font(size: DashboardMetrics.previewSubjectSize, weight: .medium))
            .foregroundStyle(theme.ink.color)
            .lineSpacing(DashboardMetrics.previewSubjectSize * 0.3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DashboardMetrics.previewSubjectTopSpacing)
    }

    // MARK: - O cartão do rascunho

    /// `surface`, borda `line`, raio r2 — o cartão vem **antes** do resumo.
    private func draftCard(_ message: Message, text: String) -> some View {
        let conta = store.account(message.accountID)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("Resposta pronta"))
                    .capsLabel(size: DashboardMetrics.capsSize)
                    .foregroundStyle(theme.accentInk.color)
                Spacer(minLength: 8)
                Text(L10n.tr("sai pela \(conta?.displayName ?? L10n.tr("conta"))"))
                    .capsLabel(size: DashboardMetrics.capsSize)
            }
            Text(text)
                .font(theme.sans.font(size: DashboardMetrics.draftBodySize))
                .foregroundStyle(theme.ink.color)
                .lineSpacing(DashboardMetrics.draftBodySize * 0.65)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DashboardMetrics.draftBodyTopSpacing)
            HStack(spacing: DashboardMetrics.draftActionsGap) {
                // **Envia direto**: o rascunho inteiro está logo acima.
                Button {
                    onSendDraft(message, text)
                } label: {
                    Text(L10n.tr("Enviar"))
                        .font(theme.sans.font(
                            size: DashboardMetrics.actionTextSize, weight: .semibold
                        ))
                        .foregroundStyle(theme.onAccent.color)
                        .padding(.horizontal, DashboardMetrics.buttonPadding)
                        .frame(height: DashboardMetrics.sendButtonHeight)
                        .background(theme.accent.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
                .accessibilityLabel(L10n.tr("Enviar a resposta pronta"))
                textAction(L10n.tr("Editar"), tone: theme.ink2.color) {
                    onEditDraft(message, text)
                }
                textAction(L10n.tr("Descartar"), tone: theme.ink4.color) {
                    onDiscardDraft(message)
                }
            }
            .padding(.top, DashboardMetrics.draftActionsTopSpacing)
        }
        .padding(DashboardMetrics.draftCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Resposta pronta"))
    }

    // MARK: - O que ele escreveu

    /// Caps + resumo da análise + "Ler o email inteiro · N linhas", que abre
    /// o `CorpoLegivelView` de sempre.
    private func wrote(_ message: Message, state: DashboardPreviewBody.State) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("O que ele escreveu"))
                .capsLabel(size: DashboardMetrics.capsSize)
            if let resumo = state.resumo {
                Text(resumo)
                    .font(theme.sans.font(size: DashboardMetrics.wroteSummarySize))
                    .foregroundStyle(theme.ink2.color)
                    .lineSpacing(DashboardMetrics.wroteSummarySize * 0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DashboardMetrics.wroteSummaryTopSpacing)
            }
            if bodyExpanded {
                CorpoLegivelView(corpo: state.corpo)
                    .padding(.top, DashboardMetrics.wroteSummaryTopSpacing)
            } else if !state.isEmpty {
                textAction(
                    DashboardMetrics.readWholeLabel(
                        lineCount: DashboardMetrics.bodyLineCount(state.text)
                    ),
                    tone: theme.ink3.color
                ) {
                    bodyExpanded = true
                }
                .padding(.top, DashboardMetrics.readWholeTopSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sem rascunho pronto: o resumo e o **corpo aberto**, com "Gerar
    /// resposta" — a prévia de hoje, sem placeholder prometendo rascunho.
    private func noDraft(_ message: Message, state: DashboardPreviewBody.State) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.tr("O que ele escreveu"))
                    .capsLabel(size: DashboardMetrics.capsSize)
                if let resumo = state.resumo {
                    Text(resumo)
                        .font(theme.sans.font(size: DashboardMetrics.wroteSummarySize))
                        .foregroundStyle(theme.ink2.color)
                        .lineSpacing(DashboardMetrics.wroteSummarySize * 0.6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DashboardMetrics.wroteSummaryTopSpacing)
                }
                if !state.isEmpty {
                    CorpoLegivelView(corpo: state.corpo)
                        .padding(.top, DashboardMetrics.wroteTopSpacing / 2)
                }
            }
            .padding(.top, DashboardMetrics.wroteTopSpacing)
            Button {
                conversation.draftReply()
            } label: {
                Text(conversation.isLoading ? L10n.tr("Escrevendo…") : L10n.tr("Gerar resposta"))
                    .font(theme.sans.font(
                        size: DashboardMetrics.actionTextSize, weight: .semibold
                    ))
                    .foregroundStyle(theme.onAccent.color)
                    .padding(.horizontal, DashboardMetrics.buttonPadding)
                    .frame(height: DashboardMetrics.sendButtonHeight)
                    .background(theme.accent.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
            .disabled(conversation.isLoading)
            .padding(.top, DashboardMetrics.wroteTopSpacing)
            .accessibilityLabel(L10n.tr("Gerar resposta"))
        }
    }

    // MARK: - Rodapé

    /// Ações em texto `ink3`, atrás da hairline: Responder eu mesmo ·
    /// Arquivar · Depois. Todas saem pela porta única (`ContextCommand`).
    private func footer(_ message: Message) -> some View {
        HStack(spacing: DashboardMetrics.previewFooterGap) {
            textAction(L10n.tr("Responder eu mesmo"), tone: theme.ink3.color) {
                onCommand(.reply(messageID: message.id))
            }
            textAction(L10n.tr("Arquivar"), tone: theme.ink3.color) {
                onCommand(.move(messageID: message.id, to: .archived))
            }
            textAction(L10n.tr("Depois"), tone: theme.ink3.color) {
                onCommand(.move(messageID: message.id, to: .later))
            }
        }
        .padding(.top, DashboardMetrics.previewFooterTopPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(theme.line2, edges: .top)
    }

    private func textAction(
        _ label: String, tone: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.sans.font(size: DashboardMetrics.actionTextSize, weight: .semibold))
                .foregroundStyle(tone)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}
