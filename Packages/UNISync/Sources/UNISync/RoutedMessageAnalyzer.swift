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

    /// **A versão do motor local, sempre.** É ela que decide o que ainda
    /// precisa de trabalho, e por isso ligar ou desligar o opt-in não pode
    /// mexer nela: uma troca de versão faz `MessageIntelligenceStore` devolver
    /// a caixa inteira à fila, e o histórico sairia deste Mac de uma vez —
    /// exatamente o que a cópia "mensagens novas" promete que não acontece.
    public var modelVersion: String { onDevice.modelVersion }

    /// As duas são legítimas: o histórico fica gravado sob a versão local e as
    /// mensagens novas sob a do provedor. Nenhuma das duas volta para a fila.
    public var acceptedModelVersions: Set<String> {
        [onDevice.modelVersion, configured.modelVersion]
    }

    /// A fila anda se **alguma** rota ativa puder responder. Com o opt-in
    /// ligado e o provedor fora do ar, o histórico continua sendo resumido
    /// aqui; se o provedor recusar as mensagens novas, quem para a fila é a
    /// contagem de falhas de ambiente, com o motivo na tela.
    public func availability() async -> AppleIntelligenceAvailability {
        let local = await onDevice.availability()
        guard local != .available, routesRemote else { return local }
        return await configured.availability()
    }

    /// A resposta que importa para a fila: **esta** mensagem tem motor?
    /// Com o opt-in ligado e a assinatura fora do ar, a resposta é "não" só
    /// para o que chegou depois do clique — o histórico continua andando.
    public func availability(for input: MessageAnalysisInput) async -> MessageAnalysisAvailability {
        await engine(for: input).availability(for: input)
    }

    public func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
        // Sem rede de segurança: se a rota escolhida falhar, a falha sobe. Cair
        // para o motor local em silêncio esconderia da pessoa que o provedor
        // que ela escolheu recusa cada mensagem.
        try await engine(for: input).analyze(input)
    }

    /// A escolha é **por mensagem**, não por configuração: só o que chegou
    /// depois do clique no opt-in sai deste Mac.
    func engine(for input: MessageAnalysisInput) -> any MessageAnalyzing {
        settingsStore.snapshot().automaticAnalysisCoversMessage(
            receivedAt: input.arrivedLocallyAt
        )
            ? configured
            : onDevice
    }

    private var routesRemote: Bool {
        let settings = settingsStore.snapshot()
        return settings.automaticAnalysis == .configuredProvider
            && settings.provider != .foundationModels
    }
}
