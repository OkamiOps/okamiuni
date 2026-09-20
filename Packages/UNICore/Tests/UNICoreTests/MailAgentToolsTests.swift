import Foundation
import Testing
@testable import UNICore

@Suite("Ferramentas nativas de e-mail para agentes")
@MainActor
struct MailAgentToolsTests {
    @Test("salva pelo porto e o rascunho reaparece ao reabrir a fonte")
    func savesAndReopensThroughDraftPort() async throws {
        let account = account("a")
        let port = RecordingDraftPort()
        let source = DraftBackedMailSource(accounts: [account], messages: [], port: port)
        let store = await loadedStore(source: source, draftPort: port)
        let tools = MailAgentTools(store: store)

        let saved = try await tools.execute(name: "drafts_create", arguments: draftCreate(
            accountID: account.id, subject: "Plano", body: "Texto salvo", to: ["team@example.com"], requestID: "persist-1"
        ))
        let id = try #require(saved["draftID"]?.stringValue)
        #expect(port.draft(id)?.body == ["Texto salvo"])
        #expect(port.saveCount == 1)

        let reopened = await loadedStore(source: source, draftPort: port)
        #expect(reopened.message(id)?.bucket == .drafts)
        #expect(reopened.message(id)?.subject == "Plano")
        #expect(reopened.message(id)?.to.map(\.address) == ["team@example.com"])
    }

