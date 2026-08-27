import Testing
import UNICore
@testable import UNIShell

@Suite("ReaderPane")
struct ReaderTests {

    /// O estado vazio do leitor ("Nada aqui. Bom sinal.") é para uma caixa
    /// vazia, não para a abertura do app: o protótipo abre em `selected: 'm1'`.
    /// Este teste trocou de sentido na Task P junto com esse defeito.
    @Test("o leitor só fica vazio quando a caixa está vazia")
    @MainActor
    func emptyOnlyWhenBoxIsEmpty() async {
        let full = MailStore(source: InMemoryMailSource.fixtures)
        await full.load()
        #expect(full.selectedMessage != nil)

        let empty = MailStore(source: InMemoryMailSource(accounts: [], messages: [], agenda: []))
        await empty.load()
        #expect(empty.selectedMessage == nil)
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
