import Foundation
import UNICore

/// Pede ao `TextAssisting` roteado um JSON fechado e o valida com
/// `Decodable` estrito. O contrato de evidência é o mesmo do motor local:
/// data só sobrevive quando `evidence` é trecho **literal** do texto
/// analisado e quando o texto de fato marca dia e hora — o modelo não pode
/// transformar a data de recebimento em compromisso inventado.
public struct TextAssistantMessageAnalyzer: MessageAnalyzing {
    public static let currentModelVersion = "text-assistant/message-analysis-v2-triage"
    /// O prefixo que marca uma versão deste analisador — ou seja, um resumo
    /// que saiu deste Mac. É por ele que a legenda do TL;DR decide, para uma
    /// versão nova não fazer os resumos antigos mentirem sobre a origem.
    public static let modelVersionPrefix = "text-assistant/"

    public static func isRemoteModelVersion(_ version: String) -> Bool {
        version.hasPrefix(modelVersionPrefix)
    }
    public let modelVersion = TextAssistantMessageAnalyzer.currentModelVersion

    private let assistant: any TextAssisting
    private let availabilityProbe: @Sendable () async -> AssistantAvailability

    /// A sonda é a rica (`AssistantAvailability`), e não o `enum` de três
    /// estados, porque é dela que sai o motivo acionável — "Adicione a chave
    /// de API deste provedor.", "Entre na assinatura xAI para usar a IA.".
    /// Sem ele a fila só saberia dizer que parou.
    public init(
        assistant: any TextAssisting,
        availability: @escaping @Sendable () async -> AssistantAvailability
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
        Self.state(of: await availabilityProbe())
    }

    /// Este analisador tem um motor só, mas o motivo dele é bom demais para
    /// virar a frase genérica do `default` do protocolo.
    public func availability(for input: MessageAnalysisInput) async -> MessageAnalysisAvailability {
        let probed = await availabilityProbe()
        return MessageAnalysisAvailability(state: Self.state(of: probed), reason: probed.reason)
    }

    /// O mesmo mapeamento do roteador: `.ready` vira `.available`, o caso
    /// Apple Intelligence passa direto, e "falta configurar"/"falta entrar"
    /// viram `.modelNotReady` — o motor existe, mas ainda não responde.
    static func state(of availability: AssistantAvailability) -> AppleIntelligenceAvailability {
        switch availability {
        case .ready: .available
        case let .appleIntelligence(state): state
        case .needsSetup, .needsSignIn: .modelNotReady
        }
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
            category: MailCategory(validatedModelValue: output.category),
            triage: output.triage?.value?.validated(against: input)
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
                           "dayOffset": Int, "startMinute": Int, "endMinute": Int} | null,
         "triage": {"needsReply": Bool,
                    "intent": "lead"|"request"|"informational"|"newsletter"|"transactional"|"scheduling",
                    "urgency": "high"|"normal"|"low",
                    "deadline": {"evidence": String, "dayOffset": Int,
                                 "minuteOfDay": Int} | null} | null}
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
        `triage` diz por que a mensagem importa: `needsReply` é true quando
        alguém espera uma resposta sua; `intent` é lead para interesse
        comercial, request para pedido de trabalho ou informação,
        informational para aviso que não pede nada, newsletter para conteúdo
        periódico, transactional para recibo, fatura ou confirmação
        automática, scheduling para marcar ou remarcar horário; `urgency` é
        high só quando o próprio texto trata a coisa como urgente.
        `deadline` é o prazo que o texto afirma, e obedece à mesma regra do
        compromisso: `evidence` precisa ser um trecho **literal**, copiado
        caractere a caractere; `dayOffset` e `minuteOfDay` são relativos à
        data de recebimento, como acima. Se não houver, use null.
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

        /// A triagem chega **tolerante**: campo desconhecido, enum inválido
        /// ou objeto malformado devolvem `nil` aqui, e não uma exceção. O
        /// resumo é o que o cartão do leitor precisa, e derrubar a análise
        /// inteira porque o modelo escreveu "urgentíssimo" em `intent`
        /// custaria o TL;DR de uma mensagem que estava perfeitamente resumida.
        /// A decodificação continua estrita — nada é adivinhado, só descartado.
        struct Triage: Decodable {
            struct Deadline: Decodable {
                let evidence: String
                let dayOffset: Int
                let minuteOfDay: Int

                /// O prazo em data local, contado a partir do recebimento —
                /// o mesmo cálculo do compromisso, pelo mesmo motivo: o
                /// modelo não sabe que dia é hoje, e o app sabe.
                func date(for input: MessageAnalysisInput) -> DetectedDeadline? {
                    guard (0...366).contains(dayOffset),
                          (0..<1_440).contains(minuteOfDay)
                    else { return nil }
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = input.timeZone
                    let dia = calendar.startOfDay(for: input.receivedAt)
                    guard let base = calendar.date(byAdding: .day, value: dayOffset, to: dia),
                          let instante = calendar.date(
                              bySettingHour: minuteOfDay / 60,
                              minute: minuteOfDay % 60,
                              second: 0,
                              of: base
                          )
                    else { return nil }
                    return DetectedDeadline(date: instante, evidence: evidence)
                }
            }

            let needsReply: Bool
            let intent: String
            let urgency: String
            let deadline: Deadline?

            func validated(against input: MessageAnalysisInput) -> MessageTriage? {
                guard let intent = MessageTriage.Intent(rawValue: intent),
                      let urgency = MessageTriage.Urgency(rawValue: urgency)
                else { return nil }
                return MessageTriage(
                    needsReply: needsReply,
                    intent: intent,
                    urgency: urgency,
                    deadline: deadline.flatMap { $0.date(for: input) }
                ).validated(against: input)
            }
        }

        let summary: String
        let category: String?
        let detectedEvent: Event?
        let triage: TolerantTriage?
    }

    /// O invólucro que transforma "triagem malformada" em `nil` em vez de
    /// erro. `Decodable` sintetizado não tem como dizer isto: um campo
    /// opcional inválido é erro de decodificação, e o contrato do §3.3 pede
    /// que só a triagem caia.
    struct TolerantTriage: Decodable {
        let value: Output.Triage?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(Output.Triage.self)
        }
    }
}
