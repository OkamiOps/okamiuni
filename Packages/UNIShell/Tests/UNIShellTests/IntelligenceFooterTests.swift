import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Ação de perguntas na barra expandida")
@MainActor
struct IntelligenceFooterTests {

    /// A barra não declara classificação nem busca semântica porque o Marco 5
    /// não entrega essas funções. Estes literais são a promessa que fica
    /// visível para a pessoa — trocar uma palavra aqui merece revisão, não uma
    /// alteração silenciosa de marketing.
    @Test("cada estado mantém a porta de perguntas e explica a disponibilidade real")
    func copyForEveryPresentation() {
        let expected: [(IntelligencePresentation, String, String, Bool)] = [
            (
                .available,
                "Inteligência local disponível",
                "Pergunte sobre suas caixas, emails e agenda. Nada sai deste Mac.",
                true
            ),
            (
                .deviceNotEligible,
                "Apple Intelligence indisponível",
                "Este Mac não é compatível com Apple Intelligence. Seus emails continuam locais.",
                false
            ),
            (
                .appleIntelligenceNotEnabled,
                "Ative a Apple Intelligence",
                "Ative-a nos Ajustes do Sistema para gerar resumos e identificar compromissos.",
                false
            ),
            (
                .modelNotReady,
                "Modelo ainda não está pronto",
                "A Apple Intelligence ainda está sendo preparada. Resumos e compromissos ficam disponíveis quando terminar.",
                false
            ),
        ]

        #expect(IntelligencePresentation.allCases.count == expected.count)
        for (presentation, title, detail, isAvailable) in expected {
            #expect(presentation.title == title)
            #expect(presentation.detail == detail)
            #expect(presentation.symbol == "apple.intelligence")
            #expect(presentation.actionTitle == "Perguntar ao ambiente")
            #expect(presentation.isAvailable == isAvailable)
            #expect(!presentation.title.localizedCaseInsensitiveContains("classificação"))
            #expect(!presentation.detail.localizedCaseInsensitiveContains("classificação"))
            #expect(!presentation.title.localizedCaseInsensitiveContains("busca semântica"))
            #expect(!presentation.detail.localizedCaseInsensitiveContains("busca semântica"))
        }
    }

    @Test("o inicializador preserva o estado disponível até o compositor conectar o motor")
    func initializerDefaultsToAvailable() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        #expect(FolderSidebar(store: store).intelligencePresentation.title
            == IntelligencePresentation.available.title)
    }

    /// O clique atravessa a `NSWindow` offscreen e chega à closure do dono da
    /// navegação. Isto impede que a nova porta fique só desenhada.
    @Test("clicar em Perguntar ao ambiente entrega a intenção ao app")
    func expandedActionCallsItsClosure() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        var opens = 0

        CliqueDeEnsaio.em(
            FolderSidebar(store: store, onOpenAssistant: { opens += 1 }),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 620),
            aY: 540,
            x: 118
        )

        #expect(opens == 1)
    }

    @Test("estado indisponível não chama a closure")
    func unavailableActionIsDisabled() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        var opens = 0

        CliqueDeEnsaio.em(
            FolderSidebar(
                store: store,
                intelligencePresentation: .modelNotReady,
                onOpenAssistant: { opens += 1 }
            ),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 620),
            aY: 540,
            x: 118
        )

        #expect(opens == 0)
    }

    @Test("a barra expandida renderiza a porta de perguntas")
    func expandedSidebarRendersAssistantAction() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let rep = try #require(Render.snapshot(
            FolderSidebar(store: store),
            named: "m5-assistant-expanded-sidebar",
            size: CGSize(width: FolderSidebar.expandedWidth, height: 620),
            theme: .tinta
        ))
        #expect(rep.pixelsWide == Int(FolderSidebar.expandedWidth))
    }
}
