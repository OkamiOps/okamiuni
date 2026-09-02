import SwiftUI
import UNIDesign
import UNICore

/// O recorte do desenho: saudação, duas colunas de cartão à esquerda
/// (Prioridades + Eventos) e o assistente largo à direita, com tiles,
/// sugestão e o CTA em cápsula. A IA não dispara sozinha.
struct DashboardScreen: View {

    static let briefingQuestion =
        "Quais são minhas prioridades agora considerando e-mails e agenda? Entregue só o que precisa de mim hoje, em poucas linhas."

    static let visibleMail = 3
    static let visibleMeetings = 3

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let now: Int
    let today: Date
    let onOpenMessage: (Message) -> Void
    let onOpenEvent: (AgendaItem) -> Void
    let onShowMail: () -> Void
    let onShowCalendar: () -> Void
    let onAsk: (AssistantRequest, InboxAssistantScope) async throws -> String

    @Binding var transcript: [AssistantMessage]
    @Binding var draft: String
    @Binding var selectedMailID: String?
    @Binding var readingMailID: String?
    let onPresented: (String) -> Void

    @State private var selectedEventID: String?
    @State private var loading = false
    @State private var errorMessage: String?

    init(
        store: MailStore,
        now: Int,
        today: Date,
        transcript: Binding<[AssistantMessage]> = .constant([]),
        draft: Binding<String> = .constant(""),
        selectedMailID: Binding<String?> = .constant(nil),
        readingMailID: Binding<String?> = .constant(nil),
        onPresented: @escaping (String) -> Void = { _ in },
        onOpenMessage: @escaping (Message) -> Void = { _ in },
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onShowMail: @escaping () -> Void = {},
        onShowCalendar: @escaping () -> Void = {},
        onAsk: @escaping (AssistantRequest, InboxAssistantScope) async throws -> String = { _, _ in "" }
    ) {
        self.store = store
        self.now = now
        self.today = today
        self._transcript = transcript
        self._draft = draft
        self._selectedMailID = selectedMailID
        self._readingMailID = readingMailID
        self.onPresented = onPresented
        self.onOpenMessage = onOpenMessage
        self.onOpenEvent = onOpenEvent
        self.onShowMail = onShowMail
        self.onShowCalendar = onShowCalendar
        self.onAsk = onAsk
    }

