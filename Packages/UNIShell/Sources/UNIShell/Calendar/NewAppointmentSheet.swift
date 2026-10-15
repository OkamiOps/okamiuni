import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// Criar um compromisso sem sair de onde se está — **uma frase primeiro**.
///
/// ## O desenho, e o que ele muda
///
/// Protótipo: `ModalAgenda.dc.html`, bloco "NOVO COMPROMISSO". A folha tem 620
/// de largura e pende do topo da janela (`top: 56px`), com o app visível
/// atrás. Ela abre com **uma linha de texto**: quem escreve "amanhã 15h com a
/// Marina sobre a proposta" vê logo abaixo um cartão "ENTENDI ASSIM" que cita
/// de onde cada pedaço saiu, aperta ⏎ e o compromisso existe. `Tab` abre os
/// campos para ajustar.
///
/// O editor antigo era o contrário: dez campos rotulados, e a frase não
/// existia. Ele continua inteiro aqui dentro — repetir, convidados, local,
/// notas, conta, reunião —, só deixou de ser a porta de entrada e passou a ler
/// como frase ("Repetir · não repete · toda semana?") em vez de formulário.
///
/// ## A frase não é IA
///
/// `AppointmentPhrase` lê a linha com `NSDataDetector` e um punhado de regras
/// de português, na máquina, sem rede. Ver a nota longa lá: fingir IA aqui
/// custaria determinismo, deixaria o cartão de explicação sem o que citar e
/// faria uma conta de modelo ser requisito para marcar uma reunião. Quando a
/// frase não diz nada reconhecível, a folha abre os campos — e é tudo.
struct NewAppointmentSheet: View {
    /// A largura do protótipo. A altura é do conteúdo: a folha com a frase é
    /// bem mais curta que a folha com os seis campos abertos, e travar as duas
    /// na mesma altura deixaria um buraco numa delas.
    static let width: CGFloat = Theme.ModalWidth.appointment

    /// A tela em que o harness fora de tela desenha a folha. Não é medida do
    /// desenho: é o tamanho do papel onde ela é fotografada.
    static let size = CGSize(width: width, height: 760)

    /// Em que estado a folha está.
    enum Mode {
        /// A linha de texto e o cartão "ENTENDI ASSIM".
        case phrase
        /// Os campos abertos, lidos como frases.
        case fields
    }

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(MeetingRoomSettingsStore.self) private var rooms: MeetingRoomSettingsStore?
    @Environment(MeetingRoomFactory.self) private var factory: MeetingRoomFactory?
    /// Os padrões de Configurações ▸ Agendas. Eles chegam **aqui**, e não no
    /// `init`: o `init` roda antes do ambiente existir, e o padrão de duração
    /// precisa valer já no primeiro quadro — por isso `applyDefaults()` no
    /// `onAppear` ajusta o fim e a agenda, e o `init` continua com a hora
    /// cheia de sempre.
    @Environment(CalendarPreferences.self) private var preferences: CalendarPreferences?

    let store: MailStore
    let anchor: Date
    let initialDayOffset: Int
    let onClose: () -> Void

    @State private var mode: Mode
    @State private var phrase = ""
    @State private var title = ""
    @State private var day: Date
    @State private var startsAt: Date
    @State private var endsAt: Date
    @State private var accountID: String
    @State private var place = ""
    @State private var meetingLink: String
    @State private var note = ""
    @State private var guests: [Contact] = []
    @State private var guestDraft = ""
    @State private var service: MeetingService?
    /// O calendário em que o compromisso nasce, vindo da preferência.
    @State private var calendarID: String?
    @State private var useExistingLink = false
    @State private var recurrence = RecurrenceRule.none
    @State private var creating = false
    @State private var reconnecting = false
    @State private var errorMessage: String?
    @FocusState private var phraseFocused: Bool
    @FocusState private var guestFieldFocused: Bool
    @State private var hoveringGuestMenu = false
    /// Ver o `init` com `debugGuestQuery`.
    @State private var seededGuestMenu = false

