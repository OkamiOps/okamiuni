import Foundation
import Observation

/// De onde as mensagens vêm. No Marco 1 só existe a implementação em memória;
/// no Marco 2, Gmail, Graph e IMAP passam a conformar a este mesmo protocolo
/// e a UI não muda.
public protocol MailSource: Sendable {
    func accounts() async throws -> [Account]
    func messages() async throws -> [Message]
    func agenda() async throws -> [AgendaItem]
}

public struct InMemoryMailSource: MailSource {
    private let _accounts: [Account]
    private let _messages: [Message]
    private let _agenda: [AgendaItem]

    public init(accounts: [Account], messages: [Message], agenda: [AgendaItem]) {
        self._accounts = accounts
        self._messages = messages
        self._agenda = agenda
    }

    public static var fixtures: InMemoryMailSource {
        InMemoryMailSource(
            accounts: Fixtures.accounts,
            messages: Fixtures.messages,
            agenda: Fixtures.agenda
        )
    }

    public func accounts() async throws -> [Account] { _accounts }
    public func messages() async throws -> [Message] { _messages }
    public func agenda() async throws -> [AgendaItem] { _agenda }
}

@MainActor
@Observable
public final class MailStore {
    public private(set) var accounts: [Account] = []
    public private(set) var messages: [Message] = []
    public private(set) var agenda: [AgendaItem] = []

    public private(set) var bucket: TriageBucket = .today
    public private(set) var selectedMessageID: String?
    public var query: String = ""
    public private(set) var loadError: String?

    private let source: MailSource

    public init(source: MailSource) {
        self.source = source
    }

    public func load() async {
        do {
            accounts = try await source.accounts()
            messages = try await source.messages()
            agenda = try await source.agenda().sorted { $0.startMinute < $1.startMinute }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Mensagens da caixa atual que casam com a busca, mais recentes primeiro.
    public var visibleMessages: [Message] {
        let inBucket = messages.filter { bucket.contains($0) }
        let searched = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? inBucket
            : inBucket.filter { matches($0, query) }
        return searched.sorted { $0.receivedAt > $1.receivedAt }
    }

    private func matches(_ message: Message, _ term: String) -> Bool {
        [message.from.name, message.from.address, message.subject, message.snippet]
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }

    public var selectedMessage: Message? {
        guard let selectedMessageID else { return nil }
        return messages.first { $0.id == selectedMessageID }
    }

    public func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    public func select(bucket newBucket: TriageBucket) {
        bucket = newBucket
        // Uma seleção que saiu da visão deixa o leitor mostrando algo que a
        // lista não contém mais. Melhor limpar.
        if let selected = selectedMessage, !newBucket.contains(selected) {
            selectedMessageID = nil
        }
    }

    public func select(message id: String) {
        selectedMessageID = id
        markRead(id)
    }

    private func markRead(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              !messages[index].isRead else { return }
        let m = messages[index]
        messages[index] = Message(
            id: m.id, accountID: m.accountID, from: m.from, receivedAt: m.receivedAt,
            subject: m.subject, snippet: m.snippet, body: m.body, tags: m.tags,
            bucket: m.bucket, isRead: true, summary: m.summary,
            detectedEvent: m.detectedEvent
        )
    }

    /// Contagem por caixa, para os contadores da barra lateral.
    public func count(for bucket: TriageBucket) -> Int {
        messages.filter { bucket.contains($0) }.count
    }
}
