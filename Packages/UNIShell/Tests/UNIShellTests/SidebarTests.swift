import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("FolderSidebar")
@MainActor
struct SidebarTests {

    /// Os números que a barra escreve, contra o design. Literais de propósito:
    /// as asserções anteriores comparavam `count(for:)` com a mesma expressão
    /// que o define (`messages.filter { … }.count`) — verdadeiras por
    /// construção, e passavam com as quatro mensagens erradas que estavam nas
    /// fixtures. O que precisa bater é o número que se lê na tela.
    @Test("os contadores por caixa são os do design")
    @MainActor
    func counts() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.count(for: .today) == 3)
        #expect(store.count(for: .later) == 3)
        #expect(store.count(for: .all) == 7)
        #expect(store.count(for: .archived) == 1)
        // "Tudo" é uma visão, não um estado: nenhuma mensagem fica de fora dela.
        #expect(store.count(for: .today) + store.count(for: .later)
            + store.count(for: .archived) == store.count(for: .all))
    }

    /// O contador respeita o filtro de conta — é o que a barra mostra depois de
    /// clicar numa caixa. Design: a conta do site tem duas mensagens, uma em
    /// "Hoje" (o lead) e uma em "Depois" (a cobrança).
    @Test("filtrar por conta reduz os contadores de todas as caixas")
    @MainActor
    func countsFollowTheAccountFilter() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(account: "host")
        #expect(store.count(for: .all) == 2)
        #expect(store.count(for: .today) == 1)
        #expect(store.count(for: .later) == 1)
        #expect(store.count(for: .archived) == 0)
    }

    /// `store.accounts.count == quantidade` é verdade mesmo se o desenho só
    /// mostrar a primeira conta (`prefix(1)`): o `store` está certo, quem
    /// mentiria é a `View`. Prova de verdade: renderizar duas listas de N
    /// contas idênticas exceto a **última**, que muda de cor entre elas, e
    /// exigir que a mudança apareça no bitmap. Se a `View` cortar para
    /// `prefix(1)` (ou qualquer corte que não alcance a última conta), a
    /// última linha nunca é desenhada e os dois bitmaps saem pixel a pixel
    /// iguais.
    private func accounts(_ quantidade: Int, lastTint: (light: String, dark: String)) -> [Account] {
        (0..<quantidade).map { i in
            let isLast = i == quantidade - 1
            return Account(
                id: "a\(i)", address: "conta\(i)@dominio\(i).com",
                displayName: "Conta \(i)", provider: .imap, host: "host\(i)",
                tintLightHex: isLast ? lastTint.light : "#3E6FA8",
                tintDarkHex: isLast ? lastTint.dark : "#7BA8D9"
            )
        }
    }

    @MainActor
    private func render(_ accounts: [Account]) async -> NSBitmapImageRep? {
        let store = MailStore(
            source: InMemoryMailSource(accounts: accounts, messages: [], agenda: [])
        )
        await store.load()
        // Alto o bastante para caber as 25 contas do maior caso sem rolar —
        // a rolagem cortaria a última linha do bitmap antes mesmo da mutação.
        return Render.bitmap(
            FolderSidebar(store: store),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 2200),
            theme: .tinta
        )
    }

    @Test("a barra lista uma linha por conta, seja qual for a quantidade")
    @MainActor
    func oneRowPerAccount() async {
        for quantidade in [0, 1, 7, 25] {
            let contas = accounts(quantidade, lastTint: ("#3E6FA8", "#7BA8D9"))
            let store = MailStore(
                source: InMemoryMailSource(accounts: contas, messages: [], agenda: [])
            )
            await store.load()
            #expect(store.accounts.count == quantidade)
        }
    }

    @Test("cada conta desenha a própria linha, não só a primeira", arguments: [2, 7, 25])
    @MainActor
    func drawsARowForEveryAccount(quantidade: Int) async throws {
        let baseline = accounts(quantidade, lastTint: ("#3E6FA8", "#7BA8D9"))
        let changedLast = accounts(quantidade, lastTint: ("#C23B3B", "#E38585"))

        let a = try #require(await render(baseline))
        let b = try #require(await render(changedLast))

        #expect(a.pixelsWide == b.pixelsWide)
        #expect(a.pixelsHigh == b.pixelsHigh)
        #expect(
            a.pixelsDiffering(from: b) > 0,
            "mudar a cor só da última conta (de \(quantidade)) não mudou nada no desenho — a linha dela não está sendo desenhada"
        )
    }

    @Test("a largura expandida é 236")
    @MainActor
    func expandedWidth() {
        #expect(FolderSidebar.expandedWidth == 236)
    }
}