    /// A folha com um nome já digitado no campo de convidados e a lista de
    /// sugestões aberta. **Só para verificação fora da tela**: o harness não
    /// digita nem foca, e é a mesma porta que `RecipientField.seededQuery`
    /// abre no composer.
    init(
        store: MailStore, anchor: Date, initialDayOffset: Int,
        initialTitle: String = "", debugGuestQuery: String,
        onClose: @escaping () -> Void
    ) {
        self.init(
            store: store, anchor: anchor, initialDayOffset: initialDayOffset,
            initialTitle: initialTitle, onClose: onClose
        )
        _guestDraft = State(initialValue: debugGuestQuery)
        _seededGuestMenu = State(initialValue: true)
    }

    /// A folha com a frase **já escrita**.
    ///
    /// Dois donos. O harness de renderização, que não digita e sem este
    /// caminho jamais fotografaria o estado do desenho (a frase e o cartão
    /// "Entendi assim"). E o "Ajustar" do cartão de evento do leitor: a IA
    /// achou a frase, o `AppointmentPhrase` leu a data dela, e quem ajusta é
    /// este editor — não um segundo editor de evento escrito só para o leitor.
    init(
        store: MailStore, anchor: Date, initialDayOffset: Int,
        initialPhrase: String, onClose: @escaping () -> Void
    ) {
        self.init(
            store: store, anchor: anchor, initialDayOffset: initialDayOffset, onClose: onClose
        )
        _phrase = State(initialValue: initialPhrase)
    }

    init(
        store: MailStore,
        anchor: Date,
        initialDayOffset: Int,
        initialTitle: String = "",
        initialMeetingLink: String = "",
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.anchor = anchor
        self.initialDayOffset = initialDayOffset
        self.onClose = onClose

        let calendar = Calendar.current
        let selectedDay = calendar.date(
            byAdding: .day, value: initialDayOffset, to: anchor
        ) ?? anchor
        let roundedHour = max(8, min(21, calendar.component(.hour, from: Date()) + 1))
        let start = calendar.date(
            bySettingHour: roundedHour, minute: 0, second: 0, of: selectedDay
        ) ?? selectedDay
        let end = calendar.date(byAdding: .minute, value: 60, to: start) ?? start

        _day = State(initialValue: calendar.startOfDay(for: selectedDay))
        _startsAt = State(initialValue: start)
        _endsAt = State(initialValue: end)
        _accountID = State(initialValue: store.selectedAccountID ?? store.accounts.first?.id ?? "")
        _title = State(initialValue: initialTitle)
        _meetingLink = State(initialValue: initialMeetingLink)
        _useExistingLink = State(initialValue: !initialMeetingLink.isEmpty)
        // Quem chega com título já tem a decisão tomada — a folha de "ajustar"
        // do Painel do dia é assim. Quem chega vazio começa pela frase.
        _mode = State(initialValue: initialTitle.isEmpty ? .phrase : .fields)
    }

    // MARK: - A leitura da frase

