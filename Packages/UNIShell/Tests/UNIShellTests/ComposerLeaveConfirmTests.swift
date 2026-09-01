import AppKit
import Testing
@testable import UNIShell

@Suite("Sair do compositor")
struct ComposerLeaveConfirmTests {

    @Test("o semáforo vermelho pergunta em vez de fechar")
    @MainActor
    func trafficLightAsksInsteadOfClosing() {
        let controller = ComposerCloseController()
        var asked = 0
        var closed = 0
        controller.blocksClose = true
        controller.onAttemptClose = { asked += 1 }

        let window = Self.offscreenWindow()
        defer { window.close() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in closed += 1 }
        controller.attach(to: window)

        let close = window.standardWindowButton(.closeButton)
        #expect(close?.target as AnyObject? === controller)
        #expect(close?.action == #selector(ComposerCloseController.closeButtonClicked(_:)))

        controller.closeButtonClicked(nil)
        #expect(asked == 1)
        #expect(closed == 0, "a janela fechou sem o cartão")
    }

    @Test("⌘W numa janela suja não reentra em performClose")
    @MainActor
    func commandWDoesNotRecurse() {
        let controller = ComposerCloseController()
        var asked = 0
        controller.blocksClose = true
        controller.onAttemptClose = { asked += 1 }

        let window = Self.offscreenWindow()
        defer { window.close() }
        controller.attach(to: window)

        // O crash: performClose clica o botão, o handler chamava performClose.
        window.performClose(nil)
        #expect(asked == 1)
        #expect(window.contentView != nil)
    }

    @Test("depois de escolher, o close passa")
    @MainActor
    func confirmedCloseGoesThrough() {
        let controller = ComposerCloseController()
        var asked = 0
        var closed = 0
        controller.blocksClose = true
        controller.onAttemptClose = { asked += 1 }

        let window = Self.offscreenWindow()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in closed += 1 }
        controller.attach(to: window)
        controller.closeNow()
        #expect(asked == 0)
        #expect(closed == 1)
    }

    @Test("janela limpa fecha sem perguntar e sem laço")
    @MainActor
    func cleanWindowClosesQuietly() {
        let controller = ComposerCloseController()
        var asked = 0
        var closed = 0
        controller.blocksClose = false
        controller.onAttemptClose = { asked += 1 }

        let window = Self.offscreenWindow()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in closed += 1 }
        controller.attach(to: window)
        window.performClose(nil)
        #expect(asked == 0)
        #expect(closed == 1)
    }

    private static func offscreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }
}
