import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// O tríptico do mockup `design/07-dashboard.html`.
///
/// Fundo `paper` com recuo 22, cabeçalho com a data em versalete e a saudação
/// em serif, e logo abaixo a faixa **HOJE** — que substitui o briefing em
/// prosa por linhas curtas ligadas a mensagens reais, prontas quando a tela
/// abre. Embaixo, três colunas: a lista de PRIORIDADES à esquerda, a prévia
/// fixa de 380 no meio, e a `AgendaRail` inteira com as PENDÊNCIAS à direita —
/// que encolhe para 168 quando o dia está livre.
///
/// **Clicar seleciona, não abre.** A prévia do meio mostra o email
/// selecionado, as ações e o bloco Contexto; abrir de verdade é ⏎ ou duplo
/// clique, e aí sim a folha do leitor (`DashboardMailSheet`, que é o
/// `ReaderPane`). O rascunho nasce **dentro** da prévia, colado no email.
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
        makeAssistantConversation: ((String) -> AssistantConversation)? = nil
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
    }

    var body: some View {
        let focus = store.dashboardFocus(nowMinute: now)
        let diaLivre = DashboardLayout.isFreeDay(focus)
        VStack(alignment: .leading, spacing: 0) {
            header(focus)
                .padding(.bottom, DashboardMetrics.headerBottomSpacing)
            todayBand(focus)
                .padding(.bottom, DashboardMetrics.todayBottomSpacing)
            HStack(spacing: 0) {
                mainColumn(focus)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.trailing, DashboardMetrics.mainTrailingPadding)
                preview(focus)
                    .frame(width: DashboardLayout.previewWidth(freeDay: diaLivre))
                    .padding(.trailing, DashboardMetrics.railLeadingSpacing)
                rightColumn(focus, freeDay: diaLivre)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(DashboardMetrics.outerPadding)
        // ⏎ abre o que está selecionado. Monitor local com guarda de foco —
        // um `keyboardShortcut` roubaria a tecla do campo do assistente.
        .bareKeyShortcuts { key in
            let alvo = DashboardKeys.opens(
                key: key,
                selectedID: selectedMailID,
                readingID: readingMailID,
                exists: selectedMailID.flatMap { store.message($0) } != nil
            )
            guard let alvo else { return false }
            readingMailID = alvo
            return true
        }
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

    /// `.head` — data em versalete, saudação em serif 28, e à direita só o
    /// destino do assistente. **Sem botão de gerar briefing**: a faixa HOJE
    /// está pronta quando a tela abre, e era o botão que fazia o dono esperar
    /// por um parágrafo que ele não pediu.
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
            Text(conversation.destination.label)
                .font(theme.sans.font(size: DashboardMetrics.providerSize))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hello)
    }

    // MARK: - Faixa HOJE

    /// `.digest` — o que substituiu o briefing em prosa.
    private func todayBand(_ focus: DashboardFocus) -> some View {
        DashboardTodayBand(
            lines: DashboardToday.lines(focus, now: today),
            restLabel: DashboardToday.restLabel(focus.discardedMailCount),
            onSelect: { selectedMailID = $0 }
        )
    }

    // MARK: - Prévia do meio

    /// `.preview` — a coluna fixa de 380 (440 no dia livre).
    private func preview(_ focus: DashboardFocus) -> some View {
        DashboardPreviewPane(
            store: store,
            item: selectedItem(focus),
            focus: focus,
            today: today,
            conversation: conversation,
            onOpen: { if let id = selectedMailID { readingMailID = id } },
            onCommand: onCommand,
            onUseDraft: { message, text in
                store.setReplyDraft(
                    ReplyDraft(to: [message.from], text: text, savedAt: Date()),
                    for: message.id
                )
                readingMailID = message.id
            },
            onEditDraft: { message, text in
                store.setReplyDraft(
                    ReplyDraft(to: [message.from], text: text, savedAt: Date()),
                    for: message.id
                )
                onCommand(.reply(messageID: message.id))
            }
        )
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
            total: focus.mail.count, hasTranscript: !transcriptTurns.isEmpty
        )
        return VStack(spacing: 0) {
            let selecionado = selectedItem(focus)?.id
            ForEach(focus.mail.prefix(visible)) { item in
                priorityRow(item, selectedID: selecionado)
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

    private func priorityRow(_ item: DashboardFocus.MailItem, selectedID: String?) -> some View {
        let message = item.message
        return DashboardPriorityRow(
            item: item,
            tint: accountTint(message.accountID).color,
            isUnread: !message.isRead,
            isSelected: selectedID == message.id,
            today: today,
            // **Clicar seleciona.** As ações moram na prévia do meio; abrir é
            // ⏎ ou duplo clique.
            onSelect: { selectedMailID = message.id },
            onOpen: {
                selectedMailID = message.id
                readingMailID = message.id
            }
        )
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
    /// Os turnos que o transcript mostra.
    ///
    /// **Sem os `.draft`**: desde o tríptico o rascunho nasce dentro da
    /// prévia, colado no email. Repeti-lo aqui embaixo seria o mesmo texto
    /// duas vezes na mesma tela — e a segunda cópia é justamente o "bloco de
    /// texto solto" que esta tarefa veio tirar.
    private var transcriptTurns: [AssistantMessage] {
        conversation.messages.filter { $0.kind != .draft }
    }

    private var assistant: some View {
        @Bindable var conversation = conversation
        return VStack(alignment: .leading, spacing: 0) {
            if !transcriptTurns.isEmpty {
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
                    ForEach(transcriptTurns) { message in
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
    /// evento nenhuma, e as PENDÊNCIAS embaixo dela. No dia livre ela encolhe
    /// para 168 e vira um recado: `[data-state="agenda-vazia"] .rail`.
    @ViewBuilder
    private func rightColumn(_ focus: DashboardFocus, freeDay: Bool) -> some View {
        if freeDay {
            freeRail
        } else {
            fullRail(focus)
        }
    }

    /// `.rail-free`.
    private var freeRail: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Dia livre")
                .font(theme.serif.font(size: DashboardMetrics.freeRailTitleSize))
                .foregroundStyle(theme.ink.color)
            Text("Sem compromissos e sem pendências. A lista ganha a largura.")
                .font(theme.sans.font(size: DashboardMetrics.freeRailTextSize))
                .foregroundStyle(theme.ink3.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DashboardMetrics.freeRailPadding)
        .frame(width: DashboardMetrics.freeRailWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface.color)
        .hairline(theme.line, edges: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dia livre")
    }

    private func fullRail(_ focus: DashboardFocus) -> some View {
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
        .hairline(theme.line, edges: .leading)
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

    /// O item de prioridade selecionado. Sem seleção, a **primeira** linha:
    /// o mockup abre com a prévia cheia, e uma coluna do meio vazia na
    /// abertura seria a área morta que esta tela veio matar.
    private func selectedItem(_ focus: DashboardFocus) -> DashboardFocus.MailItem? {
        guard let id = selectedMailID else { return focus.mail.first }
        if let hit = focus.mail.first(where: { $0.id == id }) { return hit }
        guard let message = store.message(id) else { return focus.mail.first }
        return DashboardFocus.MailItem(message: message, reason: .today)
    }

    private func accountTint(_ accountID: String) -> TokenColor {
        guard let account = store.account(accountID) else { return theme.ink3 }
        let hex = theme.isDark ? account.tintDarkHex : account.tintLightHex
        return TokenColor(css: hex) ?? theme.ink3
    }
}
