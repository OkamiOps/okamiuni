import Foundation

/// Um compromisso na trilha lateral. `startMinute` e `endMinute` são minutos
/// desde a meia-noite, como o protótipo modela (`s: 570, e: 600`).
public struct AgendaItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let startMinute: Int
    public let endMinute: Int
    public let accountID: String

    public init(
        id: String, title: String,
        startMinute: Int, endMinute: Int, accountID: String
    ) {
        self.id = id
        self.title = title
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.accountID = accountID
    }

    public var durationMinutes: Int { endMinute - startMinute }

    /// "09:30"
    public var startLabel: String {
        String(format: "%02d:%02d", startMinute / 60, startMinute % 60)
    }
}
