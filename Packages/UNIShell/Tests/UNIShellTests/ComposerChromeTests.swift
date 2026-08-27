import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Mede **tinta desenhada**, não geometria declarada.
///
/// A diferença importa: o defeito que este arquivo tranca é o glifo assentar
/// abaixo da linha média da cápsula, e a cápsula e o glifo têm a mesma
/// geometria declarada nos dois casos — o que muda é onde a tinta sai. Uma
/// asserção sobre `frame` passaria com o defeito no lugar.
///
/// A amostragem é de 4 pixels por ponto porque a 1 pixel por ponto o
/// arredondamento da linha de base vale meio ponto, que é da ordem do que se
/// quer medir. `ImageRenderer` aceita `scale`; a `NSWindow` fora da tela do
/// `Render` desenha sempre a 1. Aqui não se perde nada com o `ImageRenderer`:
/// o que ele deixa em branco são listas e campos de texto, e um botão da barra
/// não é nem um nem outro.
@MainActor
enum GlyphProbe {

    static func bitmap<V: View>(_ view: V, size: CGSize, theme: Theme, scale: Int) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(
            content: view
                .theme(theme)
                .environment(\.locale, Locale(identifier: "pt_BR"))
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = CGFloat(scale)
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    /// As faixas contíguas de tinta, em pontos, dentro do recorte pedido.
    /// Devolver faixas em vez de um extremo só é o que permite separar o glifo
    /// da barrinha de cor que fica embaixo dele.
    static func inkBands(
        _ rep: NSBitmapImageRep, scale: Int,
        xFrom: Int, xTo: Int, yFrom: Int, yTo: Int
    ) -> [ClosedRange<Double>] {
        var luma = [[Double]](
            repeating: [Double](repeating: 1, count: rep.pixelsWide), count: rep.pixelsHigh
        )
        var histogram = [Int](repeating: 0, count: 101)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let value = 0.299 * color.redComponent
                    + 0.587 * color.greenComponent
                    + 0.114 * color.blueComponent
                luma[y][x] = value
                histogram[Int((value * 100).rounded())] += 1
            }
        }
        // O fundo é a luminância mais frequente; tinta é o que está mais escuro
        // que ela. Fixar a cor do tema aqui daria um teste que quebra quando o
        // tema mudar de tom sem que nada tenha se desalinhado.
        let background = Double(histogram.firstIndex(of: histogram.max() ?? 0) ?? 100) / 100

        var inked: [Bool] = []
        for y in (yFrom * scale)..<(yTo * scale) {
            var any = false
            for x in (xFrom * scale)..<(xTo * scale) where background - luma[y][x] > 0.05 {
                any = true
                break
            }
            inked.append(any)
        }

        var bands: [ClosedRange<Double>] = []
        var start: Int?
        for (offset, on) in inked.enumerated() {
            if on, start == nil { start = offset }
            if !on, let from = start {
                bands.append(Double(yFrom * scale + from) / Double(scale)
                             ... Double(yFrom * scale + offset) / Double(scale))
                start = nil
            }
        }
        if let from = start {
            bands.append(Double(yFrom * scale + from) / Double(scale)
                         ... Double(yTo * scale) / Double(scale))
        }
        return bands
    }

    /// O centro do desenho: do topo da faixa mais alta ao pé da mais baixa.
    static func inkCenter(_ bands: [ClosedRange<Double>]) -> Double? {
        guard let top = bands.map(\.lowerBound).min(),
              let bottom = bands.map(\.upperBound).max() else { return nil }
        return (top + bottom) / 2
    }
}

@Suite("Glifos da barra de formatação")
@MainActor
struct ComposerGlyphTests {

    /// Todos os rótulos que a barra desenha, na ordem em que aparecem.
    /// São os do protótipo (`segFmt`, `segColor`, `segList`, `segAlign`,
    /// `segInsert` e `tablePick`, linhas 2097–2122 do `.dc.html`) — inclusive o
    /// `⌫`, que o `.dc.html` usa para `clearAll`.
    nonisolated static let labels = ["B", "I", "U", "S", "A", "▨", "•—", "1.", "⇤", "⇥", "⇐", "⇔", "⇒", "≡", "↗", "⌫"]

    /// A cápsula tem 26pt (protótipo `segWrap`: `height: 26px`), então a linha
    /// média está em 13. A literal está travada de propósito: derivá-la da
    /// altura que o próprio botão devolve daria um teste verdadeiro por
    /// construção, que passaria com o glifo em qualquer lugar.
    nonisolated static let capsuleMiddle = 13.0
    /// Meio pixel da amostragem a 4 por ponto, dos dois lados.
    nonisolated static let tolerance = 0.25

    @Test("cada glifo assenta na linha média da cápsula", arguments: labels)
    func glyphSitsOnTheCapsuleMiddle(label: String) throws {
        let theme = Theme.tinta
        let scale = 4
        let button = SegmentButton(label: label, on: false) {}
            // Encostado à esquerda para a divisória de 0,5pt do próprio botão
            // ficar em x = 0 e sair do recorte, em vez de virar uma coluna de
            // tinta de altura inteira no meio da medida.
            .frame(width: 44, height: 26, alignment: .leading)
            .background(theme.btn.color)

        let rep = try #require(
            GlyphProbe.bitmap(button, size: CGSize(width: 44, height: 26), theme: theme, scale: scale)
        )
        let bands = GlyphProbe.inkBands(rep, scale: scale, xFrom: 2, xTo: 44, yFrom: 0, yTo: 26)
        let center = try #require(GlyphProbe.inkCenter(bands), "\(label) não desenhou tinta nenhuma")

