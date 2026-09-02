import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
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
                .onThisMac,
                "Neste Mac",
                "Pergunte sobre suas caixas, emails e agenda. Nada sai deste Mac.",
                true
            ),
            (
                .needsSetup(
                    .init(label: "API · sem endpoint", detail: "Informe o endpoint nos Ajustes.", isLocal: false),
                    detail: "Adicione a chave de API deste provedor."
                ),
                "Configure a IA",
                "Adicione a chave de API deste provedor.",
                false
            ),
            (
                .needsSignIn(
                    .init(label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false),
                    provider: .xAI
                ),
                "Entre na assinatura",
                "Entre na assinatura Grok · xAI para usar a IA.",
                false
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
                "A Apple Intelligence ainda está sendo preparada.",
                false
            ),
        ]

        for (presentation, title, detail, isAvailable) in expected {
            #expect(presentation.title == title)
            #expect(presentation.detail == detail)
            #expect(presentation.actionTitle == "Perguntar ao ambiente")
            #expect(presentation.isAvailable == isAvailable)
            #expect(!presentation.title.localizedCaseInsensitiveContains("classificação"))
            #expect(!presentation.detail.localizedCaseInsensitiveContains("classificação"))
            #expect(!presentation.title.localizedCaseInsensitiveContains("busca semântica"))
            #expect(!presentation.detail.localizedCaseInsensitiveContains("busca semântica"))
        }
    }

    /// A cópia da barra vem do destino: prometer "local" com um provedor
    /// remoto escolhido era exatamente o defeito que esta apresentação fecha.
    @Test("o destino manda na cópia, no glifo e no escopo")
    func destinationDrivesCopy() {
        let remote = IntelligencePresentation.available(
            .init(label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false)
        )
        #expect(remote.scopeLabel == "Todo o OkamiUNI · Grok · xAI")
        #expect(remote.detail.contains("Sai deste Mac para a xAI."))
        #expect(remote.symbol == "sparkles")

        let local = IntelligencePresentation.available(
            .init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true)
        )
        #expect(local.symbol == "apple.intelligence")
        #expect(local.detail.contains("Nada sai deste Mac."))
        #expect(local.scopeLabel == "Todo o OkamiUNI · Neste Mac")

        let missing = IntelligencePresentation.needsSetup(
            .init(label: "API · sem endpoint", detail: "Informe o endpoint nos Ajustes.", isLocal: false),
            detail: "Adicione a chave de API deste provedor."
        )
        #expect(!missing.isAvailable)
        #expect(missing.detail == "Adicione a chave de API deste provedor.")
        #expect(missing.symbol == "sparkles")
        #expect(missing.actionHelp == "Adicione a chave de API deste provedor.")
    }

    /// A tradução vinda do UNISync é o único caminho entre o roteador e a
    /// barra: sem ela a tela voltaria a ter uma segunda regra própria.
    @Test("a apresentação nasce da disponibilidade medida pelo roteador")
    func presentationComesFromAvailability() {
        let destino = AssistantDestination(
            label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false
        )
        #expect(IntelligencePresentation(.ready(destino)) == .available(destino))
        #expect(IntelligencePresentation(.needsSignIn(destino, provider: .xAI))
            == .needsSignIn(destino, provider: .xAI))
        #expect(IntelligencePresentation(.needsSetup(destino, reason: "Adicione a chave de API deste provedor."))
            == .needsSetup(destino, detail: "Adicione a chave de API deste provedor."))
        #expect(IntelligencePresentation(.appleIntelligence(.deviceNotEligible)) == .deviceNotEligible)
        #expect(IntelligencePresentation(.appleIntelligence(.available)).isAvailable)
    }

    /// O botão desabilitado precisa de saída. "Abrir Ajustes" só aparece
    /// quando a pergunta não pode ser feita — e leva a Configurações.
    @Test("estado indisponível oferece Abrir Ajustes")
    func unavailableOffersSettings() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        var settings = 0

        CliqueDeEnsaio.em(
            FolderSidebar(
                store: store,
                intelligencePresentation: .modelNotReady,
                onOpenSettings: { settings += 1 }
            ),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 620),
            aY: 598,
            x: 118
        )

        #expect(settings == 1)
    }

    @Test("o inicializador preserva o estado disponível até o compositor conectar o motor")
    func initializerDefaultsToAvailable() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        #expect(FolderSidebar(store: store).intelligencePresentation
            == IntelligencePresentation.onThisMac)
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
            aY: 580,
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
            aY: 580,
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
