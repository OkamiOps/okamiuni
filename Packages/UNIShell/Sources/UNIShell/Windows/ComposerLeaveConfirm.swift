import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// A pergunta ao sair do compositor com alterações que ainda não foram
/// gravadas. Mesmo idioma da janela de compromisso: cartão nosso, não o
/// diálogo do sistema — aquele não segue o tema.
enum ComposerLeaveConfirm: Equatable {
    static var title: String { L10n.tr("Salvar no rascunho?") }
    static var message: String { L10n.tr("Há alterações que ainda não foram salvas.") }
    static var saveTitle: String { L10n.tr("Salvar") }
    static var discardTitle: String { L10n.tr("Não salvar") }
    static var cancelTitle: String { L10n.tr("Cancelar") }

    /// Só pergunta quando há o que perder. Rascunho já gravado e mensagem
    /// vazia saem direto.
    static func shouldPrompt(isDirty: Bool) -> Bool { isDirty }
}

struct ComposerLeaveCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let onSave: () -> Void
    let onDiscard: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ComposerLeaveConfirm.title)
                .font(theme.serif.font(size: 18, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(ComposerLeaveConfirm.message)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ChromeButton(
                    ComposerLeaveConfirm.cancelTitle,
                    appearance: .outlined, height: 30
                ) { onCancel() }
                ChromeButton(
                    ComposerLeaveConfirm.discardTitle,
                    appearance: .outlined, height: 30
                ) { onDiscard() }
                ChromeButton(
                    ComposerLeaveConfirm.saveTitle,
                    appearance: .accent, height: 30
                ) { onSave() }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(theme.shadow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ComposerLeaveConfirm.title)
        .accessibilityHint(ComposerLeaveConfirm.message)
    }
}

/// O X, o menu Fechar e o ⌘W passam pelo botão vermelho: o AppKit
/// `performClose` **clica** esse botão. Quem trata o clique não pode chamar
/// `performClose` de novo — era o laço que derrubava o app no ⌘W.
@MainActor
final class ComposerCloseController: NSObject {
    var blocksClose = false
    var onAttemptClose: () -> Void = {}
    var allowNextClose = false

    private(set) weak var attachedWindow: NSWindow?
    private var handling = false

    func attach(to window: NSWindow) {
        if attachedWindow !== window {
            detach()
            attachedWindow = window
        }
        claimCloseButton(of: window)
    }

    func detach() {
        if let window = attachedWindow {
            restoreCloseButton(of: window)
            window.isDocumentEdited = false
        }
        attachedWindow = nil
    }

    /// Fecha sem passar de novo pelo botão. `performClose` reentraria neste
    /// handler e estouraria a pilha — o crash do ⌘W.
    func closeNow() {
        allowNextClose = true
        guard let window = attachedWindow else { return }
        restoreCloseButton(of: window)
        window.close()
    }

    @objc func closeButtonClicked(_ sender: Any?) {
        if handling { return }
        handling = true
        defer { handling = false }
        if allowNextClose || !blocksClose {
            closeNow()
            return
        }
        onAttemptClose()
    }

    private func claimCloseButton(of window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton) else { return }
        close.target = self
        close.action = #selector(closeButtonClicked(_:))
    }

    private func restoreCloseButton(of window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton) else { return }
        if close.target as AnyObject? === self {
            close.target = window
            close.action = #selector(NSWindow.performClose(_:))
        }
    }
}

struct ComposerCloseGate: NSViewRepresentable {
    var controller: ComposerCloseController
    var blocksClose: Bool
    var isDirty: Bool
    var onAttemptClose: () -> Void

    func makeNSView(context: Context) -> WindowReachingView {
        controller.blocksClose = blocksClose
        controller.onAttemptClose = onAttemptClose
        let view = WindowReachingView()
        view.onWindow = { [controller] window in
            controller.blocksClose = blocksClose
            controller.onAttemptClose = onAttemptClose
            controller.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowReachingView, context: Context) {
        controller.blocksClose = blocksClose
        controller.onAttemptClose = onAttemptClose
        nsView.onWindow = { [controller] window in
            controller.blocksClose = blocksClose
            controller.onAttemptClose = onAttemptClose
            controller.attach(to: window)
        }
        if let window = nsView.window {
            controller.attach(to: window)
            window.isDocumentEdited = isDirty
        }
    }

    static func dismantleNSView(_ nsView: WindowReachingView, coordinator: ()) {
        nsView.window?.isDocumentEdited = false
    }
}
