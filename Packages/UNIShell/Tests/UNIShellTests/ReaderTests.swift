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

    /// Antes apontava para `m2` pelo id. No design, `m2` é a cobrança da
    /// Hostinger e **tem** compromisso detectado ("Renovar domínio · 04 set");
    /// quem não tinha era a `m2` das fixtures antigas, que nem existe mais com
    /// esse conteúdo. O que o teste quer dizer não é "m2": é "uma mensagem sem
    /// compromisso", e agora ele pede exatamente isso.
    @Test("uma mensagem sem compromisso não mostra a faixa")
    @MainActor
    func noEvent() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)

        let withoutEvent = try #require(store.messages.first { $0.detectedEvent == nil })
        store.select(message: withoutEvent.id)
        #expect(try #require(store.selectedMessage).detectedEvent == nil)
    }

    /// A outra metade: as fixtures continuam tendo dos dois tipos. Sem isto, o
    /// teste acima passaria numa lista onde nenhuma mensagem tem compromisso.
    @Test("as fixtures têm mensagens com e sem compromisso detectado")
    @MainActor
    func bothKindsExist() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.messages.contains { $0.detectedEvent != nil })
        #expect(store.messages.contains { $0.detectedEvent == nil })
    }
}
