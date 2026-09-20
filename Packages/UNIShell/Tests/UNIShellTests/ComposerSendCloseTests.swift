import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O fechar depois de enviar precisa atravessar o guardião real da janela.
/// `dismiss()` deixava esse guardião ler o rascunho como sujo e abrir
/// “Salvar no rascunho?” depois de a mensagem já ter entrado na fila.
@Suite("Enviar e fechar o compositor")
@MainActor
struct ComposerSendCloseTests {
    private final class PortaFalsa: MailSendPort, @unchecked Sendable {
        private let lock = NSLock()
        private var _chamadas = 0
        private let erro: (any Error)?

        init(erro: (any Error)? = nil) { self.erro = erro }

        var chamadas: Int {
            lock.lock()
            defer { lock.unlock() }
            return _chamadas
        }

        func send(_ message: OutgoingMessage) throws {
            lock.lock()
            _chamadas += 1
            lock.unlock()
            if let erro { throw erro }
        }
    }

    private final class CloseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        func increment() {
            lock.lock()
            _value += 1
            lock.unlock()
        }
    }

    private struct ErroDaFila: Error {}

    private func store(porta: MailSendPort) async throws -> (MailStore, Message) {
        let original = try #require(Fixtures.messages.first)
        let assinatura = try EmailSignature(plainText: "Assinatura de teste")
        let accounts = Fixtures.accounts.map {
            $0.id == original.accountID ? $0.withEmailSignature(assinatura) : $0
        }
        let source = InMemoryMailSource(
            accounts: accounts, messages: Fixtures.messages, agenda: Fixtures.month
        )
        let store = MailStore(source: source, sendPort: porta)
        await store.load()
        return (store, original)
    }

    private func window(_ store: MailStore, messageID: String, attempts: Int) -> NSWindow {
        let root = ComposerWindow(
            store: store,
            mode: .reply(messageID: messageID),
            // A assinatura é inserida depois do baseline, deixando o
            // compositor sujo como estava no relato.
            debugInsertSignature: true,
            debugSend: true,
            debugSendAttempts: attempts,
            // O guardião real já começa bloqueando o fechamento. Assim a
            // prova não depende de um passe de renderização entre tornar o
            // rascunho sujo e disparar a porta de envio.
            debugLeaveConfirm: true
        )
        .theme(.tinta)
        .environment(\.locale, Locale(identifier: "pt_BR"))
        .frame(width: 820, height: 660)

        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: 820, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<12 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if window.contentView == nil { return }
        }
    }

    @Test("enfileirar fecha a janela suja sem perguntar pelo rascunho e não duplica")
    func acceptedSendClosesWithoutDraftPromptOrDuplicate() async throws {
        let porta = PortaFalsa()
        let (store, original) = try await store(porta: porta)
        let composer = window(store, messageID: original.id, attempts: 2)
        defer { composer.close() }
        let closed = CloseCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: composer, queue: nil
        ) { _ in closed.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        settle(composer)

        #expect(porta.chamadas == 1, "uma segunda ação não pode duplicar a fila")
        #expect(closed.value == 1, "o envio aceito não pode abrir ‘Salvar no rascunho?’")
    }

    @Test("fila que recusa mantém o compositor aberto")
    func rejectedSendKeepsComposerOpen() async throws {
        let porta = PortaFalsa(erro: ErroDaFila())
        let (store, original) = try await store(porta: porta)
        let composer = window(store, messageID: original.id, attempts: 1)
        defer { composer.close() }
        let closed = CloseCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: composer, queue: nil
        ) { _ in closed.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        settle(composer)

        #expect(porta.chamadas == 1)
        #expect(closed.value == 0, "uma fila que recusou não pode fechar e perder o rascunho")
        #expect(composer.contentView != nil)
    }
}
