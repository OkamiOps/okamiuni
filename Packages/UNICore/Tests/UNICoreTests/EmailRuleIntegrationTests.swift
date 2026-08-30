import Foundation
import Testing
@testable import UNICore

@Suite("Regras chegando ao MailStore")
@MainActor
struct EmailRuleIntegrationTests {
    private struct SequenceSource: MailSource {
        let values: [MailSnapshot]

        func accounts() async throws -> [Account] { values.last?.accounts ?? [] }
        func messages() async throws -> [Message] { values.last?.messages ?? [] }
        func agenda() async throws -> [AgendaItem] { values.last?.agenda ?? [] }
        func pendingItems() async throws -> [PendingItem] { values.last?.pendingItems ?? [] }
        func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
            AsyncThrowingStream { continuation in
                for value in values { continuation.yield(value) }
                continuation.finish()
            }
        }
    }

    private final class CommandSpy: MailCommandPort, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var reads: [(Bool, [String])] = []
        private(set) var flags: [(Bool, [String])] = []
        private(set) var moves: [(TriageBucket, [String])] = []
        private(set) var placements: [(MailFolder, FolderPlacement, [String])] = []
        private(set) var gmailMoves: [(MailFolder, MailFolder, [String])] = []

        func setRead(_ isRead: Bool, accountID: String, messageIDs: [String]) throws {
            lock.withLock { reads.append((isRead, messageIDs)) }
        }
        func setFlagged(_ isFlagged: Bool, accountID: String, messageIDs: [String]) throws {
            lock.withLock { flags.append((isFlagged, messageIDs)) }
        }
        func move(to bucket: TriageBucket, accountID: String, messageIDs: [String]) throws {
            lock.withLock { moves.append((bucket, messageIDs)) }
        }
        func place(
            in folder: MailFolder, mode: FolderPlacement,
            accountID: String, messageIDs: [String]
        ) throws {
            lock.withLock { placements.append((folder, mode, messageIDs)) }
        }
        func moveGmailLabel(
            from source: MailFolder, to destination: MailFolder,
            accountID: String, messageIDs: [String]
        ) throws {
            lock.withLock { gmailMoves.append((source, destination, messageIDs)) }
        }
        func setAccountTint(lightHex: String, darkHex: String, accountID: String) throws {}
        func delete(accountID: String, messageIDs: [String]) throws {}
        func deletePermanently(accountID: String, messageIDs: [String]) throws {}
        func emptyTrash(accountID: String) throws {}
    }

    private final class SendSpy: MailSendPort, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sent: [OutgoingMessage] = []

        func send(_ message: OutgoingMessage) throws {
            lock.withLock { sent.append(message) }
        }
    }

    @Test("não reprocessa o histórico e aplica ações reais à próxima mensagem")
    func appliesOnlyToArrivals() async {
        let historical = Message.preview(id: "historica")
        let arrival = Message.preview(id: "nova")
        let source = SequenceSource(values: [
            MailSnapshot(
                accounts: Fixtures.accounts, messages: [historical],
                agenda: [], pendingItems: []
            ),
            MailSnapshot(
                accounts: Fixtures.accounts, messages: [historical, arrival],
                agenda: [], pendingItems: []
            ),
            // O mesmo retrato pode ser publicado mais de uma vez pelo banco;
            // a regra não pode enfileirar outra operação para o mesmo e-mail.
            MailSnapshot(
                accounts: Fixtures.accounts, messages: [historical, arrival],
                agenda: [], pendingItems: []
            ),
        ])
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                id: "clientes", name: "Clientes",
                condition: .senderContains("marina@clientepremium.com"),
                actions: [.markRead, .flag, .archive]
            )
        ])
        let commands = CommandSpy()
        let store = MailStore(source: source, commandPort: commands, emailRules: rules)

        await store.observe()
        await store.waitForPendingCommands()

        let old = store.messages.first { $0.id == historical.id }
        let new = store.messages.first { $0.id == arrival.id }
        #expect(old?.isRead == false)
        #expect(old?.isFlagged == false)
        #expect(old?.bucket == .today)
        #expect(new?.isRead == true)
        #expect(new?.isFlagged == true)
        #expect(new?.bucket == .archived)
        #expect(commands.reads.count == 1)
        #expect(commands.flags.count == 1)
        #expect(commands.moves.count == 1)
        #expect(commands.reads.first?.1 == ["nova"])
        #expect(commands.moves.first?.0 == .archived)
    }

    @Test("uma escolha manual contrária vence a confirmação pendente da regra")
    func manualOverrideClearsOnlyThePendingActions() async throws {
        let historical = Message.preview(id: "historica")
        let arrival = Message.preview(id: "nova")
        let source = SequenceSource(values: [
            MailSnapshot(
                accounts: Fixtures.accounts, messages: [historical],
                agenda: [], pendingItems: []
            ),
            MailSnapshot(
                accounts: Fixtures.accounts, messages: [historical, arrival],
                agenda: [], pendingItems: []
            ),
        ])
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                name: "Clientes", condition: .senderContains("marina@clientepremium.com"),
                actions: [.markRead, .flag, .archive]
            )
        ])
        let store = MailStore(source: source, commandPort: CommandSpy(), emailRules: rules)

        await store.observe()
        let transformed = try #require(store.messages.first { $0.id == arrival.id })
        store.setRead(false, for: transformed.id)
        store.setFlagged(false, for: transformed.id)
        store.move(transformed, to: .today)

        // Simula o banco ainda publicando o retrato anterior enquanto a fila
        // serial projeta a mudança manual para o servidor.
        store.apply(MailSnapshot(
            accounts: Fixtures.accounts, messages: [historical, arrival],
            agenda: [], pendingItems: []
        ))

        let current = try #require(store.messages.first { $0.id == arrival.id })
        #expect(!current.isRead)
        #expect(!current.isFlagged)
        #expect(current.bucket == .today)
    }

    @Test("mensagem enviada nunca dispara regra de entrada")
    func ignoresSentMail() async {
        let sent = Message.preview(id: "enviada", bucket: .sent)
        let source = SequenceSource(values: [
            MailSnapshot(accounts: Fixtures.accounts, messages: [], agenda: [], pendingItems: []),
            MailSnapshot(
                accounts: Fixtures.accounts, messages: [sent], agenda: [], pendingItems: []
            ),
        ])
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                name: "Não tocar enviadas", condition: .senderContains("marina"),
                actions: [.flag]
            )
        ])
        let commands = CommandSpy()
        let store = MailStore(source: source, commandPort: commands, emailRules: rules)

        await store.observe()
        await store.waitForPendingCommands()

        #expect(store.messages.first?.isFlagged == false)
        #expect(commands.flags.isEmpty)
    }

    @Test("Encaminha uma cópia segura somente uma vez por mensagem nova")
    func forwardsNewArrivalSafelyOnce() async throws {
        let historical = Message.preview(id: "historica")
        let arrival = Message.preview(id: "nova")
        let source = SequenceSource(values: [
            MailSnapshot(accounts: Fixtures.accounts, messages: [historical], agenda: [], pendingItems: []),
            MailSnapshot(accounts: Fixtures.accounts, messages: [historical, arrival], agenda: [], pendingItems: []),
            MailSnapshot(accounts: Fixtures.accounts, messages: [historical, arrival], agenda: [], pendingItems: []),
        ])
        let forwarding = try #require(EmailRuleForwarding(address: "arquivo@example.com"))
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                name: "Encaminhar clientes", condition: .senderContains("marina"), actions: [],
                accountID: "zoho", forwarding: forwarding
            )
        ])
        let send = SendSpy()
        let store = MailStore(source: source, sendPort: send, emailRules: rules)

        await store.observe()

        #expect(send.sent.count == 1)
        let message = try #require(send.sent.first)
        #expect(message.accountID == "zoho")
        #expect(message.from.address == "ricardo@empresa.com")
        #expect(message.to.map(\.address) == ["arquivo@example.com"])
        #expect(message.cc.isEmpty)
        #expect(message.bcc.isEmpty)
        #expect(message.attachments.isEmpty)
        #expect(message.subject == "Enc: Assunto")
        #expect(message.plainText.contains("Mensagem encaminhada"))
    }

    @Test("Não autoencaminha para uma conta local nem de volta ao remetente")
    func refusesForwardingLoops() async throws {
        let historical = Message.preview(id: "historica")
        let arrival = Message.preview(id: "nova")
        let source = SequenceSource(values: [
            MailSnapshot(accounts: Fixtures.accounts, messages: [historical], agenda: [], pendingItems: []),
            MailSnapshot(accounts: Fixtures.accounts, messages: [historical, arrival], agenda: [], pendingItems: []),
        ])
        let ownAddress = try #require(EmailRuleForwarding(address: "ricardo@empresa.com"))
        let senderAddress = try #require(EmailRuleForwarding(address: "marina@clientepremium.com"))
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                name: "Não para mim", condition: .senderContains("marina"), actions: [],
                accountID: "zoho", forwarding: ownAddress
            ),
            EmailRule(
                name: "Não para remetente", condition: .senderContains("marina"), actions: [],
                accountID: "zoho", forwarding: senderAddress
            ),
        ])
        let send = SendSpy()
        let store = MailStore(source: source, sendPort: send, emailRules: rules)

        await store.observe()

        #expect(send.sent.isEmpty)
    }

    @Test("Move pela semântica real de IMAP e Gmail")
    func movesWithProviderDestination() async throws {
        let imapTarget = MailFolder(
            id: "zoho/Projetos", accountID: "zoho", serverName: "Projetos",
            displayName: "Projetos", role: .other
        )
        let gmailInbox = MailFolder(
            id: "gmail/INBOX", accountID: "gmail", serverName: "INBOX",
            displayName: "Entrada", role: .inbox
        )
        let gmailTarget = MailFolder(
            id: "gmail/Label_42", accountID: "gmail", serverName: "Label_42",
            displayName: "Clientes", role: .other
        )
        let historical = Message.preview(id: "historica")
        let imapArrival = Message.preview(id: "imap-nova").withFolderIDs(["zoho/INBOX"])
        let gmailArrival = Message(
            id: "gmail-nova", accountID: "gmail",
            from: Contact(name: "Marina", address: "marina@clientepremium.com"),
            receivedAt: Fixtures.today, subject: "Assunto", snippet: "Trecho", body: ["Corpo"],
            tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil,
            folderIDs: [gmailInbox.id]
        )
        let gmailDestination = try #require(
            SwipeMoveDestination(gmailLabel: gmailTarget, removing: gmailInbox)
        )
        let source = SequenceSource(values: [
            MailSnapshot(accounts: Fixtures.accounts, messages: [historical], agenda: [], pendingItems: []),
            MailSnapshot(
                accounts: Fixtures.accounts,
                messages: [historical, imapArrival, gmailArrival], agenda: [], pendingItems: [],
                folders: [imapTarget, gmailInbox, gmailTarget]
            ),
        ])
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                name: "IMAP", condition: .subjectContains("assunto"), actions: [],
                accountID: "zoho", moveDestination: SwipeMoveDestination(imapFolder: imapTarget)
            ),
            EmailRule(
                name: "Gmail", condition: .subjectContains("assunto"), actions: [],
                accountID: "gmail", moveDestination: gmailDestination
            ),
        ])
        let commands = CommandSpy()
        let store = MailStore(source: source, commandPort: commands, emailRules: rules)

        await store.observe()
        await store.waitForPendingCommands()

        #expect(commands.placements.count == 1)
        #expect(commands.placements.first?.0 == imapTarget)
        #expect(commands.placements.first?.1 == .move)
        #expect(commands.placements.first?.2 == ["imap-nova"])
        #expect(commands.gmailMoves.count == 1)
        #expect(commands.gmailMoves.first?.0 == gmailInbox)
        #expect(commands.gmailMoves.first?.1 == gmailTarget)
        #expect(commands.gmailMoves.first?.2 == ["gmail-nova"])
    }
}
