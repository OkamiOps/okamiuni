import Foundation

/// Um prazo que o texto da mensagem afirma, com o trecho que o afirma.
///
/// `evidence` não é decoração: é a condição de existência do prazo. Sem um
/// trecho literal do texto analisado, o prazo é descartado — a mesma regra do
/// compromisso, pela mesma razão. Um modelo que "acha" que o cliente quer
/// resposta até sexta acabaria colocando um email qualquer no topo do
/// dashboard, e a pessoa não teria como conferir de onde veio a data.
public struct DetectedDeadline: Sendable, Hashable, Codable {
    public let date: Date
    public let evidence: String

    public init(date: Date, evidence: String) {
        self.date = date
        self.evidence = evidence
    }
}

/// O que a análise persistida afirma sobre **por que** esta mensagem importa.
///
/// Existe porque o ranking do dashboard era heurística de etiqueta, e
/// etiqueta é coisa das fixtures: numa conta de verdade nenhuma mensagem tem
/// "Precisa resposta" pendurada, então tudo caía em "não lido de hoje" e a
/// newsletter aparecia como prioridade. A triagem é o dado que faz a aba
/// dizer a verdade.
public struct MessageTriage: Sendable, Hashable, Codable {

    /// A intenção primária da mensagem. Fechada de propósito: um enum aberto
    /// deixaria o modelo inventar rótulo, e o ranking não saberia o que fazer
    /// com ele.
    public enum Intent: String, Sendable, Hashable, Codable, CaseIterable {
        case lead
        case request
        case informational
        case newsletter
        case transactional
        case scheduling

        /// As duas que o dashboard descarta quando ninguém as sinalizou.
        /// Ficam aqui, e não num `if` da tela, porque é regra de produto.
        public var isBackgroundNoise: Bool {
            self == .newsletter || self == .transactional
        }
    }

    public enum Urgency: String, Sendable, Hashable, Codable, CaseIterable {
        case high
        case normal
        case low
    }

    public let needsReply: Bool
    public let intent: Intent
    public let urgency: Urgency
    public let deadline: DetectedDeadline?

    public init(
        needsReply: Bool,
        intent: Intent,
        urgency: Urgency,
        deadline: DetectedDeadline? = nil
    ) {
        self.needsReply = needsReply
        self.intent = intent
        self.urgency = urgency
        self.deadline = deadline
    }

    /// A mesma triagem, sem o prazo que o texto não sustenta.
    ///
    /// O resto sobrevive: `needsReply`, intenção e urgência são juízo sobre o
    /// texto inteiro, e não afirmações factuais que se possa conferir palavra
    /// a palavra. Só a data é fato, e só ela precisa de citação.
    public func validated(against input: MessageAnalysisInput) -> MessageTriage {
        guard let deadline,
              MessageAnalysisEventEvidence.quotesLiteral(deadline.evidence, in: input)
        else {
            return MessageTriage(
                needsReply: needsReply, intent: intent, urgency: urgency, deadline: nil
            )
        }
        return self
    }

    // MARK: - Forma guardada

    /// O JSON da coluna `triage`. As duas rotas gravam o mesmo texto, e é ele
    /// que a hidratação lê de volta — não há segundo formato.
    public static func encodedJSON(_ triage: MessageTriage?) -> String? {
        guard let triage else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(triage) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `nil` para coluna vazia, texto corrompido ou enum que este binário não
    /// conhece — a mensagem volta a ser ranqueada pelas heurísticas antigas
    /// em vez de o app cair.
    public static func decoded(_ json: String?) -> MessageTriage? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(MessageTriage.self, from: data)
    }
}
