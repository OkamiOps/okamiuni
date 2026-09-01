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

    private func message(
        _ id: String,
        at receivedAt: Date,
        bucket: TriageBucket,
        read: Bool = false,
        folderIDs: [String] = []
    ) -> Message {
        Message(
            id: id, accountID: account.id,
            from: Contact(name: id, address: "\(id)@example.com"),
            receivedAt: receivedAt, subject: id, snippet: id, body: [],
            tags: [], bucket: bucket, isRead: read,
            summary: nil, detectedEvent: nil,
            folderIDs: folderIDs
        )
    }

    private var vantionFolders: [MailFolder] {
        [
            MailFolder(
                id: "conta/INBOX", accountID: account.id,
                serverName: "INBOX", displayName: "INBOX", role: .inbox
            ),
            MailFolder(
                id: "conta/Promoções", accountID: account.id,
                serverName: "Promoções", displayName: "Promoções", role: .other
            ),
        ]
    }

    @MainActor
    private func store(
        messages: [Message],
        referenceDay: Date,
        folders: [MailFolder] = [],
        accounts: [Account]? = nil
    ) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: accounts ?? [account], messages: messages, agenda: [], pendingItems: [],
                folders: folders
            ),
            agendaReferenceDay: { referenceDay }
        )
        await store.load()
        return store
    }

    @Test("Hoje contém o que chegou no dia local; Depois não corta por data")
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

    /// IMAP entrega em subpasta grava `.archived`. Sem este recorte, Hoje só
    /// mostrava a Inbox do Gmail e o que chegou hoje na Vantion ficava só
    /// em Tudo.
    @Test("Hoje traz o que chegou no dia, inclusive pasta do usuário")
    @MainActor
    func todayIncludesSubfolderMail() async {
        let reference = date(hour: 12)
        let store = await store(
            messages: [
                message(
                    "inbox-hoje", at: date(hour: 9), bucket: .today,
                    folderIDs: ["conta/INBOX"]
                ),
                message(
                    "subpasta-hoje", at: date(hour: 17, minute: 46), bucket: .archived,
                    folderIDs: ["conta/Promoções"]
                ),
                message(
                    "subpasta-ontem", at: date(day: 29, hour: 17), bucket: .archived,
                    folderIDs: ["conta/Promoções"]
                ),
                message(
                    "arquivada-hoje", at: date(hour: 8), bucket: .archived,
                    folderIDs: ["conta/INBOX"]
                ),
                message("depois-hoje", at: date(hour: 10), bucket: .later),
                message("lixeira-hoje", at: date(hour: 11), bucket: .trash),
                message("enviada-hoje", at: date(hour: 12), bucket: .sent),
                message("rascunho-hoje", at: date(hour: 13), bucket: .drafts),
                message("spam-hoje", at: date(hour: 14), bucket: .junk),
            ],
            referenceDay: reference,
            folders: vantionFolders
        )

        #expect(Set(store.visibleMessages.map(\.id)) == ["inbox-hoje", "subpasta-hoje"])
        #expect(store.count(for: .today) == 2)
        #expect(store.unreadCount(in: .today) == 2)
        #expect(!store.visibleMessages.contains { $0.id == "spam-hoje" })

        store.select(bucket: .archived)
        #expect(
            Set(store.visibleMessages.map(\.id))
                == ["subpasta-hoje", "subpasta-ontem", "arquivada-hoje"]
        )
    }

    /// No Gmail, "Mover para marcador" tira INBOX e deixa o rótulo. Isso é
    /// arquivo, não "chegou numa pasta" — Google Play em `00_Novos/Arquivo`
    /// não pode reaparecer em Hoje só porque o dia ainda é hoje.
    @Test("Tudo não mistura spam — nem o projetado ainda como Arquivado")
    @MainActor
    func allExcludesSpamIncludingLegacyArchive() async {
        let reference = date(hour: 12)
        let spamFolder = MailFolder(
            id: "conta/Spam", accountID: account.id,
            serverName: "Spam", displayName: "Spam", role: .junk
        )
        let store = await store(
            messages: [
                message(
                    "legitima", at: date(hour: 9), bucket: .today,
                    folderIDs: ["conta/INBOX"]
                ),
                message(
                    "spam-novo", at: date(hour: 10), bucket: .junk,
                    folderIDs: ["conta/Spam"]
                ),
                message(
                    "spam-velho", at: date(hour: 11), bucket: .archived,
                    folderIDs: ["conta/Spam"]
                ),
            ],
            referenceDay: reference,
            folders: vantionFolders + [spamFolder]
        )

        store.select(bucket: .all)
        #expect(Set(store.visibleMessages.map(\.id)) == ["legitima"])

        store.select(bucket: .junk)
        #expect(Set(store.visibleMessages.map(\.id)) == ["spam-novo", "spam-velho"])
    }

    @Test("Hoje não traz Gmail movido para marcador")
    @MainActor
    func todayExcludesGmailMovedToLabel() async {
        let gmail = Account(
            id: "gmail", address: "marcos@gmail.com", displayName: "Gmail",
            provider: .gmail, host: "gmail",
            tintLightHex: "#C5221F", tintDarkHex: "#F28B82"
        )
        let reference = date(hour: 12)
        let store = await store(
            messages: [
                Message(
                    id: "inbox-gmail", accountID: gmail.id,
                    from: Contact(name: "Inbox", address: "a@gmail.com"),
                    receivedAt: date(hour: 9), subject: "Inbox", snippet: "Inbox",
                    body: [], tags: [], bucket: .today, isRead: false,
                    summary: nil, detectedEvent: nil,
                    folderIDs: ["gmail/INBOX"]
                ),
                Message(
                    id: "google-play", accountID: gmail.id,
                    from: Contact(name: "Google Play", address: "play@google.com"),
                    receivedAt: date(hour: 2, minute: 31),
                    subject: "Seu recibo", snippet: "recibo",
                    body: [], tags: [], bucket: .archived, isRead: false,
                    summary: nil, detectedEvent: nil,
                    folderIDs: ["gmail/00_Novos/Arquivo"]
                ),
            ],
            referenceDay: reference,
            folders: [
                MailFolder(
                    id: "gmail/INBOX", accountID: gmail.id,
                    serverName: "INBOX", displayName: "INBOX", role: .inbox
                ),
                MailFolder(
                    id: "gmail/00_Novos/Arquivo", accountID: gmail.id,
                    serverName: "00_Novos/Arquivo", displayName: "00_Novos/Arquivo",
                    role: .other
                ),
            ],
            accounts: [gmail]
        )

        #expect(Set(store.visibleMessages.map(\.id)) == ["inbox-gmail"])
        #expect(store.count(for: .today) == 1)

        store.select(bucket: .archived)
        #expect(store.visibleMessages.map(\.id) == ["google-play"])
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

    /// O Gmail deixa INBOX+SENT no RSVP e no "Videoconferência atualizada".
    /// A projeção antiga mandava isso para Enviadas e sumia da caixa.
    @Test("Hoje traz o RSVP do Gmail que ainda está na caixa")
    @MainActor
    func todayIncludesGmailInboxSent() async {
        let gmail = Account(
            id: "gmail", address: "marcos@gmail.com", displayName: "Gmail",
            provider: .gmail, host: "gmail",
            tintLightHex: "#C5221F", tintDarkHex: "#F28B82"
        )
        let reference = date(hour: 12)
        let inbox = MailFolder(
            id: "gmail/INBOX", accountID: gmail.id,
            serverName: "INBOX", displayName: "Entrada", role: .inbox
        )
        let sent = MailFolder(
            id: "gmail/SENT", accountID: gmail.id,
            serverName: "SENT", displayName: "Enviados", role: .sent
        )
        let store = await store(
            messages: [
                Message(
                    id: "rsvp", accountID: gmail.id,
                    from: Contact(name: "eu", address: "marcos@gmail.com"),
                    receivedAt: date(hour: 0, minute: 36),
                    subject: "Videoconferência atualizada", snippet: "Luna",
                    body: [], tags: [], bucket: .sent, isRead: false,
                    summary: nil, detectedEvent: nil,
                    folderIDs: ["gmail/INBOX", "gmail/SENT"]
                ),
                Message(
                    id: "so-enviada", accountID: gmail.id,
                    from: Contact(name: "eu", address: "marcos@gmail.com"),
                    receivedAt: date(hour: 1),
                    subject: "Resposta", snippet: "ok",
                    body: [], tags: [], bucket: .sent, isRead: true,
                    summary: nil, detectedEvent: nil,
                    folderIDs: ["gmail/SENT"]
                ),
            ],
            referenceDay: reference,
            folders: [inbox, sent],
            accounts: [gmail]
        )

        #expect(Set(store.visibleMessages.map(\.id)) == ["rsvp"])
        #expect(store.count(for: .today) == 1)

        store.select(bucket: .all)
        #expect(Set(store.visibleMessages.map(\.id)) == ["rsvp"])

        store.select(bucket: .sent)
        #expect(Set(store.visibleMessages.map(\.id)) == ["rsvp", "so-enviada"])
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
