import Foundation
import Testing
@testable import UNISync

@Suite("Configurações persistidas do assistente")
struct AssistantSettingsTests {
    @Test("persiste um documento atômico sem colocar a chave de API nele")
    func persistsSnapshot() async throws {
        let suite = "okamiuni.assistant-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = "assistant"
        let settings = AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://litellm.example/v1/",
                model: "grok-4-fast",
                credentialID: "grok-team"
            ),
            additionalInstructions: "  Priorize respostas objetivas.  "
        )
        let store = AssistantSettingsStore(defaults: defaults, key: key)
        let saved = try store.save(settings)

        #expect(saved.additionalInstructions == "Priorize respostas objetivas.")
        let reloaded = AssistantSettingsStore(defaults: defaults, key: key)
        let snapshot = reloaded.snapshot()
        #expect(snapshot == saved)

        let data = try #require(defaults.data(forKey: key))
        let document = try #require(String(data: data, encoding: .utf8))
        #expect(document.contains("grok-team"))
        #expect(!document.contains("api-secret"))
    }

    @Test("normaliza endpoint LiteLLM e rejeita URL insegura ou com credenciais")
    func endpointValidation() throws {
        let base = OpenAICompatibleAssistantConfiguration(
            endpoint: "https://proxy.example/v1/",
            model: "gpt-5.4",
            credentialID: "primary"
        )
        #expect(try base.chatCompletionsURL().absoluteString == "https://proxy.example/v1/chat/completions")

        let fullRoute = OpenAICompatibleAssistantConfiguration(
            endpoint: "https://proxy.example/v1/chat/completions",
            model: "gpt-5.4"
        )
        #expect(try fullRoute.chatCompletionsURL().absoluteString == "https://proxy.example/v1/chat/completions")

        let local = OpenAICompatibleAssistantConfiguration(
            endpoint: "http://127.0.0.1:4000",
            model: "local-model"
        )
        #expect(try local.chatCompletionsURL().absoluteString == "http://127.0.0.1:4000/v1/chat/completions")

        #expect(throws: AssistantSettingsError.endpointMustUseHTTPS) {
            try OpenAICompatibleAssistantConfiguration(
                endpoint: "http://proxy.example",
                model: "remote"
            ).validated()
        }
        #expect(throws: AssistantSettingsError.endpointContainsCredentials) {
            try OpenAICompatibleAssistantConfiguration(
                endpoint: "https://user:password@proxy.example",
                model: "remote"
            ).validated()
        }
    }

    @Test("rejeita schema futuro e instruções fora do limite")
    func rejectsUnsupportedConfiguration() {
        let futureSchema = AssistantSettings.currentSchemaVersion + 1
        #expect(throws: AssistantSettingsError.unsupportedSchemaVersion(futureSchema)) {
            try AssistantSettings(schemaVersion: futureSchema).migrated()
        }
        #expect(throws: AssistantSettingsError.additionalInstructionsTooLong) {
            try AssistantSettings(
                additionalInstructions: String(
                    repeating: "x",
                    count: AssistantSettings.maximumAdditionalInstructionsCharacters + 1
                )
            ).migrated()
        }
    }

    @Test("migra o documento v1 para API key e configuração de CLI explícita")
    func migratesLegacyDocumentWithoutNewFields() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "provider": "openAICompatible",
          "openAICompatible": {
            "endpoint": "https://litellm.example/v1",
            "model": "gateway-default",
            "credentialID": "legacy-key"
          },
          "additionalInstructions": "  Seja objetivo.  "
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: data)
        let migrated = try decoded.migrated()

        #expect(migrated.schemaVersion == AssistantSettings.currentSchemaVersion)
        #expect(migrated.openAICompatible.authenticationMode == .apiKey)
        #expect(migrated.openAICompatible.credentialID == "legacy-key")
        #expect(migrated.cli.kind == .codex)
        #expect(migrated.behavior == .default)
        #expect(migrated.additionalInstructions == "Seja objetivo.")
    }

    @Test("a v5 preenche a rota da análise sem mudar o provedor")
    func migratesToSchemaFive() throws {
        let legacy = """
        {"schemaVersion":4,"provider":"cli","openAICompatible":{"endpoint":"","model":"",
         "credentialID":"openai-compatible-default","authenticationMode":"apiKey"},
         "providerOAuth":{"kind":"codex","model":"","credentialID":"provider-oauth-codex"},
         "cli":{"kind":"openCode"},"behavior":{"tone":"natural","detail":"adaptive",
         "language":"portugueseBrazil","format":"adaptive","suggestNextSteps":true,
         "questionsInstructions":"","writingInstructions":""},"additionalInstructions":""}
        """
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: Data(legacy.utf8))
        let migrated = try decoded.migrated()
        #expect(migrated.schemaVersion == 5)
        #expect(AssistantSettings.currentSchemaVersion == 5)
        #expect(migrated.provider == .cli)
        #expect(migrated.automaticAnalysis == .onDeviceOnly)
    }

    /// A cópia promete "mensagens novas". O carimbo é o que a torna verdade,
    /// e ele nasce no mesmo save que liga a rota.
    @Test("o carimbo do opt-in nasce ao ligar e some ao desligar")
    func optInStampFollowsTheRoute() throws {
        let clique = Date(timeIntervalSince1970: 1_788_000_100)
        var settings = AssistantSettings.default
        settings.provider = .openAICompatible
        settings.openAICompatible = .init(
            endpoint: "https://api.example.com/v1", model: "m",
            credentialID: "primary", authenticationMode: .apiKey
        )
        #expect(settings.automaticAnalysisSince == nil)

        settings.automaticAnalysis = .configuredProvider
        let ligado = try settings.migrated(now: clique)
        #expect(ligado.automaticAnalysisSince == clique)
        #expect(ligado.automaticAnalysisCoversMessage(receivedAt: clique))
        #expect(!ligado.automaticAnalysisCoversMessage(
            receivedAt: clique.addingTimeInterval(-1)
        ))

        // Um save posterior não move o carimbo para a frente.
        let resalvo = try ligado.migrated(now: clique.addingTimeInterval(5_000))
        #expect(resalvo.automaticAnalysisSince == clique)

        // Desligar o apaga; religar vale do novo instante, nunca do antigo.
        var desligado = resalvo
        desligado.automaticAnalysis = .onDeviceOnly
        let limpo = try desligado.migrated(now: clique.addingTimeInterval(6_000))
        #expect(limpo.automaticAnalysisSince == nil)
        #expect(!limpo.automaticAnalysisCoversMessage(receivedAt: .distantFuture))

        var religado = limpo
        religado.automaticAnalysis = .configuredProvider
        let novo = try religado.migrated(now: clique.addingTimeInterval(9_000))
        #expect(novo.automaticAnalysisSince == clique.addingTimeInterval(9_000))
    }

    /// O carimbo tem de ser **gravado** na abertura que o cria. Recalculá-lo a
    /// cada lançamento deixaria de fora tudo que chegou entre dois deles.
    @Test("o carimbo criado na abertura é persistido, e não recalculado")
    func optInStampIsPersistedOnLoad() throws {
        let suite = "okamiuni.opt-in-stamp.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        // Um documento v5 do binário anterior: rota ligada, sem carimbo.
        var semCarimbo = AssistantSettings.default
        semCarimbo.provider = .cli
        semCarimbo.automaticAnalysis = .configuredProvider
        defaults.set(try JSONEncoder().encode(semCarimbo), forKey: "assistant")

        let primeiro = AssistantSettingsStore(defaults: defaults, key: "assistant")
        let carimbo = try #require(primeiro.snapshot().automaticAnalysisSince)

        let segundo = AssistantSettingsStore(defaults: defaults, key: "assistant")
        #expect(segundo.snapshot().automaticAnalysisSince == carimbo)
    }

    @Test("a rota da análise sobrevive a uma ida e volta pelo JSON")
    func automaticAnalysisRoundTrips() throws {
        var settings = AssistantSettings.default
        settings.automaticAnalysis = .configuredProvider
        let decoded = try JSONDecoder().decode(
            AssistantSettings.self, from: try JSONEncoder().encode(settings)
        )
        #expect(decoded.automaticAnalysis == .configuredProvider)
        #expect(AssistantSettings.default.automaticAnalysis == .onDeviceOnly)
    }

    @Test("persiste preferências humanas e separa instruções de análise e escrita")
    func behaviorPreferencesArePurposeAware() throws {
        let settings = AssistantSettings(
            behavior: .init(
                tone: .direct,
                detail: .detailed,
                language: .english,
                format: .executive,
                suggestNextSteps: false,
                questionsInstructions: "Priorize riscos contratuais.",
                writingInstructions: "Nunca use a expressão conforme solicitado."
            ),
            additionalInstructions: "Use os nomes completos das empresas."
        )

        let migrated = try settings.migrated()
        let questions = migrated.configuredInstructions(for: .questions)
        let writing = migrated.configuredInstructions(for: .writing)

        #expect(questions.contains("Vá direto ao ponto"))
        #expect(questions.contains("Respond in English"))
        #expect(questions.contains("Priorize riscos contratuais."))
        #expect(!questions.contains("conforme solicitado"))
        #expect(writing.contains("conforme solicitado"))
        #expect(!writing.contains("riscos contratuais"))
        #expect(writing.contains("Use os nomes completos das empresas."))

        let encoded = try JSONEncoder().encode(migrated)
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: encoded)
        #expect(decoded == migrated)
    }

    @Test("limita instruções específicas sem contar opções estruturadas")
    func limitsPurposeInstructions() {
        let oversized = String(
            repeating: "x",
            count: AssistantSettings.maximumPurposeInstructionsCharacters + 1
        )
        #expect(throws: AssistantSettingsError.additionalInstructionsTooLong) {
            try AssistantSettings(
                behavior: .init(questionsInstructions: oversized)
            ).migrated()
        }
    }

    @Test("não sobrescreve no boot uma configuração criada por versão futura")
    func preservesFutureSchemaUntilExplicitSave() throws {
        let suite = "okamiuni.assistant-settings-future.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = "assistant"
        let future = AssistantSettings(
            schemaVersion: AssistantSettings.currentSchemaVersion + 1,
            additionalInstructions: "Não perder esta configuração."
        )
        let data = try JSONEncoder().encode(future)
        defaults.set(data, forKey: key)

        let store = AssistantSettingsStore(defaults: defaults, key: key)
        #expect(store.snapshot() == .default)
        #expect(defaults.data(forKey: key) == data)
    }
}
