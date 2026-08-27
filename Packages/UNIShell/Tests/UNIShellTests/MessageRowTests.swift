import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A lacuna que a auditoria nomeou: `MessageRow` não tinha medida nenhuma.
/// `.fixedSize`, `.lineLimit(2)` e `accountBarWidth` podiam mudar de valor, ou
/// sumir, sem que suíte nenhuma reclamasse — nada aqui olhava para o que a
/// linha de fato desenha, só para os dados que ela recebe.
///
/// Sem harness de texto (não há OCR), a técnica é a mesma da suíte de
/// hairline: ler pixel do bitmap renderizado e comparar contra o que o token
/// e a constante preveem. A barra colorida da conta (`accountBarWidth`) é o
/// instrumento — ela cobre a altura inteira da linha (`.overlay(alignment:
/// .leading)` sem `.frame(height:)` próprio, então herda o da `VStack`), e por
/// isso serve tanto para medir a própria largura quanto, por extensão, a
/// altura da linha inteira.
@Suite("MessageRow")
@MainActor
struct MessageRowTests {
    private static let width: CGFloat = 370
    private static let canvasHeight: CGFloat = 300

    private func message(subject: String = "Assunto", snippet: String) -> Message {
        Message(
            id: "m", accountID: "a",
            from: Contact(name: "Quem Escreveu", address: "quem@exemplo.com"),
            receivedAt: .now, subject: subject, snippet: snippet, body: [],
            tags: [], bucket: .today, isRead: true, summary: nil, detectedEvent: nil
        )
    }

    /// Vermelho puro como cor da conta: satura os três canais ao extremo, o
    /// que sobrevive tanto à opacidade cheia da barra (linha selecionada)
    /// quanto aos 45% da linha comum e aos 10% do fundo de seleção — nos três
    /// casos o canal vermelho fica bem acima do verde e do azul.
    private func renderRow(subject: String = "Assunto", snippet: String, isSelected: Bool = false) -> NSBitmapImageRep? {
        let row = MessageRow(
            message: message(subject: subject, snippet: snippet),
            accountHost: "host", accountTint: .red, isSelected: isSelected
        )
        let staged = row
            .frame(width: Self.width, alignment: .topLeading)
            .frame(height: Self.canvasHeight, alignment: .top)
            .background(Theme.tinta.surface.color)
        return Render.bitmap(staged, size: CGSize(width: Self.width, height: Self.canvasHeight), theme: .tinta)
    }

    /// Vermelho domina claramente verde e azul, em qualquer das opacidades que
    /// a linha usa (10%, 45%, 100% sobre o fundo do tema `tinta`) — a conta
    /// entre parênteses na descrição de cada teste mostra a folga real.
    private func isReddish(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99
        else { return false }
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        return r - max(g, b) > 0.04
    }

    /// Quantas linhas, a partir do topo, a barra da conta pinta na coluna
    /// `x`. A barra não tem `.frame(height:)` — herda o da `VStack` via
    /// `.overlay(alignment: .leading)` — então esta contagem É a altura da
    /// linha inteira, em pontos (escala 1×, como todo o harness).
    private func barRunLength(_ rep: NSBitmapImageRep, x: Int) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            guard isReddish(rep, x, y) else { break }
            count += 1
        }
        return count
    }

    // MARK: - Altura da linha segue o conteúdo, até o limite de 2 linhas

    /// Duas quebras de linha literais (`\n`) forçam três linhas *lógicas* no
    /// trecho; com `.lineLimit(2)` só duas podem aparecer. Uma quebra só
    /// força duas linhas, que cabem inteiras. Se as duas alturas saem iguais,
    /// o limite está de fato cortando a terceira — apagar `.lineLimit(2)` (a
    /// mutação que a auditoria citou) deixaria a versão de três linhas mais
    /// alta que a de duas, e o teste cairia.
    @Test("o trecho de três linhas para no limite de duas, não cresce mais")
    func snippetHeightCapsAtTwoLines() throws {
        let oneLine = try #require(renderRow(snippet: "Uma linha só, sem quebra nenhuma."))
        let twoLines = try #require(
            renderRow(snippet: "Primeira linha do trecho.\nSegunda linha do trecho.")
        )
        let threeLinesForced = try #require(
            renderRow(snippet: "Primeira linha do trecho.\nSegunda linha do trecho.\nTerceira linha, que o limite deve esconder.")
        )

        let h1 = barRunLength(oneLine, x: 1)
        let h2 = barRunLength(twoLines, x: 1)
        let h3 = barRunLength(threeLinesForced, x: 1)

        #expect(h1 > 0, "a barra da conta não pintou nada — a sonda não está medindo a linha")
        #expect(h2 > h1, "duas linhas de trecho não ficaram mais altas que uma — a linha não segue o conteúdo")
        #expect(
            h3 == h2,
            "três linhas de trecho (h=\(h3)) ficaram mais altas que duas (h=\(h2)) — o limite de 2 linhas não está cortando"
        )
    }

    // MARK: - Largura da barra da conta

    /// `accountBarWidth` é `3`. Medir a largura de fato pintada, não repetir
    /// a constante: uma `.frame(width:)` trocada no `overlay` continuaria
    /// compilando e a constante continuaria dizendo 3 sem que o desenho
    /// concordasse.
    @Test("a barra da conta pinta exatamente accountBarWidth pontos de largura")
    func accountBarWidthMatchesDrawing() throws {
        let rep = try #require(renderRow(snippet: "Um trecho comum, de uma linha."))
        // Meio da primeira linha (cabeçalho), longe de qualquer borda inferior.
        let y = 10
        var measuredWidth = 0
        for x in 0..<rep.pixelsWide {
            guard isReddish(rep, x, y) else { break }
            measuredWidth += 1
        }
        #expect(measuredWidth == Int(MessageRow.accountBarWidth))
    }

    // MARK: - Seleção pinta a linha inteira

    /// Requisito explícito do dono do projeto: a linha inteira pinta na
    /// seleção, não só embaixo do texto ou do chip. Medido bem à direita da
    /// linha (x=360 de 370), onde nem texto nem chip chegam — só o fundo.
    @Test("selecionar a linha pinta até a borda direita, não só o texto")
    func selectionPaintsTheFullRow() throws {
        let snippet = "Um trecho comum, de uma linha."
        let selected = try #require(renderRow(snippet: snippet, isSelected: true))
        let notSelected = try #require(renderRow(snippet: snippet, isSelected: false))

        let rowHeight = barRunLength(selected, x: 1)
        #expect(rowHeight > 20, "a sonda de altura não achou uma linha de verdade para escolher um y no meio dela")
        let y = rowHeight / 2
        let x = Int(Self.width) - 10

        #expect(
            isReddish(selected, x, y),
            "a linha selecionada não pintou perto da borda direita (x=\(x), y=\(y)) — a seleção não cobre a linha inteira"
        )
        #expect(
            isReddish(notSelected, x, y) == false,
            "a linha NÃO selecionada já aparece pintada perto da borda direita — falso positivo da sonda"
        )
    }
}
