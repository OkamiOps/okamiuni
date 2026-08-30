import SwiftUI
import UNICore
import UNIDesign

/// Editor curto para criar um compromisso sem sair da Agenda.
struct NewAppointmentSheet: View {
    @Environment(\.theme) private var theme

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

        _day = State(initialValue: selectedDay)
        _startsAt = State(initialValue: start)
        _endsAt = State(initialValue: end)
        _accountID = State(initialValue: store.selectedAccountID ?? store.accounts.first?.id ?? "")
        _title = State(initialValue: initialTitle)
        _meetingLink = State(initialValue: initialMeetingLink)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Novo compromisso")
                        .font(theme.sans.font(size: 16, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                    Text("Será salvo no calendário padrão deste Mac e associado à conta escolhida.")
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.ink3.color)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(theme.surface2.color)

            Form {
                TextField("Título", text: $title)
                DatePicker("Data", selection: $day, displayedComponents: .date)
                HStack {
                    DatePicker("Início", selection: $startsAt, displayedComponents: .hourAndMinute)
                    DatePicker("Fim", selection: $endsAt, displayedComponents: .hourAndMinute)
                }
                Picker("Conta", selection: $accountID) {
                    ForEach(store.accounts) { account in
                        Text(account.address).tag(account.id)
                    }
                }
                TextField("Local (opcional)", text: $place)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Link da reunião (opcional)", text: $meetingLink)
                    Text(meetingLinkHint)
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(meetingLinkIsInvalid ? theme.accent.color : theme.ink3.color)
                }
                TextField("Notas (opcional)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancelar", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Adicionar") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(16)
            .background(theme.surface2.color)
        }
        .frame(width: 470, height: 470)
        .background(theme.paper.color)
    }

    private var trimmedMeetingLink: String {
        meetingLink.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedMeetingLink: String? {
        MeetingLink.normalizado(trimmedMeetingLink)
    }

    private var meetingLinkIsInvalid: Bool {
        !trimmedMeetingLink.isEmpty && normalizedMeetingLink == nil
    }

    private var meetingLinkHint: String {
        meetingLinkIsInvalid
            ? "Use um link que comece com http:// ou https://."
            : "Meet, Zoom, Webex, Teams ou outro link web."
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accountID.isEmpty
            && minutes(endsAt) > minutes(startsAt)
            && !meetingLinkIsInvalid
    }

    private func create() {
        guard canCreate else { return }
        let calendar = Calendar.current
        let offset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: anchor),
            to: calendar.startOfDay(for: day)
        ).day ?? initialDayOffset
        guard store.addManualAgendaItem(
            title: title,
            startMinute: minutes(startsAt),
            endMinute: minutes(endsAt),
            dayOffset: offset,
            accountID: accountID,
            place: place,
            meetingLink: meetingLink,
            note: note
        ) != nil else { return }
        onClose()
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
