import Testing
import Foundation
import CoreGraphics
import UNICore

/// A largura arrastada é a terceira entrada da `PaneLayout`, ao lado de
/// `wantsSidebar` e `wantsAgenda` — não um bypass dela. Estes testes existem
/// para provar as duas metades disso: que o gesto de fato move a divisória, e
/// que nenhuma largura gravada consegue atravessar a trava do leitor.
@Suite("PaneLayout · divisórias arrastáveis")
struct PaneDragTests {

    // MARK: - Sem arraste, nada muda

    @Test("sem preferência, a janela decide exatamente como decidia antes")
    func noPreferenceKeepsTaskRBehaviour() {
        let l = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        #expect(l.messageListWidth == 400)
        #expect(l.agendaRailWidth == 276)
    }

    @Test("a agenda escondida mede zero, não a canônica")
    func hiddenAgendaMeasuresZero() {
        let l = PaneLayout.resolve(width: 1200, wantsSidebar: true, wantsAgenda: true)
        #expect(l.agendaVisible == false)
        #expect(l.agendaRailWidth == 0)
    }

    // MARK: - O gesto move mesmo

    @Test("a lista arrastada assume a largura pedida quando ela cabe")
    func draggedListTakesTheRequestedWidth() {
        let l = PaneLayout.resolve(
            width: 1920, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: 500
        )
        #expect(l.messageListWidth == 500)
        // e o leitor fica com o resto, não com uma medida fixa
        let reader: CGFloat = 1920 - l.sidebarWidth - l.messageListWidth - l.agendaRailWidth
        #expect(reader == 896)
    }

    @Test("a agenda arrastada assume a largura pedida quando ela cabe")
    func draggedAgendaTakesTheRequestedWidth() {
        let l = PaneLayout.resolve(
            width: 1920, wantsSidebar: true, wantsAgenda: true,
            draggedAgendaWidth: 330
        )
        #expect(l.agendaRailWidth == 330)
    }

    @Test("as duas divisórias são preferências independentes")
    func thePreferencesAreIndependent() {
        let onlyList = PaneLayout.resolve(
            width: 1920, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: 600
        )
        #expect(onlyList.messageListWidth == 600)
        #expect(onlyList.agendaRailWidth == 276)  // intocada

        let onlyAgenda = PaneLayout.resolve(
            width: 1920, wantsSidebar: true, wantsAgenda: true,
            draggedAgendaWidth: 210
        )
        #expect(onlyAgenda.agendaRailWidth == 210)
        #expect(onlyAgenda.messageListWidth == 400)  // teto da faixa automática
    }

    // MARK: - A faixa do gesto

    @Test("um pedido acima do teto para no teto da faixa do arraste")
    func aboveTheCeilingStopsAtTheCeiling() {
        #expect(PaneLayout.clampDraggedListWidth(5000) == 640)
        #expect(PaneLayout.clampDraggedAgendaWidth(5000) == 400)
    }

    @Test("um pedido abaixo do piso para no piso da faixa do arraste")
    func belowTheFloorStopsAtTheFloor() {
        #expect(PaneLayout.clampDraggedListWidth(0) == 260)
        #expect(PaneLayout.clampDraggedListWidth(-900) == 260)
        #expect(PaneLayout.clampDraggedAgendaWidth(12) == 200)
    }

    @Test("a faixa do gesto é mais larga que a do recolhimento automático")
    func theDragRangeIsWiderThanTheAutomaticOne() {
        // O gesto pode pedir 260 e 640 — larguras que a negociação automática
        // nunca produz. É esta folga extra que faz a divisória andar de verdade.
        let narrow = PaneLayout.resolve(
            width: 1920, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: 260
        )
        let wide = PaneLayout.resolve(
            width: 1920, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: 640
        )
        #expect(narrow.messageListWidth == 260)
        #expect(wide.messageListWidth == 640)

        let auto = PaneLayout.resolve(width: 1920, wantsSidebar: true, wantsAgenda: true)
        #expect(auto.messageListWidth == 400)
    }

    // MARK: - A trava do leitor: nenhuma preferência a atravessa

