import Testing
import CoreGraphics
import UNICore
@testable import UNIShell

@Suite("PaneDivider")
struct PaneDividerTests {

    @Test("o alvo de arraste é muito mais largo que a linha, em qualquer tela")
    func theTargetIsBigEnoughToHit() {
        #expect(PaneDivider.hitWidth == 6)
        // A razão de ser da constante: a linha que se vê é bem mais fina que o
        // alvo que se agarra. Medido contra a espessura da **tela mais grossa**
        // — 1×, onde a hairline tem um ponto inteiro. Comparar contra
        // `Hairline.thickness` (o valor de 2×) diria que a folga é o dobro do
        // que é na tela do dono do projeto.
        #expect(PaneDivider.hitWidth >= Hairline.thickness(1) * 6)
        #expect(Hairline.thickness(1) == 1)
    }

    @Test("o alvo fica centrado na linha, alcançável pelos dois painéis")
    func theTargetIsCenteredOnTheLine() {
        let boundary: CGFloat = 606        // 236 de lateral + 370 de lista
        let leading = PaneDivider.leadingEdge(centeredOn: boundary)
        let trailing = leading + PaneDivider.hitWidth

        #expect(leading == 603)
        #expect(trailing == 609)
        // três pontos de cada lado da linha
        #expect(boundary - leading == 3)
        #expect(trailing - boundary == 3)
    }

    @Test("as duas divisórias pousam sobre as linhas que os painéis desenham")
    func theDividersLandOnTheDrawnLines() {
        let layout = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)

        // A linha da lista é a `hairline(.trailing)` de `MessageList`, que fica
        // no fim da lateral mais a lista.
        #expect(layout.messageListTrailingEdge == 606)

        // A da agenda é a `hairline(.leading)` de `AgendaRail`.
        #expect(layout.agendaLeadingEdge(inWindowOfWidth: 1440) == 1178)

        // E o leitor é o que fica entre as duas.
        #expect(layout.readerWidth(inWindowOfWidth: 1440) == 572)
    }

    @Test("arrastar a divisória da lista move a linha junto")
    func draggingTheListDividerMovesTheLine() {
        let before = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        // O usuário agarrou a linha em 606 e puxou 80pt para a direita.
        let after = PaneLayout.resolve(
            width: 1440, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: before.messageListWidth + 80
        )
        #expect(before.messageListTrailingEdge == 606)
        #expect(after.messageListTrailingEdge == 686)
        #expect(after.readerWidth(inWindowOfWidth: 1440) == 492)
    }

    @Test("arrastar a divisória da agenda move a linha junto")
    func draggingTheAgendaDividerMovesTheLine() {
        let before = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        // Agarrou a linha em 1178 e puxou 50pt para a esquerda: a agenda alarga.
        let after = PaneLayout.resolve(
            width: 1440, wantsSidebar: true, wantsAgenda: true,
            draggedAgendaWidth: before.agendaRailWidth + 50
        )
        #expect(before.agendaLeadingEdge(inWindowOfWidth: 1440) == 1178)
        #expect(after.agendaRailWidth == 312)
        #expect(after.agendaLeadingEdge(inWindowOfWidth: 1440) == 1128)
    }
}
