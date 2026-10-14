import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O defeito que este arquivo existe para impedir: os painéis de cor e realce
/// abrem num `overlay` que desce por cima do editor. O `zIndex` de dentro da
/// barra só ordena os irmãos dela — sem `zIndex` na barra inteira, dentro do
/// empilhamento da janela, o editor é desenhado depois e **deceva o painel**.
/// O usuário via uma lasca branca e não conseguia escolher cor nenhuma.
///
/// Nenhum teste de unidade pegava isso, e renderizar a barra sozinha também
/// não pegaria: o defeito só existe quando ela está dentro da janela. Daí a
/// comparação de dois desenhos da **janela inteira**.
@Suite("Painéis da barra de formatação")
@MainActor
struct ToolbarPanelTests {

    private func window(_ panel: ComposerToolbar.Panel?) async -> NSBitmapImageRep? {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return Render.bitmap(
            ComposerWindow(store: store, mode: .new(accountID: nil), debugOpenPanel: panel),
            size: UNIWindow.Size.composer,
            theme: .tinta
        )
    }

    /// Quantos pixels diferem entre dois desenhos, na faixa logo abaixo da
    /// barra — que é onde o painel cai e onde o editor o cobria.
    private func differingPixels(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep, belowY: Int, height: Int
    ) -> Int {
        var count = 0
        for y in belowY..<min(belowY + height, a.pixelsHigh) {
            for x in 0..<a.pixelsWide {
                if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
            }
        }
        return count
    }

    @Test("o painel de cor aparece inteiro, não decepado pelo editor")
    func colorPanelIsVisible() async throws {
        let closed = try #require(await window(nil))
        let open = try #require(await window(.color))

        // As seis amostras medem ~310×52pt. Se o painel estiver coberto,
        // sobram só os poucos pixels que escapam na borda da barra.
        let changed = differingPixels(closed, open, belowY: 200, height: 120)
        #expect(changed > 8_000, "só \(changed) pixels mudaram: o painel está sendo decepado")
    }

    /// O mock tem **um** botão de cor, e a barra tinha dois. O realce não
    /// podia sumir junto com o `▨`: ele é a segunda seção da mesma folha, e a
    /// porta `.highlight` do harness abre essa mesma folha.
    @Test("o realce continua alcançável, na mesma folha da cor")
    func highlightPanelIsVisible() async throws {
        let closed = try #require(await window(nil))
        let open = try #require(await window(.highlight))
        let changed = differingPixels(closed, open, belowY: 200, height: 160)
        #expect(changed > 8_000, "só \(changed) pixels mudaram: a folha está sendo decepada")
    }

    /// E a folha mostra as duas paletas: um amarelo de realce (`#FBEFA6`) só
    /// existe na seção de baixo, e um vermelho de texto (`#B3261E`) só na de
    /// cima. Sem as duas, uma das seções não desenhou.
    @Test("a folha mostra as amostras de cor e as de realce")
    func sheetShowsBothPalettes() async throws {
        let open = try #require(await window(.color))
        #expect(
            open.pixels(matching: ComposerFormatting.highlights[1].hex) > 100,
            "a seção de realce não desenhou"
        )
        #expect(
            open.pixels(matching: ComposerFormatting.textColors[1].hex) > 100,
            "a seção de cor do texto não desenhou"
        )
    }
}
