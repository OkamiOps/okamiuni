import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Faixa de resposta rápida — abertura e retorno")
struct QuickReplyBandStateTests {

    private static let sender = Contact(name: "Marina Duarte", address: "marina@clientepremium.com")

    @Test("sem rascunho, a faixa nasce aberta e já com o remetente no Para")
    func freshBandStartsOpen() {
        #expect(QuickReplyBand.opensExpanded(for: nil))
        #expect(
            QuickReplyBand.seededRecipients(draft: nil, sender: Self.sender)
                .map(\.address) == ["marina@clientepremium.com"]
        )
    }

    @Test("depois de 'Responder aqui' a faixa volta fechada, mostrando o que guardou")
    func afterReplyHereItStaysClosed() {
        let saved = ReplyDraft(
            to: [Self.sender], text: "Fecho quinta.",
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(QuickReplyBand.opensExpanded(for: saved) == false)
    }

    @Test("rascunho ainda não guardado reabre aberto, no ponto em que parou")
    func unsavedDraftReopensOpen() {
        let typing = ReplyDraft(to: [Self.sender], text: "Fecho qui", savedAt: nil)
        #expect(QuickReplyBand.opensExpanded(for: typing))
        #expect(
            QuickReplyBand.seededRecipients(draft: typing, sender: Self.sender)
                .map(\.address) == ["marina@clientepremium.com"]
        )
    }

    @Test("quem apagou o destinatário não o recebe de volta")
    func clearedRecipientStaysCleared() {
        let emptied = ReplyDraft(to: [], text: "para quem eu decidir depois", savedAt: nil)
        #expect(QuickReplyBand.seededRecipients(draft: emptied, sender: Self.sender).isEmpty)
    }

    @Test("o retorno de 'Responder aqui' diz o que aconteceu com o rascunho")
    func savedNoteIsExplicit() {
        #expect(
            QuickReplyBand.savedNote(words: "4 palavras", stamp: "14:32")
                == "Resposta guardada — 4 palavras · 14:32"
        )
    }
}

@Suite("Faixa de resposta rápida — o corpo continua legível")
@MainActor
struct QuickReplyBandRenderTests {

    private static let size = CGSize(width: 760, height: 780)

    /// Quantos pixels de tinta há na faixa horizontal entre `top` e `bottom`.
    ///
    /// É a pergunta "o corpo da mensagem continua aparecendo?" em forma de
    /// número: se a faixa de resposta tivesse comido o leitor, ou se o corpo
    /// tivesse ficado atrás dela, esta região seria fundo liso.
    private static func inkPixels(
        _ rep: NSBitmapImageRep, top: CGFloat, bottom: CGFloat,
        left: Int = 40, right: Int? = nil
    ) -> Int {
        let first = Int(CGFloat(rep.pixelsHigh) * top)
        let last = Int(CGFloat(rep.pixelsHigh) * bottom)
        var count = 0
        for y in stride(from: first, to: last, by: 2) {
            for x in stride(from: left, to: right ?? (rep.pixelsWide - 40), by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // Tema claro: a tinta do texto é escura sobre papel claro.
                if color.brightnessComponent < 0.55 { count += 1 }
            }
        }
        return count
    }

    /// Quantos pixels diferem entre dois desenhos, dentro de um retângulo.
    private static func differingPixels(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
        x: ClosedRange<Int>, y: ClosedRange<Int>
    ) -> Int {
        var count = 0
        for row in y where row < min(a.pixelsHigh, b.pixelsHigh) {
            for column in x where column < min(a.pixelsWide, b.pixelsWide) {
                guard let left = a.colorAt(x: column, y: row),
                      let right = b.colorAt(x: column, y: row) else { continue }
                if abs(left.brightnessComponent - right.brightnessComponent) > 0.02 {
                    count += 1
                }
            }
        }
        return count
    }

    private func reader(_ store: MailStore) -> some View {
        ReaderPane(store: store, onAddEvent: { _ in }, onReply: { _ in })
            .environment(ThemeStore())
    }

    /// A altura que a faixa **pede** com a largura dada. Mede o layout de
    /// verdade, sem janela e sem foco: é `NSHostingView` fora de qualquer tela.
    private static func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(
            rootView: view.theme(.tinta).environment(ThemeStore()).frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("com a faixa aberta, o corpo da mensagem ainda ocupa o meio do leitor")
    func bodyStaysReadableWithBandOpen() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(message: "m1")

        let rep = try #require(
            Render.snapshot(
                reader(store), named: "leitor-faixa-aberta",
                size: Self.size, theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 760)
        #expect(rep.pixelsHigh == 780)
        // A faixa aberta ocupa o terço de baixo; o corpo tem de continuar
        // desenhando texto entre o cabeçalho e ela.
        #expect(Self.inkPixels(rep, top: 0.28, bottom: 0.50) > 500)
    }

    @Test("com a faixa fechada, o corpo ganha o espaço de volta")
    func bodyGrowsWithBandClosed() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(message: "m1")
        store.setReplyDraft(
            ReplyDraft(
                to: [Contact(name: "Marina Duarte", address: "marina@clientepremium.com")],
                text: "Quinta às 15h está de pé aqui.",
                savedAt: Date(timeIntervalSince1970: 1_000)
            ),
            for: "m1"
        )

