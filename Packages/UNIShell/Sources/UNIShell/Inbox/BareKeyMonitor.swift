import SwiftUI
import UNICore
#if canImport(AppKit)
import AppKit
#endif

/// Escuta as teclas de atalho **sem modificador** — hoje, o ⌫ que apaga.
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
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    func makeCoordinator() -> Coordinator { Coordinator(onKey: onKey) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onKey: (BareKey) -> Bool
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
                // Só um `Bool` atravessa a fronteira de isolamento: `NSEvent`
                // não é `Sendable`, e `assumeIsolated` exige que o valor de
                // volta seja. O evento em si nunca sai da thread principal —
                // ele é devolvido ou engolido aqui mesmo.
                let consumed = MainActor.assumeIsolated {
                    self?.handle(keyCode: code, modifiers: flags) ?? false
                }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }

        /// `true` quer dizer "a tecla foi consumida".
        private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
            let sticky: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let key = BareKey.match(
                keyCode: keyCode,
                hasModifier: !modifiers.intersection(sticky).isEmpty
            )
            guard let key, !Self.isEditingText else { return false }
            return onKey(key)
        }

        /// Se o primeiro respondedor está editando texto agora.
        ///
        /// `NSTextView` cobre os dois casos que importam: o editor do composer,
        /// que é um de verdade, e o campo de busca do SwiftUI, que delega para
        /// o *field editor* — também um `NSTextView`. `NSTextField` entra
        /// porque um campo sem foco de edição ainda deve ficar com o ⌫.
        ///
        /// Conservadora de propósito: na dúvida a tecla é do texto. Apagar uma
        /// mensagem por engano custa muito mais que um ⌫ que não apagou nada.
        private static var isEditingText: Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            if responder is NSTextView || responder is NSTextField { return true }
            return responder.isKind(of: NSText.self)
        }
    }
}
#endif
