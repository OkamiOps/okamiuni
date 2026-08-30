import Foundation
import Testing
@testable import UNICore

@Suite("Contrato da análise no dispositivo")
struct OnDeviceMessageAnalysisTests {
    private let receivedAt = Date(timeIntervalSince1970: 1_788_000_000)
    private let timeZone = TimeZone(identifier: "America/Sao_Paulo")!

    @Test("A entrada preserva as âncoras factuais da mensagem")
    func inputPreservesMessageAnchors() {
        let input = OnDeviceMessageAnalysisInput(
            subject: "Reunião de produto",
            sender: "Marina <marina@example.com>",
            receivedAt: receivedAt,
            body: "Podemos falar amanhã às 15h?",
            timeZone: timeZone
        )

        #expect(input.subject == "Reunião de produto")
        #expect(input.sender == "Marina <marina@example.com>")
        #expect(input.receivedAt == receivedAt)
        #expect(input.body == "Podemos falar amanhã às 15h?")
        #expect(input.timeZone.identifier == "America/Sao_Paulo")
    }

    @Test("O resultado carrega resumo, compromisso opcional e versão")
    func resultCarriesPersistableMetadata() {
        let event = DetectedEvent(
            label: "Reunião de produto",
            start: receivedAt,
            duration: 30 * 60
        )
        let result = OnDeviceMessageAnalysisResult(
            summary: "Marina propõe uma reunião de produto.",
            detectedEvent: event,
            modelVersion: "foundation-models/message-analysis-v1",
            category: .primary
        )

        #expect(result.summary.contains("Marina"))
        #expect(result.detectedEvent == event)
        #expect(result.category == .primary)
        #expect(result.modelVersion == "foundation-models/message-analysis-v1")
    }

    @Test("A porta pode ser consultada e executada de forma assíncrona")
    func asynchronousPort() async throws {
        let analyzer = AnalysisDouble()
        let input = OnDeviceMessageAnalysisInput(
            subject: "Recibo",
            sender: "Loja <vendas@example.com>",
            receivedAt: receivedAt,
            body: "Sua compra foi confirmada.",
            timeZone: timeZone
        )

        #expect(await analyzer.availability() == .available)
        let result = try await analyzer.analyze(input)
        #expect(result.summary == "Sua compra foi confirmada.")
        #expect(result.detectedEvent == nil)
        #expect(result.modelVersion == analyzer.modelVersion)
    }

    @Test("Os estados indisponíveis são explícitos")
    func availabilityStatesAreNotCollapsed() {
        #expect(OnDeviceMessageAnalysisAvailability.available.isAvailable)
        #expect(!OnDeviceMessageAnalysisAvailability.deviceNotEligible.isAvailable)
        #expect(!OnDeviceMessageAnalysisAvailability.appleIntelligenceNotEnabled.isAvailable)
        #expect(!OnDeviceMessageAnalysisAvailability.modelNotReady.isAvailable)
    }
}

private struct AnalysisDouble: OnDeviceMessageAnalyzing {
    let modelVersion = "double-v1"

    func availability() async -> OnDeviceMessageAnalysisAvailability { .available }

    func analyze(_ input: OnDeviceMessageAnalysisInput) async throws -> OnDeviceMessageAnalysisResult {
        OnDeviceMessageAnalysisResult(
            summary: input.body,
            detectedEvent: nil,
            modelVersion: modelVersion
        )
    }
}
