import Testing
import SwiftUI
import UNIDesign
import UNICore
@testable import UNIShell

@Suite("InboxScreen")
struct InboxScreenTests {

    // Estes testes existiam comparando literal com literal — declaravam
    // `let messageListWidth: CGFloat = 370` e conferiam se era 370. Passavam com
    // qualquer coisa na tela. Agora eles atravessam as constantes reais dos
    // painéis e a `PaneLayout` que os distribui, que é o que pode quebrar.

    // `panelConstantsComeFromPaneLayout` foi apagado sem substituto (Task AM).
    // Comparava `FolderSidebar.expandedWidth == PaneLayout.expandedSidebarWidth`
    // e as duas outras larguras irmãs — mas `FolderSidebar.expandedWidth` **é**
    // `PaneLayout.expandedSidebarWidth` (declarado como apelido, não como cópia:
    // ver `FolderSidebar.swift`), e o mesmo vale para `SidebarRail.width` e
    // `AgendaRail.width`. A comparação é consigo mesma por construção — nenhuma
    // mutação em `PaneLayout` consegue fazer este teste falhar. As larguras de
    // verdade já têm dono: `Packages/UNICore/Tests/UNICoreTests/PaneLayoutTests.swift`
    // mede `PaneLayout.expandedSidebarWidth`, `.railWidth` e `.agendaWidth`
    // contra os números do design (236, 62, 262) e contra `resolve(width:...)`
    // em toda a faixa — os testes que a auditoria viu falhar por mutação.

    @Test("em 1440 os quatro painéis somam a janela inteira, com 572 no leitor")
    func panelWidthsSumAt1440() {
        let layout = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)

        #expect(layout.sidebarExpanded)
        #expect(layout.agendaVisible)

        let taken = FolderSidebar.expandedWidth
            + layout.messageListWidth
            + AgendaRail.width
        let reader = 1440 - taken

        #expect(taken == 868, "236 + 370 + 262 devem somar 868, obteve \(taken)")
        #expect(reader == 572, "o leitor deve ficar com 572, obteve \(reader)")
    }

    @Test("recolhida, a lateral devolve exatamente 174pt ao resto da janela")
    func railGivesBackTheDifference() {
        let difference = PaneLayout.expandedSidebarWidth - PaneLayout.railWidth
        #expect(difference == 174, "236 − 62 = 174, obteve \(difference)")
    }
}
