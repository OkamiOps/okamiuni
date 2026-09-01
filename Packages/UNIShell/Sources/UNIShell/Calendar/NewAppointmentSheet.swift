import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// Editor para criar um compromisso sem sair da Agenda.
///
/// O link da reunião não é uma sala permanente: Meet, Zoom, Teams e Zoho
/// nascem **na hora** de adicionar, com o título deste compromisso. Cole um
/// endereço só quando a sala já existe.
struct NewAppointmentSheet: View {
    static let size = CGSize(width: 540, height: 720)

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(MeetingRoomSettingsStore.self) private var rooms: MeetingRoomSettingsStore?
    @Environment(MeetingRoomFactory.self) private var factory: MeetingRoomFactory?

    let store: MailStore
    let anchor: Date
    let initialDayOffset: Int
    let onClose: () -> Void

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
    @State private var useExistingLink = false
    @State private var recurrence = RecurrenceRule.none
    @State private var creating = false
    @State private var reconnecting = false
    @State private var errorMessage: String?

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
        let end = calendar.date(byAdding: .minute, value: 30, to: start) ?? start

        _day = State(initialValue: calendar.startOfDay(for: selectedDay))
        _startsAt = State(initialValue: start)
        _endsAt = State(initialValue: end)
        _accountID = State(initialValue: store.selectedAccountID ?? store.accounts.first?.id ?? "")
        _title = State(initialValue: initialTitle)
        _meetingLink = State(initialValue: initialMeetingLink)
        _useExistingLink = State(initialValue: !initialMeetingLink.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("Título") {
                        TextField("O que acontece", text: $title)
                            .textFieldStyle(.plain)
                            .font(theme.serif.font(size: 18, weight: .semibold))
                    }

                    labeled("Dia") {
                        AppointmentDatePicker(store: store, anchor: anchor, day: $day)
                            .padding(.vertical, 6)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        labeled("Início") {
                            DatePicker("Início", selection: $startsAt, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                        }
                        labeled("Fim") {
                            DatePicker("Fim", selection: $endsAt, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                        }
                    }

                    recurrenceSection

                    labeled("Conta") {
                        Picker("Conta", selection: $accountID) {
                            ForEach(store.accounts) { account in
                                Text(account.address).tag(account.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    meetingSection

                    labeled("Convidados") {
                        RecipientField(
                            placeholder: "nome ou email, Enter para adicionar",
                            menuWidth: 460,
                            pool: store.contactPool,
                            chips: $guests,
                            typed: $guestDraft,
                            floatsMenu: false
                        )
                        .padding(.vertical, 4)
                    }
                    .zIndex(40)

                    labeled("Local (opcional)") {
                        TextField("Sala, endereço ou online", text: $place)
                            .textFieldStyle(.plain)
                    }

                    labeled("Notas (opcional)") {
                        TextField("Pauta, contexto…", text: $note, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(2...4)
                    }
                }
                .padding(20)
            }

            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(theme.paper.color)
        .onAppear {
            applyDefaultService(for: accountID)
            refreshMeetAccess()
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent.color)
                .frame(width: 34, height: 34)
                .background(theme.accentSoft.color, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("Novo compromisso")
                    .font(theme.sans.font(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text("Uma sala nova a cada reunião — o título e o horário vão com ela.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .bottom)
    }

    private var recurrenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repetir")
                .font(theme.sans.font(size: 11, weight: .medium))
                .foregroundStyle(theme.ink3.color)

            chipRow(RecurrenceRule.Frequency.allCases) { candidate in
                recurrenceChip(candidate)
            }

            if recurrence.repeats {
                if recurrence.frequency == .daily || recurrence.frequency == .weekly
                    || recurrence.frequency == .monthly || recurrence.frequency == .yearly
                {
                    intervalRow
                }
                if recurrence.frequency == .weekly {
                    weekdayRow
                }
                countRow
            }
        }
    }

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("A cada")
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink2.color)
            stepper(value: recurrence.interval, range: 1...30) { recurrence.interval = $0 }
            Text(intervalUnit)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink2.color)
            Spacer(minLength: 0)
        }
    }

    private var intervalUnit: String {
        switch recurrence.frequency {
        case .daily: recurrence.interval == 1 ? "dia" : "dias"
        case .weekly: recurrence.interval == 1 ? "semana" : "semanas"
        case .monthly: recurrence.interval == 1 ? "mês" : "meses"
        case .yearly: recurrence.interval == 1 ? "ano" : "anos"
        default: ""
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 4) {
            ForEach(Self.weekdayOrder, id: \.offset) { item in
                let selected = recurrence.weekdays.contains(item.weekday)
                Button {
                    toggleWeekday(item.weekday)
                } label: {
                    Text(item.label)
                        .font(theme.sans.font(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? theme.onAccent.color : theme.ink3.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(selected ? theme.accent.color : theme.surface3.color, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.accessibility)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private var countRow: some View {
        HStack(spacing: 8) {
            Text("Termina")
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink2.color)
            Button {
                recurrence.count = nil
            } label: {
                Text("Nunca")
                    .font(theme.sans.font(size: 11.5, weight: recurrence.count == nil ? .semibold : .medium))
                    .foregroundStyle(recurrence.count == nil ? theme.ink.color : theme.ink3.color)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(recurrence.count == nil ? theme.surface.color : Color.clear, in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                if recurrence.count == nil { recurrence.count = 10 }
            } label: {
                Text("Após")
                    .font(theme.sans.font(size: 11.5, weight: recurrence.count != nil ? .semibold : .medium))
                    .foregroundStyle(recurrence.count != nil ? theme.ink.color : theme.ink3.color)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(recurrence.count != nil ? theme.surface.color : Color.clear, in: Capsule())
            }
            .buttonStyle(.plain)
            if let count = recurrence.count {
                stepper(value: count, range: 1...365) { recurrence.count = $0 }
                Text(count == 1 ? "vez" : "vezes")
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink2.color)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(theme.surface3.color, in: Capsule())
    }

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reunião")
                .font(theme.sans.font(size: 11, weight: .medium))
                .foregroundStyle(theme.ink3.color)

            chipRow([nil] + MeetingService.allCases.map { Optional($0) }) { candidate in
                serviceChip(candidate)
            }

            if let service {
                VStack(alignment: .leading, spacing: 8) {
                    Text(meetingHint(for: service))
                        .font(theme.sans.font(size: 11))
                        .foregroundStyle(theme.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)

                    if needsMeetReconnect, let gmail = googleAccount {
                        ChromeButton(
                            reconnecting ? "Abrindo o Google…" : "Reconectar o Google",
                            appearance: .outlined,
                            size: 11.5,
                            height: 28,
                            horizontalPadding: 12,
                            action: { reconnectGoogle(gmail) }
                        )
                        .disabled(reconnecting)
                        .accessibilityLabel("Reconectar o Google para criar o Meet")
                    }

                    Button {
                        useExistingLink.toggle()
                        if !useExistingLink { meetingLink = "" }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: useExistingLink ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(useExistingLink ? theme.accent.color : theme.ink3.color)
                            Text("Usar um link existente")
                                .font(theme.sans.font(size: 12))
                                .foregroundStyle(theme.ink2.color)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(useExistingLink ? [.isSelected] : [])

                    if useExistingLink {
                        HStack(spacing: 8) {
                            Image(systemName: service.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.accentInk.color)
                                .frame(width: 18)
                            TextField("https://…", text: $meetingLink)
                                .textFieldStyle(.plain)
                                .font(theme.mono.font(size: 11.5))
                                .foregroundStyle(theme.ink.color)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.accent.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func recurrenceChip(_ candidate: RecurrenceRule.Frequency) -> some View {
        let selected = recurrence.frequency == candidate
        return Button {
            recurrence.frequency = candidate
            if candidate == .none {
                recurrence = .none
            } else if candidate == .weekly {
                recurrence = recurrence.withWeekdayOf(day)
            }
        } label: {
            Text(candidate.shortLabel)
                .font(theme.sans.font(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? theme.ink.color : theme.ink3.color)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    if selected {
                        Capsule().fill(theme.surface.color)
                            .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func serviceChip(_ candidate: MeetingService?) -> some View {
        let selected = service == candidate
        let label = candidate?.shortLabel ?? "Sem"
        return Button {
            service = candidate
            errorMessage = nil
            if candidate == nil {
                meetingLink = ""
                useExistingLink = false
            }
        } label: {
            Text(label)
                .font(theme.sans.font(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? theme.ink.color : theme.ink3.color)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    if selected {
                        Capsule().fill(theme.surface.color)
                            .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate?.label ?? "Sem reunião")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func chipRow<Item: Hashable, Content: View>(
        _ items: [Item], @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
        .padding(3)
        .background(theme.surface3.color)
        .clipShape(Capsule())
    }

    private func stepper(value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Button { set(max(range.lowerBound, value - 1)) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            Text("\(value)")
                .font(theme.mono.font(size: 12))
                .foregroundStyle(theme.ink.color)
                .frame(minWidth: 18)
            Button { set(min(range.upperBound, value + 1)) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(theme.ink2.color)
        .background(theme.surface.color, in: Capsule())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            ChromeButton("Cancelar", appearance: .outlined, action: onClose)
                .keyboardShortcut(.cancelAction)
            ChromeButton(
                creating ? "Criando…" : "Adicionar",
                appearance: canCreate ? .accent : .muted,
                action: create
            )
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .top)
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(theme.sans.font(size: 11, weight: .medium))
                .foregroundStyle(theme.ink3.color)
            content()
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
                }
        }
    }

    private var trimmedMeetingLink: String {
        meetingLink.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedMeetingLink: String? {
        MeetingLink.normalizado(trimmedMeetingLink)
    }

    private var meetingLinkIsInvalid: Bool {
        useExistingLink && !trimmedMeetingLink.isEmpty && normalizedMeetingLink == nil
    }

    private func meetingHint(for service: MeetingService) -> String {
        if meetingLinkIsInvalid {
            return "Use um link que comece com http:// ou https://."
        }
        if useExistingLink {
            return "O endereço colado entra neste compromisso só. Não vira sala permanente."
        }
        if service == .meet {
            if googleAccount == nil {
                return "Conecte uma conta Google em Contas para criar o Meet automaticamente, ou cole um link existente."
            }
            if factory?.hasMeetAccess(accountID: googleAccount?.id ?? "") == false {
                return "O Google precisa autorizar o Calendar nesta caixa (é assim que o Meet nasce no Gmail). Reconecte uma vez."
            }
            return "Uma sala nova de Google Meet será criada ao adicionar. Título e horário vão com ela."
        }
        if let account = store.account(accountID),
           let factory, factory.canMint(service, account: account, accounts: store.accounts)
        {
            return "Uma sala nova de \(service.label) será criada ao adicionar. Título e horário vão com ela."
        }
        return "Conecte o \(service.label) em Ajustes → Agenda para criar a sala automaticamente, ou cole um link existente."
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

    private var canCreate: Bool {
        !creating
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accountID.isEmpty
            && minutes(endsAt) > minutes(startsAt)
            && !meetingLinkIsInvalid
    }

    private func applyDefaultService(for accountID: String) {
        guard let rooms else { return }
        service = rooms.profile(for: accountID).defaultService
    }

    private func commitTypedGuest() {
        let raw = guestDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let resolved = ContactDirectory.resolve(typed: raw, in: store.contactPool)
        else { return }
        let contact = resolved.contact
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
            calendarUID: googleEventID
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

    private func toggleWeekday(_ weekday: Int) {
        var days = Set(recurrence.weekdays)
        if days.contains(weekday) {
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        if days.isEmpty { days.insert(weekday) }
        recurrence.weekdays = days.sorted()
    }

    private static let weekdayOrder: [(weekday: Int, label: String, accessibility: String, offset: Int)] = [
        (2, "seg", "segunda", 0),
        (3, "ter", "terça", 1),
        (4, "qua", "quarta", 2),
        (5, "qui", "quinta", 3),
        (6, "sex", "sexta", 4),
        (7, "sáb", "sábado", 5),
        (1, "dom", "domingo", 6),
    ]
}
