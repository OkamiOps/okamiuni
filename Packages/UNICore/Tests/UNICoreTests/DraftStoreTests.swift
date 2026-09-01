import Foundation
import Testing
@testable import UNICore

@Suite("Rascunhos")
struct DraftStoreTests {

    @Test("salvar rascunho põe a linha na caixa Rascunhos, fora de Tudo")
    @MainActor
    func saveDraftAppearsInDrafts() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let conta = store.accounts[0]
        let rascunho = Message(
            id: "local-draft-1",
            accountID: conta.id,
            from: Contact(name: conta.displayName, address: conta.address),
            receivedAt: Date(),
            subject: "Rascunho de teste",
            snippet: "Corpo",
            body: ["Corpo"],
            tags: [],
            bucket: .drafts,
            isRead: true,
            summary: nil,
            detectedEvent: nil,
            to: [Contact(name: "Marina", address: "marina@x.com")]
        )
        #expect(store.saveDraft(rascunho))
        #expect(store.count(for: .drafts) == 1)
        #expect(store.messages.contains { $0.id == "local-draft-1" && $0.bucket == .drafts })
        #expect(!TriageBucket.all.contains(rascunho))
    }

    @Test("salvar de novo o mesmo id atualiza, não duplica")
    @MainActor
    func saveDraftUpdatesInPlace() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let conta = store.accounts[0]
        func item(_ assunto: String) -> Message {
            Message(
                id: "local-draft-2",
                accountID: conta.id,
                from: Contact(name: conta.displayName, address: conta.address),
                receivedAt: Date(),
                subject: assunto,
                snippet: assunto,
                body: [assunto],
                tags: [],
                bucket: .drafts,
                isRead: true,
                summary: nil,
                detectedEvent: nil
            )
        }
        #expect(store.saveDraft(item("um")))
        #expect(store.saveDraft(item("dois")))
        let rascunhos = store.messages.filter { $0.bucket == .drafts && $0.id == "local-draft-2" }
        #expect(rascunhos.count == 1)
        #expect(rascunhos.first?.subject == "dois")
    }

    @Test("descartar tira o rascunho da caixa")
    @MainActor
    func discardDraftRemovesIt() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let conta = store.accounts[0]
        let rascunho = Message(
            id: "local-draft-3",
            accountID: conta.id,
            from: Contact(name: conta.displayName, address: conta.address),
            receivedAt: Date(),
            subject: "X",
            snippet: "X",
            body: ["X"],
            tags: [],
            bucket: .drafts,
            isRead: true,
            summary: nil,
            detectedEvent: nil
        )
        #expect(store.saveDraft(rascunho))
        store.discardDraft(id: "local-draft-3")
        #expect(store.count(for: .drafts) == 0)
    }

    @Test("rascunho de resposta guarda o id do email original")
    @MainActor
    func replyDraftRemembersOrigin() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let original = store.messages[0]
        let rascunho = Message(
            id: "local-draft-4",
            accountID: original.accountID,
            from: original.from,
            receivedAt: Date(),
            subject: "Re: \(original.subject)",
            snippet: "Testesteste",
            body: ["Testesteste"],
            tags: [],
            bucket: .drafts,
            isRead: true,
            summary: nil,
            detectedEvent: nil,
            to: [original.from],
            threadKey: original.id
        )
        #expect(store.saveDraft(rascunho))
        #expect(store.message("local-draft-4")?.threadKey == original.id)
        #expect(store.message("local-draft-4")?.body == ["Testesteste"])
    }
}
