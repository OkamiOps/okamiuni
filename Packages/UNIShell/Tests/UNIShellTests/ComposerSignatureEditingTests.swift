import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Compositor com assinatura: edição e seleção")
@MainActor
struct ComposerSignatureEditingTests {
    private let before = "Pessoal, boa noite!\n\nEste trecho precisa continuar editável antes da assinatura."
    private let after = "\n\nMensagem encaminhada\nConteúdo original."

    private func store() async throws -> (MailStore, String) {
        let base = try #require(Fixtures.accounts.first)
        let signature = try EmailSignature(plainText: "Assinatura", html: "<b>Assinatura</b>")
        let store = MailStore(source: InMemoryMailSource(
            accounts: [base.withEmailSignature(signature)],
            messages: Fixtures.messages, agenda: Fixtures.month
        ))
        await store.load()
        let message = try #require(store.messages.first)
        store.setReplyDraft(ReplyDraft(text: before + after), for: message.id)
        return (store, message.id)
    }

    @Test("Digitar linhas antes da assinatura aumenta a área do editor")
    func growsWhileTyping() async throws {
        let (store, id) = try await store()
        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .reply(messageID: id),
                debugInsertSignature: true, debugSignatureOffset: before.count),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { content in
            guard let view = EditorProbe.textView(in: content, containing: before) else {
                Issue.record("Editor anterior à assinatura ausente"); return
            }
            let extra = String(repeating: "\nMais uma linha escrita antes da assinatura.", count: 12)
            view.insertText(extra, replacementRange: NSRange(location: view.string.utf16.count, length: 0))
            settle(content)
            expectAllLinesFit(view)
        }
    }

    @Test("Mudar o tamanho mantém a seleção e expande o editor", arguments: [620.0, 980.0], [false, true])
    func growsAfterFormatting(width: Double, afterSignature: Bool) async throws {
        let (store, id) = try await store()
        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .reply(messageID: id),
                debugInsertSignature: true, debugSignatureOffset: before.count),
            size: CGSize(width: width, height: 660), theme: .noite
        ) { content in
            guard let view = EditorProbe.textView(in: content, containing: afterSignature ? after : before),
                  let coordinator = view.delegate as? ComposerTextView.Coordinator else {
                Issue.record("Editor ou delegado ausente"); return
            }
            let selected = NSRange(location: 0, length: view.string.utf16.count)
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(selected)
            settle(content)
            #expect(view.selectedRange() == selected, "A seleção deve sobreviver ao redesenho")
            let model = coordinator.parent.text
            #expect(ComposerTextView.Coordinator.nsRange(of: coordinator.currentSelection(in: model), in: model) == selected,
                "O binding deve manter a seleção do usuário")
            // A mesma operação de formatação do menu nativo; o texto ainda é
            // o binding real do trecho anterior à assinatura do ComposerWindow.
            view.window?.makeFirstResponder(nil)
            #expect(view.selectedRange() == selected, "Tirar o foco não deve apagar a seleção")
            coordinator.run(.size(32))
            settle(content)
            #expect(view.selectedRange() == selected)
            #expect((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 32)
            expectAllLinesFit(view)
            coordinator.run(.bold)
            settle(content)
            #expect(view.selectedRange() == selected, "A seleção deve valer para o segundo comando também")
            let formatted = ComposerTextKit.model(view.textStorage ?? NSTextStorage())
            #expect(formatted.runs.allSatisfy { $0.attributes[BodyStyleAttribute.self]?.bold == true })
            if !afterSignature, width == 980 { capture(view) }
        }
    }

    private func settle(_ content: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        content.layoutSubtreeIfNeeded()
    }

    private func expectAllLinesFit(_ view: NSTextView) {
        guard let layout = view.layoutManager, let container = view.textContainer,
              let scroll = view.enclosingScrollView else {
            Issue.record("Layout do texto ausente"); return
        }
        layout.ensureLayout(for: container)
        let needed = layout.usedRect(for: container).height + view.textContainerInset.height * 2
        #expect(scroll.bounds.height >= needed - 1,
            "Texto requer \(needed)pt, mas só recebeu \(scroll.bounds.height)pt antes da assinatura")
    }

    private func capture(_ view: NSTextView) {
        guard let path = ProcessInfo.processInfo.environment["UNI_RENDER_DIR"],
              let scroll = view.enclosingScrollView,
              let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)
        else { return }
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("editor-formatado-32.png"))
        } catch { Issue.record("Captura falhou: \(error)") }
    }
}
