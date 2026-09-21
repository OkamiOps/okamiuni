import UNICore

/// The same production ports are shared by every interactive assistant surface.
public struct AgentApplicationServices: Sendable {
    public let attachments: (any AgentAttachmentReading)?
    public let search: (any AgentMailSearching)?
    public let calendar: (any AgentCalendarManaging)?

    public init(attachments: (any AgentAttachmentReading)? = nil,
                search: (any AgentMailSearching)? = nil,
                calendar: (any AgentCalendarManaging)? = nil) {
        self.attachments = attachments
        self.search = search
        self.calendar = calendar
    }

    @MainActor
    public func tools(store: MailStore, open: (@MainActor @Sendable (String) -> Void)? = nil) -> MailAgentTools {
        MailAgentTools(store: store, open: open, attachmentReader: attachments, mailSearch: search, calendar: calendar, htmlSanitizer: { try MimeSanitize.sanitizeDraft(html: $0) })
    }
}
