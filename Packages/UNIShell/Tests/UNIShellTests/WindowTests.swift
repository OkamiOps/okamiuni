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

/// O rodapé da janela 04 — os dois botões que eram mudos.
///
/// "Email" tinha `ChromeButton(...) {}`: ação vazia, habilitado, sem `help`.
/// "Reagendar" idem, e sem tela de edição de agenda para onde levar — foi
/// **removido**; volta no Marco 4, com o EventKit.
@Suite("Janela 04 — rodapé")
@MainActor
struct EventWindowFooterTests {

    private func loaded() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    /// O botão leva ao mesmo lugar que "Ir para o email de origem" dos menus,
    /// e pela mesma regra: `ContextMenus.originMessageID`.
    @Test("«Email» aponta para a mesma mensagem que o item do menu de contexto")
    func emailButtonTargetsTheOriginMessage() async throws {
        let store = await loaded()
        let item = try #require(store.agenda.first { $0.id == "e2" })
        let detail = Fixtures.eventDetail(for: item.title)
        let expected = try #require(ContextMenus.originMessageID(for: detail, in: store.messages))

        let window = EventWindow(store: store, itemID: "e2")
        #expect(window.originMessageID == expected)
    }

    /// E ele **age**: revela a mensagem na janela principal, custe o que custar
    /// em filtros — é o que `MailStore.reveal` faz, e é o que a ação vazia não
    /// fazia. O cenário é o pior: outra conta filtrada, outra caixa aberta e
    /// uma busca que não casa.
    @Test("«Email» revela a mensagem de origem, desfazendo o que a escondia")
    func emailButtonRevealsTheMessage() async throws {
        let store = await loaded()
        let window = EventWindow(store: store, itemID: "e2")
        let target = try #require(window.originMessageID)
        let message = try #require(store.messages.first { $0.id == target })

        let other = try #require(store.accounts.first { $0.id != message.accountID })
        store.select(account: other.id)
        store.select(bucket: message.bucket == .today ? .later : .today)
        store.query = "zzz-nao-casa-com-nada"
        let before = store.revealCount
        #expect(store.selectedMessageID != target)

        window.revealOriginMessage()

        #expect(store.selectedMessageID == target)
        #expect(store.selectedAccountID == nil)
        #expect(store.bucket.contains(message))
        #expect(store.query.isEmpty)
        // E a janela principal fica sabendo: é por este contador que ela volta
        // para a aba Email, que é `@State` de outra cena.
        #expect(store.revealCount == before + 1)
    }

    /// Sem mensagem casada não há para onde ir, e o botão não pode fingir que
    /// há: a ação sai sem mexer em nada e o botão desenha apagado.
    @Test("sem mensagem de origem o botão não mexe em nada")
    func withoutOriginNothingHappens() async throws {
        let store = await loaded()
        // Um compromisso cujo detalhe não casa com assunto nenhum da caixa.
        let window = EventWindow(store: store, itemID: "nao-existe")
        #expect(window.originMessageID == nil)

        let before = store.revealCount
        window.revealOriginMessage()
        #expect(store.revealCount == before)
    }

    /// "Reagendar" saiu. O rodapé da 04 desenha **quatro** botões — Entrar,
    /// Encaminhar, Email e Fechar —, e o quinto, mudo, não está mais lá.
    ///
    /// Contado no desenho: numa varredura horizontal na altura dos botões, cada
    /// pastilha é um trecho de cor diferente do fundo do rodapé. Com o botão
    /// mudo de volta a mesma varredura dá cinco.
    @Test("o rodapé desenha quatro botões, sem o «Reagendar» mudo")
    func footerHasFourButtons() async throws {
        let store = await loaded()
        let rep = try #require(
            Render.snapshot(
                EventWindow(store: store, itemID: "e2").environment(ThemeStore()),
                named: "evento-04-rodape",
                size: CGSize(width: 560, height: 700),
                theme: .tinta
            )
        )
        #expect(Self.pills(in: rep, y: 670, width: 560) == 4)
    }

    /// Quantas pastilhas a linha `y` atravessa: cada entrada num trecho de cor
    /// diferente do fundo do rodapé conta uma.
    private static func pills(in rep: NSBitmapImageRep, y: Int, width: Int) -> Int {
        guard let background = rep.colorAt(x: 2, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        func differs(_ color: NSColor?) -> Bool {
            guard let c = color?.usingColorSpace(.sRGB) else { return false }
            return abs(c.redComponent - background.redComponent) > 0.01
                || abs(c.greenComponent - background.greenComponent) > 0.01
                || abs(c.blueComponent - background.blueComponent) > 0.01
        }
        var count = 0
        var inside = false
        for x in 0..<width {
            let now = differs(rep.colorAt(x: x, y: y))
            if now && !inside { count += 1 }
            inside = now
        }
        return count
    }
}
