import SwiftUI
import UNIDesign
import UNICore

/// Os atalhos de teclado que agem sobre a **mensagem selecionada**.
///
/// ## Por que num lugar só
///
/// Cada atalho aqui é o gêmeo de um item de menu, e os dois têm de disparar o
/// **mesmo** `ContextCommand` — é a regra que já vale entre o menu e o arraste
/// lateral. Espalhar `.keyboardShortcut` pelas telas foi o que produziu o
/// "os atalhos do teclado nao funciona" da Task AQ: quatro declarações em
/// quatro arquivos, nenhuma delas provada. Aqui elas ficam juntas, ao lado da
/// lista de itens de menu que as anuncia, e o ensaio do app real
/// (`--ensaiar-teclado`) afere o efeito de cada uma.
///
/// ## Por que `Button` escondido
///
/// `keyboardShortcut` é o que entra no `performKeyEquivalent` da janela, que é
/// por onde um atalho **com modificador** chega. `.hidden()` tira o botão do
/// desenho sem o tirar da hierarquia, e como isto entra por `background` ele
/// não ocupa lugar no layout. É o mesmo padrão do ⌘K da barra de busca.
///
/// O ⌫ **não** está aqui: tecla sem modificador não pode ir por
/// `performKeyEquivalent`, senão ela é roubada do campo de busca e do editor do
/// composer. Ele mora em `BareKeyMonitor`.
struct MessageShortcuts: View {
    @Environment(\.openWindow) private var openWindow
    let store: MailStore

    private var runner: MenuCommandRunner {
        MenuCommandRunner(store: store, openWindow: openWindow)
    }

    /// Os atalhos só existem quando há mensagem selecionada. Sem ela não há
    /// sobre o que agir, e um `Button` aceso que não faz nada é o botão mudo
    /// pela porta do teclado.
    var body: some View {
        if let message = store.selectedMessage {
            let account = store.account(message.accountID)
            ZStack {
                shortcut(
                    "Responder a todos",
                    .replyAll,
                    enabled: ComposerSeed.replyAllExtras(
                        message, accountAddress: account?.address ?? ""
                    ) > 0
                ) { runner.run(.replyAll(messageID: message.id)) }

                shortcut("Encaminhar", .forward) {
                    runner.run(.forward(messageID: message.id))
                }
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    private func shortcut(
        _ title: String,
        _ shortcut: MenuShortcut,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
            .disabled(!enabled)
    }
}

extension MenuShortcut {
    /// O mesmo atalho, no idioma do SwiftUI.
    ///
    /// A tradução mora aqui e não em `UNICore` porque `KeyEquivalent` e
    /// `EventModifiers` são do SwiftUI, e `MenuShortcut` é o valor puro que os
    /// testes de modelo comparam. Uma constante escrita duas vezes — uma no
    /// rótulo do menu, outra no `keyboardShortcut` — divergiria: o menu
    /// prometeria ⌘E e a tecla seria outra.
    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.option) { out.insert(.option) }
        return out
    }
}
