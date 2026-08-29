import AppKit
import Foundation
import SwiftUI
import Testing
import UNIDesign
@testable import UNIShell

/// A tela do dono da M3-21: a Kickstargogo abriu "em branco" e carregou
/// enquanto ele escrevia a reclamação.
///
/// A `WebView` nasce com **um ponto** de altura e só cresce quando a régua da
/// M3-18/M3-20 responde. Entre a abertura e a resposta havia uma coluna
/// vazia — e vazio calado se lê como defeito. Agora há uma espera com cara de
/// espera, no mesmo idioma do "Carregando corpo…" da M3-3.
@Suite("O bloco de HTML enquanto ele não pintou")
@MainActor
struct ReaderHTMLLoadingTests {

    private static let html = "<html><body><p>Uma mensagem qualquer.</p></body></html>"
    private static let tamanho = CGSize(width: 700, height: 300)

    private static func desenho(pintou: Bool) -> NSBitmapImageRep? {
        Render.bitmap(
            ReaderHTMLSection(html: html, debugPintou: pintou),
            size: tamanho, theme: .tinta
        )
    }

    /// Quantos pixels não são o papel do tema — a tinta que a seção pôs na tela.
    private static func tinta(em rep: NSBitmapImageRep) -> Int {
        let papel = Theme.tinta.surface.nsColor.usingColorSpace(.sRGB)
        var contados = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let cor = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      cor.alphaComponent > 0.1, let papel else { continue }
                if abs(cor.redComponent - papel.redComponent) > 0.02
                    || abs(cor.greenComponent - papel.greenComponent) > 0.02
                    || abs(cor.blueComponent - papel.blueComponent) > 0.02 {
                    contados += 1
                }
            }
        }
        return contados
    }

    @Test("Enquanto não pinta, a espera está na tela")
    func aEsperaAparece() throws {
        let esperando = try #require(Self.desenho(pintou: false))
        #expect(
            Self.tinta(em: esperando) > 0,
            "a seção continua sendo uma coluna em branco enquanto o email carrega"
        )
    }

    @Test("Quando o conteúdo pinta, a espera some")
    func aEsperaSome() throws {
        let esperando = try #require(Self.desenho(pintou: false))
        let pintado = try #require(Self.desenho(pintou: true))
        // Pintada, a seção devolve a área para a mensagem: no harness a
        // `WebView` não desenha nada, e o que sobra é o papel limpo.
        #expect(Self.tinta(em: pintado) == 0, "a espera ficou na tela depois de a mensagem pintar")
        #expect(esperando.pixelsDiffering(from: pintado) > 0)
    }

    @Test("A frase é a do leitor, e a espera tem teto")
    func fraseETeto() {
        #expect(ReaderHTMLSection.carregando == "Carregando a mensagem…")
        // Teto, e não promessa: sem ele, uma `WebView` que nunca respondesse
        // deixaria a frase para sempre no lugar do email.
        #expect(ReaderHTMLSection.tetoDaEspera <= .seconds(8))
        #expect(ReaderHTMLSection.tetoDaEspera > .zero)
    }
}
