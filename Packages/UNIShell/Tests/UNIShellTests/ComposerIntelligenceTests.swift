import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Inteligência do composer")
@MainActor
struct ComposerIntelligenceTests {

    private func selection(
        _ text: AttributedString, from start: Int, to end: Int
    ) -> AttributedTextSelection {
        let characters = text.characters
        let lower = characters.index(text.startIndex, offsetBy: start)
        let upper = characters.index(text.startIndex, offsetBy: end)
        return AttributedTextSelection(range: lower..<upper)
    }

    @Test("o alvo é a seleção contínua, não o rascunho inteiro")
    func selectedTargetWins() throws {
        let text = AttributedString("Olá mundo amigável")
        let selected = selection(text, from: 4, to: 9)

        let context = try #require(
            ComposerEditor.intelligenceContext(of: text, selection: selected)
        )
        #expect(context.target == .selection)
        #expect(context.source == "mundo")
    }

    @Test("sem seleção o alvo é o rascunho inteiro")
    func draftTargetWhenCaretIsCollapsed() throws {
        let text = AttributedString("Uma resposta inteira")
        let caret = AttributedTextSelection(insertionPoint: text.endIndex)

        let context = try #require(
            ComposerEditor.intelligenceContext(of: text, selection: caret)
        )
        #expect(context.target == .draft)
        #expect(context.source == "Uma resposta inteira")
    }

    @Test("o motor recebe a intenção e devolve apenas uma prévia")
    func generatorReceivesRequest() async throws {
        actor Recorder {
            var captured: ComposerIntelligenceRequest?
            func record(_ request: ComposerIntelligenceRequest) { captured = request }
            func value() -> ComposerIntelligenceRequest? { captured }
        }
        let recorder = Recorder()
        let request = ComposerIntelligenceRequest(
            action: .clarify,
            target: .selection,
            source: "texto confuso"
        )

        let proposal = try await ComposerIntelligence.generate(request) { received in
            await recorder.record(received)
            return "Texto claro."
        }

        #expect(await recorder.value() == request)
        #expect(proposal.request == request)
        #expect(proposal.result == "Texto claro.")
    }

    @Test("uma resposta vazia vira erro explícito, não uma troca silenciosa")
    func emptyGenerationFails() async {
        let request = ComposerIntelligenceRequest(
            action: .summarize, target: .draft, source: "Texto existente"
        )
        var failed = false
        do {
            _ = try await ComposerIntelligence.generate(request) { _ in "   " }
        } catch {
            failed = true
        }
        #expect(failed)
    }

    @Test("a resposta gerada ocupa uma área de prévia legível")
    func generatedReplyPreviewDoesNotCollapse() throws {
        let sourceMessage = try #require(Fixtures.messages.first)
        let proposal = ComposerIntelligenceProposal(
            request: .init(
                action: .createReply,
                target: .draft,
                source: "",
                sourceMessage: sourceMessage
            ),
            result: "Olá, Marina. Obrigado pela mensagem. Posso confirmar os próximos passos ainda hoje."
        )
        let panel = ComposerIntelligencePanel(
            context: .init(target: .draft, source: ""),
            available: true,
            sourceMessage: sourceMessage,
            phase: .preview(proposal),
            instruction: .constant(""),
            generate: { _, _ in },
            apply: { _ in },
            cancel: {}
        )
        let hosted = NSHostingView(rootView: panel
            .theme(.tinta)
            .environment(\.displayScale, 1)
        )
        hosted.layoutSubtreeIfNeeded()

        #expect(
            hosted.fittingSize.height >= 180,
            "a prévia colapsou e esconderia o texto gerado"
        )
        _ = try #require(Render.snapshot(
            panel,
            named: "composer-intelligence-reply-preview",
            size: CGSize(width: 340, height: 230),
            theme: .tinta
        ))
    }

    @Test("a prévia troca somente a seleção e conserva seu estilo")
    func applyReplacesOnlySelectedText() throws {
        var text = AttributedString("Olá mundo amigável")
        var selected = selection(text, from: 4, to: 9)
        let bold = BodyStyle(bold: true)
        let range = try #require(ComposerEditor.ranges(selected, in: text).first)
        text[range][BodyStyleAttribute.self] = bold
        // Escrever atributo pode dividir runs e o editor recalcula a seleção;
        // o teste faz a mesma coisa antes de pedir a prévia.
        selected = selection(text, from: 4, to: 9)
        let context = try #require(
            ComposerEditor.intelligenceContext(of: text, selection: selected)
        )
        let proposal = ComposerIntelligenceProposal(
            request: ComposerIntelligenceRequest(
                action: .clarify, target: context.target, source: context.source
            ),
            result: "pessoas"
        )

        let result = ComposerEditor.apply(
            proposal, on: &text, selection: &selected, theme: .tinta
        )
        #expect(result == .applied)
        #expect(String(text.characters) == "Olá pessoas amigável")

        let replaced = selection(text, from: 4, to: 11)
        let replacedRange = try #require(ComposerEditor.ranges(replaced, in: text).first)
        let inheritedBold = RichBody.style(
            of: text[replacedRange].runs.first?.attributes ?? .init()
        ).bold
        #expect(inheritedBold)
    }

    @Test("a prévia do rascunho substitui tudo somente após a aplicação")
    func applyReplacesDraft() throws {
        var text = AttributedString("Rascunho antigo")
        var caret = AttributedTextSelection(insertionPoint: text.endIndex)
        let context = try #require(
            ComposerEditor.intelligenceContext(of: text, selection: caret)
        )
        let proposal = ComposerIntelligenceProposal(
            request: ComposerIntelligenceRequest(
                action: .shorten, target: context.target, source: context.source
            ),
            result: "Versão curta."
        )

        #expect(String(text.characters) == "Rascunho antigo")
        #expect(
            ComposerEditor.apply(proposal, on: &text, selection: &caret, theme: .tinta) == .applied
        )
        #expect(String(text.characters) == "Versão curta.")
    }

    @Test("criar resposta preenche um rascunho vazio somente na confirmação")
    func createReplyCanFillEmptyDraft() throws {
        var text = AttributedString("")
        var caret = AttributedTextSelection()
        let context = try #require(
            ComposerEditor.intelligenceContext(of: text, selection: caret)
        )
        let sourceMessage = try #require(Fixtures.messages.first)
        let proposal = ComposerIntelligenceProposal(
            request: ComposerIntelligenceRequest(
                action: .createReply,
                target: context.target,
                source: context.source,
                sourceMessage: sourceMessage
            ),
            result: "Obrigado pela mensagem. Confirmo ainda hoje."
        )

        #expect(text.characters.isEmpty)
        #expect(
            ComposerEditor.apply(proposal, on: &text, selection: &caret, theme: .tinta) == .applied
        )
        #expect(String(text.characters) == "Obrigado pela mensagem. Confirmo ainda hoje.")
    }

    @Test("uma prévia antiga falha fechada e não apaga texto novo")
    func staleProposalCannotBecomeNoOpOrOverwrite() throws {
        var text = AttributedString("Olá planeta")
        var selected = selection(text, from: 4, to: 11)
        let proposal = ComposerIntelligenceProposal(
            request: ComposerIntelligenceRequest(
                action: .clarify, target: .selection, source: "mundo"
            ),
            result: "pessoas"
        )

        #expect(
            ComposerEditor.apply(proposal, on: &text, selection: &selected, theme: .tinta)
                == .sourceChanged
        )
        #expect(String(text.characters) == "Olá planeta")
    }

    private func differentPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                count += 1
            }
        }
        return count
    }

    private var generator: ComposerIntelligenceGenerator {
        { request in
            switch request.action {
            case .createReply: "Obrigado pela mensagem. Posso confirmar isso hoje."
            default: "Prévia revisada para a pessoa confirmar."
            }
        }
    }

    @Test("o painel ancora e aparece na janela cheia")
    func panelRendersInComposerWindow() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let size = CGSize(width: 820, height: 660)
        let closed = try #require(
            Render.snapshot(
                ComposerWindow(store: store, mode: .reply(messageID: "m1"), intelligence: generator),
                named: "composer-intelligence-window-closed",
                size: size,
                theme: .tinta
            )
        )
        let open = try #require(
            Render.snapshot(
                ComposerWindow(
                    store: store,
                    mode: .reply(messageID: "m1"),
                    debugOpenPanel: .intelligence,
                    intelligence: generator
                ),
                named: "composer-intelligence-window-panel",
                size: size,
                theme: .tinta
            )
        )
        #expect(differentPixels(closed, open) > 8_000)
    }

    @Test("o mesmo painel aparece na faixa de resposta rápida")
    func panelRendersInQuickReplyBand() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })
        let size = CGSize(width: 700, height: 460)

        let closed = try #require(
            Render.snapshot(
                QuickReplyBand(
                    store: store, message: message, onPromote: { _ in },
                    expandRequest: 1, intelligence: generator
                ),
                named: "composer-intelligence-band-closed",
                size: size,
                theme: .tinta
            )
        )
        let open = try #require(
            Render.snapshot(
                QuickReplyBand(
                    store: store, message: message, onPromote: { _ in },
                    expandRequest: 1,
                    debugOpenPanel: .intelligence,
                    intelligence: generator
                ),
                named: "composer-intelligence-band-panel",
                size: size,
                theme: .tinta
            )
        )
        #expect(differentPixels(closed, open) > 6_000)
    }
}
