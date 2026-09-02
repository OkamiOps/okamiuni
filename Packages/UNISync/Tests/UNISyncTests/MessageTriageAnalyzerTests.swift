import Foundation
import Testing
import UNICore
@testable import UNISync

/// A triagem pelas duas rotas: o JSON pedido ao provedor configurado e a
/// saída estruturada do motor deste Mac.
@Suite("A triagem nos dois motores")
struct MessageTriageAnalyzerTests {

    private let input = MessageAnalysisInput(
        subject: "Proposta comercial",
        sender: "Marina <marina@cliente.com>",
        receivedAt: Date(timeIntervalSince1970: 1_788_000_000),
        body: "Quero fechar o pacote anual. Precisamos da sua resposta até sexta, 15h.",
        timeZone: TimeZone(identifier: "America/Sao_Paulo")!
    )

    // MARK: - Provedor configurado

    @Test("o JSON pedido ao provedor é congelado: campo novo quebra o golden")
    func questionGolden() throws {
        let pergunta = TextAssistantMessageAnalyzer.question(for: input)
        let url = try #require(Bundle.module.url(
            forResource: "message-analysis-question", withExtension: "txt", subdirectory: "Golden"
        ))
        let golden = try String(contentsOf: url, encoding: .utf8)
        if pergunta != golden {
            let atual = pergunta.components(separatedBy: "\n")
            let esperado = golden.components(separatedBy: "\n")
            let primeira = zip(atual, esperado).enumerated().first { $0.element.0 != $0.element.1 }
            if let primeira {
                Issue.record("""
                Primeira linha diferente (\(primeira.offset)):
                atual:  \(primeira.element.0)
                golden: \(primeira.element.1)
                """)
            } else {
                Issue.record("O golden tem \(esperado.count) linhas e a pergunta tem \(atual.count).")
            }
        }
        #expect(pergunta == golden)
    }

    @Test("a triagem do provedor sobrevive inteira quando o JSON bate")
    func triageFromProvider() async throws {
        let spy = SpyTextAssistantForAnalysis()
        spy.result = """
        {"summary":"Marina quer fechar o pacote anual e pede resposta.",
         "category":"primary",
         "detectedEvent":null,
         "triage":{"needsReply":true,"intent":"lead","urgency":"high",
                   "deadline":{"evidence":"até sexta, 15h","dayOffset":3,"minuteOfDay":900}}}
        """
        let analyzer = TextAssistantMessageAnalyzer(
            assistant: spy, availability: { .ready(.onThisMac) }
        )
        let triagem = try #require(try await analyzer.analyze(input).triage)
        #expect(triagem.needsReply)
        #expect(triagem.intent == .lead)
        #expect(triagem.urgency == .high)
        #expect(triagem.deadline?.evidence == "até sexta, 15h")
    }

    @Test("prazo com evidência inventada cai; a triagem continua valendo")
    func inventedDeadlineIsDropped() async throws {
        let spy = SpyTextAssistantForAnalysis()
        spy.result = """
        {"summary":"Marina quer fechar o pacote anual e pede resposta.",
         "triage":{"needsReply":true,"intent":"lead","urgency":"normal",
                   "deadline":{"evidence":"até quarta, 9h","dayOffset":1,"minuteOfDay":540}}}
        """
        let analyzer = TextAssistantMessageAnalyzer(
            assistant: spy, availability: { .ready(.onThisMac) }
        )
        let resultado = try await analyzer.analyze(input)
        #expect(resultado.triage?.deadline == nil)
        #expect(resultado.triage?.needsReply == true)
    }

    @Test("intenção fora do conjunto zera a triagem sem derrubar o resumo")
    func unknownIntentOnlyDropsTriage() async throws {
        let spy = SpyTextAssistantForAnalysis()
        spy.result = """
        {"summary":"Marina quer fechar o pacote anual e pede resposta.",
         "triage":{"needsReply":true,"intent":"urgentíssimo","urgency":"high"}}
        """
        let analyzer = TextAssistantMessageAnalyzer(
            assistant: spy, availability: { .ready(.onThisMac) }
        )
        let resultado = try await analyzer.analyze(input)
        #expect(resultado.triage == nil)
        #expect(resultado.summary == "Marina quer fechar o pacote anual e pede resposta.")
    }

    @Test("resposta sem triagem nenhuma continua sendo uma análise válida")
    func missingTriageIsFine() async throws {
        let spy = SpyTextAssistantForAnalysis()
        spy.result = #"{"summary":"Marina quer fechar o pacote anual e pede resposta."}"#
        let analyzer = TextAssistantMessageAnalyzer(
            assistant: spy, availability: { .ready(.onThisMac) }
        )
        let resultado = try await analyzer.analyze(input)
        #expect(resultado.triage == nil)
        #expect(!resultado.summary.isEmpty)
    }

    @Test("as duas versões de modelo subiram, para o histórico voltar à fila")
    func modelVersionsMovedForward() {
        #expect(TextAssistantMessageAnalyzer.currentModelVersion
            == "text-assistant/message-analysis-v2-triage")
        #expect(FoundationModelsMessageAnalyzer.currentModelVersion
            == "foundation-models/message-analysis-v7-triage")
    }

    // MARK: - Motor deste Mac

    @Test("a saída estruturada local vira triagem, com o prazo conferido")
    func triageFromFoundationModels() throws {
        let saida = MessageAnalysisGeneratedOutput(
            summary: "Marina quer fechar o pacote anual e pede resposta.",
            hasEvent: false, eventTitle: "", eventYear: 0, eventMonth: 0,
            eventDay: 0, eventHour: 0, eventMinute: 0, eventDurationMinutes: 0,
            category: "primary",
            needsReply: true, intent: "lead", urgency: "high",
            deadlineEvidence: "até sexta, 15h",
            deadlineYear: 2026, deadlineMonth: 9, deadlineDay: 4,
            deadlineHour: 15, deadlineMinute: 0
        )
        let triagem = try #require(
            try saida.analysis(for: input, modelVersion: "v").triage
        )
        #expect(triagem.needsReply)
        #expect(triagem.intent == .lead)
        #expect(triagem.deadline?.evidence == "até sexta, 15h")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone
        let partes = calendar.dateComponents(
            [.year, .month, .day, .hour], from: try #require(triagem.deadline?.date)
        )
        #expect(partes.year == 2026)
        #expect(partes.month == 9)
        #expect(partes.day == 4)
        #expect(partes.hour == 15)
    }

    @Test("prazo local sem trecho literal é descartado, e a triagem fica")
    func localDeadlineNeedsLiteralEvidence() throws {
        let saida = MessageAnalysisGeneratedOutput(
            summary: "Marina quer fechar o pacote anual e pede resposta.",
            hasEvent: false, eventTitle: "", eventYear: 0, eventMonth: 0,
            eventDay: 0, eventHour: 0, eventMinute: 0, eventDurationMinutes: 0,
            category: "primary",
            needsReply: true, intent: "request", urgency: "normal",
            deadlineEvidence: "até quarta, 9h",
            deadlineYear: 2026, deadlineMonth: 9, deadlineDay: 2,
            deadlineHour: 9, deadlineMinute: 0
        )
        let triagem = try #require(
            try saida.analysis(for: input, modelVersion: "v").triage
        )
        #expect(triagem.deadline == nil)
        #expect(triagem.intent == .request)
    }

    @Test("intenção que o motor local inventou não vira triagem")
    func localUnknownIntent() throws {
        let saida = MessageAnalysisGeneratedOutput(
            summary: "Marina quer fechar o pacote anual e pede resposta.",
            hasEvent: false, eventTitle: "", eventYear: 0, eventMonth: 0,
            eventDay: 0, eventHour: 0, eventMinute: 0, eventDurationMinutes: 0,
            category: "primary",
            needsReply: false, intent: "chamado", urgency: "normal"
        )
        #expect(try saida.analysis(for: input, modelVersion: "v").triage == nil)
    }
}
