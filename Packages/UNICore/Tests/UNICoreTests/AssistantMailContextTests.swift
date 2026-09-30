import Foundation
import Testing
@testable import UNICore

@Suite("Contexto factual do assistente")
struct AssistantMailContextTests {
    @Test("IA recebe nomes de anexos sem alegar leitura do arquivo")
    func attachmentManifest() {
        let message = Fixtures.messages[0].withBody(["Veja os slides"], html: "", calendarICS: nil,
            attachments: [.init(id: "slides", filename: "slides.pdf", mimeType: "application/pdf", byteCount: 100)])
        let context = AssistantEmailContext(message: message)
        #expect(context.body.contains("slides.pdf"))
        #expect(context.body.contains("file contents have NOT been read"))
    }
    @Test("Mensagem preserva remetente, destinatários e corpo")
    func messageContext() throws {
        let message = Fixtures.messages[0]
        let context = AssistantEmailContext(message: message)

        #expect(context.sender == message.from.display)
        #expect(context.subject == message.subject)
        #expect(context.body == message.body.joined(separator: "\n\n"))
    }

    @Test("HTML da mensagem acompanha o contexto para a IA configurada")
    func htmlFollowsTheMessage() throws {
        let original = Fixtures.messages[0]
        let html = "<p>Hi Marcos,</p><ol><li>What is IGEL OS?</li></ol>"
        let message = original.withBody(["Hi Marcos, I'm reaching out."], html: html, calendarICS: nil)
        let context = AssistantEmailContext(message: message)

        #expect(context.body == "Hi Marcos, I'm reaching out.")
        #expect(context.html == html)
    }

    @Test("Snippet cobre uma mensagem cujo corpo ainda não chegou")
    func snippetFallback() throws {
        let original = Fixtures.messages[0]
        let message = original.withBody([], html: nil, calendarICS: nil)
        let context = AssistantEmailContext(message: message)

        #expect(context.body == message.snippet)
    }

    @Test("Conversa mantém ordem cronológica")
    func conversationOrder() throws {
        let older = Fixtures.messages[1]
        let newer = Fixtures.messages[0]
        let conversation = try #require(Conversation(key: "thread", messages: [older, newer]))

        guard case let .conversation(messages) = AssistantMailContext(conversation: conversation) else {
            Issue.record("Esperava contexto de conversa")
            return
        }
        #expect(messages.map { $0.subject } == [older.subject, newer.subject])
    }

    @Test("Contexto global ignora filtros e leva todas as caixas e a agenda")
    @MainActor
    func workspaceIgnoresCurrentSelection() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let allMessages = store.messages
        let allAgenda = store.agenda

        store.select(account: try #require(store.accounts.first?.id))
        store.select(bucket: .trash)

        guard case let .workspace(workspace) = AssistantMailContext(workspace: store) else {
            Issue.record("Esperava contexto do ambiente")
            return
        }
        #expect(workspace.emailCount == allMessages.count)
        #expect(workspace.emails.count == allMessages.count)
        #expect(workspace.agenda.count == allAgenda.count)
        #expect(workspace.accounts.count == store.accounts.count)
        #expect(workspace.pendingItems.count == store.pendingItems.count)
        #expect(workspace.emails.map(\.snippet).contains(allMessages[0].snippet))
        #expect(workspace.emails.allSatisfy { email in
            allMessages.contains(where: { $0.id == email.id })
        })
    }

    @Test("contexto automático segue o negócio escolhido, relógio e reuniões restantes")
    @MainActor
    func dashboardContextFollowsVisibleScope() async throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 11))!
        let ids = Fixtures.accounts.prefix(2).map(\.id)
        let accountA = try #require(ids.first)
        let accountB = try #require(ids.last)
        let messages = ids.enumerated().map { index, id in
            Message(id: "mail-\(index)", accountID: id,
                from: Contact(name: "Pessoa \(index)", address: "p\(index)@example.com"),
                receivedAt: now.addingTimeInterval(-60), subject: "Pedido \(index)",
                snippet: "Preciso da revisão", body: ["CORPO PRIVADO NÃO ENVIADO"],
                tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil,
                triage: .init(needsReply: true, intent: .request, urgency: .normal))
        }
        let agenda = [
            AgendaItem(id: "ended", title: "Já terminou", startMinute: 540, endMinute: 600, accountID: accountA),
            AgendaItem(id: "next", title: "Próxima reunião", startMinute: 720, endMinute: 750, accountID: accountA),
            AgendaItem(id: "other", title: "Outra conta", startMinute: 720, endMinute: 750, accountID: accountB)
        ]
        let store = MailStore(source: InMemoryMailSource(accounts: Fixtures.accounts,
            messages: messages, agenda: agenda), agendaReferenceDay: { now })
        await store.load()
        guard case let .workspace(context) = AssistantMailContext(workspace: store, dashboardOnly: true,
            nowMinute: 660, dashboardAccountIDs: [accountA]) else {
            Issue.record("Esperava contexto do dashboard"); return
        }
        #expect(context.emails.map(\.id) == ["mail-0"])
        #expect(context.agenda.map(\.title) == ["Próxima reunião"])
        #expect(context.accounts.count == 1)
        #expect(context.referenceDate == now)
        #expect(!context.emails.contains { $0.snippet.contains("CORPO PRIVADO") })
        #expect(context.mailboxes.allSatisfy { $0.totalCount <= 1 })
    }
}
