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

    @Test("uma linha inteira em negrito vira título, e o negrito no meio da frase fica na frase")
    func boldLineBecomesHeading() {
        let blocks = AssistantMarkdownBlock.parse("""
        Claro. **É uma abordagem** (*in-house*) de recrutamento.

        **O que a vaga parece envolver**
        - Desenvolver soluções
        **Em resumo:** é um convite inicial.
        """)
        #expect(blocks.map(\.kind) == [
            .paragraph("Claro. **É uma abordagem** (*in-house*) de recrutamento."),
            .heading("O que a vaga parece envolver"),
            .bullet("Desenvolver soluções"),
            .paragraph("**Em resumo:** é um convite inicial."),
        ])
    }

    @Test("o cartão do leitor desenha título e lista, sem asterisco cru")
    func cardRendersSectionHeading() async throws {
        let image = try #require(Render.snapshot(
            AssistantMarkdown(text: """
            Claro. **É uma abordagem** (*in-house*) de recrutamento.

            **O que a vaga parece envolver**
            - Desenvolver soluções de segurança.
            - Atuar em vulnerabilidades e firewalls.

            **Em resumo:** é um convite inicial.
            """, style: .card(size: 14))
                .padding(16)
                .frame(width: 520)
                .environment(ThemeStore()),
            named: "reader-ai-markdown",
            size: CGSize(width: 520, height: 280),
            theme: .vidroNoite
        ))
        #expect(image.pixelsWide == 520)
    }

    @Test("a linha recolhida tira asterisco e crase")
    func plainPreviewStripsMarkers() {
        let line = AssistantMarkdownBlock.plainPreview(
            "Claro. **É uma abordagem** (*in-house*) de segurança."
        )
        #expect(line == "Claro. É uma abordagem (in-house) de segurança.")
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
