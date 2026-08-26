import Foundation

/// Compromisso que o app encontrou dentro do corpo de uma mensagem.
/// No Marco 1 vem das fixtures; no Marco 5, do modelo no dispositivo.
public struct DetectedEvent: Sendable, Hashable {
    public let label: String        // "Call de contrato · qui 27, 15:00"
    public let start: Date
    public let duration: TimeInterval

    public init(label: String, start: Date, duration: TimeInterval) {
        self.label = label
        self.start = start
        self.duration = duration
    }

    public var end: Date { start.addingTimeInterval(duration) }
}
