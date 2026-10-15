import AppKit
import SwiftUI
import Testing
import UNIDesign
@testable import UNIShell

/// Onde os semáforos **nativos** caem na janela de Configurações.
///
/// Eles não aparecem num retrato do conteúdo: são views do AppKit que moram no
/// `NSThemeFrame`, fora do `contentView`. Medi-los por bitmap da página não
/// prova nada — foi o erro da M3-21, registrado em `TrafficLightAudit`. Aqui a
/// fonte é a moldura de verdade: `NSWindow.standardWindowButton`, numa janela
/// `.titled` de 1280×800, a mesma medida do artboard.
@MainActor
@Suite("Semáforos de Configurações")
struct ConfigTrafficLightTests {

    /// O artboard: `width: 1280px; height: 800px`.
    private static let artboard = NSSize(width: 1_280, height: 800)

    private func janela() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: -50_000, y: -50_000,
                width: Self.artboard.width, height: Self.artboard.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.orderBack(nil)
        return window
    }

    /// As três medidas que o mock fixa, contadas do topo e da esquerda **da
    /// janela**:
    ///
    /// - a janela tem `padding: 10px` e o `<nav>`, `padding: 14px 12px`;
    /// - a fila de bolinhas tem `padding: 2px 6px 16px` e bolinhas de 11 com
    ///   `gap: 5px`.
    ///
    /// Isso põe o centro delas em 10 + 14 + 2 + 5,5 = **31,5** e a fila em
    /// x 28..71. Os botões do sistema têm 14pt, não 11: com a mesma folga de 5
    /// a fila mede 52 e, centrada na mesma faixa, começa em 23,5.
    @Test("as bolinhas caem na linha e na coluna que a navegação reserva")
    func semaforosNaLinhaDoMock() throws {
        let window = janela()
        defer { window.close() }

        let aligner = TrafficLightAligner(
            barHeight: TrafficLightLayout.configBarHeight,
            centerFromTop: TrafficLightLayout.configCenterFromTop,
            compactRow: true,
            rowLeading: TrafficLightLayout.configLeading,
            rowSpacing: TrafficLightLayout.configSpacing
        )
        aligner.attach(to: window)
        defer { aligner.detach() }

        let botoes = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .map { try #require(window.standardWindowButton($0)) }

        for (indice, botao) in botoes.enumerated() {
            // A barra de título não é invertida: o y do quadro conta de baixo
            // para cima dentro dela. O centro, contado do topo da janela, é o
            // que o mock desenha.
            let centro = TrafficLightLayout.centerFromTop(
                barHeight: TrafficLightLayout.configBarHeight,
                buttonHeight: botao.frame.height
            )
            _ = centro
            let centroReal = TrafficLightLayout.configBarHeight
                - botao.frame.origin.y - botao.frame.height / 2
            #expect(
                abs(centroReal - 31.5) <= 0.5,
                "o botão \(indice) está em \(centroReal) e o mock o desenha em 31,5"
            )
            #expect(
                abs(botao.frame.origin.x - (23.5 + CGFloat(indice) * 19)) <= 0.5,
                "o botão \(indice) está em x=\(botao.frame.origin.x)"
            )
        }

        // E a fila inteira cabe **dentro** do painel de navegação, com folga.
        // O painel começa em x=10 e termina em 10 + 244 = 254.
        let primeiro = try #require(botoes.first)
        let ultimo = try #require(botoes.last)
        let inicio = primeiro.frame.minX
        let fim = ultimo.frame.maxX
        #expect(inicio - ConfigMetrics.windowPadding >= 12, "sem respiro à esquerda: \(inicio)")
        #expect(
            fim <= ConfigMetrics.windowPadding + ConfigMetrics.navWidth - 12,
            "a fila encosta na borda direita da navegação: \(fim)"
        )

        // O container cresceu para a fila caber **clicável**: uma `NSView`
        // desenha fora dos próprios limites, mas não recebe clique fora deles.
        let container = try #require(primeiro.superview?.superview)
        #expect(container.frame.height == TrafficLightLayout.configBarHeight)
        #expect(
            container.frame.height >= 31.5 + primeiro.frame.height / 2,
            "o container de \(container.frame.height)pt corta a fila"
        )
    }

    /// A navegação reserva exatamente a altura que a fila ocupa: `padding-top`
    /// de 14 no painel, 2 na fila, 11 de bolinha e 16 de folga antes do título.
    @Test("o vão reservado na navegação bate com onde a plataforma desenha")
    func reservaBateComAPlataforma() {
        let centroNoPainel: CGFloat = 14 + 2 + 5.5
        let centroNaJanela = ConfigMetrics.windowPadding + centroNoPainel
        #expect(abs(centroNaJanela - TrafficLightLayout.configCenterFromTop) <= 0.01)
    }

    /// A moldura da janela de verdade, fotografada: é o `NSThemeFrame` que
    /// contém os semáforos, e é ele que mostra se eles estão onde o desenho os
    /// põe. Sai em `UNI_RENDER_DIR` para conferência humana.
    @Test("a moldura com os semáforos sai em PNG para conferência")
    func retratoDaMoldura() throws {
        let window = janela()
        defer { window.close() }

        window.contentView = NSHostingView(
            rootView: ZStack {
                Backdrop()
                HStack(alignment: .top, spacing: ConfigMetrics.panelGap) {
                    Color.clear
                        .frame(width: ConfigMetrics.navWidth)
                        .frame(maxHeight: .infinity)
                        .configPanel(.vidro)
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .configPanel(.vidro)
                }
                .padding(ConfigMetrics.windowPadding)
            }
            .theme(.vidro)
            .frame(width: Self.artboard.width, height: Self.artboard.height)
        )

        let aligner = TrafficLightAligner(
            barHeight: TrafficLightLayout.configBarHeight,
            centerFromTop: TrafficLightLayout.configCenterFromTop,
            compactRow: true,
            rowLeading: TrafficLightLayout.configLeading,
            rowSpacing: TrafficLightLayout.configSpacing
        )
        aligner.attach(to: window)
        defer { aligner.detach() }

        let frame = try #require(window.standardWindowButton(.closeButton)?.superview?.superview?.superview)
        frame.layoutSubtreeIfNeeded()
        let rect = NSRect(x: 0, y: frame.bounds.height - 120, width: 420, height: 120)
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: rect))
        frame.cacheDisplay(in: rect, to: rep)

        if let dir = Render.outputDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("Config-semaforos-claro.png"))
            }
        }
        #expect(rep.pixelsWide > 0)
    }
}
