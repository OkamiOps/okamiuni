import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("Disponibilidade do assistente")
struct AssistantAvailabilityTests {
    private func store(_ settings: AssistantSettings) throws -> AssistantSettingsStore {
        let suite = "okamiuni.assistant-availability.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try store.save(settings)
        return store
    }

    @Test("endpoint sem chave pede configuração, com o motivo")
    @available(macOS 26.0, *)
    func apiKeyMissingNeedsSetup() async throws {
        let settings = AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://api.example.com/v1", model: "m",
                credentialID: "primary", authenticationMode: .apiKey
            )
        )
        let credentials = InMemoryAssistantCredentialStore()
        let router = AssistantRouter(settingsStore: try store(settings), credentialStore: credentials)

        let availability = await router.assistantAvailability()
        #expect(availability == .needsSetup(
            .init(settings: settings),
            reason: "Adicione a chave de API deste provedor."
        ))
        #expect(!availability.isReady)
        #expect(availability.destination.label == "API · api.example.com")
    }

    @Test("com chave presente o destino fica pronto")
    @available(macOS 26.0, *)
    func apiKeyPresentIsReady() async throws {
        let settings = AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://api.example.com/v1", model: "m",
                credentialID: "primary", authenticationMode: .apiKey
            )
        )
        let credentials = InMemoryAssistantCredentialStore()
        try credentials.storeAPIKey("k", for: "primary")
        let router = AssistantRouter(settingsStore: try store(settings), credentialStore: credentials)
        #expect(await router.assistantAvailability() == .ready(.init(settings: settings)))
    }

    @Test("assinatura sem sessão pede login, nomeando o provedor")
    @available(macOS 26.0, *)
    func providerOAuthWithoutSession() async throws {
        let settings = AssistantSettings(
            provider: .providerOAuth,
            providerOAuth: .init(kind: .xAI, model: "grok-4.6")
        )
        let router = AssistantRouter(
            settingsStore: try store(settings),
            credentialStore: InMemoryAssistantCredentialStore(),
            providerOAuthTokenProvider: nil
        )
        #expect(await router.assistantAvailability()
            == .needsSignIn(.init(settings: settings), provider: .xAI))
    }

    @Test("CLI não encontrado pede configuração e nomeia o binário")
    @available(macOS 26.0, *)
    func cliNotFoundNeedsSetup() async throws {
        let settings = AssistantSettings(provider: .cli, cli: .init(kind: .claude))
        let router = AssistantRouter(
            settingsStore: try store(settings),
            credentialStore: InMemoryAssistantCredentialStore(),
            cliInstallationProvider: { [.init(kind: .claude, executablePath: nil)] }
        )
        #expect(await router.assistantAvailability() == .needsSetup(
            .init(settings: settings),
            reason: "O Claude Code não foi encontrado neste Mac."
        ))
    }

    @Test("o Foundation Models reporta o estado da Apple Intelligence, não um destino pronto")
    @available(macOS 26.0, *)
    func foundationModelsReportsAppleIntelligence() async throws {
        let router = AssistantRouter(
            settingsStore: try store(.init(provider: .foundationModels)),
            credentialStore: InMemoryAssistantCredentialStore()
        )
        let availability = await router.assistantAvailability()
        switch availability {
        case .ready(let destination):
            #expect(destination.isLocal)
        case .appleIntelligence(let state):
            #expect(state != .available)
        default:
            Issue.record("Foundation Models não pode cair em needsSetup/needsSignIn: \(availability)")
        }
    }

    @Test("salvar preferências avisa quem observa")
    func storePublishesChanges() throws {
        let suite = "okamiuni.assistant-didchange.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        let box = Box()
        store.addDidChangeHandler { settings in box.record(settings.provider) }

        try store.save(.init(provider: .cli, cli: .init(kind: .openCode)))
        try store.reset()
        #expect(box.providers == [.cli, .foundationModels])
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AssistantProvider] = []
        var providers: [AssistantProvider] { lock.withLock { values } }
        func record(_ provider: AssistantProvider) { lock.withLock { values.append(provider) } }
    }
}
