import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Rodapé de inteligência")
@MainActor
struct IntelligenceFooterTests {

    /// A barra não declara classificação nem busca semântica porque o Marco 5
    /// não entrega essas funções. Estes literais são a promessa que fica
    /// visível para a pessoa — trocar uma palavra aqui merece revisão, não uma
    /// alteração silenciosa de marketing.
    @Test("cada estado explica a capacidade real de resumos e compromissos")
    func copyForEveryPresentation() {
        let expected: [(IntelligencePresentation, String, String, String)] = [
            (
                .available,
                "Resumos e compromissos no dispositivo",
                "Este Mac resume emails e identifica compromissos. Nada sai daqui.",
                "sparkles"
            ),
            (
                .deviceNotEligible,
                "Apple Intelligence indisponível",
                "Este Mac não é compatível com Apple Intelligence. Seus emails continuam locais.",
                "desktopcomputer.trianglebadge.exclamationmark"
            ),
            (
                .appleIntelligenceNotEnabled,
                "Ative a Apple Intelligence",
                "Ative-a nos Ajustes do Sistema para gerar resumos e identificar compromissos.",
                "switch.2"
            ),
            (
                .modelNotReady,
                "Modelo ainda não está pronto",
                "A Apple Intelligence ainda está sendo preparada. Resumos e compromissos ficam disponíveis quando terminar.",
                "arrow.down.circle"
            ),
        ]

        #expect(IntelligencePresentation.allCases.count == expected.count)
        for (presentation, title, detail, symbol) in expected {
            #expect(presentation.title == title)
            #expect(presentation.detail == detail)
            #expect(presentation.symbol == symbol)
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

    /// A captura usa o `Render.snapshot`: `NSWindow` fora da área visível,
    /// `NSHostingView` e `cacheDisplay`. Com `UNI_RENDER_DIR` definido, deixa
    /// os quatro PNGs para leitura humana sem abrir nem controlar a sessão.
    @Test("os quatro estados têm retratos distintos no rodapé")
    func rendersEveryPresentation() async throws {
        let states: [(String, IntelligencePresentation)] = [
            ("available", .available),
            ("device-not-eligible", .deviceNotEligible),
            ("apple-intelligence-not-enabled", .appleIntelligenceNotEnabled),
            ("model-not-ready", .modelNotReady),
        ]
        var snapshots: [NSBitmapImageRep] = []

        for (name, presentation) in states {
            let bitmap = try #require(Render.snapshot(
                ZStack(alignment: .topLeading) {
                    Theme.tinta.surface2.color
                    IntelligenceFooter(presentation: presentation)
                        .padding(16)
                },
                named: "m5-intelligence-footer-\(name)",
                size: CGSize(width: FolderSidebar.expandedWidth, height: 144),
                theme: .tinta
            ))
            snapshots.append(bitmap)
        }

        let available = try #require(snapshots.first)
        for snapshot in snapshots.dropFirst() {
            #expect(
                available.pixelsDiffering(from: snapshot) > 0,
                "um estado não mudou o rodapé renderizado"
            )
        }
    }
}
