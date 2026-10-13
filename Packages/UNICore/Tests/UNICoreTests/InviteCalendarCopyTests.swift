import Foundation
import Testing
@testable import UNICore

/// O convite do Vanderson voltava ao Google como uma **cópia** organizada pelo
/// dono: sem convidados, com Meet novo, a cada mudança de horário. Responder é
/// só o `METHOD:REPLY`; o evento já é do organizador e o provedor o mantém.
@Suite("Convite aceito não vira cópia no calendário do provedor")
@MainActor
struct InviteCalendarCopyTests {
    @MainActor
    private final class CalendarSyncDouble: CalendarSyncing {
        var synchronized: [AgendaItem] = []
        var savedIDs: [String] = []

        func availability() async -> CalendarAvailability { .available }
        func calendars() async -> [ConnectedCalendar] { [] }
        func synchronize(referenceDay _: Date, requestAuthorization _: Bool) async throws -> [AgendaItem] {
            synchronized
        }
        func save(_ item: AgendaItem, referenceDay _: Date) async throws { savedIDs.append(item.id) }
        func remove(id _: String, referenceDay _: Date) async throws {}
    }

    private final class SendPort: MailSendPort, @unchecked Sendable {
        private(set) var sent: [OutgoingMessage] = []
        func send(_ message: OutgoingMessage) throws { sent.append(message) }
    }

    private let account = Account(
        id: "gmail-marcos", address: "msant262@gmail.com", displayName: "Marcos",
        provider: .gmail, host: "gmail", tintLightHex: "#000000", tintDarkHex: "#ffffff"
    )

    private func invite(sequence: Int, hour: Int) -> CalendarInvite {
        let start = Calendar.current.date(
            bySettingHour: hour, minute: 0, second: 0, of: Fixtures.today
        )!
        return CalendarInvite(
            summary: "Revisão de requisitos", start: start,
            end: start.addingTimeInterval(3_600),
            organizer: Contact(name: "Vanderson", address: "vanderson@example.com"),
            attendees: [Contact(name: "Marcos", address: "msant262@gmail.com")],
            method: "REQUEST", uid: "6lv7u2c4l11j7s6t4o5hk3sh98@google.com", sequence: sequence
        )
    }

    private func message(id: String) -> Message {
        Message(
            id: id, accountID: account.id,
            from: Contact(name: "Vanderson", address: "vanderson@example.com"),
            receivedAt: Fixtures.today, subject: "Revisão de requisitos", snippet: "convite",
            body: [], tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil,
            calendarICS: "BEGIN:VCALENDAR", rfcMessageID: "\(id)@google.com"
        )
    }

    /// O original como o EventKit o traz da agenda Google, ainda no horário antigo.
    private var googleOriginal: AgendaItem {
        AgendaItem(
            id: "eventkit:ABC-123:1788163200",
            title: "Revisão de requisitos", startMinute: 9 * 60, endMinute: 10 * 60,
            accountID: "okamiuni.system-calendar", dayOffset: 0,
            calendarUID: "6lv7u2c4l11j7s6t4o5hk3sh98@google.com",
            calendarID: "gmail-calendar", calendarTitle: "msant262@gmail.com",
            calendarSource: "Google"
        )
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test("Aceitar envia só o REPLY: nada é gravado no calendário do provedor")
    func acceptDoesNotWriteToProvider() async {
        let sync = CalendarSyncDouble()
        let port = SendPort()
        let msg = message(id: "m-1")
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [msg], agenda: []),
            sendPort: port, calendarSync: sync
        )
        await store.load()

        #expect(store.respondToInvite(invite(sequence: 0, hour: 14), from: msg, response: .accepted)
            == .queued(.accepted))
        await settle()

        #expect(port.sent.count == 1)
        #expect(sync.savedIDs.isEmpty)
    }

    @Test("Horário mudou e o Google já tem o evento: nem cópia local nem escrita no provedor")
    func rescheduledInviteMatchesProviderEventByUID() async {
        let sync = CalendarSyncDouble()
        sync.synchronized = [googleOriginal]
        let msg = message(id: "m-2")
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [msg], agenda: []),
            sendPort: SendPort(), calendarSync: sync
        )
        await store.load()
        let updated = invite(sequence: 3, hour: 14)

        #expect(store.agendaState(for: updated, from: msg) == .naAgenda)
        #expect(store.respondToInvite(updated, from: msg, response: .accepted) == .queued(.accepted))
        store.syncInviteWithAgenda(updated, from: msg)
        await settle()

        #expect(sync.savedIDs.isEmpty)
        #expect(!store.agenda.contains { DetectedEventConversion.isFromEmail($0.id) })
        #expect(store.agenda.first { $0.id == googleOriginal.id }?.startMinute == 9 * 60)
    }

    @Test("Convite atualizado move o compromisso local sem regravar no provedor")
    func updateMovesLocalItemOnly() async {
        let sync = CalendarSyncDouble()
        let first = message(id: "m-3")
        let second = message(id: "m-4")
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [first, second], agenda: []),
            sendPort: SendPort(), calendarSync: sync
        )
        await store.load()

        #expect(store.respondToInvite(invite(sequence: 0, hour: 14), from: first, response: .accepted)
            == .queued(.accepted))
        store.syncInviteWithAgenda(invite(sequence: 1, hour: 16), from: second)
        await settle()

        #expect(sync.savedIDs.isEmpty)
        let local = store.agenda.filter { $0.calendarUID == "6lv7u2c4l11j7s6t4o5hk3sh98@google.com" }
        #expect(local.count == 1)
        #expect(local.first?.startMinute == 16 * 60)
    }
}
