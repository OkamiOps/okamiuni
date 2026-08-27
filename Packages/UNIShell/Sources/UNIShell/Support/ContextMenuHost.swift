import SwiftUI
import UNICore
#if canImport(AppKit)
import AppKit
#endif

/// A ponte entre o modelo de menu (`UNICore.ContextMenus`) e o `contextMenu` do
/// SwiftUI.
///
/// Aqui não se decide **o que** o menu tem — isso é dado, mora em `UNICore` e
/// tem teste lá. Aqui só se traduz a lista para `Button`, `Menu` e `Divider`, e
/// se executa o comando que o item carrega.
///
/// O `NSMenu` que o macOS monta a partir disto não passa pelo `Theme`: menu de
/// contexto é do sistema, e o protótipo não desenha nenhum. O que o design
/// desenha é o painel do seletor de tema, que é outro componente — ver
/// `docs/decisoes-de-engenharia.md`, "O menu que um `<select>` abre não é do
/// protótipo".

// MARK: - Área de transferência

enum Clipboard {
    /// Texto vazio não vai para a área de transferência: apagar o que a pessoa
    /// tinha copiado por causa de um campo vazio é pior do que não copiar.
    /// Os menus já não oferecem o item nesse caso; isto é a segunda tranca.
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Execução

extension MenuShortcut {
    var keyboardShortcut: KeyboardShortcut {
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: flags)
    }
}

/// O modificador que pendura o menu numa superfície.
///
/// Lê `openWindow` do ambiente em vez de receber fechamentos: as três janelas
/// que os menus abrem (03, 04, 05) já são cenas com id, e `InboxScreen` chama
/// exatamente isto. Fechamento sobrou só para `revealMessage`, que precisa
/// trocar de aba — e só `InboxScreen` sabe qual aba está no ar.
private struct ContextMenuModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    let store: MailStore
    let entries: [ContextMenuEntry]
    let onReveal: (String) -> Void

    func body(content: Content) -> some View {
        // Menu vazio não é menu: numa superfície sem ação disponível o clique
        // com o botão direito não deve abrir uma caixa em branco.
        if entries.isEmpty {
            content
        } else {
            content.contextMenu { items(entries) }
        }
    }

    @ViewBuilder
    private func items(_ entries: [ContextMenuEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .item(let item):
                button(item)
            case .submenu(let title, let children):
                Menu(title) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        button(child)
                    }
                }
            case .separator:
                Divider()
            }
        }
    }

    private func button(_ item: ContextMenuItem) -> some View {
        Button(item.title) { run(item.command) }
            .keyboardShortcut(item.shortcut?.keyboardShortcut)
    }

    private func run(_ command: ContextCommand) {
        switch command {
        case .openMessageWindow(let messageID):
            openWindow(id: UNIWindow.message, value: messageID)

        case .reply(let messageID):
            // Selecionar antes de abrir faz duas coisas de uma vez: põe a
            // mensagem no leitor (com a faixa de resposta nela) e a marca como
            // lida, que é o que responder significa em qualquer cliente.
            store.select(message: messageID)
            openWindow(id: UNIWindow.composer, value: messageID)

        case .setRead(let messageID, let isRead):
            store.setRead(isRead, for: messageID)

        case .move(let messageID, let bucket):
            guard let message = store.messages.first(where: { $0.id == messageID }) else { return }
            store.move(message, to: bucket)

        case .markAllRead(let bucket, let accountID):
            store.markAllRead(in: bucket, accountID: accountID)

        case .filterAccount(let accountID):
            // `select(account:)` alterna. O item só existe quando o filtro
            // está desligado, e a guarda impede que um clique repetido o
            // desligue de novo por dentro do menu que prometia ligá-lo.
            guard store.selectedAccountID != accountID else { return }
            store.select(account: accountID)

        case .clearAccountFilter:
            guard store.selectedAccountID != nil else { return }
            store.select(account: nil)

        case .openEvent(let itemID):
            openWindow(id: UNIWindow.event, value: itemID)

        case .revealMessage(let messageID):
            onReveal(messageID)

        case .copy(let text):
            Clipboard.copy(text)
        }
    }
}

extension View {
    /// Pendura um menu de contexto vindo do modelo.
    ///
    /// `onReveal` só é usado por "Ir para o email de origem"; as superfícies
    /// que não têm esse item podem omiti-lo.
    func uniContextMenu(
        _ entries: [ContextMenuEntry],
        store: MailStore,
        onReveal: @escaping (String) -> Void = { _ in }
    ) -> some View {
        modifier(ContextMenuModifier(store: store, entries: entries, onReveal: onReveal))
    }
}

// MARK: - O menu de um compromisso, montado uma vez só

/// Quatro superfícies desenham um bloco de compromisso — a trilha do email e as
/// visões Dia, Semana e Mês. Elas precisam do mesmo menu, e montá-lo em cada
/// uma faria as quatro divergirem no primeiro conserto.
///
/// Mora aqui, e não em `UNICore`, porque é a única parte que precisa do
/// `MailStore` (para achar a mensagem de origem) e do calendário do dispositivo
/// (para resolver `anchor` + `dayOffset` num dia). A decisão de conteúdo
/// continua em `ContextMenus.agendaBlock`.
@MainActor
enum AgendaContextMenu {
    static func entries(
        for item: AgendaItem,
        store: MailStore,
        anchor: Date
    ) -> [ContextMenuEntry] {
        let detail = Fixtures.eventDetail(for: item.title)
        return ContextMenus.agendaBlock(
            item,
            detail: detail,
            date: date(of: item, anchor: anchor),
            originMessageID: ContextMenus.originMessageID(for: detail, in: store.messages)
        )
    }

    /// O dia do compromisso. `dayOffset` é deslocamento em dias inteiros
    /// justamente para não atravessar fuso — somá-lo ao `anchor` com o
    /// calendário do usuário é a conversão que o modelo evita guardar.
    static func date(of item: AgendaItem, anchor: Date) -> Date? {
        Calendar.current.date(byAdding: .day, value: item.dayOffset, to: anchor)
    }
}
