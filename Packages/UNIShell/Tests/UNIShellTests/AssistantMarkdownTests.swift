import AppKit
import Foundation
import SwiftUI
import Testing
import UNIDesign
@testable import UNIShell

@Suite("Markdown do assistente")
@MainActor
struct AssistantMarkdownTests {
    @Test("listas, títulos e numeração viram blocos separados")
    func parsesBlocks() {
        let blocks = AssistantMarkdownBlock.parse("""
        ## Pendências
        - responder Marina
        2. confirmar sala

        Parágrafo final.
        """)
        #expect(blocks.count == 4)
        #expect(blocks[0].kind == .heading("Pendências"))
        #expect(blocks[1].kind == .bullet("responder Marina"))
        #expect(blocks[2].kind == .numbered(marker: "2.", text: "confirmar sala"))
        #expect(blocks[3].kind == .paragraph("Parágrafo final."))
    }

    @Test("o painel renderiza a resposta do assistente como Markdown")
    func panelRendersMarkdown() async throws {
        let image = try #require(Render.snapshot(
            AssistantMarkdown(text: "- um\n- dois")
                .frame(width: 300)
                .environment(ThemeStore()),
            named: "assistant-markdown",
            size: CGSize(width: 300, height: 120),
            theme: .okami
        ))
        #expect(image.pixelsWide == 300)
    }

    /// A faixa de briefing do dashboard pede o corpo em serif 15 (`.briefing
    /// .text { font-family: var(--serif); font-size: 15px }` no mockup). O
    /// estilo compacto do painel continua sendo o padrão — quem não pede nada
    /// desenha o que sempre desenhou.
    @Test("o estilo de prosa desenha diferente do compacto")
    @MainActor
    func proseStyleDiffersFromCompact() async throws {
        let text = "Dois emails pedem decisão hoje: Marina quer fechar o contrato na quinta."
        let compacto = try #require(Render.bitmap(
            AssistantMarkdown(text: text).frame(width: 400),
            size: CGSize(width: 400, height: 120), theme: .tinta
        ))
        let prosa = try #require(Render.bitmap(
            AssistantMarkdown(text: text, style: .prose(size: 15)).frame(width: 400),
            size: CGSize(width: 400, height: 120), theme: .tinta
        ))
        #expect(compacto.pixelsDiffering(from: prosa) > 300)
    }
}
