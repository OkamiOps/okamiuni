import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Assistente integrado ao leitor")
@MainActor
struct InboxAssistantIntegrationTests {
    @Test("painel abre sobre o email sem quebrar o shell")
    func openPanelRendersOffscreen() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let size = CGSize(width: 1_440, height: 858)
        let assistant = IntegrationAssistant()

        let closed = try #require(Render.snapshot(
            InboxScreen(store: store, textAssistant: assistant)
                .environment(ThemeStore()),
            named: "m5-inbox-assistant-closed",
            size: size,
            theme: .tinta
        ))
        let open = try #require(Render.snapshot(
            InboxScreen(
                store: store,
                textAssistant: assistant,
                debugAssistantOpen: true
            )
            .environment(ThemeStore()),
            named: "m5-inbox-assistant-open",
            size: size,
            theme: .tinta
        ))

        #expect(closed.pixelsDiffering(from: open) > 20_000)
    }
}

private struct IntegrationAssistant: OnDeviceTextAssisting {
    let modelVersion = "integration"
    func availability() async -> OnDeviceMessageAnalysisAvailability { .available }
    func answer(
        question: String,
        in conversation: OnDeviceAssistantConversation
    ) async throws -> String { "Resposta local" }
    func transform(
        _ text: String,
        using action: OnDeviceWritingAction,
        context: OnDeviceAssistantMailContext?
    ) async throws -> String { "Texto local" }
}
