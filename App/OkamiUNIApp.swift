import SwiftUI
import UNIDesign
import UNIShell
import UNICore

@main
struct OkamiUNIApp: App {
    @State private var themes = ThemeStore()
    @State private var mailStore = MailStore(source: InMemoryMailSource.fixtures)
    /// Quais ações o arraste lateral da linha revela de cada lado. Persistido
    /// em `UserDefaults` como o tema — ver `SwipeSettingsStore`.
    @State private var swipes = SwipeSettingsStore()

    init() {
        FontRegistry.registerBundledFonts()
        // A faixa de resposta lê o rascunho uma vez, na primeira montagem.
        // Semear depois disso não a alcança — foi o que fez duas capturas
        // saírem byte a byte idênticas. Aqui é antes de qualquer janela.
        if WindowCapture.fromProcess != nil {
            WindowCapture.seedForCapture(mailStore)
        }
    }

    var body: some Scene {
        WindowGroup("OkamiUNI") {
            InboxScreen(store: mailStore)
                .environment(themes)
                .environment(swipes)
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
                // Porta de depuração: `open -g --args --nova-mensagem` abre a
                // janela auxiliar pelo mesmo `openWindow` do menu, sem trazer o
                // app à frente e sem sintetizar tecla nenhuma. Sem a bandeira,
                // isto não faz nada.
                .modifier(LaunchWindowOpener())
                // `--capturar=/caminho.png`: fotografa a própria janela e
                // encerra. Sem a bandeira, não faz nada.
                .captureWindowIfRequested(WindowCapture.fromProcess, store: mailStore)
                // `--ensaiar-arraste`: arrasta a primeira linha com eventos
                // sintetizados dentro do processo e fotografa cada fase. Sem a
                // bandeira, não faz nada.
                .rehearseSwipeIfRequested(SwipeRehearsal.fromProcess)
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

/// Abre a janela auxiliar pedida na linha de comando, uma vez só.
///
/// `openWindow` é chave de ambiente e precisa de um `View` para ser lida — daí
/// o modificador em vez de uma chamada dentro do `App`.
private struct LaunchWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var done = false

    func body(content: Content) -> some View {
        content.task {
            guard !done, let request = LaunchWindowRequest.fromProcess else { return }
            done = true
            openWindow(id: request.windowID, value: request.value)
        }
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
