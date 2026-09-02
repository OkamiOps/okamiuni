import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// O "Briefing do dia" do mockup `design/07-dashboard.html`.
///
/// Fundo `paper` com recuo 22, cabeçalho com a data em versalete e a saudação
/// em serif, uma faixa de briefing quando ela existe, e duas colunas separadas
/// por um fio: à esquerda as PRIORIDADES em linhas flush no idioma da
/// `MessageRow` com o assistente colado no rodapé, à direita a `AgendaRail`
/// inteira com as PENDÊNCIAS embaixo.
///
/// Não há cartão flutuante, tile colorido nem sombra própria: as medidas
/// moram em `DashboardMetrics`, com o seletor CSS do mockup ao lado de cada
/// número. A IA não dispara sozinha — quem fala com ela é a
/// `AssistantConversation` injetada, e só por clique.
struct DashboardScreen: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let now: Int
    let today: Date
    /// A única máquina de estado do assistente nesta tela. O dashboard não
    /// guarda transcript, `loading` nem mensagem de erro próprios.
    let conversation: AssistantConversation
    let onOpenMessage: (Message) -> Void
    let onOpenEvent: (AgendaItem) -> Void
    let onShowMail: () -> Void
    let onShowCalendar: () -> Void
    let onOpenSettings: () -> Void
    /// A porta das ações rápidas (§2.4) e do menu de contexto: o **mesmo**
    /// `ContextCommand` que a Caixa emite. Quem hospeda o entrega à fila
    /// transacional, que é onde mora o "Desfazer" — o dashboard não mexe no
    /// store por um caminho próprio.
    let onCommand: (ContextCommand) -> Void

    @Binding var selectedMailID: String?
    @Binding var readingMailID: String?
    let onPresented: (String) -> Void

    /// Força as ações rápidas de uma linha visíveis, sem ponteiro.
    ///
    /// Existe pelo mesmo motivo que `ChromeButton.debugFocused`: um controle
    /// que só aparece no hover não se deixa clicar num teste fora da tela, e
    /// um botão sem teste é um botão que se diz mudo sem ninguém desmentir.
    let debugHoveredMailID: String?

    // As dependências que a folha de leitura repassa ao `ReaderPane`. Elas
    // atravessam o dashboard sem que ele as use: quem monta o leitor da Caixa
    // é o `InboxScreen`, e a folha tem de receber exatamente as mesmas — outro
    // conjunto faria o TL;DR mentir sobre o destino, ou a resposta rápida
    // perder o motor.
    let onCompose: (ComposerRoute) -> Void
    let intelligence: ComposerIntelligenceGenerator?
    let intelligencePresentation: IntelligencePresentation
    let analysisDestination: @Sendable (String?) -> AssistantDestination
    let makeAssistantConversation: ((String) -> AssistantConversation)?

    @State private var hoveredMailID: String?
    /// A altura do que está dentro do transcript, para o painel abraçar o
    /// conteúdo até o teto de 300 — ver `transcript`.
    @State private var transcriptContentHeight: CGFloat = 0

    init(
        store: MailStore,
        now: Int,
        today: Date,
        conversation: AssistantConversation,
        selectedMailID: Binding<String?> = .constant(nil),
        readingMailID: Binding<String?> = .constant(nil),
        onPresented: @escaping (String) -> Void = { _ in },
        onOpenMessage: @escaping (Message) -> Void = { _ in },
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onShowMail: @escaping () -> Void = {},
        onShowCalendar: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onCommand: @escaping (ContextCommand) -> Void = { _ in },
        onCompose: @escaping (ComposerRoute) -> Void = { _ in },
        intelligence: ComposerIntelligenceGenerator? = nil,
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        makeAssistantConversation: ((String) -> AssistantConversation)? = nil,
        debugHoveredMailID: String? = nil
    ) {
        self.store = store
        self.now = now
        self.today = today
        self.conversation = conversation
        self._selectedMailID = selectedMailID
        self._readingMailID = readingMailID
        self.onPresented = onPresented
        self.onOpenMessage = onOpenMessage
        self.onOpenEvent = onOpenEvent
        self.onShowMail = onShowMail
        self.onShowCalendar = onShowCalendar
        self.onOpenSettings = onOpenSettings
        self.onCommand = onCommand
        self.onCompose = onCompose
        self.intelligence = intelligence
        self.intelligencePresentation = intelligencePresentation
        self.analysisDestination = analysisDestination
        self.makeAssistantConversation = makeAssistantConversation
        self.debugHoveredMailID = debugHoveredMailID
    }

    var body: some View {
        let focus = store.dashboardFocus(nowMinute: now)
        VStack(alignment: .leading, spacing: 0) {
            header(focus)
                .padding(.bottom, DashboardMetrics.headerBottomSpacing)
            briefingBand
            HStack(spacing: 0) {
                mainColumn(focus)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.trailing, DashboardMetrics.mainTrailingPadding)
                rightColumn(focus)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(DashboardMetrics.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
        .overlay {
            if let id = readingMailID {
                DashboardMailSheet(
                    store: store,
                    messageID: id,
                    onClose: { readingMailID = nil },
                    onOpenInMailbox: { message in
                        readingMailID = nil
                        onOpenMessage(message)
                    },
                    onDraft: { message in
                        readingMailID = nil
                        selectedMailID = message.id
                        conversation.draftReply()
                    },
                    onPresented: onPresented,
                    onCompose: onCompose,
                    intelligence: intelligence,
                    intelligencePresentation: intelligencePresentation,
                    analysisDestination: analysisDestination,
                    makeAssistantConversation: makeAssistantConversation
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard de prioridades")
    }

    // MARK: - Cabeçalho

    /// `.head` — data em versalete, saudação em serif 28, e à direita o CTA
    /// com o destino do assistente embaixo. Sem emoji: o mockup não tem.
    private func header(_ focus: DashboardFocus) -> some View {
        let account = store.selectedAccountID.flatMap { store.account($0) } ?? store.accounts.first
        let hello = DashboardFocus.greeting(
            nowMinute: now,
            displayName: account?.displayName,
            address: account?.address
        )
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(DashboardMetrics.headerDateLabel(today))
                    .capsLabel(size: DashboardMetrics.capsSize)
                Text(hello)
                    .font(theme.serif.font(size: DashboardMetrics.greetingSize, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .padding(.top, 4)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: DashboardMetrics.providerSpacing) {
                ctaButton(focus)
                Text(conversation.destination.label)
                    .font(theme.sans.font(size: DashboardMetrics.providerSize))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hello)
    }

    private func ctaButton(_ focus: DashboardFocus) -> some View {
        // O mesmo predicado que o motor usa para resolver o contexto: ele só
        // resolve email quando há um **selecionado**. Com o topo da lista
        // aqui, o botão diria "Gerar rascunho" e o motor recusaria.
        let draftsReply = DashboardCTA.draftsReply(
            canDraftReply: conversation.canDraftReply,
            hasSelectedMail: selectedMail(focus) != nil
        )
        return ChromeButton(
            appearance: .outlined,
            height: DashboardMetrics.headerButtonHeight,
            horizontalPadding: DashboardMetrics.headerButtonPadding,
            labelSize: 12.5,
            action: {
                if draftsReply {
                    conversation.draftReply()
                } else {
                    conversation.briefing()
                }
            },
            label: { Text(DashboardCTA.title(draftsReply: draftsReply)) }
        )
        .disabled(conversation.isLoading)
        .help(draftsReply ? "Pede um rascunho do email em foco" : "Pede um briefing do dia")
        .accessibilityLabel(DashboardCTA.title(draftsReply: draftsReply))
    }

    // MARK: - Faixa de briefing

    /// `.briefing` — superfície plana com fio em cima e embaixo, texto em
    /// serif 15 e as duas ações à direita. Enquanto o modelo pensa, a faixa
    /// já aparece dizendo o que está fazendo.
    @ViewBuilder
    private var briefingBand: some View {
        if let text = conversation.briefingText {
            band {
                AssistantMarkdown(
                    text: text,
                    style: .prose(size: DashboardMetrics.briefingTextSize)
                )
            }
        } else if conversation.isLoading, !conversation.hasConversation {
            band {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.accent.color)
                    Text("Lendo caixa e agenda…")
                        .font(theme.serif.font(size: DashboardMetrics.briefingTextSize))
                        .foregroundStyle(theme.ink2.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func band(@ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            content()
            HStack(spacing: 6) {
                ChromeButton(
                    appearance: .outlined,
                    height: DashboardMetrics.miniButtonHeight,
                    horizontalPadding: 12,
                    labelSize: 11.5,
                    action: { conversation.briefing() },
                    label: { Text("Gerar de novo") }
                )
                .disabled(conversation.isLoading)
                Button {
                    conversation.clear()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.ink3.color)
                        .frame(
                            width: DashboardMetrics.closeButtonSide,
                            height: DashboardMetrics.closeButtonSide
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .help("Fechar o briefing")
                .accessibilityLabel("Fechar o briefing")
            }
            .padding(.top, 1)
        }
        .padding(DashboardMetrics.briefingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: [.top, .bottom])
        .padding(.bottom, DashboardMetrics.briefingBottomSpacing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Briefing do dia")
    }

    // MARK: - Coluna principal

    private func mainColumn(_ focus: DashboardFocus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Prioridades · \(focus.mail.count)")
                .capsLabel(size: DashboardMetrics.capsSize)
                .padding(.bottom, DashboardMetrics.sectionLabelBottomPadding)
            if focus.mail.isEmpty {
                emptyPriorities
            } else {
                priorityList(focus)
            }
            // `.flexpad` do mockup: a folga sobra **aqui**, entre a lista e o
            // assistente, e é por isso que o campo fica colado no rodapé sem
            // a lista esticar linha nenhuma.
            Spacer(minLength: 0)
            assistant
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prioridades")
    }

    private func priorityList(_ focus: DashboardFocus) -> some View {
        let visible = DashboardMetrics.visibleRowCount(
            total: focus.mail.count,
            hasBriefing: conversation.briefingText != nil,
            hasTranscript: conversation.hasConversation
        )
        return VStack(spacing: 0) {
            ForEach(focus.mail.prefix(visible)) { item in
                priorityRow(item)
            }
            if let footer = DashboardMetrics.omittedFooterLabel(focus.omittedMailCount) {
                Button(action: onShowMail) {
                    Text(footer)
                        .font(theme.sans.font(size: DashboardMetrics.footerSize, weight: .semibold))
                        .foregroundStyle(theme.accentInk.color)
                        .padding(DashboardMetrics.footerPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
            }
        }
        .hairline(theme.line2, edges: .top)
    }

    private func priorityRow(_ item: DashboardFocus.MailItem) -> some View {
        let message = item.message
        return DashboardPriorityRow(
            item: item,
            tint: accountTint(message.accountID).color,
            isUnread: !message.isRead,
            isSelected: selectedMailID == message.id,
            showsActions: (debugHoveredMailID ?? hoveredMailID) == message.id,
            today: today,
            onOpen: {
                selectedMailID = message.id
                readingMailID = message.id
            },
            onReply: { onCommand(.reply(messageID: message.id)) },
            onArchive: { onCommand(.move(messageID: message.id, to: .archived)) },
            onLater: { onCommand(.move(messageID: message.id, to: .later)) }
        )
        .onHover { inside in
            hoveredMailID = inside ? message.id : (hoveredMailID == message.id ? nil : hoveredMailID)
        }
        // O menu da Caixa, na mesma porta das ações rápidas: `intercept`
        // devolve `true` para tudo, e quem hospeda executa — é lá que mora a
        // fila transacional com "Desfazer".
        .uniContextMenu(
            ContextMenus.messageRow(
                message,
                accountAddress: store.account(message.accountID)?.address ?? "",
                provider: store.account(message.accountID)?.provider,
                currentBucket: message.bucket
            ),
            store: store,
            onReveal: { onCommand(.revealMessage(messageID: $0)) },
            intercept: { command in
                onCommand(command)
                return true
            }
        )
    }

    /// `.prio-empty` — o mesmo tom do "Dia livre" da trilha.
    private var emptyPriorities: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Nada pedindo uma decisão.")
                .font(theme.serif.font(size: 15))
                .foregroundStyle(theme.ink.color)
            Text("Quando um email precisar de resposta, tiver prazo ou trouxer um lead, ele aparece aqui.")
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DashboardMetrics.emptyPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(theme.line2, edges: .top)
    }

    // MARK: - Assistente

    /// `.assist` — o transcript (quando existe) por cima, a cápsula do campo,
    /// e o destino do assistente embaixo.
    private var assistant: some View {
        @Bindable var conversation = conversation
        return VStack(alignment: .leading, spacing: 0) {
            if conversation.hasConversation {
                transcript
                    .padding(.bottom, DashboardMetrics.transcriptBottomSpacing)
            }
            if let failure = conversation.failure {
                AssistantFailureBand(
                    failure: failure,
                    onRetry: conversation.retry,
                    onOpenSettings: onOpenSettings
                )
                .padding(.bottom, DashboardMetrics.transcriptBottomSpacing)
            }
            askCapsule
            Text(conversation.destination.label)
                .font(theme.sans.font(size: DashboardMetrics.providerSize))
                .foregroundStyle(theme.ink3.color)
                .padding(.top, 6)
        }
        .padding(.top, DashboardMetrics.assistantTopPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistente")
    }

    /// `.transcript` — teto de 300pt com rolagem por dentro, para o campo
    /// nunca sair do rodapé por conta de uma resposta longa.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Assistente")
                    .capsLabel(size: DashboardMetrics.capsSize)
                Spacer()
                Button("Limpar") { conversation.clear() }
                    .buttonStyle(.plain)
                    .capsLabel(size: DashboardMetrics.capsSize)
                    .focusRing(cornerRadius: theme.radiusSmall)
                    .disabled(conversation.isLoading)
            }
            .padding(.bottom, 10)

            // `max-height: 300px; overflow-y: auto`.
            //
            // A altura sai do conteúdo **medido**, limitada ao teto. Nem
            // `maxHeight` sozinho (a `ScrollView` é gulosa e come a coluna
            // inteira, empurrando a lista para longe do cabeçalho) nem
            // `fixedSize` sozinho (aí ela cresce além dos 300 e estoura a
            // janela) resolvem: um dá o teto sem o abraço, o outro o abraço
            // sem o teto.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(conversation.messages) { message in
                        turn(message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    transcriptContentHeight = height
                }
            }
            // `maxHeight`, e não `height`: a `ScrollView` é gulosa, então
            // com este teto ela mede `min(o que cabe, o que tem dentro, 300)`
            // — abraça o conteúdo curto, para nos 300 no longo, e cede
            // quando a janela é baixa demais para os 300.
            .frame(
                maxHeight: min(
                    max(transcriptContentHeight, 1), DashboardMetrics.transcriptMaxHeight
                )
            )
        }
        .padding(DashboardMetrics.transcriptPadding)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    @ViewBuilder
    private func turn(_ message: AssistantMessage) -> some View {
        if message.speaker == .user {
            // `.turn-q` — encostada à direita, sobre `accent-soft`.
            Text(message.text)
                .font(theme.sans.font(size: DashboardMetrics.questionSize))
                .foregroundStyle(theme.ink.color)
                .lineSpacing(3.5)
                .padding(DashboardMetrics.questionPadding)
                .background(theme.accentSoft.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            theme.accentLine.color, lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            // `.turn-a` — sobre `surface3`. Rascunho é prosa de email:
            // asterisco ali é literal, e por isso não passa pelo Markdown.
            Group {
                if message.kind == .draft {
                    Text(message.text)
                        .font(theme.serif.font(size: DashboardMetrics.answerSize))
                        .foregroundStyle(theme.ink.color)
                        .lineSpacing(DashboardMetrics.answerSize * 0.35)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    AssistantMarkdown(
                        text: message.text,
                        style: .prose(size: DashboardMetrics.answerSize)
                    )
                }
            }
            .padding(DashboardMetrics.answerPadding)
            .background(theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `.ask` — cápsula `btn`/`btn-line` com o botão ↑ do acento.
    private var askCapsule: some View {
        @Bindable var conversation = conversation
        return HStack(alignment: .center, spacing: 8) {
            DashboardAskField(
                text: $conversation.draft,
                placeholder: "Pergunte sobre seus emails…",
                textColor: theme.ink.nsColor,
                placeholderColor: theme.ink4.nsColor,
                onSubmit: { conversation.submit() },
                onEscape: {
                    if readingMailID != nil {
                        readingMailID = nil
                    }
                }
            )
            .frame(minHeight: DashboardAskField.minHeight, maxHeight: DashboardAskField.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Pergunta para o assistente")

            Button {
                conversation.submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(
                        conversation.canSend ? theme.onAccent.color : theme.ink4.color
                    )
                    .frame(
                        width: DashboardMetrics.sendButtonSide,
                        height: DashboardMetrics.sendButtonSide
                    )
                    .background(conversation.canSend ? theme.accent.color : theme.surface3.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
            .disabled(!conversation.canSend)
            .help("Enter envia. Shift+Enter quebra a linha.")
            .accessibilityLabel("Enviar pergunta")
        }
        .padding(.leading, DashboardMetrics.askLeadingPadding)
        .padding(.trailing, DashboardMetrics.askTrailingPadding)
        .frame(minHeight: DashboardMetrics.askHeight)
        .background(theme.btn.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(theme.btnShadow)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Coluna direita

    /// `.rail` — a trilha da agenda **inteira**, sem reimplementar linha de
    /// evento nenhuma, e as PENDÊNCIAS embaixo dela.
    private func rightColumn(_ focus: DashboardFocus) -> some View {
        VStack(spacing: 0) {
            AgendaRail(
                store: store,
                now: now,
                headerDate: today,
                width: DashboardMetrics.railWidth,
                showsPending: false,
                background: \.surface,
                // A coluna divide a altura com as PENDÊNCIAS: sem isto a
                // borda de baixo da trilha caía no meio de um cartão.
                clipsToRowBoundary: true,
                onOpenEvent: onOpenEvent,
                onRevealMessage: { onCommand(.revealMessage(messageID: $0)) }
            )
            .frame(maxHeight: .infinity)
            pendingSection(focus)
        }
        .frame(width: DashboardMetrics.railWidth)
        .background(theme.surface.color)
    }

    /// `.pend`.
    private func pendingSection(_ focus: DashboardFocus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pendências")
                .capsLabel(size: DashboardMetrics.capsSize)
                .padding(.bottom, DashboardMetrics.pendingLabelBottomSpacing)
            if focus.pending.isEmpty {
                Text("Nada pendente.")
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                    .padding(.vertical, 2)
            } else {
                ForEach(focus.pending.prefix(DashboardMetrics.maximumPendingRows)) { item in
                    pendingRow(item)
                }
                if let resto = DashboardMetrics.omittedPendingLabel(
                    total: focus.pending.count
                ) {
                    Text(resto)
                        .font(theme.sans.font(size: DashboardMetrics.pendingOriginSize))
                        .foregroundStyle(theme.ink3.color)
                        .padding(.top, 4)
                }
            }
        }
        .padding(DashboardMetrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(theme.line2, edges: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pendências")
    }

    private func pendingRow(_ item: PendingItem) -> some View {
        let account = store.account(item.accountID)
        let origin = [account?.displayName, account?.host]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(accountTint(item.accountID).color)
                .frame(
                    width: DashboardMetrics.pendingDotSide,
                    height: DashboardMetrics.pendingDotSide
                )
                .offset(y: -2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(theme.sans.font(size: DashboardMetrics.pendingTextSize))
                    .foregroundStyle(theme.ink2.color)
                    .lineSpacing(DashboardMetrics.pendingTextSize * 0.45)
                    .fixedSize(horizontal: false, vertical: true)
                if !origin.isEmpty {
                    Text(origin)
                        .font(theme.sans.font(size: DashboardMetrics.pendingOriginSize))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, DashboardMetrics.pendingItemVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Peças

    private func selectedMail(_ focus: DashboardFocus) -> Message? {
        guard let id = selectedMailID else { return nil }
        return store.message(id) ?? focus.mail.first { $0.id == id }?.message
    }

    private func accountTint(_ accountID: String) -> TokenColor {
        guard let account = store.account(accountID) else { return theme.ink3 }
        let hex = theme.isDark ? account.tintDarkHex : account.tintLightHex
        return TokenColor(css: hex) ?? theme.ink3
    }
}
