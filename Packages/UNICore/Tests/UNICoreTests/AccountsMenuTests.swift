import Foundation
import Testing
@testable import UNICore

@Suite("O caminho até a janela de Configurações")
struct AccountsMenuTests {
    /// "Contas" virou "Configurações": a janela do Marco 2 ganha a lista de
    /// contas como a primeira seção, estruturada para receber outras depois
    /// — o dono do projeto pediu o nome que o macOS espera de ⌘,. O item da
    /// lateral segue o mesmo rótulo, para não apontar para um nome que a
    /// janela não usa mais.
    @Test("A linha da conta oferece 'Configurações…'")
    func itemNoMenuDaConta() {
        let conta = Fixtures.accounts[0]
        let entradas = ContextMenus.accountRow(conta, isFiltered: false, unread: 0)
        let rotulos = entradas.compactMap { entrada -> String? in
            guard case .item(let item) = entrada else { return nil }
            return item.title
        }
        #expect(rotulos.contains("Configurações…"))
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
