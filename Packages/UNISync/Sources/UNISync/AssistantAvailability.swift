import Foundation
import Observation
import UNICore

/// O que o app pode afirmar sobre o assistente **sem tocar na rede**.
///
/// Lê o snapshot das preferências, a presença de credencial (sem
/// materializá-la), a presença de sessão OAuth (sem renová-la) e o cache
/// de CLIs. Um botão desabilitado sem motivo é um controle mudo, e isso é
/// defeito neste projeto.
public enum AssistantAvailability: Sendable, Hashable {
    case ready(AssistantDestination)
    case needsSetup(AssistantDestination, reason: String)
    case needsSignIn(AssistantDestination, provider: AssistantProviderOAuthKind?)
    case appleIntelligence(AppleIntelligenceAvailability)

    public var destination: AssistantDestination {
        switch self {
        case let .ready(destination): destination
        case let .needsSetup(destination, _): destination
        case let .needsSignIn(destination, _): destination
        case .appleIntelligence:
            AssistantDestination(
                label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true
            )
        }
    }

    public var isReady: Bool {
        switch self {
        case .ready: true
        case let .appleIntelligence(state): state == .available
        case .needsSetup, .needsSignIn: false
        }
    }

    /// O texto que o botão desabilitado mostra. `nil` só quando está pronto.
    public var reason: String? {
        switch self {
        case .ready: nil
        case let .needsSetup(_, reason): reason
        case let .needsSignIn(destination, _): "Entre na assinatura \(destination.label) para usar a IA."
        case let .appleIntelligence(state):
            switch state {
            case .available: nil
            case .deviceNotEligible: "Este Mac não é compatível com a Apple Intelligence."
            case .appleIntelligenceNotEnabled: "Ative a Apple Intelligence nos Ajustes do Sistema."
            case .modelNotReady: "A Apple Intelligence ainda está sendo preparada."
            }
        }
    }
}

/// O estado que a interface observa. Recalculado a cada `save` das
/// preferências, porque trocar de provedor sem a lateral perceber era
/// exatamente como o app acabava mostrando "local" com Grok escolhido.
@MainActor
@Observable
public final class AssistantAvailabilityModel {
    public private(set) var availability: AssistantAvailability

    private let probe: @Sendable () async -> AssistantAvailability

    public init(
        settingsStore: AssistantSettingsStore,
        probe: @escaping @Sendable () async -> AssistantAvailability
    ) {
        self.probe = probe
        self.availability = .ready(AssistantDestination(settings: settingsStore.snapshot()))
        settingsStore.addDidChangeHandler { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    public func refresh() async {
        availability = await probe()
    }
}