    private var parsed: AppointmentPhrase {
        AppointmentPhrase.interpret(phrase, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            entry
            dayStrip
            if mode == .fields { fields }
            footer
        }
        .frame(width: Self.width)
        .modalSurface()
        // O cartão de sugestões sai da folha por desenho — sem isto ele é
        // recortado pelo `clipShape` da moldura e some justamente quando a
        // pessoa está digitando um nome.
        .zIndex(10)
        .onAppear {
            applyDefaults()
            applyDefaultService(for: accountID)
            refreshMeetAccess()
            phraseFocused = mode == .phrase
        }
        .onChange(of: accountID) { _, id in
            applyDefaultService(for: id)
            refreshMeetAccess()
        }
        .onChange(of: service) { _, _ in refreshMeetAccess() }
        .onChange(of: day) { _, newDay in
            startsAt = combining(newDay, startsAt)
            endsAt = combining(newDay, endsAt)
            if recurrence.frequency == .weekly, recurrence.weekdays.isEmpty {
                recurrence = recurrence.withWeekdayOf(newDay)
            }
        }
        .onChange(of: recurrence.frequency) { _, frequency in
            if frequency == .weekly, recurrence.weekdays.isEmpty {
                recurrence = recurrence.withWeekdayOf(day)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Novo compromisso"))
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - A porta de entrada
    //
    // Protótipo: `padding: 24px 28px 0; gap: 14px`.

    @ViewBuilder
    private var entry: some View {
        VStack(alignment: .leading, spacing: 14) {
            if mode == .phrase {
                phraseField
                if parsed.understood { understanding }
            } else {
                titleField
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
        .padding(.horizontal, Theme.modalSide)
    }

    /// A linha de texto: ícone de 18, corpo 17 em medium, "⏎ cria" em mono à
    /// direita, campo em foco com a borda de 1,5 e o anel de 4.
    private var phraseField: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.accentInk.color)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            TextField(L10n.tr("Descreva o compromisso"), text: $phrase)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 17, weight: .medium))
                .foregroundStyle(theme.ink.color)
                .focused($phraseFocused)
                .accessibilityLabel(L10n.tr("Descreva o compromisso"))
                .onSubmit(createFromPhrase)
                // `Tab` abre os campos — a segunda metade da promessa do
                // rodapé. Sem isto a frase seria um beco: ou ela acerta, ou a
                // pessoa fecha a folha e começa de novo.
                .onKeyPress(.tab) {
                    openFields()
                    return .handled
                }
            Text(L10n.tr("⏎ cria"))
                .font(theme.mono.font(size: 11))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .modalFieldBox(focused: true, verticalPadding: 14, horizontalPadding: 16)
    }

    /// `ENTENDI ASSIM` — o cartão que cita a frase de volta.
    ///
    /// Protótipo: fundo `accentSoft`, raio 12, `padding: 14px 16px`, rótulo de
    /// 12 em semibold no acento, linhas de 14,5 com `line-height: 1.5` e um
    /// ponto de 7 à esquerda.
    private var understanding: some View {
        let lida = parsed
        return VStack(alignment: .leading, spacing: 10) {
            ModalEyebrow(text: L10n.tr("Entendi assim"), accented: true)
            VStack(alignment: .leading, spacing: 8) {
                if let start = lida.start, let end = lida.end {
                    understandingRow(
                        strong: "\(DateLabels.eventDate(start)) · \(MinuteFormat.range(minutes(start), minutes(end)))",
                        faint: lida.dateSource.map { L10n.tr("— de “\($0)”") }
                    )
                }
                ForEach(resolvedGuests(lida), id: \.id) { contact in
                    understandingRow(
                        strong: contact.name,
                        faint: L10n.tr("convidada — \(contact.address)")
                    )
                }
                understandingRow(
                    prefix: L10n.tr("Título:"),
                    strong: lida.title.isEmpty ? L10n.tr("Sem título") : lida.title,
                    faint: durationAndMeetingNote(lida)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            theme.accentSoft.color,
            in: RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
        )
    }

    private func understandingRow(
        prefix: String? = nil, strong: String, faint: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ModalBullet()
            Text(understandingText(prefix: prefix, strong: strong, faint: faint))
                .font(theme.sans.font(size: 14.5))
                .lineSpacing(0.5 * 14.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Um `Text` só, com três pesos e duas cores: dois `Text` somados viram
    /// depreciação no macOS 26, e três `Text` lado a lado não quebram linha
    /// juntos.
    private func understandingText(
        prefix: String?, strong: String, faint: String?
    ) -> AttributedString {
        var line = AttributedString("")
        if let prefix {
            var head = AttributedString(prefix + " ")
            head.foregroundColor = theme.ink.color
            line.append(head)
        }
        var body = AttributedString(strong)
        body.foregroundColor = theme.ink.color
        body.font = theme.sans.font(size: 14.5, weight: .semibold)
        line.append(body)
        if let faint {
            var tail = AttributedString(" " + faint)
            tail.foregroundColor = theme.ink3.color
            line.append(tail)
        }
        return line
    }

    private func durationAndMeetingNote(_ lida: AppointmentPhrase) -> String {
        let minutos = lida.duration ?? 60
        let duracao = minutos % 60 == 0
            ? (minutos == 60 ? L10n.tr("1 hora") : L10n.tr("\(minutos / 60) horas"))
            : L10n.tr("\(minutos) minutos")
        guard let service, !useExistingLink else { return "· \(duracao)" }
        return "· \(duracao), \(service.label) \(L10n.tr("criado junto"))"
    }

    /// Os nomes da frase resolvidos contra a agenda de contatos **real**. Um
    /// nome que não existe na agenda não vira convidado inventado: ele fica de
    /// fora, e o cartão não o cita.
    private func resolvedGuests(_ lida: AppointmentPhrase) -> [Contact] {
        lida.guestNames.compactMap { name in
            ContactDirectory.resolve(typed: name, in: store.contactPool)
                .map { Contact(name: $0.name, address: $0.address) }
        }
    }

    /// O título como campo, no estado aberto: 24 em bold com `-0.02em`, e
    /// embaixo a linha do quando e com quem em 13,5 `ink3`.
    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L10n.tr("O que acontece"), text: $title)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 24, weight: .bold))
                .tracking(theme.modalTitleTracking(at: 24))
                .foregroundStyle(theme.ink.color)
                .accessibilityLabel(L10n.tr("Título do compromisso"))
            Text(whenLine)
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(theme.ink3.color)
        }
    }

