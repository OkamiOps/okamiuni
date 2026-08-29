import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A seção "O que gerou este compromisso", aberta, mostra o **email**.
///
/// O defeito, do print do dono: expandida, a seção mostrava a linha do email
/// (quem escreveu, o assunto, a data) e a nota de origem — o cabeçalho do
/// email, e nada do que ele dizia. Agora vêm os primeiros parágrafos do texto
/// plano, na tipografia do leitor, e um "Abrir no leitor" que leva ao resto.
@Suite("Janela 04 — o que gerou, aberto")
@MainActor
struct EventOriginPreviewTests {

    private static let tamanho = CGSize(width: 560, height: 700)

    /// Uma caixa com uma mensagem `m1` e um compromisso `email-m1` nascido
    /// dela — é o `id` que faz `originMessageID` casar os dois sem adivinhar
    /// assunto (ver `DetectedEventConversion.messageID(forAgendaID:)`).
    private static func loja(corpo: [String]) async -> MailStore {
        let mensagem = Message(
            id: "m1", accountID: "zoho",
            from: Contact(name: "Favini", address: "favini@vantion.com.br"),
            receivedAt: Fixtures.today, subject: "Convite: DreamSquad <> Vantion",
            snippet: "Confirma quinta?", body: corpo, tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil
        )
        let detalhe = EventDetail(
            place: EventPlace.semLocal, link: nil,
            organizer: EventPerson(
                name: "Favini", address: "favini@vantion.com.br",
                role: "organizador", status: .yes
            ),
            people: [],
            note: "Do convite por email · conta vantion",
            recurrence: "Evento único", notice: "Sem alerta",
            agenda: [],
            thread: [
                EventThreadEntry(
                    when: "21 de jul., 14:30", who: "Favini",
                    what: "Convite: DreamSquad <> Vantion", kind: .email
                )
            ],
            descricao: nil
        )
        let item = AgendaItem(
            id: "email-m1", title: "DreamSquad", startMinute: 594, endMinute: 644,
            accountID: "zoho", dayOffset: 0,
            calendarUID: "u1", calendarSequence: 0, detail: detalhe
        )
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: Fixtures.accounts, messages: [mensagem], agenda: [item]
            )
        )
        await store.load()
        return store
    }

    private static func janela(corpo: [String]) async -> NSBitmapImageRep? {
        let store = await loja(corpo: corpo)
        return Render.bitmap(
            EventWindow(store: store, itemID: "email-m1", debugSections: EventSections(origin: true)),
            size: tamanho, theme: .tinta
        )
    }

    /// A prova de que o corpo está na tela: dois emails com textos diferentes
    /// desenham diferente. Sem a prévia, a janela mostra os mesmos remetente,
    /// assunto e data nos dois — e os desenhos ficam idênticos.
    @Test("aberta, a seção desenha o começo do corpo do email")
    func previaDesenhaOCorpo() async throws {
        let um = try #require(await Self.janela(corpo: [
            "Oi, Marcos. Confirmando a conversa de quinta às 15h.",
            "Levo a proposta revisada e o cronograma.",
        ]))
        let outro = try #require(await Self.janela(corpo: [
            "Bom dia. Precisamos remarcar: surgiu uma viagem.",
            "Sugiro a semana que vem, de manhã.",
        ]))
        #expect(
            um.pixelsDiffering(from: outro) > 0,
            "a seção aberta não está desenhando o corpo do email"
        )
    }

    /// Mensagem sem corpo local — a metade da caixa do dono, no primeiro
    /// sincronismo. A seção não pode inventar espera de rede nesta janela: ela
    /// fica com a linha do email e com o botão, e o desenho é o mesmo de outra
    /// mensagem sem corpo.
    @Test("sem corpo no banco, a seção não desenha prévia nenhuma")
    func semCorpoNaoDesenhaPrevia() async throws {
        let vazio = try #require(await Self.janela(corpo: []))
        let sobrasEmBranco = try #require(await Self.janela(corpo: ["", "   "]))
        #expect(vazio.pixelsDiffering(from: sobrasEmBranco) == 0)

        // E é diferente de ter corpo: a prévia é o que aparece quando há um.
        let comCorpo = try #require(await Self.janela(corpo: ["Confirmando quinta às 15h."]))
        #expect(vazio.pixelsDiffering(from: comCorpo) > 0)
    }

    /// O botão **age**: `MailStore.reveal` desfaz o que escondia a mensagem e a
    /// seleciona na janela principal — o mesmo caminho do botão "Email" do
    /// rodapé (M3-13), pela mesma função.
    ///
    /// Provado com um clique de verdade, entregue por `NSWindow.sendEvent` a
    /// uma janela a −50.000pt: nenhum evento vai para o sistema, nenhuma janela
    /// vem à frente. A altura do botão não é chutada — ela é **lida do
    /// desenho**, procurando o fundo `btn` do botão acima do rodapé.
    @Test("«Abrir no leitor» leva à mensagem de origem")
    func abrirNoLeitorRevela() async throws {
        let store = await Self.loja(corpo: ["Confirmando quinta às 15h."])
        let janela = EventWindow(
            store: store, itemID: "email-m1", debugSections: EventSections(origin: true)
        )
        let desenho = try #require(
            Render.bitmap(janela, size: Self.tamanho, theme: .tinta)
        )
        let y = try #require(
            Self.linhaDoBotao(in: desenho),
            "o botão «Abrir no leitor» não está desenhado"
        )

        let antes = store.revealCount
        CliqueDeEnsaio.em(janela, size: Self.tamanho, aY: CGFloat(y), x: 60)
        #expect(store.revealCount > antes, "o clique em «Abrir no leitor» não fez nada")
        #expect(store.selectedMessage?.id == "m1")
    }

    /// A linha do meio do botão "Abrir no leitor": ele é o único desenho com
    /// fundo `btn` **acima** do rodapé, que começa nos últimos 60pt da janela.
    private static func linhaDoBotao(in rep: NSBitmapImageRep) -> Int? {
        let alvo = Theme.tinta.btn
        var linhas: [Int] = []
        for y in 0..<(rep.pixelsHigh - 60) {
            for x in 30..<200 where corresponde(rep.colorAt(x: x, y: y), a: alvo) {
                linhas.append(y)
                break
            }
        }
        guard let primeira = linhas.first, let ultima = linhas.last else { return nil }
        return (primeira + ultima) / 2
    }

    private static func corresponde(_ cor: NSColor?, a token: TokenColor) -> Bool {
        guard let c = cor?.usingColorSpace(.sRGB),
              let alvo = token.nsColor.usingColorSpace(.sRGB), c.alphaComponent > 0.9
        else { return false }
        return abs(c.redComponent - alvo.redComponent) < 0.01
            && abs(c.greenComponent - alvo.greenComponent) < 0.01
            && abs(c.blueComponent - alvo.blueComponent) < 0.01
    }
}
