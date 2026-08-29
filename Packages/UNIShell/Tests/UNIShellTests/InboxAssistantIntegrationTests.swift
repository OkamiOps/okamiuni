import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Assistente integrado ao leitor")
@MainActor
struct InboxAssistantIntegrationTests {
    @Test("o botão contextual do leitor abre a IA e respeita indisponibilidade")
    func readerButtonIsAnAction() {
        var opens = 0
        CliqueDeEnsaio.em(
            ReaderAssistantButton(presentation: .available) { opens += 1 },
            size: CGSize(width: 60, height: 50),
            aY: 13,
            x: 14
        )
        #expect(opens == 1)

        CliqueDeEnsaio.em(
            ReaderAssistantButton(presentation: .modelNotReady) { opens += 1 },
            size: CGSize(width: 60, height: 50),
            aY: 13,
            x: 14
        )
        #expect(opens == 1)
    }

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
        let selectedID = try #require(store.selectedMessageID)
        let emailActions = try #require(Render.snapshot(
            InboxScreen(
                store: store,
                textAssistant: assistant,
                debugAssistantOpen: true,
                debugAssistantScope: .email(selectedID)
            )
            .environment(ThemeStore()),
            named: "m5-inbox-assistant-email-actions",
            size: size,
            theme: .tinta
        ))

        #expect(closed.pixelsDiffering(from: open) > 20_000)
        #expect(open.pixelsDiffering(from: emailActions) > 2_000)
    }

    @Test("rodapé usa o ambiente inteiro e ícone do leitor mantém o email")
    func globalAndEmailContextsStaySeparated() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let assistant = RecordingIntegrationAssistant()
        let screen = InboxScreen(store: store, textAssistant: assistant)
        let request = LocalAssistantRequest(
            context: .init(subject: "Ensaio"),
            question: "O que importa?",
            conversation: [.init(speaker: .user, text: "O que importa?")]
        )

        _ = try await screen.askAssistant(request, scope: .workspace)
        guard case let .workspace(workspace) = try #require(await assistant.lastContext()) else {
            Issue.record("O botão global não entregou contexto do ambiente")
            return
        }
        #expect(workspace.emailCount == store.messages.count)
        #expect(workspace.agenda.count == store.agenda.count)
        #expect(workspace.accounts.count == store.accounts.count)

        let selectedID = try #require(store.selectedMessageID)
        _ = try await screen.askAssistant(request, scope: .email(selectedID))
        let emailContext = try #require(await assistant.lastContext())
        switch emailContext {
        case .email, .conversation:
            break
        case .workspace:
            Issue.record("O ícone do leitor perdeu o contexto do email")
        }
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

private actor RecordingIntegrationAssistant: OnDeviceTextAssisting {
    nonisolated let modelVersion = "recording-integration"
    private var contexts: [OnDeviceAssistantMailContext] = []

    func availability() async -> OnDeviceMessageAnalysisAvailability { .available }
    func answer(
        question: String,
        in conversation: OnDeviceAssistantConversation
    ) async throws -> String {
        contexts.append(conversation.mailContext)
        return "Resposta local"
    }
    func transform(
        _ text: String,
        using action: OnDeviceWritingAction,
        context: OnDeviceAssistantMailContext?
    ) async throws -> String { "Texto local" }

    func lastContext() -> OnDeviceAssistantMailContext? { contexts.last }
}
