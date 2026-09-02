import Foundation

/// A varredura toca dezenas de caminhos do disco. Fazê-la a cada pergunta
/// é um custo por tecla; guardá-la para sempre faria "instalei o Codex
/// agora" precisar de reinício. Sessenta segundos, e `invalidate()` ao
/// salvar Ajustes, resolvem os dois lados.
public final class CachedAssistantCLIDiscovery: @unchecked Sendable {
    public static let validity: TimeInterval = 60

    private let lock = NSLock()
    private let discovery: AssistantCLIDiscovery
    private let validity: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: [AssistantCLIInstallation]?
    private var scannedAt: Date?

    public init(
        discovery: AssistantCLIDiscovery = .init(),
        validity: TimeInterval = CachedAssistantCLIDiscovery.validity,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.discovery = discovery
        self.validity = validity
        self.now = now
    }

    public func installations() -> [AssistantCLIInstallation] {
        let instant = now()
        lock.lock()
        if let cached, let scannedAt, instant.timeIntervalSince(scannedAt) < validity {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // A varredura fica fora do lock: ela toca disco, e prender o
        // cofre durante I/O transformaria uma pergunta lenta em duas.
        let scanned = discovery.scan()
        lock.lock()
        cached = scanned
        scannedAt = instant
        lock.unlock()
        return scanned
    }

    public func invalidate() {
        lock.lock()
        cached = nil
        scannedAt = nil
        lock.unlock()
    }
}
