import Testing
import UNICore
@testable import UNIShell

@Suite("ReaderPane")
struct ReaderTests {

    @Test("sem seleção não há o que ler")
    @MainActor
    func noSelection() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.selectedMessage == nil)
    }

    @Test("a mensagem m1 traz resumo e compromisso detectado")
    @MainActor
    func summaryAndEvent() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m1")

        let selected = try #require(store.selectedMessage)
        #expect(selected.summary?.isEmpty == false)
        let event = try #require(selected.detectedEvent)
        #expect(event.label.contains("15:00"))
        #expect(event.end > event.start)
    }

    @Test("a mensagem m2 não tem compromisso — a faixa não deve aparecer")
    @MainActor
    func noEvent() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m2")
        #expect(try #require(store.selectedMessage).detectedEvent == nil)
    }
}