    private var whenLine: String {
        var parts = [
            DateLabels.eventDate(day),
            MinuteFormat.range(minutes(startsAt), minutes(endsAt)),
        ]
        if let first = guests.first {
            parts.append(
                guests.count == 1
                    ? L10n.tr("com \(first.name)")
                    : L10n.tr("com \(first.name) e mais \(guests.count - 1)")
            )
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - O dia escolhido
    //
    // Protótipo: `padding: 18px 28px 0`.

    private var dayStrip: some View {
        DayFreeBusyStrip(
            store: store,
            dayOffset: dayOffsetOfSelection,
            // O dia **da proposta**, e não o do campo: enquanto a frase é a
            // porta de entrada, quem manda é o que ela disse. Com `day` aqui,
            // o rótulo dizia "terça 25" e a faixa tracejada caía na quinta.
            day: Calendar.current.startOfDay(for: effectiveStart),
            startMinute: minutes(effectiveStart),
            endMinute: minutes(effectiveEnd)
        )
        .padding(.top, 18)
        .padding(.horizontal, Theme.modalSide)
    }

    /// O início que a trilha mostra: o da frase enquanto ela é a porta de
    /// entrada, o dos campos depois. Senão a trilha desenharia uma coisa e o
    /// botão criaria outra.
    private var effectiveStart: Date {
        mode == .phrase ? (parsed.start ?? startsAt) : startsAt
    }

    private var effectiveEnd: Date {
        mode == .phrase ? (parsed.end ?? endsAt) : endsAt
    }

    private var dayOffsetOfSelection: Int {
        let calendar = Calendar.current
        let base = mode == .phrase ? (parsed.start ?? day) : day
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: anchor), to: calendar.startOfDay(for: base)
        ).day ?? initialDayOffset
    }

