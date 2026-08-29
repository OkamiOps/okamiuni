import Foundation

/// Os dados mínimos que uma análise local recebe de uma mensagem.
///
/// O fuso é parte da entrada porque expressões como "amanhã às 15h" só têm
/// significado quando são interpretadas contra a data de recebimento no fuso
/// da pessoa, e não contra o relógio de quem estiver rodando o processo.
public struct OnDeviceMessageAnalysisInput: Sendable, Hashable {
    public let subject: String
    public let sender: String
    public let receivedAt: Date
    public let body: String
    public let timeZone: TimeZone

    public init(
        subject: String,
        sender: String,
        receivedAt: Date,
        body: String,
        timeZone: TimeZone
    ) {
        self.subject = subject
        self.sender = sender
        self.receivedAt = receivedAt
        self.body = body
        self.timeZone = timeZone
    }
}

/// O que o motor local consegue afirmar sobre uma mensagem.
///
/// `modelVersion` identifica a política e o esquema que produziram o dado.
/// A API do sistema não expõe a versão interna do modelo Apple; por isso o
/// adaptador versiona a sua própria fronteira de saída sem inventar esse dado.
public struct OnDeviceMessageAnalysisResult: Sendable, Hashable {
    public let summary: String
    public let detectedEvent: DetectedEvent?
    public let modelVersion: String

    public init(summary: String, detectedEvent: DetectedEvent?, modelVersion: String) {
        self.summary = summary
        self.detectedEvent = detectedEvent
        self.modelVersion = modelVersion
    }
}

/// Os motivos que a interface pode explicar sem importar FoundationModels.
public enum OnDeviceMessageAnalysisAvailability: Sendable, Hashable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    public var isAvailable: Bool {
        self == .available
    }
}

/// Falhas da fronteira de análise, separadas do estado de disponibilidade.
public enum OnDeviceMessageAnalysisError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(OnDeviceMessageAnalysisAvailability)
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
public protocol OnDeviceMessageAnalyzing: Sendable {
    var modelVersion: String { get }

    func availability() async -> OnDeviceMessageAnalysisAvailability
    func analyze(_ input: OnDeviceMessageAnalysisInput) async throws -> OnDeviceMessageAnalysisResult
}
