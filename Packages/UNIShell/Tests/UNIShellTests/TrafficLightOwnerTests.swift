import AppKit
import Testing
@testable import UNIShell

/// O crash de 14/10/2026: ao trocar de tema clássico para Vidro, a barra do
/// topo (64pt) e o trilho (48pt) ficaram com um alinhador cada no mesmo
/// container de semáforos. Um escrevia, o outro acordava e reescrevia, até a
/// pilha estourar dentro de `-[NSView setFrame:]`.
@MainActor
@Suite("Semáforos: um alinhador por janela")
struct TrafficLightOwnerTests {

    private func janela() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        return window
    }

    @Test("dois alinhadores de alturas diferentes não entram em laço; o último manda")
    func ultimoAlinhadorManda() throws {
        let window = janela()
        defer { window.close() }

        let barra = TrafficLightAligner(barHeight: 64)
        let trilho = TrafficLightAligner(
            barHeight: TrafficLightLayout.railBarHeight,
            centerFromTop: TrafficLightLayout.railCenterFromTop,
            compactRow: true
        )
        barra.attach(to: window)
        trilho.attach(to: window)

        // Redimensionar posta `didResize` e `frameDidChange`: com dois donos,
        // era aqui que a recursão começava.
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.setContentSize(NSSize(width: 960, height: 620))

        let container = try #require(window.standardWindowButton(.closeButton)?.superview?.superview)
        #expect(container.frame.height == TrafficLightLayout.railBarHeight)

        trilho.detach()
        barra.detach()
    }
}
