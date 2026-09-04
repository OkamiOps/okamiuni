import SwiftUI
import UNICore

/// O menu **Mensagem** da barra do sistema, e a casa dos atalhos que agem sobre
/// a mensagem selecionada.
///
/// ## Por que a barra de menus, e não um `Button` escondido
///
/// A primeira versão disto era um `Button` com `.keyboardShortcut` por
/// atalho, escondido no fundo da tela — o mesmo padrão do ⌘K da busca. O
/// ensaio no app real derrubou essa versão: **⌘E media "MORTO"**. O motivo é
/// a ordem que `NSApplication.sendEvent` segue — o **menu principal** recebe o
/// evento antes do `performKeyEquivalent` da janela, e ⌘E já pertence a "Use
/// Selection for Find", do grupo de edição de texto que o SwiftUI monta
/// sozinho. Um `Button` escondido nunca chegava a ver a tecla.
///
/// Reivindicar ⌘E aqui resolve na ordem certa: quem está no menu principal
/// ganha de quem está no menu principal, e o nosso item vence o do sistema.
/// E há um ganho que não é técnico: a barra de menus passa a **listar** o que
/// os menus de contexto prometem. Um atalho que a barra de menus não mostra é
/// um atalho que ninguém descobre.
///
/// ## O que **não** está aqui
///
/// O ⌫. Tecla sem modificador num item de menu é roubada do campo de busca e
/// do editor do composer — o menu vem antes do primeiro respondedor, e é
/// exatamente essa ordem que faz ⌘E funcionar aqui e faria ⌫ atrapalhar. Ele
/// mora em `BareKeyMonitor`, que só age quando o foco não está em texto. O
/// item "Apagar" continua no menu de contexto da mensagem, onde o ⌫ aparece
/// escrito ao lado sem ser registrado como equivalente.
public struct MessageCommands: Commands {
    let store: MailStore
    /// A sessão do assistente — é dela que ⌘J depende. `nil` desliga o item
    /// em vez de o deixar aceso e mudo.
    let assistantSession: AssistantSession?

    public init(store: MailStore, assistantSession: AssistantSession? = nil) {
        self.store = store
        self.assistantSession = assistantSession
    }

    public var body: some Commands {
        CommandMenu(L10n.tr("Mensagem")) {
            MessageCommandItems(store: store)
            if let assistantSession {
                Divider()
                AssistantCommandItem(session: assistantSession)
            }
        }
    }
}

/// ⌘J — abre e fecha a gaveta do assistente.
///
/// Mora **no menu principal** pelo mesmo motivo de ⌘E: é ele que
/// `NSApplication.sendEvent` consulta antes da janela, e um `Button` escondido
/// atrás de um campo de texto focado nunca chegaria a ver a tecla — a gaveta
/// abre com o foco no campo dela, e é justamente aí que ⌘J tem de fechá-la.
///
/// A leitura do estado acontece **dentro da ação**: o corpo de um `View`
/// hospedado em `Commands` é avaliado uma vez, no lançamento (ver a nota
/// acima), e uma condição escrita aqui congelaria para sempre.
private struct AssistantCommandItem: View {
    @Environment(\.openWindow) private var openWindow
    let session: AssistantSession

    var body: some View {
        Button(L10n.tr("Assistente")) {
            if session.isDetached {
                openWindow(id: UNIWindow.assistant)
            } else {
                session.toggle()
            }
        }
        .keyboardShortcut("j", modifiers: .command)
    }
}

/// Os itens em si. Vivem num `View` porque `openWindow` é chave de ambiente, e
/// um `Commands` não tem ambiente para lê-la — o mesmo motivo do ⌘N.
///
/// ## O corpo não pode olhar a mensagem selecionada
///
/// Custou uma rodada de ensaio descobrir: o corpo de um `View` hospedado em
/// `Commands` é avaliado **uma vez**, no lançamento — antes de `MailStore.load`
/// —, e não é reavaliado quando o `@Observable` muda. A primeira versão lia
/// `store.selectedMessage` aqui e o fechamento de cada item capturava `nil`
/// para sempre: os itens apareciam acesos no menu e não faziam nada. Botão
/// mudo com atalho, que é a pior combinação das duas.
///
/// Então **toda** leitura de estado acontece dentro da ação, no instante do
/// clique. E os rótulos que dependeriam do estado usam a forma de dois lados —
/// "Marcar como lida / não lida" —, que é o mesmo idioma que
/// `SwipeAction.settingsLabel` já usa pelo mesmo motivo: um lugar onde não há
/// mensagem em mãos. Um rótulo que se dissesse "Marcar como lida" e nunca
/// mudasse mentiria metade do tempo.
///
/// O menu de contexto continua sendo o lugar que diz o estado exato: lá há
/// mensagem em mãos, e o rótulo é o contrário do que ela é agora.
private struct MessageCommandItems: View {
    @Environment(\.openWindow) private var openWindow
    let store: MailStore

    private var runner: MenuCommandRunner {
        MenuCommandRunner(store: store, openWindow: openWindow)
    }

    var body: some View {
        Group {
            item(L10n.tr("Responder"), .reply) { .reply(messageID: $0.id) }
            item(L10n.tr("Responder a todos"), .replyAll) { message in
                // A mesma regra do menu de contexto, do mesmo lugar: sem mais
                // ninguém além do remetente, responder a todos daria a janela
                // do ⌘R com outro nome.
                let conta = store.account(message.accountID)?.address ?? ""
                guard ComposerSeed.replyAllExtras(message, accountAddress: conta) > 0 else {
                    return nil
                }
                return .replyAll(messageID: message.id)
            }
            item(L10n.tr("Encaminhar"), .forward) { .forward(messageID: $0.id) }

            Divider()

            item(L10n.tr("Arquivar"), .archive) { .move(messageID: $0.id, to: .archived) }
            item(L10n.tr("Adiar para Depois"), .later) { .move(messageID: $0.id, to: .later) }

            Divider()

            item(L10n.tr("Marcar como lida / não lida"), .readToggle) {
                .setRead(messageID: $0.id, isRead: !$0.isRead)
            }
            item(L10n.tr("Sinalizar / tirar a sinalização"), .flag) {
                .setFlagged(messageID: $0.id, isFlagged: !$0.isFlagged)
            }
        }
    }

    /// `command` recebe a mensagem selecionada **no instante do clique**, e
    /// devolver `nil` é como um item diz "não há o que fazer com esta" — é o
    /// que impede "Responder a todos" de abrir uma janela igual à do ⌘R numa
    /// mensagem que só tem remetente.
    private func item(
        _ title: String,
        _ shortcut: MenuShortcut,
        command: @escaping (Message) -> ContextCommand?
    ) -> some View {
        Button(title) {
            guard let message = store.selectedMessage,
                  let command = command(message) else { return }
            runner.run(command)
        }
        .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
    }
}

extension MenuShortcut {
    /// O mesmo atalho, no idioma do SwiftUI.
    ///
    /// A tradução mora aqui e não em `UNICore` porque `KeyEquivalent` e
    /// `EventModifiers` são do SwiftUI, e `MenuShortcut` é o valor puro que os
    /// testes de modelo comparam. Uma constante escrita duas vezes — uma no
    /// rótulo do menu de contexto, outra no `keyboardShortcut` — divergiria: o
    /// menu prometeria ⌘E e a tecla seria outra.
    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.option) { out.insert(.option) }
        return out
    }
}
