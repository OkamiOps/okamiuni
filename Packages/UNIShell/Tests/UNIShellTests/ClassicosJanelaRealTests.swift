import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Os temas clássicos na janela de verdade, com os semáforos na foto.
///
/// A regra do dono: "os temas clássicos devem perder o vidro mas manter o
/// design e todo restante". Antes disto a janela tinha dois shells e `isGlass`
/// escolhia entre eles; agora há um só, e o que o tema decide é o material do
/// painel. Esta suíte é a prova por desenho disso, nos quatro temas que o
/// redesenho precisava ver — um claro de papel (Tinta), um claro quente
/// (Linho), um escuro frio (Grafite) e o Okami, que é o tema dos artboards
/// `*-Classico` — mais os dois Vidros, que entram como regressão: se eles
/// mudarem um pixel, foi aqui que se soube.
///
/// Os PNGs saem com `UNI_RENDER_DIR` apontado para uma pasta, como no resto
/// do projeto. Sem ela a suíte continua afirmando o que afirma, só não escreve
/// arquivo nenhum.
@Suite("Clássicos na janela real")
@MainActor
struct ClassicosJanelaRealTests {

    static let janela = CGSize(width: 1440, height: 916)


    private func loja() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test(
        "as três telas, abertas e recolhidas, nos clássicos e nos Vidros",
        arguments: [Workspace.dashboard, Workspace.mail, Workspace.calendar],
        // Os quatro clássicos escolhidos, e os dois Vidros de regressão.
        ["okami", "tinta", "linho", "grafite", "vidro", "vidro-noite"]
    )
    func retratos(workspace: Workspace, tema: String) async throws {
        let theme = try #require(Theme.named(tema))
        for aberta in [true, false] {
            let store = await loja()
            let estado = aberta ? "aberta" : "recolhida"
            let foto = try #require(JanelaReal.fotografar(
                InboxScreen(
                    store: store,
                    debugAssistantOpen: false,
                    debugWorkspace: workspace,
                    debugWantsSidebar: aberta
                ).environment(ThemeStore()),
                size: Self.janela, theme: theme,
                named: "\(tema)-\(workspace.rawValue)-\(estado)"
            ))
            #expect(foto.bitmap.pixelsWide == Int(Self.janela.width))
            // O trilho é o mesmo nos 28: é dele que saem os semáforos, e a
            // folga do painel não depende da paleta. Esta é a afirmação que
            // pega um `gap` por tema, se alguém o introduzir.
            let centroDoTrilho = PanelStyle.vidroGap + AppRail.width / 2
            #expect(
                abs(foto.grupo.midX - centroDoTrilho) <= 0.5,
                "\(tema): os semáforos saíram do trilho"
            )
        }
    }
}
