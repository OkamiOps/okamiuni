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
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 916)
    }
}
