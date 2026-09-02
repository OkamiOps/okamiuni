import Foundation

/// Os dados mínimos que uma análise local recebe de uma mensagem.
///
/// O fuso é parte da entrada porque expressões como "amanhã às 15h" só têm
/// significado quando são interpretadas contra a data de recebimento no fuso
/// da pessoa, e não contra o relógio de quem estiver rodando o processo.
public struct MessageAnalysisInput: Sendable, Hashable {
    public let subject: String
    public let sender: String
    public let receivedAt: Date
    public let body: String
    public let timeZone: TimeZone
    /// Quando a mensagem apareceu **neste Mac**.
    ///
    /// Separado de `receivedAt` de propósito: aquele é o `Date:` de quem
    /// mandou, e serve para o cálculo de "amanhã às 15h"; este é um fato
    /// local, e é o único que pode decidir a quem a mensagem pode ser
    /// mostrada. `nil` quando não há registro — aí só resta `receivedAt`.
    public let firstSeenAt: Date?

    public init(
        subject: String,
        sender: String,
        receivedAt: Date,
        body: String,
        timeZone: TimeZone,
        firstSeenAt: Date? = nil
    ) {
        self.subject = subject
        self.sender = sender
        self.receivedAt = receivedAt
        self.body = body
        self.timeZone = timeZone
        self.firstSeenAt = firstSeenAt
    }

    /// O instante que o app pode defender como "quando isto chegou aqui".
    ///
    /// O menor dos dois: um `Date:` no futuro não torna uma mensagem antiga
    /// recém-chegada, e um `Date:` no passado não torna uma recém-chegada
    /// antiga o bastante para escapar de um consentimento já dado. Errar para
    /// o lado de "mais antiga" é errar para o lado de não enviar.
    public var arrivedLocallyAt: Date {
        guard let firstSeenAt else { return receivedAt }
        return min(receivedAt, firstSeenAt)
    }
}

/// O que o motor local consegue afirmar sobre uma mensagem.
///
/// `modelVersion` identifica a política e o esquema que produziram o dado.
/// A API do sistema não expõe a versão interna do modelo Apple; por isso o
/// adaptador versiona a sua própria fronteira de saída sem inventar esse dado.
public struct MessageAnalysisResult: Sendable, Hashable {
    public let summary: String
    public let detectedEvent: DetectedEvent?
    /// Categoria fechada devolvida pelo modelo; `nil` quando a resposta veio
    /// ausente ou não passou pela validação do enum.
    public let category: MailCategory?
    public let modelVersion: String

    public init(
        summary: String,
        detectedEvent: DetectedEvent?,
        modelVersion: String,
        category: MailCategory? = nil
    ) {
        self.summary = summary
        self.detectedEvent = detectedEvent
        self.category = category
        self.modelVersion = modelVersion
    }
}

/// Os motivos que a interface pode explicar sem importar FoundationModels.
public enum AppleIntelligenceAvailability: Sendable, Hashable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    public var isAvailable: Bool {
        self == .available
    }
}

/// Falhas da fronteira de análise, separadas do estado de disponibilidade.
public enum MessageAnalysisError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(AppleIntelligenceAvailability)
    case invalidResponse(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(.available):
            return "A análise no dispositivo não está disponível neste momento."
        case .unavailable(.deviceNotEligible):
            return "Este dispositivo não é elegível para a análise no dispositivo."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "A Apple Intelligence está desativada neste dispositivo."
        case .unavailable(.modelNotReady):
            return "O modelo no dispositivo ainda não está pronto."
        case .invalidResponse:
            return "O modelo devolveu uma análise inválida."
        case let .generationFailed(message):
            return message
        }
    }
}

/// A porta assíncrona entre o estado do app e um motor local de linguagem.
///
/// Implementações ficam fora de UNICore para que este pacote continue usando
/// apenas Foundation e Observation.
public protocol MessageAnalyzing: Sendable {
    /// A versão que a fila usa para decidir o que ainda precisa de trabalho e
    /// que é gravada quando uma mensagem é assumida.
    var modelVersion: String { get }

    /// As versões já gravadas que **não** exigem reprocessamento.
    ///
    /// Existe porque um motor pode produzir resultados sob mais de uma versão
    /// legítima — um roteador que manda o histórico ao motor local e as
    /// mensagens novas ao provedor configurado grava duas. Sem isto, cada
    /// resultado gravado sob a "outra" versão pareceria obsoleto e a caixa
    /// inteira voltaria para a fila.
    var acceptedModelVersions: Set<String> { get }

    func availability() async -> AppleIntelligenceAvailability
    func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult

    /// O motor que **esta** mensagem usaria pode responder agora?
    ///
    /// Existe porque `availability()` responde pelo app inteiro, e um roteador
    /// tem mais de um motor: com o opt-in ligado e a assinatura expirada, o
    /// motor local segue pronto — só a mensagem nova não tem para onde ir.
    /// Perguntar por mensagem é o que permite pular a que não pode andar sem
    /// travar o histórico atrás dela, e é o que dá à fila um motivo que a
    /// pessoa consegue resolver.
    func availability(for input: MessageAnalysisInput) async -> MessageAnalysisAvailability

    /// Esta mensagem usa a **rota ativa** — a que as configurações de agora
    /// escolheriam para uma mensagem nova?
    ///
    /// Existe porque recusar não tem o mesmo peso nas duas rotas. Um Mac sem
    /// Apple Intelligence, com o provedor remoto configurado e funcionando,
    /// recusa cada mensagem anterior ao opt-in — e parar a fila por isso
    /// desligaria a rota que atende justamente o que ainda vai chegar. Só a
    /// recusa da rota ativa bloqueia trabalho que a fila poderia fazer.
    func routesActiveEngine(for input: MessageAnalysisInput) -> Bool
}

public extension MessageAnalyzing {
    /// Um motor só: a única versão aceita é a dele.
    var acceptedModelVersions: Set<String> { [modelVersion] }

    /// Um motor só: a resposta por mensagem é a do app inteiro. O motivo sai
    /// da mesma frase que a falha usaria, para a barra lateral não precisar
    /// inventar cópia própria.
    func availability(for input: MessageAnalysisInput) async -> MessageAnalysisAvailability {
        let state = await availability()
        return MessageAnalysisAvailability(
            state: state,
            reason: state == .available
                ? nil
                : MessageAnalysisError.unavailable(state).errorDescription
        )
    }

    /// Um motor só: a rota dele é a única, e portanto sempre a ativa.
    func routesActiveEngine(for input: MessageAnalysisInput) -> Bool { true }
}

/// O que o motor **desta** mensagem pode fazer agora, com o motivo em
/// linguagem de gente quando não pode nada.
///
/// `reason` é o texto que a fila pausada mostra ("Adicione a chave de API
/// deste provedor.", "Entre na assinatura xAI para usar a IA."): sem ele a
/// barra lateral só saberia dizer que parou.
public struct MessageAnalysisAvailability: Sendable, Equatable {
    public let state: AppleIntelligenceAvailability
    public let reason: String?

    public init(state: AppleIntelligenceAvailability, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }

    public var isAvailable: Bool { state == .available }

    public static let available = MessageAnalysisAvailability(state: .available)
}
