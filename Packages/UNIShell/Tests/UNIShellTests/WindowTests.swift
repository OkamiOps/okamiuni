import Testing
import SwiftUI
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Janelas")
struct WindowTests {

    /// Trava os tamanhos escritos no protótipo. Cada número vem de uma linha
    /// citada no brief; se alguém "arredondar" um deles, isto acusa.
    @Test("os tamanhos são os do protótipo")
    func sizes() {
        #expect(UNIWindow.Size.composer == CGSize(width: 820, height: 660))    // 03, linha 790
        #expect(UNIWindow.Size.newMessage == CGSize(width: 820, height: 620))  // 06, linha 368
        #expect(UNIWindow.Size.message == CGSize(width: 800, height: 600))     // 05, linha 745
        #expect(UNIWindow.Size.event.width == 560)                             // 04, linha 590
    }

    @Test("cada janela tem seu identificador de cena")
    func distinctSceneIDs() {
        let ids = [UNIWindow.composer, UNIWindow.newMessage, UNIWindow.message, UNIWindow.event]
        #expect(Set(ids).count == ids.count)
    }

    @Test("o título da barra distingue responder de escrever do zero")
    @MainActor
    func composerTitle() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })

        #expect(ComposerWindow.windowTitle(replyingTo: message)
                == "Re: Revisão do contrato — podemos fechar quinta?")
        // 06 não responde a ninguém.
        #expect(ComposerWindow.windowTitle(replyingTo: nil) == "Nova mensagem")
    }

    @Test("responder a uma mensagem que sumiu não vira 'Re: '")
    func composerTitleWithoutSubject() {
        let ghost = Message(
            id: "x", accountID: "zoho",
            from: Contact(name: "", address: ""), receivedAt: .now,
            subject: "", snippet: "", body: [], tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil
        )
        #expect(ComposerWindow.windowTitle(replyingTo: ghost) == "Nova mensagem")
    }

    @Test("a linha do organizador separa nome e endereço por cor")
    func organizerLine() {
        let line = EventWindow.organizerLine(
            name: "Marina Duarte", address: "marina@clientepremium.com",
            ink: .black, ink3: .gray
        )
        #expect(String(line.characters) == "Marina Duarte · marina@clientepremium.com")

        let colors = line.runs.map(\.foregroundColor)
        #expect(colors == [.black, .gray])
    }

    /// A trilha de agenda é o gatilho da janela 04: o compromisso clicado tem de
    /// levar consigo um detalhe que a tela sabe desenhar.
    @Test("cada compromisso da trilha resolve um detalhe para a janela 04")
    @MainActor
    func everyRailItemHasDetail() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(!store.agenda.isEmpty)

        for item in store.agenda {
            let detail = Fixtures.eventDetail(for: item.title)
            // O organizador é o único campo que a tela nunca pode não ter:
            // o roster começa nele.
            #expect(!detail.organizer.name.isEmpty)
            #expect(detail.guestCount >= 1)
        }

        // E o que o protótipo de fato descreve chega inteiro:
        let oneOnOne = try #require(store.agenda.first { $0.id == "e2" })
        let detail = Fixtures.eventDetail(for: oneOnOne.title)
        #expect(detail.hasLink)
        #expect(detail.agenda.count == 3)
        #expect(oneOnOne.rangeLabel == "11:00 – 11:45")
    }
}
