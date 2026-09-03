import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Os dois defeitos que o render da Tarefa 3 mostrou, e que nenhum teste de
/// lá pegava — porque todos mediam **o que foi desenhado**, e nenhum mediu
/// **o que ficou coberto**.
///
/// 1. O botão flutuante "Perguntar · ⌘J" sentava em cima de "O que você
///    prometeu", o rodapé da coluna do dia.
/// 2. A lista de prioridades rolava sem dizer que rolava: a linha da Maria
///    (seção Lead) desaparecia na aresta dura do recorte, com o rodapé
///    "Tirei da lista" logo abaixo — a aparência exata de "acabou".
@Suite("Dashboard 08 · nada pinta por cima de nada")
@MainActor
struct Dashboard08SobreposicaoTests {

    private static let size = CGSize(width: 1_440, height: 852)

    private func tela(_ store: MailStore) -> some View {
        DashboardScreen(
            store: store,
            now: DiaDoDono.agoraMinuto,
            today: DiaDoDono.agora,
            drafts: DiaDoDono.rascunhos,
            conversation: AssistantConversation(
                scope: .email,
                context: .init(subject: "Caixa e agenda de hoje"),
                destination: .init(label: "Codex · ChatGPT", detail: "", isLocal: false),
                engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
            ),
            filter: .constant(.standard),
            selectedMailID: .constant("jack"),
            readingMailID: .constant(nil)
        )
        .environment(ThemeStore())
    }

    // MARK: - Réguas

    private func faixa(_ a: Int, _ b: Int) -> Range<Int> { a < b ? a..<b : a..<a }

    private func casa(
        _ rep: NSBitmapImageRep, _ x: Int, _ y: Int,
        _ alvo: NSColor, _ tolerance: Double
    ) -> Bool {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              c.alphaComponent > 0.9 else { return false }
        return abs(c.redComponent - alvo.redComponent) < tolerance
            && abs(c.greenComponent - alvo.greenComponent) < tolerance
            && abs(c.blueComponent - alvo.blueComponent) < tolerance
    }

    /// A borda esquerda do botão flutuante, medida pelo **ícone** dele.
    ///
    /// O preenchimento não serve de régua: em `tinta` o `btn` está a um passo
    /// do `paper` e a corrida de cor engole a coluna inteira. O ícone é
    /// `accent`, a cor mais distante do fundo nos dois temas, e na faixa do
    /// rodapé ele é a única coisa em accent do lado direito da tela.
    private func bordaEsquerdaDoBotao(
        _ rep: NSBitmapImageRep, theme: Theme, y: Range<Int>
    ) -> Int? {
        guard let alvo = theme.accent.nsColor.usingColorSpace(.sRGB) else { return nil }
        var menor: Int?
        for py in y where py < rep.pixelsHigh {
            for px in 1_150..<rep.pixelsWide where casa(rep, px, py, alvo, 0.06) {
                menor = min(menor ?? px, px)
                break
            }
        }
        return menor.map { $0 - Int(DashboardMetrics.askButtonLeadingPadding) }
    }

