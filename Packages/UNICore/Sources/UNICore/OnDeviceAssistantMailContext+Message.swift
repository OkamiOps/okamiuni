import Foundation

public extension OnDeviceAssistantEmailContext {
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
            body: paragraphs.isEmpty ? message.snippet : paragraphs.joined(separator: "\n\n")
        )
    }
}

public extension OnDeviceAssistantMailContext {
    init(message: Message) {
        self = .email(OnDeviceAssistantEmailContext(message: message))
    }

    /// `Conversation.messages` já vem da mais antiga para a mais nova.
    init(conversation: Conversation) {
        self = .conversation(conversation.messages.map(OnDeviceAssistantEmailContext.init(message:)))
    }
}
