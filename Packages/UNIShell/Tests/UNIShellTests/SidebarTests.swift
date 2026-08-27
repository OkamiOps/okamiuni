import Testing
import UNICore
@testable import UNIShell

@Suite("FolderSidebar")
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

    @Test("a barra lista uma linha por conta, seja qual for a quantidade")
    @MainActor
    func oneRowPerAccount() async {
        for quantidade in [0, 1, 7, 25] {
            let contas = (0..<quantidade).map { i in
                Account(
                    id: "a\(i)", address: "x@d\(i).com",
                    displayName: "C\(i)", provider: .imap, host: "d\(i)",
                    tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
                )
            }
            let store = MailStore(
                source: InMemoryMailSource(accounts: contas, messages: [], agenda: [])
            )
            await store.load()
            #expect(store.accounts.count == quantidade)
        }
    }

    @Test("a largura expandida é 236")
    @MainActor
    func expandedWidth() {
        #expect(FolderSidebar.expandedWidth == 236)
    }
}
