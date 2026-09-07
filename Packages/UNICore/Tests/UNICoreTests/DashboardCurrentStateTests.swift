import Foundation
import Testing
@testable import UNICore

@Suite("Dashboard respeita o estado atual")
@MainActor
struct DashboardCurrentStateTests {
    @Test("A IA do dashboard não recebe mensagens já dispensadas")
    func briefingUsesActiveState() async throws {
        let store = MailStore(source: InMemoryMailSource(accounts: Fixtures.accounts,
            messages: Fixtures.messages.map { $0.withBucket(.trash) }, agenda: []))
        await store.load()
        guard case let .workspace(context) = AssistantMailContext(workspace: store, dashboardOnly: true) else {
            Issue.record("Esperava contexto do dashboard"); return
        }
        #expect(context.emails.isEmpty)
        #expect(context.emailCount == 0)
    }

    @Test("Gmail sem rótulos confirmados não gera uma cobrança")
    func unverifiedGmailIsNotActionable() {
        let message = Message(id: "a:g:legacy", accountID: "a", from: Contact(name: "Jack", address: "jack@example.com"),
            receivedAt: Date(), subject: "Oferta", snippet: "Oferta comercial", body: [],
            tags: [Tag(name: "Lead")], bucket: .today, isRead: false, summary: nil, detectedEvent: nil)
        #expect(!DashboardFocus.isActiveCandidate(message))
        #expect(DashboardFocus.isActiveCandidate(message.withFolderIDs(["a/INBOX"])))
    }
    @Test("Arquivar, adiar e excluir retiram a mensagem do dashboard imediatamente")
    func dismissedMessagesStayOut() async {
        let original = Fixtures.messages.first { $0.triage?.needsReply == true || $0.tags.contains { $0.name == "Precisa resposta" } }!
        for bucket in [TriageBucket.archived, .later, .trash, .junk] {
            let source = InMemoryMailSource(accounts: Fixtures.accounts,
                messages: [original.withBucket(bucket)], agenda: [])
            let store = MailStore(source: source)
            await store.load()
            #expect(store.dashboardFocus(nowMinute: 720).mail.isEmpty)
        }
    }

    @Test("Uma resposta enviada tira a pergunta anterior das pendências reais")
    func sentEvidenceReachesRanking() async {
        let question = Message(id: "question", accountID: "a", from: Contact(name: "Ana", address: "ana@example.com"),
            receivedAt: Date(timeIntervalSince1970: 100), subject: "Proposta", snippet: "Pode confirmar?",
            body: [], tags: [Tag(name: "Precisa resposta")], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil, rfcMessageID: "question@example.com", threadKey: "thread")
        let reply = Message(id: "reply", accountID: "a", from: Contact(name: "Marcos", address: "me@example.com"),
            receivedAt: Date(timeIntervalSince1970: 200), subject: "Re: Proposta", snippet: "Confirmado",
            body: [], tags: [], bucket: .sent, isRead: true, summary: nil, detectedEvent: nil,
            references: ["question@example.com"], threadKey: "thread")
        let store = MailStore(source: InMemoryMailSource(accounts: [], messages: [question, reply], agenda: []))
        await store.load()
        #expect(store.dashboardFocus(nowMinute: 720).mail.isEmpty)
    }
}