    @Test("a largura salva numa janela grande não espreme o leitor numa pequena")
    func preferenceFromABigWindowSurvivesASmallOne() {
        // O usuário arrastou até 640 numa tela de 27".
        let big = PaneLayout.resolve(
            width: 2560, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: 640, draggedAgendaWidth: 400
        )
        #expect(big.messageListWidth == 640)
        #expect(big.agendaRailWidth == 400)

        // Mesma preferência gravada, app reaberto numa janela de 900pt.
        let small = PaneLayout.resolve(
            width: 900, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: 640, draggedAgendaWidth: 400
        )
        #expect(small.agendaVisible == false)
        #expect(small.agendaRailWidth == 0)
        #expect(small.messageListWidth == 508)   // 900 − 72 (trilha) − 320 (leitor)
        #expect(900 - PaneLayout.railWidth - small.messageListWidth == PaneLayout.readerMinimumWidth)

        // E a preferência não foi apagada: a mesma entrada numa janela grande
        // devolve os 640 de novo. Só o resultado cedeu, a intenção não.
        let backToBig = PaneLayout.resolve(
            width: 2560, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: 640, draggedAgendaWidth: 400
        )
        #expect(backToBig.messageListWidth == 640)
        #expect(backToBig.agendaRailWidth == 400)
    }

    @Test("em 1440 uma lista de 640 recua até onde o leitor permite")
    func at1440TheListYieldsToTheReader() {
        let l = PaneLayout.resolve(
            width: 1440, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: 640, draggedAgendaWidth: 400
        )
        #expect(l.agendaRailWidth == 400)   // a agenda pedida foi respeitada
        #expect(l.messageListWidth == 472)  // 1440 − 248 − 400 − 320
        #expect(l.readerWidth(inWindowOfWidth: 1440) == PaneLayout.readerMinimumWidth)
    }

    @Test("uma agenda larga demais cede quando a lista já está no piso dela")
    func aTooWideAgendaYieldsWhenTheListCannot() {
        // 1280 é a primeira largura em que a agenda aparece. Com a agenda no
        // teto de 400 e a lista sem preferência — logo, presa no piso de 340 da
        // faixa automática —, não há de onde tirar os pontos do leitor a não
        // ser da própria agenda.
        let l = PaneLayout.resolve(
            width: 1280, wantsSidebar: true, wantsAgenda: true,
            draggedAgendaWidth: 400
        )
        #expect(l.agendaVisible)
        #expect(l.messageListWidth == 340)
        #expect(l.agendaRailWidth == 372)   // 400 cedeu 28
        #expect(l.readerWidth(inWindowOfWidth: 1280) == PaneLayout.readerMinimumWidth)
    }

    @Test("os pisos das duas faixas cabem na janela mais estreita que mostra a agenda")
    func theFloorsFitAtTheAgendaBreakpoint() {
        // A garantia estrutural por trás da trava do leitor: em 1280, a lateral
        // aberta mais o piso da lista arrastada mais o teto da agenda arrastada
        // mais o mínimo do leitor ainda sobram pontos. Se alguém subir um dos
        // pisos ou o teto da agenda além disto, é aqui que descobre.
        let needed = PaneLayout.expandedSidebarWidth
            + PaneLayout.draggableListRange.lowerBound
            + PaneLayout.draggableAgendaRange.lowerBound
            + PaneLayout.readerMinimumWidth
        #expect(needed <= 1280)
        #expect(needed == 1028)
    }

    @Test("o leitor nunca fica abaixo de 320, com qualquer preferência, em qualquer largura")
    func readerNeverStarvesWithAnyPreference() {
        let listPreferences: [CGFloat?] = [nil, 260, 320, 370, 500, 640, 9999, -50]
        let agendaPreferences: [CGFloat?] = [nil, 200, 276, 400, 9999, -50]

        var sweeps = 0
        let expectedSweeps = listPreferences.count * agendaPreferences.count * 86

        for listPreference in listPreferences {
            for agendaPreference in agendaPreferences {
                for width in stride(from: 860.0, through: 2560.0, by: 20.0) {
                    sweeps += 1
                    let l = PaneLayout.resolve(
                        width: width,
                        wantsSidebar: true,
                        wantsAgenda: true,
                        draggedListWidth: listPreference,
                        draggedAgendaWidth: agendaPreference
                    )
                    #expect(
                        l.readerWidth(inWindowOfWidth: width) >= PaneLayout.readerMinimumWidth,
                        "leitor espremido em \(width)pt com lista \(String(describing: listPreference)) e agenda \(String(describing: agendaPreference))"
                    )
                }
            }
        }

