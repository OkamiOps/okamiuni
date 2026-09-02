import Foundation
import Testing
@testable import UNISync

@Suite("Cache da descoberta de CLIs")
struct CachedAssistantCLIDiscoveryTests {
    @Test("dez chamadas em menos de 60 s varrem o disco uma vez")
    func scansOncePerWindow() {
        let clock = Clock()
        let counter = Counter()
        let cache = CachedAssistantCLIDiscovery(
            discovery: AssistantCLIDiscovery(
                environment: ["PATH": "/usr/bin"],
                homeDirectory: "/tmp/casa",
                bundleResourceDirectory: nil,
                isExecutable: { _ in counter.bump(); return false }
            ),
            validity: 60,
            now: { clock.now }
        )
        for _ in 0..<10 { _ = cache.installations() }
        let afterTen = counter.value
        #expect(afterTen > 0)

        clock.advance(59)
        _ = cache.installations()
        #expect(counter.value == afterTen)

        clock.advance(2)
        _ = cache.installations()
        #expect(counter.value > afterTen)
    }

    @Test("salvar Ajustes invalida o cache na hora")
    func invalidateForcesRescan() {
        let clock = Clock()
        let counter = Counter()
        let cache = CachedAssistantCLIDiscovery(
            discovery: AssistantCLIDiscovery(
                environment: ["PATH": "/usr/bin"],
                homeDirectory: "/tmp/casa",
                bundleResourceDirectory: nil,
                isExecutable: { _ in counter.bump(); return false }
            ),
            validity: 60,
            now: { clock.now }
        )
        _ = cache.installations()
        let first = counter.value
        _ = cache.installations()
        #expect(counter.value == first)

        cache.invalidate()
        _ = cache.installations()
        #expect(counter.value > first)
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0
        var now: Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
        func advance(_ value: TimeInterval) { lock.withLock { seconds += value } }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }
}
