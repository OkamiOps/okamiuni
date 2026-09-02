import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// O `AppComposition` é um `let` simples do `App`, e o modelo de
/// disponibilidade é uma classe `@Observable`. A pergunta que este arquivo
/// responde é a única que importa para a fiação: **uma leitura de
/// `model.availability` feita dentro do corpo de uma `View` redesenha quando a
/// sonda termina?** É exatamente a forma usada em `App/OkamiUNIApp.swift`
/// (`LeituraDoAssistente`), e é por isso que o app não lê o modelo direto no
/// fecho da `WindowGroup`.
@Suite("Redesenho da lateral quando a sonda termina")
@MainActor
struct AssistantAvailabilityRenderTests {
    nonisolated static let remoto = AssistantAvailability.needsSignIn(
        AssistantDestination(label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false),
        provider: .xAI
    )

    @Test("a lateral troca a cópia depois do primeiro refresh")
    func bodyReadIsTracked() async throws {
        let suite = "okamiuni.assistant-render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = AssistantSettingsStore(defaults: defaults, key: "assistant")
        let model = AssistantAvailabilityModel(settingsStore: settings, probe: { Self.remoto })

        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let diario = Diario()

        let janela = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: FolderSidebar.expandedWidth, height: 620),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        janela.isReleasedWhenClosed = false
        janela.contentView = NSHostingView(
            rootView: LeitorDeEnsaio(model: model, diario: diario, store: store)
                .theme(.tinta)
                .environment(\.locale, Locale(identifier: "pt_BR"))
        )
        janela.orderBack(nil)
        defer { janela.close() }
        assenta()

        #expect(diario.titulos.first == "Neste Mac")

        await model.refresh()
        assenta()

        #expect(model.availability == Self.remoto)
        #expect(diario.titulos.last == "Entre na assinatura",
                "a lateral ficou presa na primeira medida: \(diario.titulos)")
        #expect(diario.titulos.contains("Neste Mac"))
    }

    private func assenta() {
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

/// A mesma forma de `LeituraDoAssistente` no app: a leitura acontece no corpo
/// da `View`, que é onde o rastreio do `@Observable` a registra.
@MainActor
private struct LeitorDeEnsaio: View {
    let model: AssistantAvailabilityModel
    let diario: Diario
    let store: MailStore

    var body: some View {
        let apresentacao = IntelligencePresentation(model.availability)
        diario.anotar(apresentacao.title)
        return FolderSidebar(store: store, intelligencePresentation: apresentacao)
    }
}

@MainActor
private final class Diario {
    private(set) var titulos: [String] = []
    func anotar(_ titulo: String) {
        if titulos.last != titulo { titulos.append(titulo) }
    }
}
