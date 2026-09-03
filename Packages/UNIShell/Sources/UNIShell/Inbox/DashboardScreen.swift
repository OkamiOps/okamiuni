import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// O dashboard 08 — `design/08-dashboard-ia.dc.html`, "a IA trabalhando".
///
/// **Uma única caixa de cor na tela: o herói.** Todo o resto é hairline e
/// tipografia — sem chip, sem pílula, sem caixa dentro de caixa. Se uma borda
/// aparecer aqui, confira no mockup se ela existe.
///
/// A tela desenha o `DayPlan` (UNICore, puro): cabeçalho de uma linha, o
/// herói "Comece por aqui", e três colunas — a lista com o filtro em texto e
/// as seções, a prévia de 360 com o **cartão do rascunho antes de tudo**, e o
/// dia de 248. No canto, o botão "Perguntar · ⌘J".
///
/// **A IA nunca executa sozinha.** Toda proposta vira ação só por clique, e
/// as ações saem pela mesma porta da Caixa (`ContextCommand`, fila
/// transacional com desfazer). Enviar segue o ruling de 2026-09-03: na prévia
/// (rascunho inteiro à vista) envia direto pela fila de saída; na linha
/// (texto truncado) o clique arma a confirmação de uma linha primeiro.
struct DashboardScreen: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let now: Int
    let today: Date
    /// Os rascunhos antecipados, por mensagem — `ReadyDraftsModel.drafts` na
    /// fiação real; um dicionário montado à mão nos testes.
    let drafts: [String: ReadyDraft]
    /// A máquina de estado do "Gerar resposta" da prévia. O dashboard não
    /// guarda transcript nem loading próprios.
    let conversation: AssistantConversation
    /// A barra fina do chrome está trabalhando — vira "Atualizando…".
    let isWorking: Bool
    @Binding var filter: DayPlan.Filter
    @Binding var selectedMailID: String?
    @Binding var readingMailID: String?
    let onPresented: (String) -> Void
    let onOpenMessage: (Message) -> Void
    let onOpenEvent: (AgendaItem) -> Void
    /// A porta única das ações — o mesmo `ContextCommand` da Caixa.
    let onCommand: (ContextCommand) -> Void
    /// Descartar/consumir um rascunho antecipado → `discardReadyDraft`.
    let onDiscardDraft: (String) -> Void
    /// "Perguntar · ⌘J" — abre o painel do assistente que já existe.
    let onAskAssistant: () -> Void
    // As dependências que a folha de leitura repassa ao `ReaderPane`.
    let onCompose: (ComposerRoute) -> Void
    let intelligence: ComposerIntelligenceGenerator?
    let intelligencePresentation: IntelligencePresentation
    let analysisDestination: @Sendable (String?) -> AssistantDestination
    let makeAssistantConversation: ((String) -> AssistantConversation)?

    /// A linha com a confirmação de envio armada. O ruling: Enviar na linha
    /// **não** envia — seleciona e pergunta.
    @State private var confirmingSendID: String?
    /// O popover do "Conferir" do rodapé da lista.
    @State private var showingRemoved = false
    /// "Outro horário" do bloco sugerido — o editor de compromisso de sempre.
    @State private var pickingAnotherTime = false

    init(
        store: MailStore,
        now: Int,
        today: Date,
        drafts: [String: ReadyDraft] = [:],
        conversation: AssistantConversation,
        isWorking: Bool = false,
        filter: Binding<DayPlan.Filter> = .constant(.standard),
        selectedMailID: Binding<String?> = .constant(nil),
        readingMailID: Binding<String?> = .constant(nil),
        onPresented: @escaping (String) -> Void = { _ in },
        onOpenMessage: @escaping (Message) -> Void = { _ in },
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onCommand: @escaping (ContextCommand) -> Void = { _ in },
        onDiscardDraft: @escaping (String) -> Void = { _ in },
        onAskAssistant: @escaping () -> Void = {},
        onCompose: @escaping (ComposerRoute) -> Void = { _ in },
        intelligence: ComposerIntelligenceGenerator? = nil,
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        makeAssistantConversation: ((String) -> AssistantConversation)? = nil,
        debugConfirmingSendID: String? = nil
    ) {
        self.store = store
        self.now = now
        self.today = today
        self.drafts = drafts
        self.conversation = conversation
        self.isWorking = isWorking
        self._filter = filter
        self._selectedMailID = selectedMailID
        self._readingMailID = readingMailID
        self.onPresented = onPresented
        self.onOpenMessage = onOpenMessage
        self.onOpenEvent = onOpenEvent
        self.onCommand = onCommand
        self.onDiscardDraft = onDiscardDraft
        self.onAskAssistant = onAskAssistant
        self.onCompose = onCompose
        self.intelligence = intelligence
        self.intelligencePresentation = intelligencePresentation
        self.analysisDestination = analysisDestination
        self.makeAssistantConversation = makeAssistantConversation
        // Porta do harness: nasce com a confirmação de uma linha armada, para
        // o ensaio provar que **só** o Enviar dela envia. Nada no app usa.
        _confirmingSendID = State(initialValue: debugConfirmingSendID)
    }

    /// Os rascunhos que valem: validados contra a mensagem **cheia** e
    /// reescritos para o recorte sem corpo do focus — ver `DashboardPlanInput`.
    private var validatedDrafts: [String: ReadyDraft] {
        DashboardPlanInput.validatedDrafts(drafts) { store.message($0) }
    }

    /// O plano do dia, recalculado a cada mudança observável do store, dos
    /// rascunhos e das regras — e a cada minuto do relógio que `now` carrega.
    ///
    /// Os disparos descartados pelo ranking voltam ao recorte antes do
    /// `make`: o plano decide o destino de cada um (Vence, ou "Tirei da
    /// lista"), e sem vê-los chegar ele não teria o que decidir.
    private var plan: DayPlan {
        let selecionada = store.selectedAccountID
        let disparos = store.messages.filter { message in
            message.bucket == .today
                && message.effectiveBulkMarks.isBulk
                && (selecionada == nil || message.accountID == selecionada)
        }
        return DayPlan.make(
            focus: DashboardPlanInput.planFocus(
                store.dashboardFocus(nowMinute: now), broadcasts: disparos
            ),
            drafts: validatedDrafts,
            rules: store.senderRules,
            agenda: store.agenda,
            filter: filter,
            now: today,
            nowMinute: now
        )
    }

    var body: some View {
        let plan = plan
        VStack(alignment: .leading, spacing: 0) {
            header
            if let hero = plan.hero {
                heroBand(hero)
                    .padding(.top, DashboardMetrics.heroTopSpacing)
            }
            columns(plan)
                .frame(maxHeight: .infinity)
        }
        .padding(DashboardMetrics.contentPadding)
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
        .overlay(alignment: .bottomTrailing) { askButton }
        .overlay { readingSheet }
        .sheet(isPresented: $pickingAnotherTime) {
            NewAppointmentSheet(
                store: store,
                anchor: today,
                initialDayOffset: plan.replyBlock?.day ?? 0,
                initialTitle: DashboardMetrics.replyBlockTitle(
                    names: DashboardDay.planNames(for: plan)
                ),
                onClose: { pickingAnotherTime = false }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard do dia")
    }

    // MARK: - Cabeçalho de uma linha

    /// Saudação 22/600 + data em versalete; à direita o relógio da tela e o
    /// provedor. A saudação encolheu de propósito: a notícia é o herói.
    private var header: some View {
        let account = store.selectedAccountID.flatMap { store.account($0) }
            ?? store.accounts.first
        let hello = DashboardFocus.greeting(
            nowMinute: now,
            displayName: account?.displayName,
            address: account?.address
        )
        return HStack(alignment: .firstTextBaseline, spacing: DashboardMetrics.headerGap) {
            Text(hello)
                .font(theme.sans.font(size: DashboardMetrics.greetingSize, weight: .semibold))
                .tracking(-0.01 * DashboardMetrics.greetingSize)
                .foregroundStyle(theme.ink.color)
            Text(DashboardMetrics.headerDateLabel(today))
                .capsLabel(size: DashboardMetrics.capsSize)
            Spacer(minLength: 8)
            Text(DashboardMetrics.updateLabel(nowMinute: now, isBusy: isWorking))
                .font(theme.sans.font(size: DashboardMetrics.statusSize))
                .foregroundStyle(theme.ink4.color)
            Text(conversation.destination.label)
                .font(theme.sans.font(size: DashboardMetrics.statusSize))
                .foregroundStyle(theme.ink4.color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hello)
    }

    // MARK: - Herói

    /// "Comece por aqui" — **a única caixa de cor da tela** (`accentSoft`).
    /// Sem herói, o bloco não aparece: nada de placeholder.
    private func heroBand(_ hero: DayPlan.Hero) -> some View {
        HStack(alignment: .center, spacing: DashboardMetrics.heroGap) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Comece por aqui")
                    .capsLabel(size: DashboardMetrics.capsSize)
                    .foregroundStyle(theme.accentInk.color)
                Text(hero.sentence)
                    .font(theme.sans.font(size: DashboardMetrics.heroSentenceSize, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineSpacing(DashboardMetrics.heroSentenceSize * 0.35)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                selectedMailID = hero.messageID
                // O herói mostra a frase, não o rascunho inteiro — então o
                // ruling vale aqui também: armar a confirmação, nunca enviar.
                if hero.hasReadyDraft { confirmingSendID = hero.messageID }
            } label: {
                Text(DashboardMetrics.heroButtonLabel(hasReadyDraft: hero.hasReadyDraft))
                    .font(theme.sans.font(size: DashboardMetrics.actionTextSize, weight: .semibold))
                    .foregroundStyle(theme.onAccent.color)
                    .padding(.horizontal, DashboardMetrics.heroButtonPadding)
                    .frame(height: DashboardMetrics.heroButtonHeight)
                    .background(theme.accent.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
            Button {
                selectedMailID = hero.messageID
            } label: {
                Text("Ver antes")
                    .font(theme.sans.font(size: DashboardMetrics.actionTextSize, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
        }
        .padding(DashboardMetrics.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comece por aqui: \(hero.sentence)")
    }

    // MARK: - As três colunas

    private func columns(_ plan: DayPlan) -> some View {
        HStack(alignment: .top, spacing: 0) {
            listColumn(plan)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.trailing, DashboardMetrics.listTrailingPadding)
            divider
            preview(plan)
            divider
                .padding(.leading, DashboardMetrics.dayDividerLeadingSpacing)
            dayColumn(plan)
        }
    }

    /// A hairline entre colunas — começa 22 abaixo do herói, como as colunas.
    private var divider: some View {
        Rectangle()
            .fill(theme.line.color)
            .frame(width: Hairline.thickness(displayScale))
            .padding(.top, DashboardMetrics.columnsTopSpacing)
    }

    // MARK: - Lista

    private func listColumn(_ plan: DayPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow(plan)
            // A lista rola **dentro** da coluna, e o rodapé é o chão dela.
            // Sem o `maxHeight`, a rolagem tomava a altura do conteúdo e a
            // última linha morria na aresta, colada em "Tirei da lista".
            sections(plan)
                .frame(maxHeight: .infinity)
            removedFooter(plan)
        }
    }

    /// O filtro **em texto**: ativo = ink com sublinhado accent de 1.5;
    /// inativo = ink4. Contagem em mono ao lado. À direita, as contas.
    private func filterRow(_ plan: DayPlan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DashboardMetrics.filterGap) {
                ForEach(DayPlan.Filter.Category.allCases, id: \.self) { category in
                    filterItem(category, count: plan.counts[category] ?? 0)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: DashboardMetrics.accountGap) {
                ForEach(store.accounts) { account in
                    accountItem(account)
                }
            }
        }
        .padding(DashboardMetrics.filterRowPadding)
        .hairline(theme.line, edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filtro da lista")
    }

    private func filterItem(_ category: DayPlan.Filter.Category, count: Int) -> some View {
        let ativo = filter.on.contains(category)
        return Button {
            if ativo { filter.on.remove(category) } else { filter.on.insert(category) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DashboardMetrics.filterCountSpacing) {
                Text(category.label)
                    .font(theme.sans.font(size: DashboardMetrics.filterTextSize))
                    .foregroundStyle(ativo ? theme.ink.color : theme.ink4.color)
                Text("\(count)")
                    .font(theme.mono.font(size: DashboardMetrics.filterCountSize, weight: .medium))
                    .foregroundStyle(ativo ? theme.accentInk.color : theme.ink4.color)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                if ativo {
                    Rectangle()
                        .fill(theme.accent.color)
                        .frame(height: DashboardMetrics.filterUnderlineThickness)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel("\(category.label), \(count)")
        .accessibilityAddTraits(ativo ? .isSelected : [])
    }

    /// A conta como ponto 7ø na tinta + nome. Clique alterna o filtro de
    /// conta; conjunto vazio é "todas".
    private func accountItem(_ account: Account) -> some View {
        let filtrada = filter.accounts.isEmpty || filter.accounts.contains(account.id)
        return Button {
            if filter.accounts.contains(account.id) {
                filter.accounts.remove(account.id)
            } else {
                filter.accounts.insert(account.id)
            }
        } label: {
            HStack(spacing: DashboardMetrics.accountDotSpacing) {
                Circle()
                    .fill(accountTint(account.id).color)
                    .frame(
                        width: DashboardMetrics.accountDotSide,
                        height: DashboardMetrics.accountDotSide
                    )
                Text(account.displayName)
                    .font(theme.sans.font(size: DashboardMetrics.accountNameSize))
                    .foregroundStyle(theme.ink3.color)
            }
            .opacity(filtrada ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel("Conta \(account.displayName)")
    }

    // MARK: - Seções

    private func sections(_ plan: DayPlan) -> some View {
        // A seleção efetiva: sem clique nenhum, a primeira linha — a mesma
        // que a prévia mostra. Lista e prévia nunca discordam sobre quem
        // está selecionado.
        let selecionado = selectedItem(plan)?.id
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plan.sections.enumerated()), id: \.element.kind) { indice, section in
                    sectionHeader(section, isFirst: indice == 0)
                    ForEach(section.rows) { row in
                        dashboardRow(row, selectedID: selecionado)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // O mesmo respiro do corpo do email: a última linha nunca morre
            // colada na aresta do recorte.
            .padding(.bottom, DashboardMetrics.previewBodyFade)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .avisaQueRola("A lista continua abaixo. Role para ver o resto.")
    }

    /// CapsLabel `ink2` + contagem mono — pad 26 0 6 (primeira: 18).
    private func sectionHeader(_ section: DayPlan.Section, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.kind.label)
                .capsLabel(size: DashboardMetrics.capsSize)
                .foregroundStyle(theme.ink2.color)
            Text("\(section.rows.count)")
                .font(theme.mono.font(size: DashboardMetrics.sectionCountSize))
                .foregroundStyle(theme.ink4.color)
        }
        .padding(
            .top,
            isFirst ? DashboardMetrics.firstSectionTopPadding
                : DashboardMetrics.sectionTopPadding
        )
        .padding(.bottom, DashboardMetrics.sectionBottomPadding)
    }

    private func dashboardRow(_ row: DayPlan.Row, selectedID: String?) -> some View {
        let message = row.item.message
        return DashboardRow(
            row: row,
            tint: accountTint(message.accountID).color,
            accountMark: accountMark(message.accountID),
            usedAgenda: validatedDrafts[row.id]?.usedAgenda == true,
            isSelected: selectedID == row.id,
            isConfirmingSend: confirmingSendID == row.id,
            today: today,
            onSelect: { select(row.id) },
            onOpen: {
                selectedMailID = row.id
                readingMailID = row.id
            },
            onPrimary: { primaryAction(for: row) },
            onSecondary: { secondaryAction(for: row) },
            onConfirmSend: { confirmSend(row) },
            onCancelSend: { confirmingSendID = nil }
        )
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

    // MARK: - Ações das linhas

    private func select(_ id: String) {
        selectedMailID = id
        if confirmingSendID != id { confirmingSendID = nil }
    }

    /// A ação primária da proposta. **Enviar na linha não envia**: arma a
    /// confirmação de uma linha (o ruling de 2026-09-03).
    private func primaryAction(for row: DayPlan.Row) {
        switch row.proposal {
        case .sendDraft:
            selectedMailID = row.id
            confirmingSendID = row.id
        case .later:
            // A data proposta não cabe em `ContextCommand.move` — ver o
            // relatório da tarefa. O destino é a caixa Depois.
            onCommand(.move(messageID: row.id, to: .later))
        case .archiveAndLearn:
            // As duas na mesma leva: arquivar **e** aprender a regra. O
            // desfazer da regra é o próprio comando invertido.
            onCommand(.move(messageID: row.id, to: .archived))
            onCommand(.learnSender(
                address: row.item.message.from.address, neverPriority: true
            ))
        case .keep:
            selectedMailID = row.id
        }
    }

    private func secondaryAction(for row: DayPlan.Row) {
        switch row.proposal {
        case .sendDraft:
            // Editar: o rascunho vai para o composer, pelo seed de resposta.
            if let texto = validatedDrafts[row.id]?.text {
                editDraft(row.item.message, text: texto)
            }
        case .later:
            // "Agora": responder já — abre o composer de resposta.
            onCommand(.reply(messageID: row.id))
        case .archiveAndLearn, .keep:
            // "Manter": a linha fica. Nada a executar.
            selectedMailID = row.id
        }
    }

    /// O Enviar **da confirmação** — este sim envia, pela fila de saída
    /// normal, e consome o rascunho.
    private func confirmSend(_ row: DayPlan.Row) {
        confirmingSendID = nil
        guard let draft = validatedDrafts[row.id] else { return }
        let message = store.message(row.id) ?? row.item.message
        if DashboardSend.send(draft: draft.text, for: message, in: store, theme: theme) {
            onDiscardDraft(row.id)
        }
    }

    private func editDraft(_ message: Message, text: String) {
        store.setReplyDraft(
            ReplyDraft(to: [message.from], text: text, savedAt: Date()),
            for: message.id
        )
        onCommand(.reply(messageID: message.id))
    }

    // MARK: - Rodapé da lista

    @ViewBuilder
    private func removedFooter(_ plan: DayPlan) -> some View {
        let entradas = plan.removed.map { removido in
            let contato = store.message(removido.messageID)?.from
            let nome = contato?.name.trimmingCharacters(in: .whitespaces) ?? ""
            return (
                name: nome.isEmpty ? (contato?.address ?? removido.subject) : nome,
                why: removido.why
            )
        }
        let extra = max(0, (plan.counts[.broadcasts] ?? 0) - plan.removed.count)
        if let frase = DashboardMetrics.removedFooterLabel(entradas, extraCount: extra) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(frase)
                    .font(theme.sans.font(size: DashboardMetrics.listFooterSize))
                    .foregroundStyle(theme.ink4.color)
                    .lineSpacing(DashboardMetrics.listFooterSize * 0.5)
                Button {
                    showingRemoved = true
                } label: {
                    Text("Conferir")
                        .font(theme.sans.font(
                            size: DashboardMetrics.listFooterSize, weight: .semibold
                        ))
                        .foregroundStyle(theme.accentInk.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                // Filtrar a Caixa por uma lista de ids não existe hoje; o
                // popover lista o que saiu, com o porquê de cada um — ver o
                // relatório da tarefa.
                .popover(isPresented: $showingRemoved) {
                    removedPopover(plan)
                }
            }
            .padding(.top, DashboardMetrics.listFooterTopPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(frase)
        }
    }

    private func removedPopover(_ plan: DayPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tirei da lista hoje")
                .capsLabel(size: DashboardMetrics.capsSize)
            ForEach(plan.removed, id: \.messageID) { removido in
                VStack(alignment: .leading, spacing: 2) {
                    Text(removido.subject)
                        .font(theme.sans.font(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    Text(removido.why)
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: - Prévia

    private func preview(_ plan: DayPlan) -> some View {
        let item = selectedItem(plan)
        return DashboardPreviewColumn(
            store: store,
            item: item,
            today: today,
            readyDraft: item.flatMap { validatedDrafts[$0.id] },
            conversation: conversation,
            onSendDraft: { message, texto in
                // **Aqui envia direto**: o rascunho inteiro está na tela.
                if DashboardSend.send(draft: texto, for: message, in: store, theme: theme) {
                    onDiscardDraft(message.id)
                }
            },
            onEditDraft: { message, texto in
                editDraft(message, text: texto)
            },
            onDiscardDraft: { message in
                onDiscardDraft(message.id)
            },
            onCommand: onCommand
        )
        .frame(
            width: DashboardMetrics.previewWidth + DashboardMetrics.previewLeadingPadding,
            alignment: .topLeading
        )
    }

    /// O item selecionado — ou a primeira linha do plano: o mockup abre com a
    /// prévia cheia, e uma coluna vazia na abertura seria área morta.
    private func selectedItem(_ plan: DayPlan) -> DashboardFocus.MailItem? {
        let linhas = plan.sections.flatMap(\.rows)
        guard let id = selectedMailID else { return linhas.first?.item }
        if let hit = linhas.first(where: { $0.id == id }) { return hit.item }
        guard let message = store.message(id) else { return linhas.first?.item }
        return DashboardFocus.MailItem(message: message, reason: .today)
    }

    // MARK: - Dia

    private func dayColumn(_ plan: DayPlan) -> some View {
        let focus = store.dashboardFocus(nowMinute: now)
        return DashboardDayColumn(
            entries: DashboardDay.entries(
                agenda: store.agenda,
                deadlines: DashboardDay.deadlines(in: plan, today: today),
                plan: plan.replyBlock,
                planNames: DashboardDay.planNames(for: plan),
                nowMinute: now
            ),
            nextUpLabel: focus.nextUpLabel,
            pending: focus.pending,
            onOpenEvent: { id in
                if let item = store.agenda.first(where: { $0.id == id }) {
                    onOpenEvent(item)
                }
            },
            onRevealMessage: { onCommand(.revealMessage(messageID: $0)) },
            onReserve: { reserve(plan) },
            onPickAnotherTime: { pickingAnotherTime = true }
        )
    }

    /// "Reservar" — o bloco vira compromisso de verdade, pelo mesmo caminho
    /// do editor de agenda (`addManualAgendaItem`).
    private func reserve(_ plan: DayPlan) {
        guard let bloco = plan.replyBlock else { return }
        let conta = store.selectedAccountID ?? store.accounts.first?.id ?? ""
        _ = store.addManualAgendaItem(
            title: DashboardMetrics.replyBlockTitle(
                names: DashboardDay.planNames(for: plan)
            ),
            startMinute: bloco.startMinute,
            endMinute: bloco.startMinute + bloco.minutes,
            dayOffset: bloco.day,
            accountID: conta,
            sendInvites: false
        )
    }

    // MARK: - Botão "Perguntar · ⌘J"

    private var askButton: some View {
        Button(action: onAskAssistant) {
            HStack(spacing: DashboardMetrics.askButtonGap) {
                Image(systemName: "bubble.left")
                    .font(.system(size: DashboardMetrics.askIconSize, weight: .medium))
                    .foregroundStyle(theme.accent.color)
                Text("Perguntar")
                    .font(theme.sans.font(size: DashboardMetrics.askLabelSize, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text("⌘J")
                    .font(theme.mono.font(size: DashboardMetrics.askShortcutSize))
                    .foregroundStyle(theme.ink4.color)
            }
            .padding(.leading, DashboardMetrics.askButtonLeadingPadding)
            .padding(.trailing, DashboardMetrics.askButtonTrailingPadding)
            .frame(height: DashboardMetrics.askButtonHeight)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.askButtonRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardMetrics.askButtonRadius)
                    .strokeBorder(
                        theme.btnLine.color, lineWidth: Hairline.thickness(displayScale)
                    )
            }
            // A única sombra da tela — a do mockup, número a número.
            .shadow(
                color: .black.opacity(DashboardMetrics.askShadowOpacity),
                radius: DashboardMetrics.askShadowRadius,
                x: 0, y: DashboardMetrics.askShadowY
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: DashboardMetrics.askButtonRadius)
        .keyboardShortcut("j", modifiers: .command)
        .padding(.trailing, DashboardMetrics.askButtonTrailing)
        .padding(.bottom, DashboardMetrics.askButtonBottom)
        .accessibilityLabel("Perguntar ao assistente, comando J")
    }

    // MARK: - Folha de leitura

    @ViewBuilder
    private var readingSheet: some View {
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

    // MARK: - Peças

    private func accountMark(_ accountID: String) -> String {
        guard let account = store.account(accountID) else { return "" }
        return DashboardMetrics.accountMark(host: account.host, address: account.address)
    }

    private func accountTint(_ accountID: String) -> TokenColor {
        guard let account = store.account(accountID) else { return theme.ink3 }
        let hex = theme.isDark ? account.tintDarkHex : account.tintLightHex
        return TokenColor(css: hex) ?? theme.ink3
    }
}