    @Test("requestID repete somente a mesma criação e protege contra conflito")
    func requestIDIsIdempotentAndDetectsConflict() async throws {
        let account = account("a")
        let port = RecordingDraftPort()
        let source = DraftBackedMailSource(accounts: [account], messages: [], port: port)
        let store = await loadedStore(source: source, draftPort: port)
        let tools = MailAgentTools(store: store)
        let arguments = draftCreate(
            accountID: account.id, subject: "Reunião", body: "Primeira versão", to: ["ana@example.com"], requestID: "retry-42"
        )

        let first = try await tools.execute(name: "drafts_create", arguments: arguments)
        let second = try await tools.execute(name: "drafts_create", arguments: arguments)
        let id = try #require(first["draftID"]?.stringValue)
        #expect(second["draftID"]?.stringValue == id)
        #expect(port.saveCount == 1)

        #expect(await conflicts {
            _ = try await tools.execute(name: "drafts_create", arguments: draftCreate(
                accountID: account.id, subject: "Reunião", body: "Texto alterado", to: ["ana@example.com"], requestID: "retry-42"
            ))
        })
        #expect(store.message(id)?.body == ["Primeira versão"])
        #expect(port.saveCount == 1)
    }

    @Test("limita listagem, busca e criação às contas autorizadas")
    func scopesEveryOperationToAllowedAccounts() async throws {
        let allowed = account("a")
        let outside = account("b")
        let visible = message(id: "visible", account: allowed, subject: "Visível")
        let hidden = message(id: "hidden", account: outside, subject: "Secreto")
        let store = await loadedStore(
            source: InMemoryMailSource(accounts: [allowed, outside], messages: [visible, hidden], agenda: [])
        )
        let tools = MailAgentTools(store: store, accountIDs: [allowed.id])

        let accounts = try await tools.execute(name: "accounts_list", arguments: .object([:]))
        #expect(accounts["accounts"]?.arrayValue?.map { $0["accountID"]?.stringValue } == [allowed.id])

        let search = try await tools.execute(name: "mail_search", arguments: .object([:]))
        #expect(search["items"]?.arrayValue?.map { $0["messageID"]?.stringValue } == [visible.id])

        await #expect(throws: AgentToolError.self) {
            _ = try await tools.execute(name: "drafts_create", arguments: draftCreate(
                accountID: outside.id, subject: "Fora", body: "Não pode", to: ["x@example.com"], requestID: "outside"
            ))
        }
        await #expect(throws: AgentToolError.self) {
            _ = try await tools.execute(name: "mail_prepare_reply", arguments: .object([
                "messageID": .string(hidden.id), "body": .string("Não pode"), "requestID": .string("outside-message"),
            ]))
        }
    }

    @Test("busca todos os resultados locais e pagina com janelas de data")
    func searchPaginatesBeyondContextSnapshotAndFiltersDates() async throws {
        let account = account("a")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = (0..<300).map { index in
            Message(
                id: "mail-\(index)", accountID: account.id,
                from: Contact(name: "Remetente", address: "sender@example.com"),
                receivedAt: start.addingTimeInterval(TimeInterval(index)),
                subject: "Relatório \(index)", snippet: "Item \(index)", body: ["Corpo \(index)"], tags: [],
                bucket: .today, isRead: false, summary: nil, detectedEvent: nil
            )
        }
        let store = await loadedStore(
            source: InMemoryMailSource(accounts: [account], messages: messages, agenda: [])
        )
        let tools = MailAgentTools(store: store)

        let page = try await tools.execute(name: "mail_search", arguments: .object([
            "offset": .number(250), "limit": .number(50),
        ]))
        #expect(page["total"]?.intValue == 300)
        #expect(page["items"]?.arrayValue?.count == 50)
        #expect(page["items"]?.arrayValue?.first?["messageID"]?.stringValue == "mail-49")
        #expect(page["items"]?.arrayValue?.last?["messageID"]?.stringValue == "mail-0")
        #expect(page["nextOffset"] == .null)

        let filtered = try await tools.execute(name: "mail_search", arguments: .object([
            "receivedAfter": .string(start.addingTimeInterval(250).ISO8601Format()),
            "receivedBefore": .string(start.addingTimeInterval(260).ISO8601Format()),
            "offset": .number(3), "limit": .number(4),
        ]))
        #expect(filtered["total"]?.intValue == 10)
        #expect(filtered["items"]?.arrayValue?.map { $0["messageID"]?.stringValue } == ["mail-256", "mail-255", "mail-254", "mail-253"])
        #expect(filtered["nextOffset"]?.intValue == 7)
    }

    @Test("atualiza com versão otimista e preserva destinatários e anexos")
    func updateRequiresCurrentVersionAndPreservesAttachments() async throws {
        let account = account("a")
        let attachment = MailAttachment(id: "a-1", filename: "contrato.pdf", mimeType: "application/pdf", byteCount: 32)
        let original = Message(
            id: "manual-draft", accountID: account.id,
            from: Contact(name: account.displayName, address: account.address),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Original", snippet: "Corpo antigo", body: ["Corpo antigo"], tags: [],
            bucket: .drafts, isRead: true, summary: nil, detectedEvent: nil,
            to: [Contact(name: "Ana", address: "ana@example.com")],
            cc: [Contact(name: "Bruno", address: "bruno@example.com")],
            bodyHTML: "", attachments: [attachment]
        )
        let port = RecordingDraftPort()
        let store = await loadedStore(
            source: DraftBackedMailSource(accounts: [account], messages: [original], port: port),
            draftPort: port
        )
        let tools = MailAgentTools(store: store)
        let read = try await tools.execute(name: "drafts_get", arguments: .object(["draftID": .string(original.id)]))
        let currentVersion = try #require(read["version"]?.stringValue)

        _ = try await tools.execute(name: "drafts_update", arguments: .object([
            "draftID": .string(original.id), "version": .string(currentVersion),
            "body": .string("Corpo novo"), "subject": .string("Atualizado"),
        ]))
        let updated = try #require(store.message(original.id))
        #expect(updated.subject == "Atualizado")
        #expect(updated.body == ["Corpo novo"])
        #expect(updated.to == original.to)
        #expect(updated.cc == original.cc)
        #expect(updated.attachments == [attachment])

        #expect(await conflicts {
            _ = try await tools.execute(name: "drafts_update", arguments: .object([
                "draftID": .string(original.id), "version": .string(currentVersion), "body": .string("Perdido"),
            ]))
        })
        #expect(store.message(original.id)?.body == ["Corpo novo"])
    }

    @Test("rascunho rico informa formatação e bloqueia atualização sem escrever")
    func richDraftCannotBeUpdatedByAgent() async throws {
        let account = account("a")
        let original = Message(
            id: "rich-draft", accountID: account.id,
            from: Contact(name: account.displayName, address: account.address),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Formatado", snippet: "Texto formatado", body: ["Texto formatado"], tags: [],
            bucket: .drafts, isRead: true, summary: nil, detectedEvent: nil,
            to: [Contact(name: "Ana", address: "ana@example.com")],
            bodyHTML: "<p>Texto <strong>formatado</strong></p><!-- okamiuni-signature:keep -->"
        )
        let port = RecordingDraftPort()
        let store = await loadedStore(
            source: DraftBackedMailSource(accounts: [account], messages: [original], port: port),
            draftPort: port
        )
        let tools = MailAgentTools(store: store)
        let read = try await tools.execute(name: "drafts_get", arguments: .object(["draftID": .string(original.id)]))
        let version = try #require(read["version"]?.stringValue)
        #expect(read["hasRichFormatting"]?.boolValue == true)

        await #expect(throws: AgentToolError.self) {
            _ = try await tools.execute(name: "drafts_update", arguments: .object([
                "draftID": .string(original.id), "version": .string(version), "body": .string("Texto substituído"),
            ]))
        }
        #expect(port.saveCount == 0)
        #expect(store.message(original.id)?.body == original.body)
        #expect(store.message(original.id)?.bodyHTML == original.bodyHTML)
    }

    @Test("drafts_get hidrata um rascunho frio e a versão lida atualiza sem conflito")
    func coldDraftLoadsBeforeReadingAndUsesHydratedVersionForUpdate() async throws {
        let account = account("a")
        let original = Message(
            id: "cold-draft", accountID: account.id,
            from: Contact(name: account.displayName, address: account.address),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Rascunho frio", snippet: "Prévia antiga", body: [], tags: [],
            bucket: .drafts, isRead: true, summary: nil, detectedEvent: nil,
            to: [Contact(name: "Ana", address: "ana@example.com")], bodyHTML: nil
        )
        let port = RecordingDraftPort()
        let bodyPort = LazyBodyPort(body: .success(FetchedBody(
            paragraphs: ["Corpo carregado da origem."], html: ""
        )))
        let store = await loadedStore(
            source: DraftBackedMailSource(accounts: [account], messages: [original], port: port),
            bodyPort: bodyPort, draftPort: port
        )
        let tools = MailAgentTools(store: store)

        let read = try await tools.execute(name: "drafts_get", arguments: .object(["draftID": .string(original.id)]))
        let hydratedVersion = try #require(read["version"]?.stringValue)
        #expect(read["body"]?.stringValue == "Corpo carregado da origem.")
        #expect(read["hasRichFormatting"]?.boolValue == false)
        #expect(await bodyPort.requests == [.init(accountID: account.id, messageID: original.id)])

        let saved = try await tools.execute(name: "drafts_update", arguments: .object([
            "draftID": .string(original.id), "version": .string(hydratedVersion),
            "body": .string("Corpo atualizado."),
        ]))
        #expect(saved["status"]?.stringValue == "saved")
        #expect(store.message(original.id)?.body == ["Corpo atualizado."])
        #expect(port.draft(original.id)?.body == ["Corpo atualizado."])
        #expect(await bodyPort.requests == [.init(accountID: account.id, messageID: original.id)])
    }

    @Test("a guarda de HTML rico é aplicada depois de hidratar o rascunho frio")
    func coldRichDraftIsBlockedAfterLoadingItsBody() async throws {
        let account = account("a")
        let original = Message(
            id: "cold-rich-draft", accountID: account.id,
            from: Contact(name: account.displayName, address: account.address),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Rascunho rico frio", snippet: "Prévia", body: [], tags: [],
            bucket: .drafts, isRead: true, summary: nil, detectedEvent: nil,
            to: [Contact(name: "Ana", address: "ana@example.com")], bodyHTML: nil
        )
        let port = RecordingDraftPort()
        let bodyPort = LazyBodyPort(body: .success(FetchedBody(
            paragraphs: ["Texto formatado."], html: "<p>Texto <strong>formatado</strong></p>"
        )))
        let store = await loadedStore(
            source: DraftBackedMailSource(accounts: [account], messages: [original], port: port),
            bodyPort: bodyPort, draftPort: port
        )
        let tools = MailAgentTools(store: store)

        let read = try await tools.execute(name: "drafts_get", arguments: .object(["draftID": .string(original.id)]))
        let version = try #require(read["version"]?.stringValue)
        #expect(read["hasRichFormatting"]?.boolValue == true)

        await #expect(throws: AgentToolError.self) {
            _ = try await tools.execute(name: "drafts_update", arguments: .object([
                "draftID": .string(original.id), "version": .string(version),
                "body": .string("Isso não pode apagar a assinatura."),
            ]))
        }
        #expect(port.saveCount == 0)
        #expect(store.message(original.id)?.bodyHTML == "<p>Texto <strong>formatado</strong></p>")
        #expect(await bodyPort.requests == [.init(accountID: account.id, messageID: original.id)])
    }

    @Test("mail_read_thread devolve falha quando o corpo sob demanda falha")
    func readingThreadFailsInsteadOfReturningPartialColdBody() async throws {
        let account = account("a")
        let original = Message(
            id: "cold-message", accountID: account.id,
            from: Contact(name: "Ana", address: "ana@example.com"),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Precisa carregar", snippet: "Prévia", body: [], tags: [],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil, bodyHTML: nil
        )
        let bodyPort = LazyBodyPort(body: .failure(LazyBodyPortError.unavailable))
        let store = await loadedStore(
            source: InMemoryMailSource(accounts: [account], messages: [original], agenda: []),
            bodyPort: bodyPort
        )
        let tools = MailAgentTools(store: store)

        do {
            _ = try await tools.execute(name: "mail_read_thread", arguments: .object(["messageID": .string(original.id)]))
            Issue.record("A leitura não pode devolver uma thread parcial quando a busca do corpo falha.")
        } catch let error as AgentToolError {
            guard case let .unavailable(reason) = error else {
                Issue.record("Esperava indisponibilidade do corpo, recebeu: \(error)")
                return
            }
            #expect(reason == "O corpo remoto não está disponível.")
        }
        #expect(await bodyPort.requests == [.init(accountID: account.id, messageID: original.id)])
    }

    @Test("argumentos inválidos não criam rascunho nem disparam envio")
    func invalidArgumentsDoNotPersistOrSend() async throws {
        let account = account("a")
        let port = RecordingDraftPort()
        let store = await loadedStore(
            source: DraftBackedMailSource(accounts: [account], messages: [], port: port),
            draftPort: port
        )
        let tools = MailAgentTools(store: store)

        await #expect(throws: AgentToolError.self) {
            _ = try await tools.execute(name: "drafts_create", arguments: draftCreate(
                accountID: account.id, subject: "Teste", body: "Texto", to: ["endereço quebrado"], requestID: "invalid-address"
            ))
        }
        await #expect(throws: AgentToolError.self) {
            _ = try await tools.execute(name: "drafts_create", arguments: .object([
                "accountID": .string(account.id), "subject": .string("Teste"), "body": .string("Texto"),
                "to": .array([]), "requestID": .string("extra"), "sendNow": .bool(true),
            ]))
        }
        #expect(port.saveCount == 0)
        #expect(store.messages.isEmpty)
        #expect(!store.canSend)
    }

    @Test("prepara reply e reply-all sem enviar, incluindo antigos Cc em Para")
    func preparesRepliesWithSafeRecipients() async throws {
        let account = account("a")
        let original = Message(
            id: "incoming", accountID: account.id,
            from: Contact(name: "Ana", address: "ana@example.com"), receivedAt: Date(),
            subject: "Projeto", snippet: "Vamos alinhar", body: ["Vamos alinhar"], tags: [],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil,
            to: [
                Contact(name: "Eu", address: account.address),
                Contact(name: "Bruno", address: "bruno@example.com"),
            ],
            cc: [
                Contact(name: "Carla", address: "carla@example.com"),
                Contact(name: "Ana", address: "ana@example.com"),
            ],
            rfcMessageID: "original@example.com"
        )
        let port = RecordingDraftPort()
        let store = await loadedStore(
            source: DraftBackedMailSource(accounts: [account], messages: [original], port: port),
            draftPort: port
        )
        let tools = MailAgentTools(store: store)

        let reply = try await tools.execute(name: "mail_prepare_reply", arguments: .object([
            "messageID": .string(original.id), "body": .string("Obrigado."), "requestID": .string("reply-1"),
        ]))
        let replyID = try #require(reply["draftID"]?.stringValue)
        #expect(store.message(replyID)?.to.map(\.address) == ["ana@example.com"])
        #expect(store.message(replyID)?.cc.isEmpty == true)
        #expect(reply["sent"]?.boolValue == false)

        let replyAll = try await tools.execute(name: "mail_prepare_reply", arguments: .object([
            "messageID": .string(original.id), "body": .string("Incluindo todos."),
            "replyAll": .bool(true), "requestID": .string("reply-all-1"),
        ]))
        let replyAllID = try #require(replyAll["draftID"]?.stringValue)
        let recipients = store.message(replyAllID)?.to.map(\.address)
        #expect(recipients == ["ana@example.com", "bruno@example.com", "carla@example.com"])
        // O seed move os Cc para Para para ninguém ficar escondido no composer.
        #expect(store.message(replyAllID)?.cc.isEmpty == true)
        #expect(!store.canSend)
    }

    @Test("falha de persistência não insere um rascunho apenas na memória")
    func failedPersistenceDoesNotInsertInMemoryDraft() async throws {
        let account = account("a")
        let port = RecordingDraftPort(failSaves: true)
        let store = await loadedStore(
            source: DraftBackedMailSource(accounts: [account], messages: [], port: port),
            draftPort: port
        )
        let tools = MailAgentTools(store: store)

        await #expect(throws: AgentToolError.self) {
            _ = try await tools.execute(name: "drafts_create", arguments: draftCreate(
                accountID: account.id, subject: "Não gravou", body: "Continua no editor", to: ["ana@example.com"], requestID: "disk-error"
            ))
        }
        #expect(port.saveCount == 1)
        #expect(port.allDrafts.isEmpty)
        #expect(store.messages.isEmpty)
        #expect(store.loadError != nil)
    }

    @Test("rascunho salvo produz cartão de revisão que abre somente o rascunho")
    func savedDraftCreatesReviewCard() async throws {
        let account = account("a")
        let port = RecordingDraftPort()
        let store = await loadedStore(
            source: DraftBackedMailSource(accounts: [account], messages: [], port: port),
            draftPort: port
        )
        let tools = MailAgentTools(store: store)

        let saved = try await tools.execute(name: "drafts_create", arguments: draftCreate(
            accountID: account.id, subject: "Para revisar", body: "Rascunho pronto", to: ["ana@example.com"], requestID: "review-card"
        ))
        let id = try #require(saved["draftID"]?.stringValue)
        #expect(tools.proposals.count == 1)
        #expect(tools.proposals.first?.actions == [.openMessage(messageID: id)])

        let card = try #require(AssistantProposalCard.cards(for: tools.proposals, turnID: "turn").first)
        #expect(card.secondaryMessageID == id)
        #expect(card.effects.count == 1)
        guard case let .command(.revealMessage(messageID)) = card.effects[0] else {
            Issue.record("O cartão de rascunho não revela a mensagem salva.")
            return
        }
        #expect(messageID == id)
    }

    private func loadedStore(
        source: some MailSource, bodyPort: BodyFetching? = nil, draftPort: MailDraftPort? = nil
    ) async -> MailStore {
        let store = MailStore(source: source, bodyPort: bodyPort, draftPort: draftPort)
        await store.load()
        return store
    }

    private func account(_ id: String) -> Account {
        Account(
            id: id, address: "me-\(id)@example.com", displayName: "Conta \(id)",
            provider: .imap, host: "mail.example.com", tintLightHex: "#000000", tintDarkHex: "#FFFFFF"
        )
    }

    private func message(id: String, account: Account, subject: String) -> Message {
        Message(
            id: id, accountID: account.id, from: Contact(name: "Remetente", address: "sender@\(account.id).example.com"),
            receivedAt: Date(), subject: subject, snippet: subject, body: [subject], tags: [],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil
        )
    }

    private func draftCreate(
        accountID: String, subject: String, body: String, to: [String], requestID: String
    ) -> AgentJSONValue {
        .object([
            "accountID": .string(accountID), "subject": .string(subject), "body": .string(body),
            "to": .array(to.map(AgentJSONValue.string)), "requestID": .string(requestID),
        ])
    }

    private func conflicts(_ action: () async throws -> Void) async -> Bool {
        do {
            try await action()
            return false
        } catch let error as AgentToolError {
            if case .conflict = error { return true }
            return false
        } catch {
            return false
        }
    }
}

