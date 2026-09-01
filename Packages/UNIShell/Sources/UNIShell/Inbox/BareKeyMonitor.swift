import SwiftUI
import UNICore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(WebKit)
import WebKit
#endif

/// Escuta as teclas de atalho **sem modificador** — o ⌫ que apaga e as
/// setas que andam na lista.
///
/// ## Por que não é um `keyboardShortcut`
///
/// Todo outro atalho deste app é um `Button` escondido com
/// `.keyboardShortcut(...)`, porque é isso que entra no `performKeyEquivalent`
/// da janela. E é exatamente por isso que o ⌫ não pode ir por lá: a janela
/// consulta `performKeyEquivalent` **antes** de entregar a tecla ao primeiro
/// respondedor. Um ⌫ registrado assim seria roubado do campo de busca e do
/// editor do composer — a pessoa apagaria uma mensagem tentando apagar uma
/// letra. O brief da tarefa pede o atalho "só quando o foco NÃO está num campo
/// de texto", e este é o único lugar de onde dá para saber isso.
///
/// ## O que o monitor local é, e o que ele não é
///
/// `addLocalMonitorForEvents` vê os eventos **deste processo**, na fila deste
/// app, antes de eles serem despachados. Não é um monitor global: nada é
/// observado fora do app, nenhuma tecla da máquina é lida quando o OkamiUNI não
/// está na frente, e nenhum evento é sintetizado. Ele também enxerga o que o
/// ensaio da Task AQ posta por `NSApp.postEvent`, que é o que torna o ⌫
/// provável no app real.
///
/// Devolver o evento deixa ele seguir; devolver `nil` o consome. A guarda é a
/// **única** decisão aqui, e ela é conservadora: qualquer coisa que pareça
/// edição de texto fica com a tecla.
struct BareKeyMonitor: ViewModifier {
    let onKey: (BareKey) -> Bool

    func body(content: Content) -> some View {
        #if canImport(AppKit)
        content.background(BareKeyProbe(onKey: onKey).frame(width: 0, height: 0))
        #else
        content
        #endif
    }
}

extension View {
    /// `onKey` devolve `true` quando de fato agiu — só então a tecla é
    /// consumida. Quem não tem o que apagar deixa o ⌫ seguir o caminho dele.
    func bareKeyShortcuts(_ onKey: @escaping (BareKey) -> Bool) -> some View {
        modifier(BareKeyMonitor(onKey: onKey))
    }
}

#if canImport(AppKit)
private struct BareKeyProbe: NSViewRepresentable {
    let onKey: (BareKey) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onKey = onKey
    }

    func makeCoordinator() -> Coordinator { Coordinator(onKey: onKey) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onKey: (BareKey) -> Bool
        weak var view: NSView?
        private var token: Any?

        init(onKey: @escaping (BareKey) -> Bool) { self.onKey = onKey }

        func start() {
            guard token == nil else { return }
            // O fechamento do monitor chega na thread principal, mas o
            // AppKit não o declara `@MainActor` e `NSEvent` não é `Sendable`.
            // `assumeIsolated` afirma o que já é verdade, sem copiar o evento
            // para fora da thread — o `nonisolated(unsafe)` está confinado a
            // este ponto e não escapa dele.
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let code = event.keyCode
                let flags = event.modifierFlags
                let windowNumber = event.windowNumber
                // Só valores `Sendable` atravessam a fronteira de isolamento:
                // `NSEvent` não é `Sendable`, e `assumeIsolated` exige que o
                // valor de volta seja. O evento em si nunca sai da thread
                // principal — ele é devolvido ou engolido aqui mesmo.
                let consumed = MainActor.assumeIsolated {
                    self?.handle(
                        keyCode: code, modifiers: flags, windowNumber: windowNumber
                    ) ?? false
                }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }

        /// `true` quer dizer "a tecla foi consumida".
        private func handle(
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags,
            windowNumber: Int
        ) -> Bool {
            // O monitor é do processo: sem isto, Esc na busca do composer
            // apagaria a busca da caixa, e ⌫ num botão da janela 03 apagaria
            // a mensagem da lista.
            if let ours = view?.window?.windowNumber, ours != windowNumber {
                return false
            }
            let sticky: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let key = BareKey.match(
                keyCode: keyCode,
                hasModifier: !modifiers.intersection(sticky).isEmpty
            )
            guard let key else { return false }
            let responder = NSApp.keyWindow?.firstResponder
            // Esc cancela o campo de busca (o editor de campo). ⌫ e as setas
            // continuam do texto — composer e faixa de resposta não perdem a
            // tecla. Documento (`NSTextView` que não é field editor) fica com
            // o Esc dele: a faixa recolhe só quando está vazia.
            if key == .escape {
                if BareKeyFocus.isEditingDocument(responder) { return false }
            } else if BareKeyFocus.isEditingText(responder) {
                return false
            }
            return onKey(key)
        }
    }
}

/// Quem fica com o ⌫ e as setas: o texto, ou a lista.
///
/// Fora da `View` para o teste afirmar a guarda sem montar janela. O leitor
/// HTML **não** é edição: a `WKWebView` aceita foco para ⌘C/⌘A, mas o
/// conteúdo não se apaga — e tratar isso como campo de texto era o ⌫ morto
/// depois de clicar no email.
@MainActor
enum BareKeyFocus {
    nonisolated static let searchFieldID = "uni.busca"

    static func isEditingText(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        if responder.isKind(of: NSText.self) { return true }
        #if canImport(WebKit)
        var view: NSView? = responder as? NSView
        while let current = view {
            if let web = current as? WebViewQueNaoRouba {
                return web.eCampoDeTexto
            }
            if current is WKWebView { return true }
            view = current.superview
        }
        #endif
        return false
    }

    /// Composer e faixa de resposta: `NSTextView` de verdade, não o editor
    /// embutido dum `NSTextField`. O Esc é deles — recolher no meio da frase
    /// custa mais do que a tecla economiza.
    static func isEditingDocument(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSTextView else { return false }
        return !text.isFieldEditor
    }

    /// O campo de busca da barra, e só ele. O editor de campo do AppKit é um
    /// `NSTextView` filho; a identidade mora no `NSTextField` (ou num ancestral
    /// SwiftUI) com `uni.busca`.
    static func isSearchField(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current.identifier?.rawValue == searchFieldID { return true }
            if current.accessibilityIdentifier() == searchFieldID { return true }
            view = current.superview
        }
        return false
    }
}
#endif
