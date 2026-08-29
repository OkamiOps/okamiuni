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

    @Test("Data de recebimento não vira compromisso sem evidência no email")
    func receiptCannotBorrowReceivedAt() throws {
        let receipt = OnDeviceMessageAnalysisInput(
            subject: "Recibo da compra",
            sender: "Loja <vendas@example.com>",
            receivedAt: input.receivedAt,
            body: "Sua compra foi confirmada e o recibo está anexado.",
            timeZone: timeZone
        )
        let hallucinated = MessageAnalysisGeneratedOutput(
            summary: "A compra foi confirmada.",
            hasEvent: true,
            eventTitle: "Compra confirmada",
            eventYear: 2026,
            eventMonth: 8,
            eventDay: 29,
            eventHour: 10,
            eventMinute: 40,
            eventDurationMinutes: 0
        )

        let result = try hallucinated.analysis(for: receipt, modelVersion: "test-v1")
        #expect(result.detectedEvent == nil)
    }

    @Test("Evento precisa repetir no resultado um horário explícito do email")
    func eventTimeMustMatchSource() throws {
        let wrongTime = MessageAnalysisGeneratedOutput(
            summary: "Marina propõe uma conversa amanhã.",
            hasEvent: true,
            eventTitle: "Conversa",
            eventYear: 2026,
            eventMonth: 8,
            eventDay: 30,
            eventHour: 16,
            eventMinute: 0,
            eventDurationMinutes: 30
        )

        let result = try wrongTime.analysis(for: input, modelVersion: "test-v1")
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
            eventHour: 15,
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

    @Test(
        "O motor real detecta compromisso quando data, hora e duração são explícitas",
        .enabled(if: ProcessInfo.processInfo.environment["OKAMIUNI_LIVE_MODEL_TEST"] == "1")
    )
    func liveModelDetectsExplicitEvent() async throws {
        let analyzer = FoundationModelsMessageAnalyzer()
        let currentAvailability = await analyzer.availability()
        guard currentAvailability == .available else {
            throw OnDeviceMessageAnalysisError.unavailable(currentAvailability)
        }

        let result = try await analyzer.analyze(
            OnDeviceMessageAnalysisInput(
                subject: "Reunião do projeto",
                sender: "Marina <marina@example.com>",
                receivedAt: input.receivedAt,
                body: "Nossa reunião será amanhã às 15h, com duração de 30 minutos.",
                timeZone: timeZone
            )
        )
        let event = try #require(result.detectedEvent)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        #expect(calendar.component(.hour, from: event.start) == 15)
        #expect(calendar.component(.minute, from: event.start) == 0)
        #expect(event.duration == 30 * 60)
    }
}
