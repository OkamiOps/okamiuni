import Foundation
import UNICore

/// Pede ao `TextAssisting` roteado um JSON fechado e o valida com
/// `Decodable` estrito. O contrato de evidência é o mesmo do motor local:
/// data só sobrevive quando `evidence` é trecho **literal** do texto
/// analisado e quando o texto de fato marca dia e hora — o modelo não pode
/// transformar a data de recebimento em compromisso inventado.
public struct TextAssistantMessageAnalyzer: MessageAnalyzing {
    public static let currentModelVersion = "text-assistant/message-analysis-v1"
    /// O prefixo que marca uma versão deste analisador — ou seja, um resumo
    /// que saiu deste Mac. É por ele que a legenda do TL;DR decide, para uma
    /// versão nova não fazer os resumos antigos mentirem sobre a origem.
    public static let modelVersionPrefix = "text-assistant/"

    public static func isRemoteModelVersion(_ version: String) -> Bool {
        version.hasPrefix(modelVersionPrefix)
    }
    public let modelVersion = TextAssistantMessageAnalyzer.currentModelVersion

    private let assistant: any TextAssisting
    private let availabilityProbe: @Sendable () async -> AppleIntelligenceAvailability

    public init(
        assistant: any TextAssisting,
        availability: @escaping @Sendable () async -> AppleIntelligenceAvailability
    ) {
        self.assistant = assistant
        self.availabilityProbe = availability
    }

    /// Barata de propósito: ela deriva do retrato que o roteador já mantém
    /// (`AssistantRouter.assistantAvailability()`), sem tocar na rede. O
    /// mapeamento é o do próprio roteador: `.ready` vira `.available`, o caso
    /// Apple Intelligence passa direto, e "falta configurar"/"falta entrar"
    /// viram `.modelNotReady` — o motor existe, mas ainda não responde.
    public func availability() async -> AppleIntelligenceAvailability {
        await availabilityProbe()
    }

    public func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
        let currentAvailability = await availability()
        guard currentAvailability == .available else {
            throw MessageAnalysisError.unavailable(currentAvailability)
        }

        let raw = try await assistant.answer(
            question: Self.question(for: input),
            in: AssistantConversationSnapshot(
                mailContext: .email(AssistantEmailContext(
                    subject: input.subject,
                    sender: input.sender,
                    sentAt: input.receivedAt,
                    body: input.body
                ))
            )
        )
        guard let data = Self.jsonPayload(in: raw) else {
            throw MessageAnalysisError.invalidResponse("A resposta não continha JSON.")
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else {
            throw MessageAnalysisError.invalidResponse("O JSON não bate com o contrato pedido.")
        }
        // A mesma guarda de qualidade do motor local: cabeçalho, repetição do
        // assunto e metadados de recebimento não ocupam o cartão de TL;DR.
        let summary = try MessageSummaryQuality.validated(output.summary, for: input)

        return MessageAnalysisResult(
            summary: summary,
            detectedEvent: output.detectedEvent.flatMap { $0.validated(against: input) },
            modelVersion: modelVersion,
            category: MailCategory(validatedModelValue: output.category)
        )
    }

    static func question(for input: MessageAnalysisInput) -> String {
        """
        Analise o e-mail em <untrusted-app-context> e devolva SOMENTE um
        objeto JSON, sem texto antes ou depois, sem bloco de código, com
        exatamente estas chaves:
        {"summary": String,
         "category": "primary"|"transactions"|"updates"|"promotions"|"social"|null,
         "detectedEvent": {"title": String, "evidence": String,
                           "dayOffset": Int, "startMinute": Int, "endMinute": Int} | null}
        `summary` tem 1 ou 2 frases em português do Brasil e começa pelo
        conteúdo, não por metadados. `category` é a intenção do e-mail:
        primary para conversa humana, trabalho ou cliente; transactions para
        pedido, fatura, pagamento ou recibo; updates para notificações ou
        status; promotions para newsletter, oferta ou marketing; social para
        rede ou comunidade. `detectedEvent` só existe quando o texto marca data
        e hora explícitas; `evidence` precisa ser um trecho **literal**,
        copiado caractere a caractere do corpo. Se não houver, use null.
        `dayOffset` é relativo à data de recebimento no fuso
        \(input.timeZone.identifier); `startMinute` e `endMinute` são
        minutos desde a meia-noite.
        """
    }

    /// O modelo às vezes embrulha o JSON em ```json. Pegar do primeiro `{`
    /// ao último `}` é mais honesto do que exigir formatação perfeita — e
    /// continua estrito, porque o `Decodable` recusa qualquer outra coisa.
    static func jsonPayload(in raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end
        else { return nil }
        return Data(raw[start...end].utf8)
    }

    struct Output: Decodable {
        struct Event: Decodable {
            let title: String
            let evidence: String
            let dayOffset: Int
            let startMinute: Int
            let endMinute: Int

            /// A mesma regra do motor local: sem trecho literal, e sem data e
            /// hora reconhecíveis no texto, o compromisso é descartado inteiro.
            func validated(against input: MessageAnalysisInput) -> DetectedEvent? {
                let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, !evidence.isEmpty else { return nil }
                guard input.body.contains(evidence) || input.subject.contains(evidence) else {
                    return nil
                }
                guard (0...31).contains(dayOffset),
                      (0..<1_440).contains(startMinute),
                      (0...1_440).contains(endMinute),
                      endMinute > startMinute
                else { return nil }

                let hour = startMinute / 60
                let minute = startMinute % 60
                guard MessageAnalysisEventEvidence.supports(
                    input: input, hour: hour, minute: minute
                ) else { return nil }

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = input.timeZone
                let day = calendar.startOfDay(for: input.receivedAt)
                guard let base = calendar.date(byAdding: .day, value: dayOffset, to: day),
                      let start = calendar.date(
                          bySettingHour: hour, minute: minute, second: 0, of: base
                      )
                else { return nil }

                return DetectedEvent(
                    label: label,
                    start: start,
                    duration: TimeInterval((endMinute - startMinute) * 60)
                )
            }
        }

        let summary: String
        let category: String?
        let detectedEvent: Event?
    }
}
