import Foundation

public extension AssistantEmailContext {
    /// Traduz o modelo de e-mail do app para a fronteira factual do assistente.
    init(message: Message) {
        let paragraphs = message.body
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        self.init(
            subject: message.subject,
            sender: message.from.display,
            recipients: (message.to + message.cc).map(\.display),
            sentAt: message.receivedAt,
            body: paragraphs.isEmpty ? message.snippet : paragraphs.joined(separator: "\n\n"),
            html: message.hasHTML ? message.bodyHTML : nil
        )
    }
}

public extension AssistantMailContext {
    init(message: Message) {
        self = .email(AssistantEmailContext(message: message))
    }

    /// `Conversation.messages` já vem da mais antiga para a mais nova.
    init(conversation: Conversation) {
        self = .conversation(conversation.messages.map(AssistantEmailContext.init(message:)))
    }

    /// Constrói o retrato do botão global. A seleção atual fica deliberadamente
    /// de fora: este caminho representa o ambiente do app, não o e-mail aberto.
    @MainActor
    init(workspace store: MailStore) {
        let emails = store.messages
            .sorted { lhs, rhs in
                if lhs.isFlagged != rhs.isFlagged { return lhs.isFlagged }
                if lhs.isRead != rhs.isRead { return !lhs.isRead }
                return lhs.receivedAt > rhs.receivedAt
            }
            .map { message in
                AssistantWorkspaceEmailContext(
                    id: message.id,
                    account: store.account(message.accountID)?.address ?? message.accountID,
                    mailbox: message.bucket.label,
                    isRead: message.isRead,
                    isFlagged: message.isFlagged,
                    subject: message.subject,
                    sender: message.from.display,
                    recipients: (message.to + message.cc).map(\.display),
                    sentAt: message.receivedAt,
                    snippet: message.snippet
                )
        }
        let mailboxes = TriageBucket.allCases.map { bucket in
            let messages = store.messages.filter { store.includes($0, in: bucket) }
            return AssistantMailboxContext(
                name: bucket.label,
                totalCount: messages.count,
                unreadCount: messages.filter { !$0.isRead }.count
            )
        }
        let agenda = store.agenda
            .sorted {
                let lhs = ($0.dayOffset, $0.startMinute, $0.title)
                let rhs = ($1.dayOffset, $1.startMinute, $1.title)
                return lhs < rhs
            }
            .map { item in
                let place = item.detail?.place.trimmingCharacters(in: .whitespacesAndNewlines)
                return AssistantAgendaContext(
                    title: item.title,
                    date: store.agendaDate(for: item),
                    startMinute: item.startMinute,
                    endMinute: item.endMinute,
                    account: store.account(item.accountID)?.address ?? item.accountID,
                    place: place?.isEmpty == false ? place : nil
                )
            }
        let accounts = store.accounts.map { account in
            "\(account.displayName) · \(account.address) · \(account.host)"
        }
        let pendingItems = store.pendingItems.map { item in
            AssistantPendingContext(
                text: item.text,
                account: store.account(item.accountID)?.address ?? item.accountID
            )
        }

        self = .workspace(AssistantWorkspaceContext(
            accounts: accounts,
            emailCount: store.messages.count,
            unreadCount: store.messages.filter { !$0.isRead }.count,
            mailboxes: mailboxes,
            emails: emails,
            agenda: agenda,
            pendingItems: pendingItems
        ))
    }
}
