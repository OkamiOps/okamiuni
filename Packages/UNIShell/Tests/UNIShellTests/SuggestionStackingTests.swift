import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Onde a barra de formatação está, medido no próprio desenho.
///
/// A faixa da barra é a **única** parte da medida que precisa ser localizada, e
/// cravar a coordenada seria o pior jeito de fazê-lo: qualquer linha nova no
/// cabeçalho — Cc aberto, Cco aberto, a linha "De" da tela 06 — empurra a barra
/// para baixo, e o teste passaria a medir outra faixa em silêncio.
///
/// A âncora é a cápsula de fonte e corpo. Ela é o único pedaço da barra pintado
/// no token `btn`, e mede 26pt de altura. A tolerância é **0,008 por canal**, e
/// não os 0,02 do resto da suíte, porque em `tinta` `surface` e `btn` diferem
/// só 0,02 — com a tolerância larga o editor inteiro responderia "sou a
/// cápsula". A armadilha está registrada em `docs/decisoes-de-engenharia.md`.
@MainActor
enum ToolbarBand {

    /// As linhas que a cápsula ocupa, ou nulo se ela não foi encontrada.
    ///
    /// `probeX` tem de cair **dentro** da cápsula e **fora** dos glifos: entre
    /// o fim do rótulo da fonte e o `▼`. Na janela isso é x = 100 (a cápsula
    /// vai de 18 a 185, o rótulo acaba em ~91 e o `▼` começa em 119); na faixa
    /// do leitor, x = 120.
    static func capsuleRows(
        in image: NSBitmapImageRep, probeX: Int, theme: Theme, searching range: Range<Int>
    ) -> ClosedRange<Int>? {
        guard let token = theme.btn.nsColor.usingColorSpace(.deviceRGB) else { return nil }
        var run: [Int] = []
        var best: [Int] = []
        for y in range {
            let pixel = image.colorAt(x: probeX, y: y)?.usingColorSpace(.deviceRGB)
            let matches = pixel.map {
                abs($0.redComponent - token.redComponent) < 0.008
                    && abs($0.greenComponent - token.greenComponent) < 0.008
                    && abs($0.blueComponent - token.blueComponent) < 0.008
            } ?? false
            if matches, run.isEmpty || run.last == y - 1 {
                run.append(y)
            } else {
                if run.count > best.count { best = run }
                run = matches ? [y] : []
            }
        }
        if run.count > best.count { best = run }
        guard let first = best.first, let last = best.last else { return nil }
        return first...last
    }

    /// Quantos pixels diferem entre dois desenhos **dentro** da faixa da barra,
    /// com 6pt de folga para pegar a moldura e a borda dela.
    static func differingPixels(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep, capsule: ClosedRange<Int>
    ) -> Int {
        var count = 0
        let range = max(0, capsule.lowerBound - 6)...min(a.pixelsHigh - 1, capsule.upperBound + 6)
        for y in range {
            for x in 0..<min(a.pixelsWide, b.pixelsWide)
            where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                count += 1
            }
        }
        return count
    }
}

/// O defeito que este arquivo existe para impedir: a lista de sugestões de
/// contato abre num `overlay` que desce por cima da linha seguinte, e a linha
/// seguinte pode ser a **barra de formatação**. O `zIndex` de dentro do
/// `RecipientField` só ordena os irmãos dele; quem decide se a barra é
/// desenhada antes ou depois da linha de destinatário é o empilhamento da
/// **janela**. A barra vinha com 20 e as linhas de destinatário com 8 e 7,
/// então ela era desenhada por último e apagava a lista na altura dela — o
/// print do dono do projeto, com os nomes ilegíveis debaixo da barra, em Cc.
///
/// ## O que precisou ser medido antes de a medida valer
///
/// A primeira versão deste teste comparava a **caixa inteira** da diferença, e
/// passava com o defeito no lugar. O motivo: o cartão mede ~280pt de altura e a
/// barra só ~50. Coberto, ele continua aparecendo inteiro acima da barra (na
/// própria linha do campo) e abaixo dela (por cima do editor, que a linha ganha
/// por ser desenhada depois). A caixa media 312pt nos dois casos.
///
/// O defeito vive **só na fatia da barra**, e é ela que se mede. Medido nesta
/// máquina, com o empilhamento antigo de volta:
///
/// | campo | com 8/7/6 contra 20 | com o empilhamento que desce |
/// |---|---|---|
/// | Para | 0 | 18.821 |
/// | Cc | 0 | 13.718 |
/// | Cco | 0 | 13.718 |
///
/// Zero, exato: naquela faixa a barra cobre a lista pixel a pixel.
@Suite("Empilhamento das listas de sugestão")
@MainActor
struct SuggestionStackingTests {

