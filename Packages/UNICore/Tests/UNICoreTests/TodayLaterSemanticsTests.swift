import Foundation
import Testing
@testable import UNICore

/// Mantém o relógio injetado mutável para provar que a chave do cache não
/// atravessa a meia-noite com a lista do dia anterior.
private final class MutableReferenceDay: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

@Suite("Semântica de Hoje e Depois")
struct TodayLaterSemanticsTests {
    private let account = Account(
        id: "conta", address: "marcos@example.com", displayName: "Marcos",
        provider: .imap, host: "mail.example.com",
        tintLightHex: "#2C7D5E", tintDarkHex: "#7CBAAA"
    )

    /// Datas de parede no mesmo calendário que a produção usa. Não há soma de
    /// 86.400 segundos: meia-noite e horário de verão pertencem ao calendário.
    private func date(
        year: Int = 2026, month: Int = 8, day: Int = 30,
        hour: Int, minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    private func message(_ id: String, at receivedAt: Date, bucket: TriageBucket, read: Bool = false) -> Message {
        Message(
            id: id, accountID: account.id,
            from: Contact(name: id, address: "\(id)@example.com"),
            receivedAt: receivedAt, subject: id, snippet: id, body: [],
            tags: [], bucket: bucket, isRead: read,
            summary: nil, detectedEvent: nil
        )
    }

    @MainActor
    private func store(
        messages: [Message], referenceDay: Date
    ) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: [account], messages: messages, agenda: [], pendingItems: []
            ),
            agendaReferenceDay: { referenceDay }
        )
        await store.load()
        return store
    }

    @Test("Hoje contém apenas Inbox recebida no dia local; Depois não corta por data")
    @MainActor
    func todayIsStrictButLaterIsExplicit() async {
        let reference = date(hour: 12)
        let store = await store(
            messages: [
                message("primeiro-minuto", at: date(hour: 0), bucket: .today),
                message("ultimo-minuto", at: date(hour: 23, minute: 59), bucket: .today),
                message("ontem", at: date(day: 29, hour: 23, minute: 59), bucket: .today),
                message("amanha", at: date(day: 31, hour: 0), bucket: .today),
                message("depois-antigo", at: date(day: 2, hour: 8), bucket: .later),
                message("depois-futuro", at: date(day: 31, hour: 8), bucket: .later),
            ],
            referenceDay: reference
        )

        #expect(Set(store.visibleMessages.map(\.id)) == ["primeiro-minuto", "ultimo-minuto"])

        store.select(bucket: .later)
        #expect(Set(store.visibleMessages.map(\.id)) == ["depois-antigo", "depois-futuro"])
    }

    @Test("contadores e marcar tudo em Hoje usam o mesmo recorte temporal da lista")
    @MainActor
    func todayCountsAndMarkAllReadIgnoreOldInbox() async {
        let reference = date(hour: 12)
        let store = await store(
            messages: [
                message("hoje", at: date(hour: 9), bucket: .today),
                message("inbox-antiga", at: date(day: 29, hour: 9), bucket: .today),
                message("depois", at: date(day: 2, hour: 9), bucket: .later),
            ],
            referenceDay: reference
        )

        #expect(store.count(for: .today) == 1)
        #expect(store.unreadCount(in: .today) == 1)

        store.markAllRead(in: .today)

        #expect(store.messages.first { $0.id == "hoje" }?.isRead == true)
        #expect(store.messages.first { $0.id == "inbox-antiga" }?.isRead == false)
        #expect(store.unreadCount(in: .today) == 0)
    }

    @Test("revelar Inbox antiga sai de Hoje para Tudo, onde a lista a contém")
    @MainActor
    func revealOldInboxUsesAllInsteadOfHiddenToday() async {
        let reference = date(hour: 12)
        let store = await store(
            messages: [message("inbox-antiga", at: date(day: 29, hour: 9), bucket: .today)],
            referenceDay: reference
        )

        #expect(store.visibleMessages.isEmpty)

        store.reveal("inbox-antiga")

        #expect(store.bucket == .all)
        #expect(store.visibleMessages.map(\.id) == ["inbox-antiga"])
        #expect(store.selectedMessageID == "inbox-antiga")
    }

    @Test("o cache de Hoje muda quando a referência cruza a meia-noite")
    @MainActor
    func todayCacheUsesReferenceDay() async {
        let reference = MutableReferenceDay(date(hour: 23, minute: 59))
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: [account],
                messages: [
                    message("fim-do-dia", at: date(hour: 23, minute: 58), bucket: .today),
                    message("novo-dia", at: date(day: 31, hour: 0), bucket: .today),
                ],
                agenda: [], pendingItems: []
            ),
            agendaReferenceDay: { reference.value }
        )
        await store.load()

        #expect(store.visibleMessages.map(\.id) == ["fim-do-dia"])

        reference.value = date(day: 31, hour: 0, minute: 1)

        #expect(store.visibleMessages.map(\.id) == ["novo-dia"])
    }
}
