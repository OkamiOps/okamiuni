import Testing
import CoreGraphics
import UNICore

@Suite("PaneLayout")
struct PaneLayoutTests {

    @Test("em janela larga tudo aparece se o usuário quiser")
    func wideShowsEverything() {
        let l = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        #expect(l.sidebarExpanded)
        #expect(l.agendaVisible)
    }

    @Test("a agenda é o primeiro painel a sair")
    func agendaGoesFirst() {
        let l = PaneLayout.resolve(width: 1200, wantsSidebar: true, wantsAgenda: true)
        #expect(l.sidebarExpanded)
        #expect(l.agendaVisible == false)
    }

    @Test("abaixo de 920 a lateral recolhe para a trilha")
    func sidebarCollapses() {
        let l = PaneLayout.resolve(width: 919, wantsSidebar: true, wantsAgenda: true)
        #expect(l.sidebarExpanded == false)
        #expect(l.agendaVisible == false)
    }

    @Test("a janela nega, mas não apaga a intenção: ao crescer, volta")
    func intentSurvivesShrinking() {
        // o mesmo `wants` atravessa as três larguras
        let narrow = PaneLayout.resolve(width: 900, wantsSidebar: true, wantsAgenda: true)
        let wide = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        #expect(narrow.sidebarExpanded == false)
        #expect(wide.sidebarExpanded)      // sem estado persistido entre as duas chamadas
    }

    @Test("quem não quer a lateral não a ganha de volta ao alargar")
    func refusalIsRespected() {
        let l = PaneLayout.resolve(width: 1440, wantsSidebar: false, wantsAgenda: false)
        #expect(l.sidebarExpanded == false)
        #expect(l.agendaVisible == false)
    }

    @Test("a lista fica dentro da faixa em qualquer largura", arguments: [
        860.0, 920.0, 1000.0, 1120.0, 1280.0, 1440.0, 1920.0, 2560.0,
    ])
    func listStaysInRange(width: CGFloat) {
        let l = PaneLayout.resolve(width: width, wantsSidebar: true, wantsAgenda: true)
        #expect(l.messageListWidth >= 320)
        #expect(l.messageListWidth <= 400)
    }

    @Test("o leitor nunca fica abaixo do mínimo legível")
    func readerNeverStarves() {
        for width in stride(from: 860.0, through: 2560.0, by: 20.0) {
            let l = PaneLayout.resolve(width: width, wantsSidebar: true, wantsAgenda: true)
            let taken = (l.sidebarExpanded ? PaneLayout.expandedSidebarWidth : PaneLayout.railWidth)
                + l.messageListWidth
                + l.agendaRailWidth
            #expect(width - taken >= PaneLayout.readerMinimumWidth, "leitor espremido em \(width)pt")
        }
    }

    // MARK: - Trava do ponto de fidelidade da Task P
    //
    // Os testes acima só olham faixas, e uma faixa de 100pt de folga passa com
    // a janela de 1440 deslocada em 30pt. A Task P alinhou a tela **naquele
    // ponto**; se a `PaneLayout` devolver outra coisa em 1440, o marco anterior
    // quebra sem nenhum teste acima reclamar. Estas asserções travam a literal.

    @Test("em 1440 a lista mede exatamente os 400 do redesenho")
    func fidelityAt1440() {
        let l = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        #expect(l.messageListWidth == 400)
    }

    @Test("em 1440 o leitor recebe exatamente os 516 do redesenho")
    func readerAt1440() {
        let l = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        let reader = l.readerWidth(inWindowOfWidth: 1440)
        #expect(reader == 516)
    }

    // MARK: - As fronteiras das faixas
    //
    // Os testes do enunciado amostram 900/1000/1200/1440, que ficam longe das
    // bordas. Um `>` no lugar de `>=` passa por todos eles e erra a fronteira.

    @Test("920 é a primeira largura que expande a lateral, 919 não")
    func sidebarBoundary() {
        #expect(PaneLayout.resolve(width: 919, wantsSidebar: true, wantsAgenda: true).sidebarExpanded == false)
        #expect(PaneLayout.resolve(width: 920, wantsSidebar: true, wantsAgenda: true).sidebarExpanded)
    }

    @Test("1280 é a primeira largura que mostra a agenda, 1279 não")
    func agendaBoundary() {
        #expect(PaneLayout.resolve(width: 1279, wantsSidebar: true, wantsAgenda: true).agendaVisible == false)
        #expect(PaneLayout.resolve(width: 1280, wantsSidebar: true, wantsAgenda: true).agendaVisible)
    }

    @Test("no piso da janela a lista encolhe até o mínimo de 320")
    func listFloorAtWindowFloor() {
        let l = PaneLayout.resolve(width: 860, wantsSidebar: true, wantsAgenda: true)
        #expect(l.messageListWidth == 320)
    }

    @Test("recolher a lateral por vontade alarga o leitor")
    func collapsingSidebarWidensTheReader() {
        let open = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        let shut = PaneLayout.resolve(width: 1440, wantsSidebar: false, wantsAgenda: true)
        let readerOpen = open.readerWidth(inWindowOfWidth: 1440)
        let readerShut = shut.readerWidth(inWindowOfWidth: 1440)
        #expect(readerShut > readerOpen)
        #expect(shut.messageListWidth <= 400)
    }
}