    var body: some View {
        let focus = store.dashboardFocus(nowMinute: now)
        VStack(alignment: .leading, spacing: 18) {
            greeting
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    priorities(focus)
                    events(focus)
                }
                .frame(minWidth: 340, maxWidth: 440)
                assistant(focus)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
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
                        Task { await runDraft(for: message) }
                    },
                    onPresented: onPresented
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard de prioridades")
    }

    // MARK: - Saudação

    private var greeting: some View {
        let account = store.selectedAccountID.flatMap { store.account($0) } ?? store.accounts.first
        let hello = DashboardFocus.greeting(
            nowMinute: now,
            displayName: account?.displayName,
            address: account?.address
        )
        let titled = hello.contains(",") ? "\(hello)!" : hello
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(titled)
                .font(theme.sans.font(size: 28, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text("👋")
                .font(.system(size: 24))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(titled)
    }

    // MARK: - Prioridades

    private func priorities(_ focus: DashboardFocus) -> some View {
        let items = Array(focus.mail.prefix(Self.visibleMail))
        return board {
            VStack(alignment: .leading, spacing: 12) {
                sectionHead(
                    icon: "star.fill",
                    iconColor: theme.accent,
                    title: "Prioridades",
                    action: "Ver todas",
                    perform: onShowMail
                )
                if items.isEmpty {
                    emptyCopy("Nada pedindo uma decisão.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(items) { item in
                            mailRow(item)
                        }
                    }
                }
                Spacer(minLength: 0)
                footerLink("Ver todas as prioridades →", perform: onShowMail)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prioridades")
    }

    private func mailRow(_ item: DashboardFocus.MailItem) -> some View {
        let message = item.message
        let selected = selectedMailID == message.id
        let tint = accountTint(message.accountID)
        return Button {
            selectedMailID = message.id
            selectedEventID = nil
            readingMailID = message.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(tint.color)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.subject)
                            .font(theme.sans.font(size: 13.5, weight: .semibold))
                            .foregroundStyle(theme.ink.color)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        rankPill(item.reason)
                    }
                    Text(message.listHeadline)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                nestFill.color,
                in: RoundedRectangle(cornerRadius: nestRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: nestRadius, style: .continuous)
                    .strokeBorder(
                        selected ? theme.info.color.opacity(0.55) : theme.line2.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: nestRadius)
        .contextMenu {
            Button("Abrir na Caixa") { onOpenMessage(message) }
        }
        .accessibilityLabel("\(message.subject), \(item.reason.rankLabel), \(message.listHeadline)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func rankPill(_ reason: DashboardFocus.Reason) -> some View {
        let pigment = reason.isUrgent ? theme.danger : theme.accent
        let fill = wash(pigment, amount: theme.isDark ? 0.38 : 0.16)
        let ink = pigment.ensuringContrast(against: fill, minimum: 3.2)
        return Text(reason.rankLabel)
            .font(theme.sans.font(size: 10.5, weight: .semibold))
            .foregroundStyle(ink.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill.color, in: Capsule())
            .accessibilityHidden(true)
    }

    // MARK: - Eventos

    private func events(_ focus: DashboardFocus) -> some View {
        let todayItems = focus.meetings.filter { $0.dayOffset == 0 }
        let showingToday = !todayItems.isEmpty
        let items = Array((showingToday ? todayItems : focus.meetings).prefix(Self.visibleMeetings))
        return board {
            VStack(alignment: .leading, spacing: 12) {
                sectionHead(
                    icon: "calendar",
                    iconColor: theme.info,
                    title: showingToday ? "Eventos de hoje" : "Próximos",
                    action: "Ver agenda",
                    perform: onShowCalendar
                )
                if items.isEmpty {
                    emptyCopy("Nada na frente.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(items) { item in
                            meetingRow(item, showDay: !showingToday)
                        }
                    }
                }
                Spacer(minLength: 0)
                footerLink("Ver agenda completa →", perform: onShowCalendar)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(showingToday ? "Eventos de hoje" : "Próximos compromissos")
    }

    private func meetingRow(_ item: AgendaItem, showDay: Bool) -> some View {
        let live = item.dayOffset == 0 && now >= item.startMinute && now < item.endMinute
        let tint = accountTint(item.accountID)
        return Button {
            selectedEventID = item.id
            selectedMailID = nil
            onOpenEvent(item)
        } label: {
            HStack(spacing: 12) {
                timeChip(item.startLabel, live: live)
                Circle()
                    .fill(live ? theme.live.color : tint.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(theme.sans.font(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    if let place = honestPlace(item) {
                        Text(place)
                            .font(theme.sans.font(size: 12))
                            .foregroundStyle(theme.ink3.color)
                            .lineLimit(1)
                    } else if showDay {
                        Text(DashboardFocus.meetingDayName(offset: item.dayOffset, anchor: today))
                            .font(theme.sans.font(size: 12))
                            .foregroundStyle(theme.ink3.color)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                nestFill.color,
                in: RoundedRectangle(cornerRadius: nestRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: nestRadius, style: .continuous)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: nestRadius)
        .accessibilityLabel("\(item.startLabel), \(item.title)")
    }

    private func timeChip(_ label: String, live: Bool) -> some View {
        Text(label)
            .font(theme.mono.font(size: 12, weight: .medium))
            .foregroundStyle(live ? theme.live.color : theme.ink.color)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                (live ? wash(theme.live, amount: theme.isDark ? 0.34 : 0.14) : nestFill).color,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    // MARK: - Assistente

    private func assistant(_ focus: DashboardFocus) -> some View {
        board {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    robot
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("IA Assistant")
                                .font(theme.sans.font(size: 16, weight: .semibold))
                                .foregroundStyle(theme.ink.color)
                            betaBadge
                        }
                        Text("Resumo do que pede você agora.")
                            .font(theme.sans.font(size: 12))
                            .foregroundStyle(theme.ink3.color)
                    }
                    Spacer(minLength: 0)
                    draftButton(focus)
                    if !transcript.isEmpty {
                        Button("Limpar") {
                            transcript = []
                            errorMessage = nil
                            draft = ""
                        }
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.ink3.color)
                        .focusRing(cornerRadius: theme.radiusSmall)
                        .disabled(loading)
                    }
                }

                if let mail = selectedMail(focus) ?? store.message(selectedMailID ?? "") {
                    contextChip(mail)
                }

                Text("Resumo inteligente")
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink.color)

                HStack(spacing: 10) {
                    metricTile(
                        "\(focus.mail.count)",
                        caption: "Emails",
                        pigment: theme.success
                    )
                    metricTile(
                        "\(focus.meetings.filter { $0.dayOffset == 0 }.count)",
                        caption: "Eventos",
                        pigment: theme.accent
                    )
                    metricTile(
                        "\(focus.pending.count)",
                        caption: "Pendências",
                        pigment: theme.info
                    )
                }

                if transcript.isEmpty {
                    suggestion(focus)
                } else {
                    transcriptList
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(theme.ink.color)
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.info.color)
                        Text("Lendo caixa e agenda…")
                            .font(theme.sans.font(size: 12.5))
                            .foregroundStyle(theme.ink3.color)
                    }
                }

                Spacer(minLength: 0)
                composer
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("IA Assistant")
    }

    private func suggestion(_ focus: DashboardFocus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sugestão da IA")
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink3.color)
            Text(suggestionCopy(focus))
                .font(theme.sans.font(size: 14))
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    nestFill.color,
                    in: RoundedRectangle(cornerRadius: nestRadius, style: .continuous)
                )
        }
    }

    private var transcriptList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(transcript) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.speaker == .user ? "Você" : "Assistente")
                            .font(theme.sans.font(size: 11, weight: .medium))
                            .foregroundStyle(theme.ink4.color)
                        Text(message.text)
                            .font(theme.sans.font(size: 13.5))
                            .foregroundStyle(theme.ink.color)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func draftButton(_ focus: DashboardFocus) -> some View {
        Button {
            Task { await runSuggestion(focus) }
        } label: {
            Text("Gerar rascunho")
                .font(theme.sans.font(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(theme.accent.color, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 14, tint: \.onAccent)
        .disabled(loading)
        .help(focus.mail.isEmpty ? "Pede um recorte do dia" : "Pede um rascunho do email em foco")
        .accessibilityLabel("Gerar rascunho")
    }

    private func contextChip(_ mail: Message) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.info.color)
                .accessibilityHidden(true)
            Text(mail.subject)
                .font(theme.sans.font(size: 12, weight: .medium))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                selectedMailID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.ink4.color)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: 9)
            .accessibilityLabel("Parar de usar este email como contexto")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            nestFill.color,
            in: RoundedRectangle(cornerRadius: nestRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Contexto: \(mail.subject)")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            DashboardAskField(
                text: $draft,
                placeholder: "Pergunte algo sobre seus emails…",
                textColor: theme.ink.nsColor,
                placeholderColor: theme.ink4.nsColor,
                onSubmit: { Task { await run(draft) } },
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
                Task { await run(draft) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSend ? theme.onEnter.color : theme.ink4.color)
                    .frame(width: 28, height: 28)
                    .background(canSend ? theme.enter.color : theme.surface3.color)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: 14, tint: \.onEnter)
            .disabled(!canSend || loading)
            .help("Enter envia. Shift+Enter quebra a linha.")
            .accessibilityLabel("Enviar pergunta")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(
            nestFill.color,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metricTile(_ value: String, caption: String, pigment: TokenColor) -> some View {
        let fill = wash(pigment, amount: theme.isDark ? 0.44 : 0.16)
        let ink = theme.ink.ensuringContrast(against: fill, minimum: 3.0)
        let muted = theme.ink3.ensuringContrast(against: fill, minimum: 2.4)
        return VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(theme.sans.font(size: 22, weight: .semibold))
                .foregroundStyle(ink.color)
                .monospacedDigit()
            Text(caption)
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(muted.color)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            fill.color,
            in: RoundedRectangle(cornerRadius: nestRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(caption)")
    }

    private var robot: some View {
        let fill = wash(theme.info, amount: theme.isDark ? 0.40 : 0.18)
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(fill.color)
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(theme.ink.color).frame(width: 6, height: 6)
                    Circle().fill(theme.ink.color).frame(width: 6, height: 6)
                }
                Capsule()
                    .fill(theme.ink.color.opacity(0.45))
                    .frame(width: 14, height: 3)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    private var betaBadge: some View {
        let fill = wash(theme.info, amount: theme.isDark ? 0.36 : 0.14)
        let ink = theme.info.ensuringContrast(against: fill, minimum: 3.0)
        return Text("Beta")
            .font(theme.sans.font(size: 10, weight: .semibold))
            .foregroundStyle(ink.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(fill.color, in: Capsule())
    }

    // MARK: - Peças

    private func board<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                boardFill.color,
                in: RoundedRectangle(cornerRadius: boardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: boardRadius, style: .continuous)
                    .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
            }
            .shadow(
                color: Color.black.opacity(theme.isDark ? 0.38 : 0.07),
                radius: 18,
                y: 8
            )
    }

    private func sectionHead(
        icon: String,
        iconColor: TokenColor,
        title: String,
        action: String,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor.color)
                .accessibilityHidden(true)
            Text(title)
                .font(theme.sans.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Spacer(minLength: 8)
            Button(action, action: perform)
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 12, weight: .medium))
                .foregroundStyle(theme.link.color)
                .focusRing(cornerRadius: theme.radiusSmall)
        }
    }

    private func footerLink(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .buttonStyle(.plain)
            .font(theme.sans.font(size: 12.5, weight: .medium))
            .foregroundStyle(theme.link.color)
            .focusRing(cornerRadius: theme.radiusSmall)
            .padding(.top, 4)
    }

    private func emptyCopy(_ text: String) -> some View {
        Text(text)
            .font(theme.sans.font(size: 13))
            .foregroundStyle(theme.ink3.color)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var boardRadius: CGFloat { theme.radiusLarge < 1 ? 0 : 20 }
    private var nestRadius: CGFloat { theme.radiusSmall < 1 ? 0 : 14 }

    /// No Okami o `surface` cola no `paper`. O cartão precisa de um degrau
    /// visível — senão o desenho vira um retângulo morto.
    private var boardFill: TokenColor {
        theme.surface.contrastRatio(with: theme.paper) >= 1.18
            ? theme.surface
            : theme.surface3
    }

    private var nestFill: TokenColor {
        boardFill.mixing(with: theme.ink, amount: theme.isDark ? 0.10 : 0.04)
    }

    /// `amount` é quanto pigmento entra no fundo do cartão. No escuro precisa
    /// de ~40% — 12% vira lama cinza.
    private func wash(_ pigment: TokenColor, amount: Double) -> TokenColor {
        boardFill.mixing(with: pigment, amount: amount)
    }

    private func suggestionCopy(_ focus: DashboardFocus) -> String {
        if let mail = selectedMail(focus) ?? focus.mail.first?.message {
            return "Resposta pendente de \(mail.listHeadline): \(mail.subject). Gerar um rascunho?"
        }
        if let item = selectedMeeting(focus) ?? focus.meetings.first {
            return "Próximo: \(item.title) às \(item.startLabel). Preparar o que importa?"
        }
        return "Quando chegar algo que peça você, a sugestão aparece aqui."
    }

    private var askScope: InboxAssistantScope {
        if let id = selectedMailID ?? readingMailID { return .email(id) }
        return .workspace
    }

    private func askScopeTitle(_ focus: DashboardFocus) -> String {
        if let message = selectedMail(focus) { return message.subject }
        if let item = selectedMeeting(focus) { return item.title }
        return "Caixa e agenda de hoje"
    }

    private func askScopeDetail(_ focus: DashboardFocus) -> String {
        if let message = selectedMail(focus) { return message.from.display }
        if let item = selectedMeeting(focus) {
            return "\(DashboardFocus.meetingDayName(offset: item.dayOffset, anchor: today)) · \(item.rangeLabel)"
        }
        return focus.nextUpLabel
    }

    private func selectedMail(_ focus: DashboardFocus) -> Message? {
        guard let id = selectedMailID else { return nil }
        return store.message(id) ?? focus.mail.first { $0.id == id }?.message
    }

    private func selectedMeeting(_ focus: DashboardFocus) -> AgendaItem? {
        guard let id = selectedEventID else { return nil }
        return focus.meetings.first { $0.id == id }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runSuggestion(_ focus: DashboardFocus) async {
        if let mail = selectedMail(focus) ?? focus.mail.first?.message {
            await runDraft(for: mail)
            return
        }
        await run(Self.briefingQuestion)
    }

    private func runDraft(for mail: Message) async {
        selectedMailID = mail.id
        await store.loadBodyIfNeeded(mail.id)
        let followUp = transcript.contains(where: { $0.speaker == .assistant })
        let question = followUp
            ? "Continue a partir do que já combinamos. Revise ou complete o rascunho de resposta para este email, só o corpo, no idioma da mensagem."
            : "Com o email em contexto, escreva um rascunho de resposta pronto para eu revisar. Só o corpo, no idioma da mensagem, curto e direto."
        await run(question)
    }

    private func run(_ raw: String) async {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !loading else { return }
        draft = ""
        transcript.append(.init(speaker: .user, text: question))
        loading = true
        errorMessage = nil
        defer { loading = false }
        if case .email(let id) = askScope {
            await store.loadBodyIfNeeded(id)
        }
        do {
            let focus = store.dashboardFocus(nowMinute: now)
            let history = Array(transcript.suffix(16))
            let request = AssistantRequest(
                context: AssistantContext(subject: askScopeTitle(focus), sender: askScopeDetail(focus)),
                question: question,
                conversation: history
            )
            let answer = try await onAsk(request, askScope)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                errorMessage = "Não foi possível formar uma resposta."
                return
            }
            transcript.append(.init(speaker: .assistant, text: answer))
        } catch is CancellationError {
            return
        } catch {
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = description.isEmpty ? "Não foi possível responder agora." : description
        }
    }

    private func honestPlace(_ item: AgendaItem) -> String? {
        if let place = item.detail?.place,
           !place.isEmpty,
           place != EventPlace.semLocal {
            return place
        }
        if let title = item.calendarTitle, !title.isEmpty { return title }
        return nil
    }

    private func accountTint(_ accountID: String) -> TokenColor {
        guard let account = store.account(accountID) else { return theme.ink3 }
        let hex = theme.isDark ? account.tintDarkHex : account.tintLightHex
        return TokenColor(css: hex) ?? theme.ink3
    }
}
