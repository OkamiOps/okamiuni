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
                        // Sem saber qual assinatura é, o caminho ainda existe:
                        // Ajustes. `nil` deixaria a faixa de erro sem botão.
                        provider.map(Recovery.reconnect) ?? .openSettings
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
                        provider.map(Recovery.reconnect) ?? .openSettings
                    default:
                        .retry
                    }
                }()
            )
        case let error as AssistantCLITextAssistantError:
            self.init(
                message: {
                    let base = error.errorDescription ?? Self.fallbackMessage
                    guard case let .processFailed(_, stderrTail) = error else { return base }
                    return Self.cliMessage(base: base, stderrTail: stderrTail)
                }(),
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
        case is CancellationError:
            // Quem cancelou foi a pessoa. Não há o que recuperar, e um botão
            // aqui só faria parecer que algo deu errado.
            self.init(message: "Pedido cancelado.", recovery: nil)
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
    /// A **última** linha, e não a primeira. O que chega aqui é uma cauda
    /// cortada por byte (`size - 4096`): a primeira linha é quase sempre o
    /// meio de uma frase, e pode até começar com o `\u{FFFD}` de uma sequência
    /// UTF-8 partida ao meio pelo corte. A causa vem no fim, depois do banner
    /// e da barra de progresso.
    static func cliMessage(base: String, stderrTail: String) -> String {
        let lastLine = stderrTail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !Self.isNoise($0) }) ?? ""
        guard !lastLine.isEmpty else { return base }
        return "\(base) \(lastLine)"
    }

    /// Linha vazia, ou o que sobrou de bytes que não formam texto — o resto
    /// de uma sequência partida pelo corte não diz nada a ninguém.
    private static func isNoise(_ line: String) -> Bool {
        line.replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
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
                    Self.reconnectTitle(kind),
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

    /// Exaustivo de propósito: um provedor novo tem de quebrar a compilação
    /// aqui, e não sair rotulado com o nome do outro.
    static func reconnectTitle(_ kind: AssistantProviderOAuthKind) -> String {
        switch kind {
        case .codex: "Reconectar ChatGPT"
        case .xAI: "Reconectar xAI"
        }
    }
}