private final class RecordingDraftPort: MailDraftPort, @unchecked Sendable {
    private let lock = NSLock()
    private let failSaves: Bool
    private var drafts: [String: Message] = [:]
    private var writes = 0

    init(failSaves: Bool = false) {
        self.failSaves = failSaves
    }

    func saveDraft(_ message: Message) throws {
        lock.withLock {
            writes += 1
            if failSaves { return }
            drafts[message.id] = message
        }
        if failSaves { throw RecordingDraftPortError.saveFailed }
    }

    func deleteDraft(id: String) throws {
        _ = lock.withLock { drafts.removeValue(forKey: id) }
    }

    func draft(_ id: String) -> Message? {
        lock.withLock { drafts[id] }
    }

    var allDrafts: [Message] {
        lock.withLock { Array(drafts.values) }
    }

    var saveCount: Int {
        lock.withLock { writes }
    }
}

private enum RecordingDraftPortError: Error {
    case saveFailed
}

private struct BodyRequest: Sendable, Equatable {
    let accountID: String
    let messageID: String
}

private actor LazyBodyPort: BodyFetching {
    private let body: Result<FetchedBody, any Error>
    private(set) var requests: [BodyRequest] = []

    init(body: Result<FetchedBody, any Error>) {
        self.body = body
    }

    func fetchBody(accountID: String, messageID: String) async throws -> FetchedBody {
        requests.append(.init(accountID: accountID, messageID: messageID))
        return try body.get()
    }
}

private enum LazyBodyPortError: LocalizedError {
    case unavailable

    var errorDescription: String? { "O corpo remoto não está disponível." }
}

private struct DraftBackedMailSource: MailSource {
    let storedAccounts: [Account]
    let storedMessages: [Message]
    let port: RecordingDraftPort

    init(accounts: [Account], messages: [Message], port: RecordingDraftPort) {
        self.storedAccounts = accounts
        self.storedMessages = messages
        self.port = port
    }

    func accounts() async throws -> [Account] { storedAccounts }

    func messages() async throws -> [Message] {
        storedMessages + port.allDrafts
    }

    func agenda() async throws -> [AgendaItem] { [] }

    func pendingItems() async throws -> [PendingItem] { [] }
}