    private static let size = CGSize(width: 820, height: 620)
    /// Dentro da cápsula de fonte e corpo, fora dos glifos. Ver `ToolbarBand`.
    private static let probeX = 100

    /// A janela com a linha do campo aberta. `query` nula abre a linha **sem**
    /// a lista — é a referência certa, porque abrir Cc empurra tudo que vem
    /// depois para baixo, e comparar contra a janela de linha fechada acusaria
    /// a diferença de layout como se fosse a lista.
    private func window(
        _ slot: ComposerWindow.RecipientSlot, query: String?
    ) async -> NSBitmapImageRep? {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return Render.snapshot(
            ComposerWindow(
                store: store, mode: .new(accountID: nil),
                debugSuggestion: .init(slot: slot, query: query)
            ),
            named: "janela-\(slot)-\(query == nil ? "sem-lista" : "com-lista")",
            size: Self.size,
            theme: .tinta
        )
    }

    @Test("a lista de sugestões passa por cima da barra de formatação", arguments: [
        ComposerWindow.RecipientSlot.to, .cc, .bcc,
    ])
    func suggestionListDrawsOverToolbar(slot: ComposerWindow.RecipientSlot) async throws {
        let closed = try #require(await window(slot, query: nil))
        let open = try #require(await window(slot, query: "a"))

        let capsule = try #require(
            ToolbarBand.capsuleRows(
                in: closed, probeX: Self.probeX, theme: .tinta, searching: 120..<400
            ),
            "a cápsula de fonte e corpo não foi encontrada: a âncora da medida saiu do lugar"
        )
        // 26pt de cápsula, menos a borda de cada lado. Se a busca tivesse
        // pegado o editor ou o rodapé, a altura denunciaria.
        let height = capsule.upperBound - capsule.lowerBound + 1
        #expect(height > 16 && height < 32, "a âncora mede \(height)pt: não é a cápsula da barra")

        let changed = ToolbarBand.differingPixels(closed, open, capsule: capsule)
        let complaint = "só \(changed) pixels mudaram na faixa da barra (\(capsule)): "
            + "a lista de \(slot) está sendo coberta por ela"
        #expect(changed > 8_000, "\(complaint)")
    }
}

/// A faixa de resposta do leitor tem o mesmo empilhamento a defender. Ela já
/// vinha com os números na ordem certa — o que não é o mesmo que estar
/// provado: sem teste, o próximo conserto na faixa troca a ordem e ninguém
/// percebe até o print seguinte.
///
/// `QuickReplyBandTests` já cobre a lista do campo "Para" daqui — e cobre com a
/// caixa inteira, que é justamente a medida que **não** enxerga este defeito. O
/// que falta, e mora aqui, são Cc e Cco medidos na fatia da barra.
@Suite("Empilhamento das listas na faixa de resposta")
@MainActor
struct BandSuggestionStackingTests {

    private static let size = CGSize(width: 700, height: 520)
    /// A barra compacta é mais estreita e começa mais à esquerda que a da
    /// janela; a cápsula dela responde em x = 120.
    private static let probeX = 120

    private func band(query: String?) async -> NSBitmapImageRep? {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        guard let message = store.messages.first(where: { $0.id == "m1" }) else { return nil }
        return Render.snapshot(
            QuickReplyBand(
                store: store, message: message, onPromote: { _ in }, expandRequest: 1,
                seededCopyQuery: query, debugCopiesOpen: true
            )
            .environment(ThemeStore())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.tinta.surface.color),
            named: "faixa-cc-\(query == nil ? "sem-lista" : "com-lista")",
            size: Self.size,
            theme: .tinta
        )
    }

    /// A faixa semeia Cc e Cco com a mesma busca, então a medida cobre as duas
    /// listas de uma vez.
    @Test("as listas de Cc e Cco da faixa passam por cima da barra compacta")
    func bandCopyListsDrawOverToolbar() async throws {
        let closed = try #require(await band(query: nil))
        let open = try #require(await band(query: "a"))

        let capsule = try #require(
            ToolbarBand.capsuleRows(
                in: closed, probeX: Self.probeX, theme: .tinta, searching: 100..<300
            ),
            "a cápsula da barra compacta não foi encontrada"
        )
        let height = capsule.upperBound - capsule.lowerBound + 1
        #expect(height > 16 && height < 32, "a âncora mede \(height)pt: não é a cápsula da barra")

        let changed = ToolbarBand.differingPixels(closed, open, capsule: capsule)
        // Medido: **4.098** com a barra desenhada por cima — não zero, porque a
        // folga de 6pt em volta da cápsula ainda pega a ponta da lista de Cco
        // que escapa acima dela. O corte de 6.000 fica entre esse número e o do
        // desenho certo.
        #expect(
            changed > 6_000,
            "só \(changed) pixels mudaram na faixa da barra compacta: as listas estão cobertas"
        )
    }
}
