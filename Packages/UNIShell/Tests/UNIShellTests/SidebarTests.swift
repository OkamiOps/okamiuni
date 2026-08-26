import Testing
import UNICore
@testable import UNIShell

@Suite("FolderSidebar")
struct SidebarTests {

    @Test("os contadores por caixa batem com o store")
    @MainActor
    func counts() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.count(for: .all) == store.messages.count)
        #expect(store.count(for: .today) == store.messages.filter { $0.bucket == .today }.count)
    }

    @Test("a barra lista uma linha por conta, seja qual for a quantidade")
    @MainActor
    func oneRowPerAccount() async {
        for quantidade in [0, 1, 7, 25] {
            let contas = (0..<quantidade).map { i in
                Account(
                    id: "a\(i)", address: "x@d\(i).com",
                    displayName: "C\(i)", provider: .imap, tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
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
    func expandedWidth() {
        #expect(FolderSidebar.expandedWidth == 236)
    }
}
