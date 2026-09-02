import Foundation
import UNICore

/// Escolhe o motor **por chamada**, lendo o snapshot das preferências.
/// Quando o provedor configurado é o Foundation Models, as duas rotas
/// coincidem e o app não paga nada por isso.
public struct RoutedMessageAnalyzer: MessageAnalyzing {
    private let settingsStore: AssistantSettingsStore
    private let onDevice: any MessageAnalyzing
    private let configured: any MessageAnalyzing

    public init(
        settingsStore: AssistantSettingsStore,
        onDevice: any MessageAnalyzing,
        configured: any MessageAnalyzing
    ) {
        self.settingsStore = settingsStore
        self.onDevice = onDevice
        self.configured = configured
    }

    public var modelVersion: String { current.modelVersion }

    public func availability() async -> AppleIntelligenceAvailability {
        await current.availability()
    }

    public func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
        // Sem rede de segurança: se a rota escolhida falhar, a falha sobe. Cair
        // para o motor local em silêncio esconderia da pessoa que o provedor
        // que ela escolheu recusa cada mensagem.
        try await current.analyze(input)
    }

    private var current: any MessageAnalyzing {
        let settings = settingsStore.snapshot()
        switch settings.automaticAnalysis {
        case .onDeviceOnly: return onDevice
        case .configuredProvider:
            return settings.provider == .foundationModels ? onDevice : configured
        }
    }
}
