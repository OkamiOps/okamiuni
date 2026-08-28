import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O defeito: os menus de fonte, corpo e conta eram `Picker(.menu)`, que é um
/// `NSPopUpButton`. O AppKit pinta a **moldura dele** por cima da cápsula do
/// design — o `segWrap` do protótipo vira um controle do macOS. Foi o "tem
/// vários dropdown usando o padrao do sistema em vez de custom" do dono do
/// projeto.
///
/// ## O que se mede, e por que é isto
///
/// O controle do protótipo é **chapado**: `appearance: none; border: none;
/// background: transparent` dentro de um `segWrap` que é `background: var(--btn)`.
/// Quer dizer: fora dos glifos e da divisória, todo pixel de dentro da cápsula é
/// o token `btn`. Um `NSPopUpButton` pinta a área inteira com o degradê dele, e
/// nenhum pixel sobra no token.
///
/// A medida é a **fração** do interior que está no token, e não uma linha ou um
/// pixel escolhido a dedo: fração não depende de onde exatamente o glifo caiu, e
/// separa os dois desenhos por dois zeros. Medido nesta máquina, com o `Picker`
/// de volta no lugar:
///
/// | | com `Picker` | com `ComposerSelect` |
/// |---|---|---|
/// | barra, tema `tinta` | 0,0021 | 0,7703 |
/// | barra, tema `noite` | 0,0040 | 0,8095 |
/// | linha "De", `tinta` | 0,0000 | 0,7618 |
///
/// O corte fica em 0,5 — longe dos dois lados.
@Suite("Menus do composer são desenhados por nós")
@MainActor
struct ComposerSelectTests {

    /// Quanto do retângulo está no token `btn`.
    ///
    /// A tolerância de 0,02 por canal é a mesma que o resto da suíte usa, e a
    /// armadilha dela está registrada em `docs/decisoes-de-engenharia.md`: em
    /// `tinta`, `surface` e `btn` caem dentro dela. Por isso os retângulos
    /// medidos aqui ficam **inteiramente dentro** da cápsula, onde o fundo da
    /// linha não entra na conta.
    private func tokenFraction(
        _ image: NSBitmapImageRep, x: Range<Int>, y: Range<Int>, token: TokenColor
    ) -> Double {
        guard let target = token.nsColor.usingColorSpace(.deviceRGB) else { return 0 }
        var hit = 0, total = 0
        for row in y {
            for column in x {
                total += 1
                guard let pixel = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB)
                else { continue }
                if abs(pixel.redComponent - target.redComponent) < 0.02,
                   abs(pixel.greenComponent - target.greenComponent) < 0.02,
                   abs(pixel.blueComponent - target.blueComponent) < 0.02 {
                    hit += 1
                }
            }
        }
        return total > 0 ? Double(hit) / Double(total) : 0
    }

    /// A cápsula de fonte e corpo da barra: `padding: 9px 18px` em volta de um
    /// `segWrap` de 26pt de altura e 112 + 54 de largura. O retângulo medido é o
    /// interior dela, um ponto para dentro da borda em cada lado.
    @Test("a cápsula de fonte e corpo é chapada no token, sem moldura do sistema", arguments: [
        "tinta", "noite",
    ])
    func fontCapsuleIsFlat(themeID: String) async throws {
        let theme = try #require(Theme.all.first { $0.id == themeID })
        let bar = try #require(
            Render.snapshot(
                ComposerToolbar(reading: .blank) { _ in },
                named: "select-barra-\(themeID)",
                size: CGSize(width: 820, height: 44),
                theme: theme
            )
        )
        let flat = tokenFraction(bar, x: 20..<183, y: 11..<34, token: theme.btn)
        #expect(
            flat > 0.5,
            "só \(flat) da cápsula está no token `btn`: voltou a moldura do sistema"
        )
    }

    /// A mesma prova para o seletor de conta da linha "De" (tela 06).
    ///
    /// **Só no tema claro, e o motivo importa.** Medido: com o `Picker` de
    /// volta, este mesmo retângulo dá 0,0 em `tinta` e **0,795** em `noite` — o
    /// controle do sistema muda de tamanho, o retângulo passa a pegar o fundo
    /// da linha, e no tema escuro esse fundo cai dentro da tolerância de `btn`.
    /// Quer dizer: a mesma asserção passaria com o defeito no lugar. Um teste
    /// que passa com o código quebrado não vale, então ele fica só onde separa.
    @Test("o seletor de conta da linha De também é chapado no token")
    func accountSelectIsFlat() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let window = try #require(
            Render.snapshot(
                ComposerWindow(store: store, mode: .new(accountID: nil)),
                named: "select-de-tinta",
                size: CGSize(width: 820, height: 620),
                theme: .tinta
            )
        )
        let flat = tokenFraction(window, x: 85..<196, y: 53..<76, token: Theme.tinta.btn)
        #expect(
            flat > 0.5,
            "só \(flat) do seletor de conta está no token `btn`: voltou a moldura do sistema"
        )
    }

    /// O menu abre num `popover`, que é janela própria e não é desenhado pelo
    /// `Render` — a janela do harness nunca é a janela-chave. O que dá para
    /// provar aqui é o **conteúdo** que ele vai mostrar, e é o que interessa:
    /// que a lista deixou de ter seis fontes.
    ///
    /// A aritmética da lista está em `FontCatalogTests`, no `UNICore`. O que
    /// falta lá, e mora aqui, é que a barra de fato monta os dois blocos a
    /// partir das fontes **desta máquina**.
    @Test("o menu de fonte tem as seis do design e as instaladas, nesta ordem")
    func fontMenuHasBothGroups() throws {
        let groups = ComposerFormatting.familyGroups
        #expect(groups.first?.title == "Do design")
        #expect(groups.first?.options.map(\.value) == FontCatalog.design.map(\.value))

        // Qualquer Mac tem mais famílias do que as seis do design. Se este
        // ramo não existir, a barra continua limitada e o defeito voltou.
        let installed = try #require(groups.dropFirst().first)
        #expect(installed.title == "Instaladas")
        #expect(
            installed.options.count > 20,
            "só \(installed.options.count) famílias instaladas: a lista voltou a ser fechada"
        )
        // E nenhuma das seis do design aparece repetida embaixo.
        let design = Set(FontCatalog.design.map(\.value))
        #expect(installed.options.allSatisfy { !design.contains($0.value) })
    }

    /// O controle fechado escreve o rótulo, não o valor. É o que impede
    /// `-apple-system` de aparecer na barra depois de a pessoa escolher
    /// "SF Pro".
    @Test("o corpo vira texto no menu e volta a número no comando")
    func sizeRoundTrip() throws {
        let options = try #require(ComposerFormatting.sizeGroups.first).options
        #expect(options.map(\.value) == ["11", "13", "15", "17", "20", "24", "32"])
        #expect(options.allSatisfy { Double($0.value) != nil })
    }
}
