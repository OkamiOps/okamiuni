import Testing
import SwiftUI
import UNIDesign
import UNICore
@testable import UNIShell

@Suite("InboxScreen")
struct InboxScreenTests {

    // Estes testes existiam comparando literal com literal — declaravam
    // `let messageListWidth: CGFloat = 400` e conferiam se era 400. Passavam com
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
    // contra os números do design (248, 72, 276) e contra `resolve(width:...)`
    // em toda a faixa — os testes que a auditoria viu falhar por mutação.

    @Test("em 1440 os quatro painéis somam a janela inteira, com 516 no leitor")
    func panelWidthsSumAt1440() {
        let layout = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)

        #expect(layout.sidebarExpanded)
        #expect(layout.agendaVisible)

        let taken = FolderSidebar.expandedWidth
            + layout.messageListWidth
            + AgendaRail.width
        let reader = 1440 - taken

        #expect(taken == 924, "248 + 400 + 276 devem somar 924, obteve \(taken)")
        #expect(reader == 516, "o leitor deve ficar com 516, obteve \(reader)")
    }

    @Test("recolhida, a lateral devolve exatamente 176pt ao resto da janela")
    func railGivesBackTheDifference() {
        let difference = PaneLayout.expandedSidebarWidth - PaneLayout.railWidth
        #expect(difference == 176, "248 − 72 = 176, obteve \(difference)")
    }
}