        let rep = try #require(
            Render.snapshot(
                reader(store), named: "leitor-faixa-fechada",
                size: Self.size, theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 760)
        #expect(rep.pixelsHigh == 780)
        // O corpo continua desenhando texto no mesmo lugar de antes…
        #expect(Self.inkPixels(rep, top: 0.28, bottom: 0.50) > 500)
        // …e o parágrafo que a faixa aberta empurrava para fora agora aparece.
        #expect(Self.inkPixels(rep, top: 0.57, bottom: 0.67) > 200)
    }

    @Test("a faixa vive no rodapé: abrir e fechar não mexe no corpo da mensagem")
    func bandLivesInTheFooter() async throws {
        func render(saved: Bool, named: String) async throws -> NSBitmapImageRep {
            let store = MailStore(source: InMemoryMailSource.fixtures)
            await store.load()
            store.select(message: "m1")
            if saved {
                store.setReplyDraft(
                    ReplyDraft(
                        to: [Contact(name: "Marina Duarte", address: "marina@clientepremium.com")],
                        text: "Quinta às 15h está de pé aqui.",
                        savedAt: Date(timeIntervalSince1970: 1_000)
                    ),
                    for: "m1"
                )
            }
            return try #require(
                Render.snapshot(reader(store), named: named, size: Self.size, theme: .tinta)
            )
        }

        let open = try await render(saved: false, named: "leitor-faixa-aberta")
        let closed = try await render(saved: true, named: "leitor-faixa-fechada")

        // Do fim do cabeçalho até 420pt é corpo de mensagem nos dois estados, e
        // tem de ser o **mesmo** desenho: a faixa mora embaixo. Se ela subisse
        // para cima do corpo — ou o cobrisse — estes pixels divergiriam.
        #expect(Self.differingPixels(open, closed, x: 40...720, y: 150...420) == 0)

        // E o rodapé é justamente onde os dois têm de divergir: aberta ali há
        // campo, editor e botões; fechada, uma linha de confirmação.
        #expect(Self.differingPixels(open, closed, x: 40...720, y: 560...740) > 5_000)
    }

    @Test("a faixa fechada devolve mais de 150pt de altura ao corpo")
    func closedBandIsMuchShorter() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })

        let openHeight = Self.fittingHeight(
            QuickReplyBand(store: store, message: message, onPromote: { _ in }),
            width: 700
        )

        store.setReplyDraft(
            ReplyDraft(
                to: [message.from], text: "Quinta às 15h está de pé aqui.",
                savedAt: Date(timeIntervalSince1970: 1_000)
            ),
            for: message.id
        )
        let closedHeight = Self.fittingHeight(
            QuickReplyBand(store: store, message: message, onPromote: { _ in }),
            width: 700
        )

        // Números do protótipo: editor de 110 + linha "Para" + rodapé + meta,
        // dentro do `padding: 10px 28px 16px` da faixa.
        #expect(openHeight > 230)
        // A confirmação fechada é uma linha só.
        #expect(closedHeight < 90)
        #expect(openHeight - closedHeight > 150)
    }

    @Test("o menu de sugestões desenha as linhas do catálogo")
    func suggestionMenuRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })
        let size = CGSize(width: 700, height: 460)

        // O papel por baixo é explícito: sem ele a área que a faixa não ocupa
        // sai preta no bitmap, e "preto" conta como tinta na contagem abaixo.
        func band(query: String?) -> some View {
            QuickReplyBand(
                store: store, message: message, onPromote: { _ in }, seededQuery: query
            )
            .environment(ThemeStore())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.tinta.surface.color)
        }

        let closed = try #require(
            Render.snapshot(band(query: nil), named: "faixa-sem-menu", size: size, theme: .tinta)
        )
        let open = try #require(
            Render.snapshot(band(query: "a"), named: "faixa-sugestoes", size: size, theme: .tinta)
        )
        #expect(open.pixelsWide == 700)

// O menu é uma sobreposição: ele não muda o tamanho de nada, então a
        // pergunta certa é "o retângulo dele mudou de conteúdo?". Sem menu esse
        // pedaço é a área de escrita vazia; com menu são cinco linhas de
        // contato desenhadas por cima dela.
        let insideMenu = Self.differingPixels(
            closed, open, x: 90...370, y: 50...265
        )
        #expect(insideMenu > 2_000)

        // E a mudança fica onde deve: fora do menu, os dois desenhos são iguais.
        let outsideMenu = Self.differingPixels(
            closed, open, x: 420...680, y: 300...440
        )
        #expect(outsideMenu == 0)
    }

    @Test("a faixa escura desenha com os mesmos tokens")
    func darkThemeRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(message: "m1")
        let dark = try #require(Theme.all.first { $0.isDark })

        let rep = try #require(
            Render.snapshot(
                reader(store), named: "leitor-faixa-aberta-escuro",
                size: Self.size, theme: dark
            )
        )
        #expect(rep.pixelsHigh == 780)
    }
}