    /// Quantos pixels desta faixa **não** são o fundo da tela.
    private func tintaSobre(
        _ rep: NSBitmapImageRep, theme: Theme, x: Range<Int>, y: Range<Int>
    ) -> Int {
        guard let fundo = theme.paper.nsColor.usingColorSpace(.sRGB) else { return -1 }
        var n = 0
        for py in y where py >= 0 && py < rep.pixelsHigh {
            for px in x where px >= 0 && px < rep.pixelsWide {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - fundo.redComponent) > 0.02
                    || abs(c.greenComponent - fundo.greenComponent) > 0.02
                    || abs(c.blueComponent - fundo.blueComponent) > 0.02 {
                    n += 1
                }
            }
        }
        return n
    }

    private func pixels(
        _ rep: NSBitmapImageRep, de token: TokenColor,
        x: Range<Int>, y: Range<Int>, tolerance: Double = 0.02
    ) -> Int {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        for py in y where py < rep.pixelsHigh {
            for px in x where px < rep.pixelsWide {
                if casa(rep, px, py, alvo, tolerance) { n += 1 }
            }
        }
        return n
    }

    /// O topo do botão flutuante, pelas medidas do mockup: ele mora
    /// `askButtonBottom` acima da aresta e tem `askButtonHeight` de altura.
    private var topoDoBotao: Int {
        Int(Self.size.height - DashboardMetrics.askButtonBottom
            - DashboardMetrics.askButtonHeight)
    }

    // MARK: - Defeito 1: o botão cobria "O que você prometeu"

    @Test("o botão Perguntar não pinta por cima do rodapé da coluna do dia")
    func askButtonDoesNotCoverThePromises() async throws {
        let store = await DiaDoDono.loja()
        for theme in [Theme.okami, Theme.tinta] {
            let rep = try #require(Render.bitmap(tela(store), size: Self.size, theme: theme))

            let esquerda = try #require(
                bordaEsquerdaDoBotao(rep, theme: theme, y: topoDoBotao..<852),
                "\(theme.id): o botão Perguntar sumiu do canto"
            )
            #expect(esquerda > 1_200, "\(theme.id): a borda medida em \(esquerda) não é o botão")

            // A faixa vertical do botão, **à esquerda dele**, dentro da coluna
            // do dia: ali só pode haver fundo. Com o rodapé "O que você
            // prometeu" ainda embaixo, a legenda dele cai exatamente aqui.
            //
            // A sombra do botão (a única da tela) sangra para a esquerda e é
            // parte dele: o recorte para onde ela alcança.
            let sombra = Int(DashboardMetrics.askShadowRadius * 2)
            let tinta = tintaSobre(
                rep, theme: theme,
                x: faixa(1_150, esquerda - sombra),
                y: faixa(topoDoBotao - 2, Int(Self.size.height))
            )
            #expect(tinta == 0, "\(theme.id): \(tinta) pixels de conteúdo na faixa do botão")
        }
    }

    // MARK: - Defeito 2: a lista rolava calada

    @Test("a lista que rola diz que rola, e a que cabe inteira fica quieta")
    func theListAnnouncesItsOverflow() async throws {
        let cheia = await DiaDoDono.loja(mensagens: DiaDoDono.caixaLonga)
        let curta = await DiaDoDono.loja(mensagens: [DiaDoDono.jack])

        for theme in [Theme.okami, Theme.tinta] {
            let comSobra = try #require(Render.bitmap(tela(cheia), size: Self.size, theme: theme))
            let semSobra = try #require(Render.bitmap(tela(curta), size: Self.size, theme: theme))

            // A pílula "MAIS ABAIXO" é `accentSoft`, encostada na borda
            // direita da coluna da lista, acima do rodapé.
            let recorte = 450..<690
            let linhas = 680..<830
            let acesa = pixels(
                comSobra, de: theme.accentSoft, x: recorte, y: linhas, tolerance: 0.015
            )
            let apagada = pixels(
                semSobra, de: theme.accentSoft, x: recorte, y: linhas, tolerance: 0.015
            )
            #expect(acesa > 300, "\(theme.id): a lista rola e não avisa (\(acesa) px)")
            #expect(apagada < 50, "\(theme.id): o aviso apareceu sem ter o que rolar")
        }
    }

    /// E o rodapé é o **chão** da coluna, não o fim do conteúdo: com o dobro
    /// de linhas ele não desce um pixel.
    @Test("com mais linhas, o rodapé Tirei da lista fica no mesmo lugar")
    func theRemovedFooterStaysPut() async throws {
        let poucas = await DiaDoDono.loja()
        let muitas = await DiaDoDono.loja(mensagens: DiaDoDono.caixaLonga)
        let theme = Theme.okami

        func rodape(_ rep: NSBitmapImageRep) -> Int? {
            guard let alvo = theme.accentInk.nsColor.usingColorSpace(.sRGB) else { return nil }
            for py in stride(from: 851, through: 700, by: -1) {
                for px in 40..<690 where casa(rep, px, py, alvo, 0.05) { return py }
            }
            return nil
        }

        let a = try #require(Render.bitmap(tela(poucas), size: Self.size, theme: theme))
        let b = try #require(Render.bitmap(tela(muitas), size: Self.size, theme: theme))
        let ya = try #require(rodape(a))
        let yb = try #require(rodape(b))
        #expect(abs(ya - yb) <= 2, "o rodapé da lista andou com o tamanho do conteúdo")
    }
}