        // Sem isto o teste passaria de graça se a varredura não rodasse.
        #expect(sweeps == expectedSweeps)
        #expect(sweeps == 4128)
    }

    @Test("nenhuma preferência escapa da própria faixa em nenhuma largura")
    func preferencesNeverEscapeTheirRange() {
        var sweeps = 0
        for width in stride(from: 860.0, through: 2560.0, by: 20.0) {
            sweeps += 1
            let l = PaneLayout.resolve(
                width: width, wantsSidebar: true, wantsAgenda: true,
                draggedListWidth: 9999, draggedAgendaWidth: 9999
            )
            #expect(l.messageListWidth <= 640)
            #expect(l.messageListWidth >= 260)
            if l.agendaVisible {
                #expect(l.agendaRailWidth <= 400)
                #expect(l.agendaRailWidth >= 200)
            }
        }
        #expect(sweeps == 86)
    }
}

/// A preferência gravada é a intenção, não o que coube. Estes testes travam
/// isso e a distinção entre "nunca arrastei" e "arrastei até zero".
@Suite("PaneWidthStore")
@MainActor
struct PaneWidthStoreTests {

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "okamiuni.test.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("um store novo não tem preferência nenhuma")
    func startsEmpty() {
        let store = PaneWidthStore(defaults: freshDefaults())
        #expect(store.messageList == nil)
        #expect(store.agenda == nil)
    }

    @Test("a largura arrastada sobrevive a uma nova execução")
    func survivesRelaunch() {
        let defaults = freshDefaults()
        PaneWidthStore(defaults: defaults).setMessageList(512)

        // outra instância, como no próximo lançamento do app
        let reopened = PaneWidthStore(defaults: defaults)
        #expect(reopened.messageList == 512)
        #expect(reopened.agenda == nil)
    }

    @Test("lista e agenda são preferências independentes, não uma largura global")
    func theTwoPreferencesAreSeparate() {
        let defaults = freshDefaults()
        let store = PaneWidthStore(defaults: defaults)
        store.setMessageList(300)
        store.setAgenda(380)

        let reopened = PaneWidthStore(defaults: defaults)
        #expect(reopened.messageList == 300)
        #expect(reopened.agenda == 380)
    }

    @Test("o store grava a largura já presa na faixa do gesto")
    func storedWidthIsClamped() {
        let defaults = freshDefaults()
        let store = PaneWidthStore(defaults: defaults)
        store.setMessageList(9999)
        store.setAgenda(1)
        #expect(store.messageList == 640)
        #expect(store.agenda == 200)
        #expect(PaneWidthStore(defaults: defaults).messageList == 640)
    }

    @Test("o duplo clique apaga a preferência em vez de gravar um zero")
    func resetClearsRatherThanZeroes() {
        let defaults = freshDefaults()
        let store = PaneWidthStore(defaults: defaults)
        store.setMessageList(512)
        store.setAgenda(380)

        store.resetMessageList()
        #expect(store.messageList == nil)
        #expect(store.agenda == 380)  // a outra divisória não foi afetada

        let reopened = PaneWidthStore(defaults: defaults)
        #expect(reopened.messageList == nil)   // e não 0
        #expect(reopened.agenda == 380)
    }

    @Test("apagar a preferência devolve a lista à negociação da janela")
    func resetReturnsTheListToTheWindow() {
        let defaults = freshDefaults()
        let store = PaneWidthStore(defaults: defaults)
        store.setMessageList(640)

        let dragged = PaneLayout.resolve(
            width: 1440, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: store.messageList
        )
        #expect(dragged.messageListWidth == 596)  // 1440 − 248 − 276 − 320

        store.resetMessageList()
        let restored = PaneLayout.resolve(
            width: 1440, wantsSidebar: true, wantsAgenda: true,
            draggedListWidth: store.messageList
        )
        #expect(restored.messageListWidth == 400)  // o valor canônico do redesenho
    }
}
