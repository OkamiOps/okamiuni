import SwiftUI
import UNIDesign
import UNIShell
import UNICore

@main
struct OkamiUNIApp: App {
    @State private var themes = ThemeStore()
    @State private var mailStore = MailStore(source: InMemoryMailSource.fixtures)

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("OkamiUNI") {
            InboxScreen(store: mailStore)
                .environment(themes)
                .theme(themes.theme)
                // A barra de 58pt é a barra de título: o conteúdo desenha
                // debaixo dela, com os semáforos nativos dentro. Sem isto o
                // SwiftUI empurra tudo para baixo da área segura e sobra uma
                // faixa vazia entre os botões do sistema e as nossas ações.
                .ignoresSafeArea(.container, edges: .top)
                // 860 é o piso da faixa mais estreita da Task R: trilha de
                // 62 + lista de 320 ainda deixam 478pt para o leitor.
                //
                // A altura da *janela* não chega a 600: ela é sempre
                // `minHeight + 32`, e os 32 são a barra de título que a
                // `.hiddenTitleBar` continua reservando no quadro da janela
                // mesmo com o conteúdo desenhando por baixo dela. Medido:
                // minHeight 100 dá janela de 132, minHeight 700 dava 732.
                // Nenhum conteúdo impõe altura — com minHeight 100 o shell
                // inteiro comprime até 100. Então 600 aqui é 600 de conteúdo,
                // 632 de janela.
                .frame(minWidth: 860, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 916)
        .commands {
            // ⌘N abre a 06. O botão "Escrever" da barra do topo chama o mesmo
            // caminho — ele mora no `WindowChrome`, que é de outra tarefa.
            CommandGroup(replacing: .newItem) { NewMessageCommand() }
        }

        // As quatro janelas da Task U. Cenas de verdade, não folhas: o protótipo
        // as chama de "em janela" e desenha sombra e raio próprios, que numa
        // cena o macOS desenha por nós. `WindowGroup(id:for:)` ainda dá o que
        // uma `NSWindow` à mão custaria: tamanho declarado, ⌘W, Janela ▸ e uma
        // janela por valor (dois compositores para duas mensagens diferentes,
        // e a mesma janela de volta quando o valor se repete).
        //
        // O valor é sempre `String` porque `WindowGroup(for:)` exige
        // `Codable & Hashable` — e porque a janela deve reler do `MailStore`,
        // não carregar uma cópia congelada da mensagem.

        WindowGroup(id: UNIWindow.composer, for: String.self) { $messageID in
            ComposerWindow(store: mailStore, mode: .reply(messageID: messageID ?? ""))
                .themed(themes)
                .frame(minWidth: 620, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.composer)

        WindowGroup(id: UNIWindow.newMessage, for: String.self) { $accountID in
            ComposerWindow(store: mailStore, mode: .new(accountID: accountID))
                .themed(themes)
                .frame(minWidth: 620, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.newMessage)

        WindowGroup(id: UNIWindow.message, for: String.self) { $messageID in
            MessageWindow(store: mailStore, messageID: messageID ?? "")
                .themed(themes)
                .frame(minWidth: 520, minHeight: 380)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.message)

        WindowGroup(id: UNIWindow.event, for: String.self) { $itemID in
            EventWindow(store: mailStore, itemID: itemID ?? "")
                .themed(themes)
                .frame(minWidth: 460, minHeight: 380)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.event)
    }
}

extension View {
    /// O tema atravessa para as janelas novas: o `ThemeStore` no ambiente (para
    /// quem troca de tema) e o `Theme` resolvido (para quem só desenha).
    /// As duas coisas, sempre — só o `.theme(...)` deixaria o seletor mudo, e
    /// só o `.environment(...)` deixaria a janela no tema padrão.
    fileprivate func themed(_ themes: ThemeStore) -> some View {
        environment(themes).theme(themes.theme)
    }
}

/// ⌘N. Vive num `View` porque `openWindow` é uma chave de ambiente, e um `App`
/// não tem ambiente para lê-la.
private struct NewMessageCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Nova mensagem") {
            openWindow(id: UNIWindow.newMessage, value: "")
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}
