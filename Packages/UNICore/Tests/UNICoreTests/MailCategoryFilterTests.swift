import Foundation
import Testing
@testable import UNICore

@Suite("Filtros de categoria da caixa Hoje")
struct MailCategoryFilterTests {
    private let today = Calendar.current.date(
        from: DateComponents(year: 2026, month: 8, day: 30, hour: 12)
    )!

    private func message(
        _ id: String,
        subject: String,
        category: MailCategory? = nil,
        bucket: TriageBucket = .today,
        day: Int = 30
    ) -> Message {
        let receivedAt = Calendar.current.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: 9)
        )!
        return Message(
            id: id, accountID: "conta",
            from: Contact(name: "Remetente", address: "email@example.com"),
            receivedAt: receivedAt, subject: subject, snippet: subject,
            body: [], tags: [], bucket: bucket, isRead: false,
            summary: nil, detectedEvent: nil, category: category
        )
    }

    @MainActor
    private func makeStore(_ messages: [Message]) async -> MailStore {
        let account = Account(
            id: "conta", address: "marcos@example.com", displayName: "Marcos",
            provider: .imap, host: "example.com",
            tintLightHex: "#4D7964", tintDarkHex: "#8CB7A2"
        )
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: [account], messages: messages, agenda: [], pendingItems: []
            ),
            agendaReferenceDay: { today }
        )
        await store.load()
        return store
    }

    @Test("Todos e cada categoria contam o mesmo recorte temporal de Hoje")
    @MainActor
    func countsUseStrictTodayScope() async {
        let store = await makeStore([
            message("cliente", subject: "Revisão do contrato", category: .primary),
            message("fatura", subject: "Sua fatura", category: .transactions),
            message("oferta", subject: "30% de desconto", category: .promotions),
            message("antiga", subject: "Newsletter antiga", category: .promotions, day: 29),
            message("adiada", subject: "Status adiado", category: .updates, bucket: .later),
        ])

        #expect(store.categoryCount(nil) == 3)
        #expect(store.categoryCount(.primary) == 1)
        #expect(store.categoryCount(.transactions) == 1)
        #expect(store.categoryCount(.promotions) == 1)
        #expect(store.categoryCount(.updates) == 0)
    }

    @Test("selecionar categoria filtra lista e reposiciona o leitor")
    @MainActor
    func selectionFiltersAndReselects() async {
        let store = await makeStore([
            message("principal", subject: "Conversa", category: .primary),
            message("social", subject: "Comunidade", category: .social),
        ])

        store.select(category: .social)

        #expect(store.categoryFilter == .social)
        #expect(store.visibleMessages.map(\.id) == ["social"])
        #expect(store.selectedMessageID == "social")

        store.select(category: nil)
        #expect(Set(store.visibleMessages.map(\.id)) == ["principal", "social"])
    }

    @Test("categoria persistida pela IA vence a heurística do assunto")
    @MainActor
    func persistedCategoryWinsFallback() async {
        let clientEmail = message(
            "cliente", subject: "Newsletter: revisão do contrato", category: .primary
        )
        let store = await makeStore([clientEmail])

        #expect(store.resolvedCategory(for: clientEmail) == .primary)
        store.select(category: .promotions)
        #expect(store.visibleMessages.isEmpty)
        store.select(category: .primary)
        #expect(store.visibleMessages.map(\.id) == ["cliente"])
    }

    @Test("trocar de caixa limpa a categoria invisível")
    @MainActor
    func switchingMailboxResetsCategory() async {
        let store = await makeStore([
            message("principal", subject: "Conversa", category: .primary),
            message("adiada", subject: "Aviso", category: .updates, bucket: .later),
        ])
        store.select(category: .primary)

        store.select(bucket: .later)

        #expect(store.categoryFilter == nil)
        #expect(store.visibleMessages.map(\.id) == ["adiada"])
    }
}