    // MARK: - Os campos, lidos como frases
    //
    // Protótipo: `padding: 10px 28px 2px`, cada linha numa grade de
    // `26px 104px 1fr auto` com `padding: 11px 0` e uma linha de um pixel em
    // cima. O rótulo em `ink3`, o valor em `ink`, a ação no acento.

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            repeatRow
            accountRow
            meetingRow
            guestsRow
            placeRow
            noteRow
        }
        .padding(.top, 10)
        .padding(.horizontal, Theme.modalSide)
        .padding(.bottom, 2)
    }

    /// A moldura de uma linha. `leading` é o que vai na coluna do valor —
    /// marcador de cor, avatar — e vem antes do texto.
    private func sentenceRow<Value: View, Leading: View>(
        icon: String,
        label: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 26, alignment: .leading)
                .accessibilityHidden(true)
            Text(label)
                .font(theme.sans.font(size: 14))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 104, alignment: .leading)
            HStack(spacing: 8) {
                leading()
                value()
            }
            .font(theme.sans.font(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(theme.sans.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.accentInk.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.modalButtonRadius)
            }
        }
        .padding(.vertical, 11)
        .hairline(theme.modalLine, edges: .top)
    }

    private var repeatRow: some View {
        sentenceRow(
            icon: "repeat",
            label: L10n.tr("Repetir"),
            actionTitle: recurrence.repeats ? L10n.tr("não repetir") : L10n.tr("toda semana?"),
            // Um clique, dois destinos: a sugestão do desenho ("toda semana?")
            // e a volta. Repetições mais exóticas continuam possíveis pela
            // janela do compromisso, que é onde elas cabem.
            action: { recurrence = recurrence.repeats ? .none : weeklyOnTheSelectedDay }
        ) {
            Text(
                recurrence.repeats
                    ? recurrence.label
                    : L10n.tr("não repete")
            )
            .foregroundStyle((recurrence.repeats ? theme.ink : theme.ink2).color)
            .lineLimit(1)
        }
    }

    private var weeklyOnTheSelectedDay: RecurrenceRule {
        var rule = RecurrenceRule.none
        rule.frequency = .weekly
        return rule.withWeekdayOf(day)
    }

    private var accountRow: some View {
        let manyAccounts = store.accounts.count > 1
        let troca: (() -> Void)? = manyAccounts ? { cycleAccount() } : nil
        return sentenceRow(
            icon: "calendar",
            label: L10n.tr("Agenda"),
            actionTitle: manyAccounts ? L10n.tr("trocar") : nil,
            action: troca,
            leading: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accountTint.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        ) {
            Text(store.account(accountID)?.address ?? L10n.tr("sem conta"))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var accountTint: TokenColor {
        guard let account = store.account(accountID),
              let token = TokenColor(css: account.tint(isDark: theme.isDark))
        else { return theme.accent }
        return token
    }

    @ViewBuilder
    private var meetingRow: some View {
        sentenceRow(
            icon: "video",
            label: L10n.tr("Reunião"),
            actionTitle: L10n.tr("trocar"),
            action: cycleService,
            leading: {
                if service != nil {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.modalGreen.color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
        ) {
            Text(meetingValue)
                .foregroundStyle((service == nil ? theme.ink2 : theme.ink).color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // O que o desenho não mostra porque não cabe numa linha, e que a folha
        // perde se sair: colar um endereço existente, e o aviso de reconectar
        // o Google quando o Meet não pode nascer. Entram como continuação da
        // linha de cima, com o recuo da coluna do valor.
        if service != nil {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    useExistingLink.toggle()
                    if !useExistingLink { meetingLink = "" }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: useExistingLink ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle((useExistingLink ? theme.accent : theme.ink3).color)
                        Text(L10n.tr("Usar um link existente"))
                            .font(theme.sans.font(size: 12.5))
                            .foregroundStyle(theme.ink2.color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(useExistingLink ? [.isSelected] : [])

                if useExistingLink {
                    TextField("https://…", text: $meetingLink)
                        .textFieldStyle(.plain)
                        .font(theme.mono.font(size: 12.5))
                        .foregroundStyle(theme.ink.color)
                        .modalFieldBox(verticalPadding: 9, horizontalPadding: 12)
                }

                if needsMeetReconnect, let gmail = googleAccount {
                    Button { reconnectGoogle(gmail) } label: {
                        Text(reconnecting
                            ? L10n.tr("Abrindo o Google…")
                            : L10n.tr("Reconectar o Google para criar o Meet"))
                            .font(theme.sans.font(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.accentInk.color)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(reconnecting)
                }
            }
            .padding(.leading, 26 + 104)
            .padding(.bottom, 11)
        }
    }

    private var meetingValue: String {
        if useExistingLink {
            return meetingLink.isEmpty ? L10n.tr("link colado") : meetingLink
        }
        guard let service else { return L10n.tr("sem reunião") }
        return L10n.tr("\(service.label) — criado ao salvar")
    }

    private var guestsRow: some View {
        sentenceRow(
            icon: "person",
            label: L10n.tr("Convidados"),
            leading: {
                if let first = guests.first {
                    Text(first.initials)
                        .font(theme.sans.font(size: 10, weight: .semibold))
                        .foregroundStyle(theme.onAccent.color)
                        .frame(width: 22, height: 22)
                        .background(guestTint, in: Circle())
                        .accessibilityHidden(true)
                }
            }
        ) {
            HStack(spacing: 8) {
                if !guests.isEmpty {
                    Text(guests.map(\.name).joined(separator: ", "))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                        .foregroundStyle(theme.ink3.color)
                }
                TextField(L10n.tr("+ nome ou e-mail"), text: $guestDraft)
                    .textFieldStyle(.plain)
                    .font(theme.sans.font(size: 14))
                    .foregroundStyle(theme.ink.color)
                    .focused($guestFieldFocused)
                    .onSubmit(commitTypedGuest)
                    .accessibilityLabel(L10n.tr("Convidar por nome ou e-mail"))
            }
        }
        // A lista de sugestões nasce **da linha**, por cima do que vem
        // embaixo: o desenho mantém o campo com cara de uma linha de texto, e
        // a agenda de contatos não pode sumir por causa disso. Mesmo cartão do
        // composer (`ContactSuggestionsCard`), opaco e elevado.
        .overlay(alignment: .bottomLeading) {
            if !guestSuggestions.isEmpty,
               guestFieldFocused || hoveringGuestMenu || seededGuestMenu {
                // Uma âncora de altura zero no pé da linha, e o cartão
                // pendurado no topo dela: assim ele cai **abaixo** da linha em
                // vez de a cobrir. Com o cartão preso direto ao
                // `bottomLeading` ele subia a própria altura e escondia o
                // campo que a pessoa está digitando.
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .topLeading) {
                        ContactSuggestionsCard(
                            query: guestDraft,
                            suggestions: guestSuggestions,
                            width: 320,
                            pick: addGuest
                        )
                        .onHover { hoveringGuestMenu = $0 }
                    }
                    .offset(x: 26 + 104, y: 6)
                    .zIndex(50)
            }
        }
        .zIndex(50)
    }

    /// Os contatos que casam com o que está sendo digitado, tirando quem já
    /// está convidado. Mesma regra do campo de destinatários do composer.
    private var guestSuggestions: [DirectoryContact] {
        ContactDirectory.suggestions(
            matching: guestDraft, excluding: guests, in: store.contactPool
        )
    }

    private func addGuest(_ suggestion: DirectoryContact) {
        guard !guests.contains(where: { $0.id == suggestion.contact.id }) else { return }
        guests.append(suggestion.contact)
        guestDraft = ""
    }

    /// O azul do protótipo (`#0ea5e9`) — aqui o `liveMeeting` do tema, que é
    /// o mesmo azul e já vira com os 28. Não há paleta por pessoa nesta base,
    /// e inventar uma só para este avatar seria uma cor nova no app.
    private var guestTint: Color { theme.liveMeeting.color }

    private var placeRow: some View {
        sentenceRow(icon: "mappin.and.ellipse", label: L10n.tr("Local")) {
            TextField(
                service == nil ? L10n.tr("Sala ou endereço") : L10n.tr("Online"),
                text: $place
            )
            .textFieldStyle(.plain)
            .font(theme.sans.font(size: 14))
            .foregroundStyle(theme.ink.color)
            .accessibilityLabel(L10n.tr("Local"))
        }
    }

    private var noteRow: some View {
        sentenceRow(icon: "text.alignleft", label: L10n.tr("Notas")) {
            TextField(L10n.tr("Pauta, contexto…"), text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 14))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1...3)
                .accessibilityLabel(L10n.tr("Notas"))
        }
    }

    // MARK: - O rodapé
    //
    // Protótipo: `margin-top: 14px`, a linha, `padding: 16px 28px 20px`, a
    // frase de contexto à esquerda e as duas ações.

    private var footer: some View {
        ModalFooter(context: footerContext, onCancel: onClose) {
            ModalPrimaryButton(
                title: primaryTitle,
                enabled: canCreate,
                action: mode == .phrase ? createFromPhrase : create
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("new-appointment-primary")
        }
        .padding(.top, 14)
    }

    private var footerContext: String {
        if mode == .phrase {
            return L10n.tr("Enter cria do jeito que está. Tab abre os campos para ajustar.")
        }
        if let first = guests.first {
            return L10n.tr("O convite sai para \(first.name) quando você adicionar.")
        }
        return L10n.tr("Nada sai por e-mail enquanto não houver convidado.")
    }

    private var primaryTitle: String {
        if creating { return L10n.tr("Criando…") }
        return mode == .phrase ? L10n.tr("Criar assim") : L10n.tr("Adicionar")
    }

    // MARK: - Da frase para os campos

    /// `Tab`: passa o que a frase disse para os campos e abre todos eles.
    private func openFields() {
        apply(parsed)
        mode = .fields
        phraseFocused = false
    }

    private func apply(_ lida: AppointmentPhrase) {
        if !lida.title.isEmpty { title = lida.title }
        if let start = lida.start {
            let calendar = Calendar.current
            day = calendar.startOfDay(for: start)
            startsAt = start
            endsAt = lida.end ?? (calendar.date(byAdding: .minute, value: 60, to: start) ?? start)
        }
        for contact in resolvedGuests(lida) where !guests.contains(where: { $0.id == contact.id }) {
            guests.append(contact)
        }
    }

    /// ⏎ na linha de texto: aplica e cria, num passo.
    private func createFromPhrase() {
        apply(parsed)
        guard canCreateFromPhrase else {
            // Nada reconhecido: a folha abre os campos em vez de criar um
            // compromisso sem hora. É o que o brief pede — e é melhor do que
            // um botão que não responde.
            mode = .fields
            phraseFocused = false
            return
        }
        create()
    }

    private var canCreateFromPhrase: Bool {
        parsed.start != nil && !parsed.title.isEmpty
    }

    // MARK: - O resto, que já existia

    private var trimmedMeetingLink: String {
        meetingLink.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedMeetingLink: String? {
        MeetingLink.normalizado(trimmedMeetingLink)
    }

    private var meetingLinkIsInvalid: Bool {
        useExistingLink && !trimmedMeetingLink.isEmpty && normalizedMeetingLink == nil
    }

    private var needsMeetReconnect: Bool {
        guard service == .meet, !useExistingLink, let gmail = googleAccount, factory != nil else {
            return false
        }
        return factory?.hasMeetAccess(accountID: gmail.id) == false
    }

    private func refreshMeetAccess() {
        guard service == .meet, let gmail = googleAccount else { return }
        Task { await factory?.refreshMeetAccess(accountID: gmail.id) }
    }

    private var googleAccount: Account? {
        guard let account = store.account(accountID) else {
            return store.accounts.first { $0.provider == .gmail }
        }
        return MeetingGoogleAccount.resolve(for: account, among: store.accounts)
    }

    private func reconnectGoogle(_ gmail: Account) {
        guard let factory, !reconnecting else { return }
        reconnecting = true
        errorMessage = nil
        Task { @MainActor in
            defer { reconnecting = false }
            do {
                try await factory.reconnectGoogle(accountID: gmail.id, loginHint: gmail.address)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cycleAccount() {
        guard let index = store.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accountID = store.accounts[(index + 1) % store.accounts.count].id
    }

    /// "trocar" passa pela lista inteira, e `nil` ("sem reunião") faz parte
    /// dela: é como o desenho oferece as quatro opções do brief numa linha só.
    private func cycleService() {
        let order: [MeetingService?] = [nil] + MeetingService.allCases.map { Optional($0) }
        let index = order.firstIndex(of: service) ?? 0
        service = order[(index + 1) % order.count]
        errorMessage = nil
        if service == nil {
            meetingLink = ""
            useExistingLink = false
        }
    }

    private var canCreate: Bool {
        if mode == .phrase { return !creating && !phrase.trimmingCharacters(in: .whitespaces).isEmpty }
        return !creating
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accountID.isEmpty
            && minutes(endsAt) > minutes(startsAt)
            && !meetingLinkIsInvalid
    }

    /// A duração e a agenda padrão, antes de a pessoa tocar em qualquer
    /// coisa. Quem já veio com título e hora do leitor ("ajustar") mantém o
    /// que trouxe — o padrão é para um compromisso que nasce vazio.
    private func applyDefaults() {
        guard let preferences else { return }
        let defaults = preferences.newAppointment(startingAt: startsAt)
        if mode == .phrase { endsAt = defaults.end }
        if calendarID == nil { calendarID = defaults.calendarID }
    }

    /// A sala padrão é **global** agora (`CalendarPreferences.defaultRoom`).
    /// O perfil por conta continua sendo lido só quando a global está vazia,
    /// para ninguém perder a escolha antiga antes da migração rodar.
    private func applyDefaultService(for accountID: String) {
        if let preferences, let global = preferences.defaultRoom {
            service = global
            return
        }
        guard let rooms else { return }
        service = rooms.profile(for: accountID).defaultService
    }

    private func commitTypedGuest() {
        let raw = guestDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let resolved = ContactDirectory.resolve(typed: raw, in: store.contactPool)
        else { return }
        let contact = Contact(name: resolved.name, address: resolved.address)
        if !guests.contains(where: { $0.id == contact.id }) {
            guests.append(contact)
        }
        guestDraft = ""
    }

    private func create() {
        guard canCreate else { return }
        commitTypedGuest()
        errorMessage = nil
        if let service, !useExistingLink {
            creating = true
            Task { await createAsync(service: service) }
            return
        }
        finish(
            link: useExistingLink ? trimmedMeetingLink : "",
            hostedOnGoogle: false
        )
    }

    @MainActor
    private func createAsync(service: MeetingService) async {
        defer { creating = false }
        guard let minted = await mint(service) else { return }
        finish(
            link: minted.link,
            hostedOnGoogle: service == .meet,
            googleEventID: minted.googleEventID
        )
    }

    private func finish(
        link: String, hostedOnGoogle: Bool = false, googleEventID: String? = nil
    ) {
        let calendar = Calendar.current
        let offset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: anchor),
            to: calendar.startOfDay(for: day)
        ).day ?? initialDayOffset
        let rule = recurrence.frequency == .weekly
            ? recurrence.withWeekdayOf(day)
            : recurrence
        guard store.addManualAgendaItem(
            title: title,
            startMinute: minutes(startsAt),
            endMinute: minutes(endsAt),
            dayOffset: offset,
            accountID: accountID,
            place: place,
            meetingLink: link,
            note: note,
            recurrence: rule,
            guests: guests,
            syncToSystemCalendar: !hostedOnGoogle,
            sendInvites: !hostedOnGoogle,
            calendarUID: googleEventID,
            calendarID: calendarID,
            alert: preferences?.alert ?? .none
        ) != nil else { return }
        onClose()
    }

    private func mint(_ service: MeetingService) async -> MeetingMint? {
        guard let account = store.account(accountID) else {
            errorMessage = MeetingRoomError.needsGoogle.errorDescription
            return nil
        }
        guard let factory else {
            // Ensaios e testes: sem fábrica, o compromisso nasce sem sala.
            return MeetingMint(link: "")
        }
        let oauthID = service == .meet
            ? (MeetingGoogleAccount.resolve(for: account, among: store.accounts)?.id ?? account.id)
            : account.id
        guard factory.canMint(service, account: account, accounts: store.accounts) else {
            errorMessage = (service == .meet
                ? MeetingRoomError.needsGoogle
                : MeetingRoomError.notConnected(service)).errorDescription
            return nil
        }
        do {
            let rule = recurrence.frequency == .weekly
                ? recurrence.withWeekdayOf(day) : recurrence
            return try await factory.mint(
                MeetingRoomRequest(
                    service: service, account: account,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: startsAt, end: endsAt,
                    oauthAccountID: oauthID,
                    attendees: guests,
                    rrule: rule.rfc5545
                )
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func combining(_ day: Date, _ time: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(
            bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: day
        ) ?? time
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
