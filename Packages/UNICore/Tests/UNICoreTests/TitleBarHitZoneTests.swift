import CoreGraphics
import Testing
@testable import UNICore

/// Onde a barra de título é barra, e onde ela é controle.
///
/// A Task AL provou o duplo clique chamando `hitTest` numa `NSView` e o recurso
/// continuou morto na mão do dono do projeto: o `hitTest` era o segundo passo de
/// um caminho cujo primeiro nunca acontecia. A Task AQ separou as duas coisas —
/// **o caminho** do evento é provado por ensaio no app real
/// (`--ensaiar-barra`), e **a decisão** é esta função, que um teste alcança.
@Suite("Área vazia da barra de título")
struct TitleBarHitZoneTests {

    /// As molduras medidas na barra de 1440, tiradas do log do ensaio: botão da
    /// lateral, abas, busca, botão da agenda, lockup, seletor de tema e
    /// "Escrever". Todas na faixa de 22 ± 19 — nenhuma passa de y=41.
    private let controls: [CGRect] = [
        CGRect(x: 84, y: 10, width: 26, height: 24),
        CGRect(x: 124, y: 8, width: 143, height: 28),
        CGRect(x: 446, y: 8, width: 400, height: 28),
        CGRect(x: 1026, y: 10, width: 26, height: 24),
        CGRect(x: 1066, y: 3, width: 137, height: 38),
        CGRect(x: 1217, y: 9, width: 99, height: 26),
        CGRect(x: 1330, y: 8, width: 96, height: 27),
    ]

    /// O ponto que o ensaio usa: 48 do topo, abaixo de todos os controles.
    @Test("abaixo da fileira de controles a barra é barra")
    func belowTheControlRowIsEmpty() {
        #expect(TitleBarHitZone.isEmptyArea(
            CGPoint(x: 700, y: 48), barHeight: 58, controls: controls
        ))
    }

    /// A mesma coluna, na linha média: ali está o campo de busca, e clicar duas
    /// vezes num campo de texto é selecionar uma palavra, não dar zoom na
    /// janela.
    @Test("sobre um controle a barra não é barra", arguments: [
        CGPoint(x: 97, y: 22),    // botão da lateral
        CGPoint(x: 195, y: 22),   // abas
        CGPoint(x: 646, y: 22),   // busca
        CGPoint(x: 1039, y: 22),  // botão da agenda
        CGPoint(x: 1134, y: 22),  // lockup
        CGPoint(x: 1266, y: 22),  // seletor de tema
        CGPoint(x: 1378, y: 22),  // "Escrever"
    ])
    func overAControlIsNotEmpty(point: CGPoint) {
        #expect(!TitleBarHitZone.isEmptyArea(point, barHeight: 58, controls: controls))
    }

    /// Entre dois controles a barra volta a ser barra — é a folga do `HStack`.
    @Test("entre dois controles a barra é barra")
    func betweenControlsIsEmpty() {
        // Entre as abas (terminam em 267) e a busca (começa em 446).
        #expect(TitleBarHitZone.isEmptyArea(
            CGPoint(x: 350, y: 22), barHeight: 58, controls: controls
        ))
    }

    /// A faixa dos semáforos nativos fica antes de x=70 e não tem controle
    /// nosso; mesmo assim ela é barra, e é o AppKit que responde pelos botões
    /// do sistema, num nível acima do nosso.
    @Test("a faixa dos semáforos continua sendo barra")
    func trafficLightStripIsEmptyForUs() {
        #expect(TitleBarHitZone.isEmptyArea(
            CGPoint(x: 40, y: 22), barHeight: 58, controls: controls
        ))
    }

    @Test("abaixo da barra não é barra")
    func belowTheBarIsNotTheBar() {
        #expect(!TitleBarHitZone.isEmptyArea(
            CGPoint(x: 700, y: 59), barHeight: 58, controls: controls
        ))
        #expect(!TitleBarHitZone.isEmptyArea(
            CGPoint(x: 700, y: 400), barHeight: 58, controls: controls
        ))
    }

    /// A borda de baixo pertence à barra: 58 é o último ponto dela, e recusá-lo
    /// deixaria uma linha morta que o usuário não vê.
    @Test("a borda de baixo ainda é barra")
    func theBottomEdgeIsStillTheBar() {
        #expect(TitleBarHitZone.isEmptyArea(
            CGPoint(x: 700, y: 58), barHeight: 58, controls: controls
        ))
    }

    /// Antes de a primeira medição chegar a lista está vazia. Aí a barra
    /// inteira é vazia — e é melhor assim: o duplo clique funciona desde o
    /// primeiro quadro, e no quadro seguinte os controles já se excluíram.
    @Test("sem molduras medidas a barra inteira é vazia")
    func withoutFramesTheWholeBarIsEmpty() {
        #expect(TitleBarHitZone.isEmptyArea(
            CGPoint(x: 700, y: 22), barHeight: 58, controls: []
        ))
    }
}
