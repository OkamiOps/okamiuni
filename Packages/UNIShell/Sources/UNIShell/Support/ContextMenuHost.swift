import SwiftUI
import UNICore
#if canImport(AppKit)
import AppKit
#endif

/// A ponte entre o modelo de menu (`UNICore.ContextMenus`) e o painel que o
/// app desenha.
///
/// Aqui não se decide **o que** o menu tem — isso é dado, mora em `UNICore` e
/// tem teste lá. Aqui só se liga o clique direito à apresentação e se executa o
/// comando que o item carrega.
///
/// ## O `NSMenu` saiu (Task AN)
///
/// Até esta tarefa isto era um `contextMenu { … }` do SwiftUI, e a decisão
/// registrada era "menu de contexto é do sistema". O dono do projeto mandou o
/// print — o painel cinza do macOS, com o realce rosa do sistema, em cima de
/// uma interface que desenha todos os dropdowns dela — e revogou a decisão.
///
/// O que substituiu: `RightClickCatcher` pega o botão direito sem tirar o
/// clique, o duplo clique nem o arraste lateral de quem está embaixo;
/// `ContextMenuPresenter` abre um painel `ContextMenuPanel` numa janela
/// própria; `UNICore.MenuPlacement` decide onde ele cabe. Nenhuma cor do
/// sistema atravessa: o painel inteiro sai de `Theme`.
///
/// **A exceção deliberada é o editor do composer** (`ComposerTextView`): o menu
/// dele *acrescenta* ao menu de texto do sistema — ortografia, substituições,
/// serviços —, e redesenhá-lo custaria essas funções. Ver
/// `docs/decisoes-de-engenharia.md`.

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

/// O pedaço de `ContextCommand` que só precisa do `MailStore`.
///
/// Existe porque o menu de contexto deixou de ser o único caminho: o arraste
/// lateral da linha dispara os mesmos comandos, e o **desfazer** dele dispara o
/// inverso — tudo `.move` ou `.setRead`. Um segundo `switch` num segundo lugar
/// faria os dois divergirem no primeiro conserto.
///
/// Os comandos que abrem janela ou mexem na área de transferência **não**
/// passam por aqui, e a função devolve `false` em vez de os engolir calada.
@MainActor
enum StoreCommand {
    @discardableResult
    static func run(_ command: ContextCommand, on store: MailStore) -> Bool {
        switch command {
        case .deleteForever(let messageID):
            store.deleteForever(messageID)
            return true

        case .restoreDeleted(let messageID):
            store.restoreDeleted(messageID)
            return true

        case .emptyTrash(let accountID):
            store.emptyTrash(accountID: accountID)
            return true

        case .setRead(let messageID, let isRead):
            store.setRead(isRead, for: messageID)
            return true

        case .setFlagged(let messageID, let isFlagged):
            store.setFlagged(isFlagged, for: messageID)
            return true

        case .move(let messageID, let bucket):
            guard let message = store.messages.first(where: { $0.id == messageID }) else {
                return false
            }
            // A seleção andar para a próxima quando a mensagem sai da visão é
            // trabalho de `move`, e tem teste em `UNICore`. Não se repete aqui.
            store.move(message, to: bucket)
            return true

        case .removeFromAgenda(let itemID):
            store.removeFromAgenda(itemID)
            return true

        case .restoreToAgenda(let itemID):
            store.restoreToAgenda(itemID)
            return true

        case .markAllRead(let bucket, let accountID):
            store.markAllRead(in: bucket, accountID: accountID)
            return true

        default:
            return false
        }
    }
}

/// Executa um `ContextCommand` inteiro — inclusive os que abrem janela e os que
/// mexem na área de transferência.
///
/// Existe porque o menu de contexto deixou de ser o único chamador: os atalhos
/// de teclado da Task AR (`MessageShortcuts`) disparam **os mesmos comandos**,
/// e um segundo `switch` num segundo lugar faria o atalho e o item de menu
/// divergirem no primeiro conserto — que é exatamente o defeito que
/// `StoreCommand` já existia para evitar, um nível abaixo.
///
/// `openWindow` e `onReveal` entram como valores porque nenhum dos dois é
/// alcançável daqui: o primeiro é chave de ambiente, o segundo precisa trocar
/// de aba e só `InboxScreen` sabe qual está no ar.
@MainActor
struct MenuCommandRunner {
    let store: MailStore
    let openWindow: OpenWindowAction
    var onReveal: (String) -> Void = { _ in }
    /// Quem quiser dar retorno visível a um comando o intercepta antes.
    /// Devolver `true` quer dizer "já cuidei disto"; o runner não repete.
    var intercept: (ContextCommand) -> Bool = { _ in false }

    func run(_ command: ContextCommand) {
        if intercept(command) { return }
        switch command {
        case .openMessageWindow(let messageID):
            openWindow(id: UNIWindow.message, value: messageID)

        case .reply(let messageID):
            // Selecionar antes de abrir faz duas coisas de uma vez: põe a
            // mensagem no leitor (com a faixa de resposta nela) e a marca como
            // lida, que é o que responder significa em qualquer cliente.
            store.select(message: messageID)
            openWindow(
                id: UNIWindow.composer,
                value: ComposerRoute.reply(messageID: messageID).value
            )

        case .replyAll(let messageID):
            store.select(message: messageID)
            openWindow(
                id: UNIWindow.composer,
                value: ComposerRoute.replyAll(messageID: messageID).value
            )

        case .forward(let messageID):
            // Encaminhar **não** marca como lida, ao contrário de responder:
            // repassar uma mensagem não é tê-la lido. `select` é o que marca,
            // e por isso ele fica de fora aqui.
            openWindow(
                id: UNIWindow.composer,
                value: ComposerRoute.forward(messageID: messageID).value
            )

        case .setRead, .setFlagged, .move, .markAllRead,
             .deleteForever, .restoreDeleted, .emptyTrash,
             .removeFromAgenda, .restoreToAgenda:
            StoreCommand.run(command, on: store)

        case .composeFrom(let accountID):
            // A cena 06 já carrega o id da conta como valor — é o mesmo
            // caminho do ⌘N, que passa `""` e cai na primeira conta.
            openWindow(id: UNIWindow.newMessage, value: accountID)

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

/// O modificador que pendura o menu numa superfície.
///
/// A captura é um `overlay`, e a ordem importa: no AppKit o teste de acerto
/// corre de frente para trás, e só quem está na frente pode devolver `nil` para
/// o evento seguir para quem está atrás. Como fundo, a `NSView` ficaria atrás
/// da hospedeira do SwiftUI e nunca veria o clique direito.
private struct ContextMenuModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    let store: MailStore
    let entries: [ContextMenuEntry]
    let onReveal: (String) -> Void
    let intercept: (ContextCommand) -> Bool

    func body(content: Content) -> some View {
        // Menu vazio não é menu: numa superfície sem ação disponível o clique
        // com o botão direito não deve abrir uma caixa em branco.
        if entries.isEmpty {
            content
        } else {
            content.overlay {
                RightClickCatcher { point, window in
                    ContextMenuPresenter.shared.present(
                        entries, at: point, in: window, theme: theme
                    ) { command in
                        MenuCommandRunner(
                            store: store, openWindow: openWindow,
                            onReveal: onReveal, intercept: intercept
                        ).run(command)
                    }
                }
            }
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
        onReveal: @escaping (String) -> Void = { _ in },
        intercept: @escaping (ContextCommand) -> Bool = { _ in false }
    ) -> some View {
        modifier(ContextMenuModifier(
            store: store, entries: entries, onReveal: onReveal, intercept: intercept
        ))
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
