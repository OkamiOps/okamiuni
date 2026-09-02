import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// A tradução única de qualquer `Error` do assistente para o que a pessoa
/// lê e para o que ela pode fazer a respeito.
///
/// Os quatro enums de adaptador ficam como estão: cada um sabe do seu
/// transporte. O que não podia continuar é cada superfície inventar a sua
/// própria frase a partir de `localizedDescription`, sem oferecer saída.
public struct AssistantFailure: Sendable, Hashable {
    public enum Recovery: Sendable, Hashable {
        case retry
        case openSettings
        case reconnect(AssistantProviderOAuthKind)
    }

    public let message: String
    public let recovery: Recovery?

    public init(message: String, recovery: Recovery?) {
        self.message = message
        self.recovery = recovery
    }

    /// `provider` só é conhecido quando quem chama sabe qual assinatura
    /// está configurada; sem ele, um 401 vira "tentar de novo" em vez de
    /// mandar reconectar uma conta que talvez nem seja a certa.
    public init(_ error: any Error, provider: AssistantProviderOAuthKind? = nil) {
        switch error {
        case let error as TextAssistantError:
            self.init(
                message: error.errorDescription ?? Self.fallbackMessage,
                recovery: {
                    switch error {
                    case .unavailable, .invalidRequest: .openSettings
                    case .emptyResponse, .generationFailed: .retry
                    }
                }()
            )
        case let error as OpenAICompatibleTextAssistantError:
            self.init(
                message: error.errorDescription ?? Self.fallbackMessage,
                recovery: {
                    switch error {
                    case .missingAPIKey, .missingOAuthAuthorization,
                         .oauthProviderUnavailable, .authenticationFailed:
                        .openSettings
                    case .rateLimited, .timedOut, .connectionFailed,
                         .server, .invalidResponse:
                        .retry
                    }
                }()
            )
        case let error as AssistantProviderOAuthTextAssistantError:
            self.init(
                message: error.errorDescription ?? Self.fallbackMessage,
                recovery: {
                    switch error {
                    case .missingAuthorization, .authenticationFailed,
                         .subscriptionNotEligible, .managedByCodexRuntime:
                        provider.map(Recovery.reconnect)
                    case .rateLimited, .timedOut, .connectionFailed,
                         .redirectRefused, .upgradeRequired,
                         .server, .invalidResponse:
                        .retry
                    }
                }()
            )
        case let error as AssistantProviderOAuthError:
            self.init(
                message: error.errorDescription ?? Self.fallbackMessage,
                recovery: {
                    switch error {
                    case .missingSession, .sessionProviderMismatch,
                         .authorizationDenied, .authorizationExpired,
                         .invalidTokenResponse:
                        provider.map(Recovery.reconnect)
                    default:
                        .retry
                    }
                }()
            )
        case let error as AssistantCLITextAssistantError:
            self.init(
                message: error.errorDescription ?? Self.fallbackMessage,
                recovery: {
                    switch error {
                    case .executableNotFound, .executableNotAllowed, .processFailed:
                        .openSettings
                    case .timedOut, .outputTooLarge, .invalidResponse:
                        .retry
                    }
                }()
            )
        case let error as AssistantSettingsError:
            self.init(
                message: error.errorDescription ?? Self.fallbackMessage,
                recovery: .openSettings
            )
        case let error as MessageAnalysisError:
            self.init(
                message: error.errorDescription ?? Self.fallbackMessage,
                recovery: .retry
            )
        default:
            let described = (error as? any LocalizedError)?.errorDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.init(
                message: described.isEmpty ? Self.fallbackMessage : described,
                recovery: .retry
            )
        }
    }

    /// O stderr do CLI é o único lugar onde a causa real aparece ("not
    /// logged in", "model not found"). Uma linha basta: a cauda inteira é
    /// ruído e pode carregar caminho de arquivo da pessoa.
    ///
    /// O ajudante já existe porque a regra é dele; quem lhe passa a cauda é a
    /// Task 11, quando `processFailed` passar a carregar `stderrTail`.
    static func cliMessage(base: String, stderrTail: String) -> String {
        let firstLine = stderrTail
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else { return base }
        return "\(base) \(firstLine)"
    }

    static let fallbackMessage = "Não foi possível responder agora."
}

/// A faixa única de erro. Painel, dashboard e janela de mensagem mostram
/// esta, e nenhuma tem cópia própria.
struct AssistantFailureBand: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let failure: AssistantFailure
    var onRetry: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
                    .accessibilityHidden(true)
                Text(failure.message)
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch failure.recovery {
            case .retry:
                ChromeButton(
                    "Tentar de novo", appearance: .outlined,
                    size: 11.5, height: 27, horizontalPadding: 10,
                    action: onRetry
                )
                .help("Repete o último pedido ao assistente")
            case .openSettings:
                ChromeButton(
                    "Abrir Ajustes", appearance: .outlined,
                    size: 11.5, height: 27, horizontalPadding: 10,
                    action: onOpenSettings
                )
                .help("Abre Configurações para escolher ou corrigir o provedor")
            case let .reconnect(kind):
                ChromeButton(
                    "Reconectar \(kind == .codex ? "ChatGPT" : "xAI")",
                    appearance: .outlined,
                    size: 11.5, height: 27, horizontalPadding: 10,
                    action: onOpenSettings
                )
                .help("Abre Configurações para entrar de novo na assinatura")
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(theme.surface3.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant-failure-band")
    }
}
