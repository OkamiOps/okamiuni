import AppKit
import Foundation
import SwiftUI
import Testing
import UNIDesign
@testable import UNIShell

/// O cabeçalho e os semáforos, na mesma linha — nas **seis** janelas.
///
/// A tela do dono da M3-21: na janela de resposta o título estava
/// visivelmente abaixo dos botões do sistema. Medido: a barra de 42pt centrava
/// o título em y=21, e os semáforos ficavam onde o macOS os deixa numa
/// `.hiddenTitleBar` — centro em y=16. Cinco pontos.
///
/// A causa não era o desenho da barra: era o **alinhador**. Ele existia só na
/// `WindowChrome` da janela principal, e as outras cinco barras nunca o
/// chamavam. Aqui a régua é a mesma dos dois lados: a linha da plataforma,
/// `TrafficLightLayout.contentCenterFromTop`.
@Suite("Cabeçalho e semáforo na mesma linha")
@MainActor
struct TitleBarAlignmentTests {

    /// A linha média do que uma barra desenha, lida do bitmap: a primeira e a
    /// última fileira com tinta, **sem** a hairline da borda de baixo.
    private static func linhaMedia(
        _ rep: NSBitmapImageRep, papel: TokenColor, x: Range<Int>
    ) -> Double? {
        guard let fundo = papel.nsColor.usingColorSpace(.sRGB) else { return nil }
        var ys: [Int] = []
        for y in 0..<(rep.pixelsHigh - 2) {
            for coluna in x {
                guard let cor = rep.colorAt(x: coluna, y: y)?.usingColorSpace(.sRGB),
                      cor.alphaComponent > 0.5 else { continue }
                if abs(cor.redComponent - fundo.redComponent) > 0.05
                    || abs(cor.greenComponent - fundo.greenComponent) > 0.05
                    || abs(cor.blueComponent - fundo.blueComponent) > 0.05 {
                    ys.append(y)
                    break
                }
            }
        }
        guard let primeira = ys.first, let ultima = ys.last else { return nil }
        return (Double(primeira) + Double(ultima)) / 2
    }

    /// **A prova por bitmap, lado do título.** O título da janela 03/05/06 cai
    /// na linha da plataforma, e não no meio de uma barra de 42.
    @Test("o título da barra das janelas cai na linha 22")
    func tituloNaLinha() throws {
        let rep = try #require(
            Render.bitmap(
                WindowTitleBar(title: "Responder").environment(ThemeStore()),
                size: CGSize(width: 820, height: WindowTitleBar<EmptyView>.height),
                theme: .tinta
            )
        )
        let centro = try #require(
            Self.linhaMedia(rep, papel: Theme.tinta.surface2, x: 200..<620)
        )
        // O título em y=\(centro); o semáforo, na mesma linha.
        #expect(abs(centro - Double(TrafficLightLayout.contentCenterFromTop)) <= 1)
    }

    /// **A prova por bitmap, lado da janela principal.** O recolhe ao lado
    /// do semáforo cai na linha 22 — a das bolinhas — e não no centro dos
    /// 64pt. A marca de 38pt segue no centro da toolbar.
    @Test("o recolhe ao lado do semáforo cai na linha 22")
    func barraPrincipalNaLinha() throws {
        let rep = try #require(
            Render.bitmap(
                WindowChrome(
                    workspace: .constant(.mail), query: .constant(""), accountCount: 2,
                    onToggleSidebar: {}, onToggleAgenda: {}, onCompose: {}
                ).environment(ThemeStore()),
                size: CGSize(width: 1200, height: WindowChrome.height), theme: .tinta
            )
        )
        // x=82…106 é o recolhe de 24pt depois do espaço reservado aos
        // semáforos. Medir só ele evita confundir a hairline com o conteúdo.
        let centro = try #require(
            Self.linhaMedia(rep, papel: Theme.tinta.surface2, x: 82..<107)
        )
        #expect(abs(centro - Double(TrafficLightLayout.contentCenterFromTop)) <= 1)
    }

    /// A barra das janelas mede o dobro da linha — e é isso que faz o centro
    /// dela **ser** a linha, sem conta pelo caminho.
    @Test("a barra das janelas mede duas vezes a linha da plataforma")
    func alturaDaBarra() {
        #expect(WindowTitleBar<EmptyView>.height == TrafficLightLayout.contentCenterFromTop * 2)
        #expect(WindowTitleBar<EmptyView>.height == 44)
    }

    /// O semáforo cabe: com centro em 22 e 14pt de lado, ele termina em 29 —
    /// dentro dos 44 da barra, e o alinhador cresce o container até lá.
    @Test("o semáforo cabe inteiro na barra das janelas")
    func semaforoCabe() {
        let altura = WindowTitleBar<EmptyView>.height
        let origem = TrafficLightLayout.buttonOriginY(barHeight: altura, buttonHeight: 14)
        #expect(origem >= 0)
        #expect(origem + 14 <= altura)
        #expect(
            TrafficLightLayout.centerFromTop(barHeight: altura, buttonHeight: 14)
                == TrafficLightLayout.contentCenterFromTop
        )
    }

    /// O último semáforo termina em x=70. O cabeçalho do compromisso não pode
    /// começar no mesmo pixel: ele segue o respiro de 14pt da barra principal.
    @Test("o cabeçalho do compromisso deixa respiro após os semáforos")
    func compromissoRespeitaSemaforos() {
        #expect(EventWindow.headerLeadingInset == WindowChrome.trafficLightInset + 14)
        #expect(EventWindow.headerLeadingInset == 84)
    }
}
