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
    }
}
