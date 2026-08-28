import Foundation
import Testing
@testable import UNICore

@Suite("O caminho até a janela de Contas")
struct AccountsMenuTests {
    @Test("A linha da conta oferece 'Contas…'")
    func itemNoMenuDaConta() {
        let conta = Fixtures.accounts[0]
        let entradas = ContextMenus.accountRow(conta, isFiltered: false, unread: 0)
        let rotulos = entradas.compactMap { entrada -> String? in
            guard case .item(let item) = entrada else { return nil }
            return item.title
        }
        #expect(rotulos.contains("Contas…"))
    }

    @Test("O comando é próprio, e não um `copy` disfarçado")
    func comandoProprio() {
        let entradas = ContextMenus.accountRow(Fixtures.accounts[0], isFiltered: false, unread: 0)
        let comandos = entradas.compactMap { entrada -> ContextCommand? in
            guard case .item(let item) = entrada else { return nil }
            return item.command
        }
        #expect(comandos.contains(.openAccounts))
    }
}