        #expect(
            abs(center - Self.capsuleMiddle) <= Self.tolerance,
            """
            "\(label)" está \(String(format: "%+.3f", center - Self.capsuleMiddle))pt fora da \
            linha média da cápsula (tinta em \(bands.map { String(format: "%.2f…%.2f", $0.lowerBound, $0.upperBound) })).
            """
        )
    }

    /// Por que a correção não pode sair das métricas da fonte pedida.
    @Test("a tinta do glifo de reserva não fica onde a fonte pedida diria")
    func fallbackGlyphsAreMeasuredNotAssumed() {
        let font = NSFont.systemFont(ofSize: 12)
        let letter = GlyphMetrics.ink(of: "B", font: font)
        let arrow = GlyphMetrics.ink(of: "⇔", font: font)

        #expect(!letter.isEmpty)
        #expect(!arrow.isEmpty)
        // Medido nesta máquina: o "B" tem o centro da tinta a 4,23pt da linha de
        // base e o "⇔" a 3,05pt, porque o segundo é desenhado por outra face.
        // Corrigir os dois pela mesma métrica deixaria um deles fora de linha —
        // que é exatamente o defeito de origem.
        #expect(
            abs(letter.middle - arrow.middle) > 1,
            "a diferença entre as faces sumiu: \(letter.middle) contra \(arrow.middle)"
        )
    }
}

@Suite("Cápsulas da barra de formatação")
@MainActor
struct ComposerToolbarCapsuleTests {

    /// Larguras das cápsulas da barra, em pontos, na ordem em que aparecem.
    private func capsuleWidths() throws -> [Double] {
        let theme = Theme.tinta
        let scale = 1
        let bar = ComposerToolbar(reading: .blank) { _ in }
        // Aqui é a `NSWindow` fora da tela, não o `ImageRenderer`: a barra tem
        // dois `Picker`, e o `ImageRenderer` desenha controle nativo como um
        // bloco de "não suportado" — a primeira cápsula sairia com 201pt.
        let rep = try #require(
            Render.bitmap(bar, size: CGSize(width: 820, height: 44), theme: theme)
        )
        // A faixa tem 9pt de folga em cima e a cápsula 26pt: a linha média cai
        // em y = 22. Mede-se ali, onde toda cápsula tem fundo e nenhuma tem
        // borda horizontal.
        let row = Int(22.0 * Double(scale))
        var luma = [Double](repeating: 1, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: row) else { continue }
            luma[x] = 0.299 * color.redComponent
                + 0.587 * color.greenComponent
                + 0.114 * color.blueComponent
        }
        // O fundo da faixa (`--surface2`) é o que está na folga de 18pt à
        // esquerda da primeira cápsula. Tirar a moda da linha não serve: as
        // cápsulas cobrem mais linha que as folgas, e o tom mais frequente
        // acaba sendo o **fundo do botão**.
        let background = luma[2]

        var runs: [(from: Int, to: Int)] = []
        var start: Int?
        for x in 0..<rep.pixelsWide {
            let onCapsule = abs(luma[x] - background) > 0.004
            if onCapsule, start == nil { start = x }
            if !onCapsule, let from = start {
                runs.append((from, x))
                start = nil
            }
        }
        if let from = start { runs.append((from, rep.pixelsWide)) }

        // O interior do `Picker` nativo tem trechos exatamente da cor da faixa,
        // então a primeira cápsula sai picada. As folgas entre cápsulas são de
        // 7pt (protótipo: `gap: 7px`); qualquer buraco menor que isso é dentro
        // de uma cápsula, não entre duas.
        var merged: [(from: Int, to: Int)] = []
        for run in runs {
            if let last = merged.last, Double(run.from - last.to) / Double(scale) < 5 {
                merged[merged.count - 1].to = run.to
            } else {
                merged.append(run)
            }
        }
        return merged.map { Double($0.to - $0.from) / Double(scale) }.filter { $0 >= 4 }
    }

    /// O defeito: `⌫` funciona, mas dividia cápsula com o `↗`, que está
    /// desabilitado neste marco. Uma moldura só em volta de um item apagado e
    /// um vivo lê como grupo inteiro morto — o dono do projeto relatou que o
    /// botão "parece desabilitado".
    ///
    /// A barra passa a terminar em **três cápsulas soltas** de 30pt — `↗`, `⌫`
    /// e `⊞` (protótipo `tablePick.btnStyle`: `width: 30px`) — em vez de um
    /// grupo de dois seguido do `⊞`. Antes desta mudança as três últimas
    /// mediam 114, 59 e 32.
    ///
    /// A medida inclui cerca de 1pt de sombra de cada lado (`--btn-shadow`),
    /// daí a folga de 3pt. Ela é pequena o bastante para não confundir uma
    /// cápsula solta de 30pt com o grupo de dois, de 57pt.
    @Test("o botão de limpar formatação tem cápsula própria")
    func clearFormattingStandsAlone() throws {
        let widths = try capsuleWidths()
        let solos = Array(widths.suffix(3))
        #expect(solos.count == 3, "cápsulas medidas: \(widths)")
        #expect(
            solos.allSatisfy { abs($0 - 30) <= 3 },
            "as três últimas cápsulas deviam ter 30pt cada; medidas \(solos) de \(widths)"
        )
    }
}
