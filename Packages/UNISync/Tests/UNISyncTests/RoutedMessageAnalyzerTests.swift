import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Rota da análise automática")
struct RoutedMessageAnalyzerTests {
    private func store(_ route: AutomaticAnalysisRoute) throws -> AssistantSettingsStore {
        let suite = "okamiuni.automatic-analysis.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try store.save(.init(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://api.example.com/v1", model: "m",
                credentialID: "primary", authenticationMode: .apiKey
            ),
            automaticAnalysis: route
        ))
        return store
    }

    private var input: MessageAnalysisInput {
        .init(
            subject: "Revisão", sender: "Marina <marina@example.com>",
            receivedAt: Date(timeIntervalSince1970: 1_788_000_000),
            body: "Falamos amanhã às 15h.",
            timeZone: TimeZone(identifier: "America/Sao_Paulo")!
        )
    }

    @Test("o padrão é a rota do dispositivo, mesmo com provedor remoto escolhido")
    func defaultsToOnDevice() async throws {
        #expect(AssistantSettings.default.automaticAnalysis == .onDeviceOnly)
        let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
        let configured = SpyMessageAnalyzer(modelVersion: "remoto")
        let analyzer = RoutedMessageAnalyzer(
            settingsStore: try store(.onDeviceOnly),
            onDevice: onDevice, configured: configured
        )
        _ = try await analyzer.analyze(input)
        #expect(onDevice.calls == 1)
        #expect(configured.calls == 0)
        #expect(analyzer.modelVersion == "on-device")
    }

    @Test("com opt-in, cada mensagem vai para o provedor configurado")
    func optInRoutesToConfigured() async throws {
        let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
        let configured = SpyMessageAnalyzer(modelVersion: "remoto")
        let analyzer = RoutedMessageAnalyzer(
            settingsStore: try store(.configuredProvider),
            onDevice: onDevice, configured: configured
        )
        _ = try await analyzer.analyze(input)
        #expect(configured.calls == 1)
        #expect(onDevice.calls == 0)
        #expect(analyzer.modelVersion == "remoto")
    }

    @Test("com o Foundation Models escolhido, o opt-in não muda nada")
    func foundationModelsKeepsTheLocalEngine() async throws {
        let suite = "okamiuni.automatic-analysis.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try store.save(.init(provider: .foundationModels, automaticAnalysis: .configuredProvider))

        let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
        let configured = SpyMessageAnalyzer(modelVersion: "remoto")
        let analyzer = RoutedMessageAnalyzer(
            settingsStore: store, onDevice: onDevice, configured: configured
        )
        _ = try await analyzer.analyze(input)
        #expect(onDevice.calls == 1)
        #expect(configured.calls == 0)
    }

    @Test("o JSON do provedor é validado com rigor, e evidência sem trecho literal cai")
    func strictJSONValidation() async throws {
        let spy = SpyTextAssistantForAnalysis()
        spy.result = """
        {"summary":"Marina propõe amanhã às 15h.",
         "category":"primary",
         "detectedEvent":{"title":"Conversa","evidence":"amanhã às 15h",
                          "startMinute":900,"endMinute":960,"dayOffset":1}}
        """
        let analyzer = TextAssistantMessageAnalyzer(assistant: spy, availability: { .available })
        let result = try await analyzer.analyze(input)
        #expect(result.summary == "Marina propõe amanhã às 15h.")
        #expect(result.detectedEvent != nil)
        #expect(result.category == .primary)
        #expect(result.modelVersion == TextAssistantMessageAnalyzer.currentModelVersion)

        // A mesma hora que o corpo marca, mas a evidência é inventada: sem
        // trecho literal o compromisso cai, e só o resumo sobrevive.
        spy.result = """
        {"summary":"Resumo do que ficou combinado entre as duas partes.",
         "detectedEvent":{"title":"Reunião",
         "evidence":"terça que vem","startMinute":900,"endMinute":960,"dayOffset":1}}
        """
        let invented = try await analyzer.analyze(input)
        #expect(invented.detectedEvent == nil)
        #expect(invented.summary == "Resumo do que ficou combinado entre as duas partes.")

        spy.result = "isto não é JSON"
        await #expect(throws: MessageAnalysisError.self) {
            _ = try await analyzer.analyze(input)
        }
    }

    @Test("o compromisso aceito vira data local a partir do recebimento")
    func detectedEventUsesTheReceivedDay() async throws {
        let spy = SpyTextAssistantForAnalysis()
        spy.result = """
        {"summary":"Marina propõe amanhã às 15h.",
         "detectedEvent":{"title":"Conversa","evidence":"amanhã às 15h",
                          "startMinute":900,"endMinute":960,"dayOffset":1}}
        """
        let analyzer = TextAssistantMessageAnalyzer(assistant: spy, availability: { .available })
        let event = try #require(try await analyzer.analyze(input).detectedEvent)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone
        let components = calendar.dateComponents([.hour, .minute], from: event.start)
        #expect(components.hour == 15)
        #expect(components.minute == 0)
        #expect(event.duration == 60 * 60)
        #expect(calendar.dateComponents([.day], from: input.receivedAt, to: event.start).day == 1)
        #expect(event.label == "Conversa")
    }

    @Test("o resumo vazio e a categoria fora do conjunto não passam")
    func rejectsEmptySummaryAndUnknownCategory() async throws {
        let spy = SpyTextAssistantForAnalysis()
        spy.result = #"{"summary":"   ","detectedEvent":null}"#
        let analyzer = TextAssistantMessageAnalyzer(assistant: spy, availability: { .available })
        await #expect(throws: MessageAnalysisError.self) {
            _ = try await analyzer.analyze(input)
        }

        spy.result = #"{"summary":"Marina propõe conversar amanhã à tarde.","category":"pessoal"}"#
        let result = try await analyzer.analyze(input)
        #expect(result.category == nil)
    }

    @Test("indisponível não é traduzido em análise vazia")
    func unavailablePropagates() async throws {
        let spy = SpyTextAssistantForAnalysis()
        let analyzer = TextAssistantMessageAnalyzer(
            assistant: spy, availability: { .modelNotReady }
        )
        #expect(await analyzer.availability() == .modelNotReady)
        await #expect(throws: MessageAnalysisError.unavailable(.modelNotReady)) {
            _ = try await analyzer.analyze(input)
        }
        #expect(spy.calls == 0)
    }
}

final class SpyMessageAnalyzer: MessageAnalyzing, @unchecked Sendable {
    let modelVersion: String
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(modelVersion: String) { self.modelVersion = modelVersion }

    func availability() async -> AppleIntelligenceAvailability { .available }

    func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
        lock.withLock { count += 1 }
        return .init(summary: "resumo", detectedEvent: nil, modelVersion: modelVersion)
    }
}

final class SpyTextAssistantForAnalysis: TextAssisting, @unchecked Sendable {
    let modelVersion = "spy/analysis"
    private let lock = NSLock()
    private var storedResult = "{}"
    private var count = 0

    var result: String {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }

    var calls: Int { lock.withLock { count } }

    func availability() async -> AppleIntelligenceAvailability { .available }

    func answer(question: String, in conversation: AssistantConversationSnapshot) async throws -> String {
        lock.withLock { count += 1 }
        return result
    }

    func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String {
        lock.withLock { count += 1 }
        return result
    }
}
