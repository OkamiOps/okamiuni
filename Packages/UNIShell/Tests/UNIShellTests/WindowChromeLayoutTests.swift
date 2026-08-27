import Testing
import CoreGraphics
@testable import UNIShell

/// A barra superior é o que o dono do projeto mais olha, e o que ele já
/// reclamou duas vezes. Estes testes travam as duas decisões da Task S: a ordem
/// dos controles (com o lockup à direita) e a linha média em que os semáforos
/// nativos passam a cair.
@Suite("Barra superior — posições e ordem")
struct WindowChromeLayoutTests {

    // MARK: ordem horizontal

    @Test("a ordem dos controles é a que o dono pediu, da esquerda para a direita")
    func controlOrderIsLocked() {
        #expect(
            WindowChrome.controlOrder == [
                .sidebarToggle,
                .tabs,
                .search,
                .agendaToggle,
                .lockup,
                .themePicker,
            ]
        )
    }

    @Test("todo controle aparece uma vez só, e nenhum some da barra")
    func everyControlAppearsExactlyOnce() {
        let order = WindowChrome.controlOrder
        #expect(order.count == 6)
        #expect(Set(order) == Set(ChromeControl.allCases))
        #expect(order.count == Set(order).count)
    }

    /// Divergência deliberada do protótipo: no protótipo o lockup abre a barra.
    /// O dono pediu para movê-lo, e este teste é o que impede que ele volte
    /// sozinho num refactor.
    @Test("o lockup fecha a barra em vez de abri-la, encostado no seletor de temas")
    func lockupClosesTheBar() {
        let order = WindowChrome.controlOrder
        guard
            let lockup = order.firstIndex(of: .lockup),
            let picker = order.firstIndex(of: .themePicker),
            let tabs = order.firstIndex(of: .tabs)
        else {
            Issue.record("a barra perdeu um dos três controles que a Task S posiciona")
            return
        }
        #expect(lockup > tabs, "o lockup voltou para a esquerda das abas")
        #expect(picker - lockup == 1, "o lockup desencostou do seletor de temas")
        #expect(order.first == .sidebarToggle, "a esquerda tem de abrir com o botão da lateral")
    }

    @Test("só a busca cede largura")
    func onlySearchIsFlexible() {
        #expect(WindowChrome.flexibleControl == .search)
        #expect(WindowChrome.controlOrder.contains(.search))
    }

    // MARK: alinhamento vertical

    /// O macOS centra os semáforos na barra de título de 32pt que reserva mesmo
    /// numa janela `.hiddenTitleBar`. Medido por acessibilidade antes da
    /// Task S: quadro y=8..24, centro em 16.
    @Test("a posição nativa dos semáforos é a que foi medida na janela")
    func nativeCenterIsWhatWasMeasured() {
        #expect(TrafficLightLayout.nativeBarHeight == 32)
        #expect(TrafficLightLayout.nativeCenterFromTop == 16)
    }

    /// Os botões que `NSWindow.standardWindowButton` devolve têm 14pt de lado —
    /// medido na hierarquia de views. O quadro de acessibilidade é maior (16pt),
    /// mas quem posiciona é o `frame`.
    @Test("na barra de 58pt o semáforo nasce em y=22 e fica com centro em y=29")
    func trafficLightLandsOnTheBarsMidline() {
        #expect(TrafficLightLayout.buttonOriginY(barHeight: 58, buttonHeight: 14) == 22)
        #expect(TrafficLightLayout.centerFromTop(barHeight: 58, buttonHeight: 14) == 29)
    }

    /// Duas literais independentes que têm de se encontrar: a linha média que a
    /// barra usa para os controles dela (`WindowChrome.centerY`) e a que a conta
    /// do semáforo produz a partir da altura da barra.
    @Test("o semáforo cai na mesma linha média que os nossos controles")
    func trafficLightMeetsOurControls() {
        #expect(WindowChrome.centerY == 29)
        #expect(WindowChrome.height == 58)
        let semaphore = TrafficLightLayout.centerFromTop(
            barHeight: WindowChrome.height, buttonHeight: 14
        )
        #expect(
            semaphore == WindowChrome.centerY,
            "semáforo em y=\(semaphore), nossos controles em y=\(WindowChrome.centerY)"
        )
    }

    @Test("o resíduo que o dono reclamou era de 13pt")
    func residualWasThirteenPoints() {
        let before = TrafficLightLayout.nativeCenterFromTop
        let after = TrafficLightLayout.centerFromTop(barHeight: 58, buttonHeight: 14)
        #expect(before == 16)
        #expect(after == 29)
        #expect(after - before == 13)
    }

    /// É por isto que o `NSTitlebarContainerView` precisa crescer junto: um
    /// `NSView` desenha fora dos próprios limites mas não recebe clique fora
    /// deles. Empurrado para y=29 dentro da barra nativa de 32pt, o semáforo
    /// terminaria em y=36 — 4pt fora — e ficaria visível e morto.
    @Test("empurrar o botão sem crescer a barra o deixaria fora dos limites")
    func buttonWouldOverflowTheNativeBar() {
        let bottom = TrafficLightLayout.centerFromTop(barHeight: 58, buttonHeight: 14) + 7
        #expect(bottom == 36)
        #expect(bottom > TrafficLightLayout.nativeBarHeight)

        let originIn58 = TrafficLightLayout.buttonOriginY(barHeight: 58, buttonHeight: 14)
        #expect(originIn58 >= 0)
        #expect(originIn58 + 14 <= 58, "o botão tem de caber inteiro na barra de 58pt")
    }

    /// A barra de título mora em coordenadas do `NSThemeFrame`, que não é
    /// invertido: ela encosta no topo da janela, então a origem sobe junto com a
    /// altura. Numa janela de 916pt de altura com barra de 58, isso é y=858.
    @Test("o container da barra de título cresce a partir do topo da janela")
    func containerFrameGrowsFromTheTop() {
        let frame = TrafficLightLayout.containerFrame(
            windowSize: CGSize(width: 1440, height: 916), barHeight: 58
        )
        #expect(frame == CGRect(x: 0, y: 858, width: 1440, height: 58))
    }

    @Test(
        "o container acompanha a janela em toda largura que a Task R prevê",
        arguments: [
            (CGSize(width: 880, height: 916), CGRect(x: 0, y: 858, width: 880, height: 58)),
            (CGSize(width: 1200, height: 916), CGRect(x: 0, y: 858, width: 1200, height: 58)),
            (CGSize(width: 1440, height: 916), CGRect(x: 0, y: 858, width: 1440, height: 58)),
            (CGSize(width: 860, height: 632), CGRect(x: 0, y: 574, width: 860, height: 58)),
        ]
    )
    func containerFollowsTheWindow(size: CGSize, expected: CGRect) {
        #expect(TrafficLightLayout.containerFrame(windowSize: size, barHeight: 58) == expected)
    }
}
