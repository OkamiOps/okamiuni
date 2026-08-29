import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("Adapter Foundation Models")
struct FoundationModelsMessageAnalyzerTests {
    private let timeZone = TimeZone(identifier: "America/Sao_Paulo")!

    private var input: OnDeviceMessageAnalysisInput {
        OnDeviceMessageAnalysisInput(
            subject: "Planejamento",
            sender: "Marina <marina@example.com>",
            receivedAt: Date(timeIntervalSince1970: 1_788_000_000),
            body: "Podemos falar amanhã às 15h.",
            timeZone: timeZone
        )
    }

    @Test("O prompt ancora datas relativas no recebimento e no fuso")
    func promptUsesExplicitTemporalAnchors() {
        let prompt = MessageAnalysisPrompt.make(for: input)

        #expect(prompt.contains("subject: Planejamento"))
        #expect(prompt.contains("sender: Marina <marina@example.com>"))
        #expect(prompt.contains("receivedAt: 2026-08-29T"))
        #expect(prompt.contains("timezone: America/Sao_Paulo"))
        #expect(prompt.contains("Não invente pessoas, ações, compromissos, datas, horários"))
        #expect(prompt.contains("Só marque hasEvent como true"))
    }

    @Test("O corpo longo preserva começo e fim dentro do limite")
    func bodyLimitPreservesBothEnds() {
        let body = "COMEÇO-" + String(repeating: "x", count: 80) + "-FIM"
        let bounded = MessageAnalysisPrompt.boundedBody(body, maximumCharacters: 41)

        #expect(bounded.count <= 41)
        #expect(bounded.hasPrefix("COMEÇO-"))
        #expect(bounded.hasSuffix("-FIM"))
        #expect(bounded.contains(MessageAnalysisPrompt.omittedMiddleMarker))
    }

    @Test("Parsing cria compromisso somente com campos coerentes")
    func parsingCreatesValidatedEvent() throws {
        let output = MessageAnalysisGeneratedOutput(
            summary: "Marina propõe uma conversa de planejamento.",
            hasEvent: true,
            eventTitle: "Conversa de planejamento",
            eventYear: 2026,
            eventMonth: 8,
            eventDay: 30,
            eventHour: 15,
            eventMinute: 0,
            eventDurationMinutes: 0
        )

        let result = try output.analysis(
            for: input,
            modelVersion: "test-v1"
        )
        let event = try #require(result.detectedEvent)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: event.start
        )
        #expect(result.summary == "Marina propõe uma conversa de planejamento.")
        #expect(result.modelVersion == "test-v1")
        #expect(event.label == "Conversa de planejamento")
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 30)
        #expect(components.hour == 15)
        #expect(components.minute == 0)
        #expect(event.duration == 0)
    }

    @Test("Campos soltos não viram compromisso quando hasEvent é falso")
    func parsingDoesNotInventAnEvent() throws {
        let output = MessageAnalysisGeneratedOutput(
            summary: "Marina menciona planejamento.",
            hasEvent: false,
            eventTitle: "Não usar",
            eventYear: 2026,
            eventMonth: 99,
            eventDay: 99,
            eventHour: 99,
            eventMinute: 99,
            eventDurationMinutes: -1
        )

        let result = try output.analysis(
            for: input,
            modelVersion: "test-v1"
        )

        #expect(result.detectedEvent == nil)
    }

    @Test("Data impossível é rejeitada em vez de normalizada")
    func parsingRejectsImpossibleDate() throws {
        let output = MessageAnalysisGeneratedOutput(
            summary: "Mensagem com data inválida.",
            hasEvent: true,
            eventTitle: "Reunião",
            eventYear: 2026,
            eventMonth: 2,
            eventDay: 30,
            eventHour: 10,
            eventMinute: 0,
            eventDurationMinutes: 30
        )

        #expect(throws: OnDeviceMessageAnalysisError.invalidResponse("Data de compromisso inválida.")) {
            try output.analysis(
                for: input,
                modelVersion: "test-v1"
            )
        }
    }

    /// Só roda sob pedido explícito: a suíte padrão não consome geração local.
    @Test(
        "O motor real resume uma mensagem neutra sem inventar compromisso",
        .enabled(if: ProcessInfo.processInfo.environment["OKAMIUNI_LIVE_MODEL_TEST"] == "1")
    )
    func liveModel() async throws {
        guard #available(macOS 26.0, *) else { return }

        let analyzer = FoundationModelsMessageAnalyzer()
        let currentAvailability = await analyzer.availability()
        guard currentAvailability == .available else {
            throw OnDeviceMessageAnalysisError.unavailable(currentAvailability)
        }

        let result = try await analyzer.analyze(
            OnDeviceMessageAnalysisInput(
                subject: "Recibo da compra",
                sender: "Loja Exemplo <vendas@example.com>",
                receivedAt: Date(timeIntervalSince1970: 1_788_000_000),
                body: "Olá. Sua compra foi confirmada e o recibo está anexado a esta mensagem.",
                timeZone: timeZone
            )
        )

        #expect(!result.summary.isEmpty)
        #expect(result.detectedEvent == nil)
        #expect(result.modelVersion == analyzer.modelVersion)
    }
}
