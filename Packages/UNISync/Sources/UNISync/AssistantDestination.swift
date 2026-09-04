import Foundation
import UNICore

/// Para onde vai o conteúdo quando a pessoa aciona o assistente.
///
/// Existe porque a cópia do app dizia "local" com Grok, LiteLLM, Codex e
/// CLI selecionados. Toda superfície que fala do assistente lê daqui — não
/// há segunda fonte, e não há frase sobre privacidade que não passe por
/// `isLocal`.
public struct AssistantDestination: Sendable, Hashable {
    public let label: String
    public let detail: String
    /// `true` só no Foundation Models. É o que autoriza "Nada sai deste Mac."
    public let isLocal: Bool

    public init(label: String, detail: String, isLocal: Bool) {
        self.label = label
        self.detail = detail
        self.isLocal = isLocal
    }

    /// O único destino local: o motor no próprio Mac. A frase que promete
    /// privacidade mora num lugar só — repetida em quatro arquivos, ela
    /// sobreviveria a uma correção feita em apenas três.
    public static var onThisMac: AssistantDestination { AssistantDestination(
        label: L10n.tr("Neste Mac"), detail: L10n.tr("Nada sai deste Mac."), isLocal: true
    ) }

    /// Um resumo que **saiu** deste Mac, mas cujo provedor não dá mais para
    /// determinar — a pessoa trocou de provedor depois de ele ser gravado.
    /// Neutro de propósito: a única coisa errada a fazer aqui seria prometer
    /// que o conteúdo ficou no Mac.
    public static var configuredProviderUnknown: AssistantDestination { AssistantDestination(
        label: L10n.tr("provedor configurado"),
        detail: L10n.tr("Este resumo saiu deste Mac para o provedor que estava configurado."),
        isLocal: false
    ) }

    public init(settings: AssistantSettings) {
        switch settings.provider {
        case .foundationModels:
            self = .onThisMac
        case .providerOAuth:
            switch settings.providerOAuth.kind {
            case .xAI:
                self.init(
                    label: "Grok · xAI",
                    detail: L10n.tr("Sai deste Mac para a xAI."),
                    isLocal: false
                )
            case .codex:
                self.init(
                    label: "Codex · ChatGPT",
                    detail: L10n.tr("Sai deste Mac pelo Codex instalado."),
                    isLocal: false
                )
            }
        case .openAICompatible:
            let family = settings.openAICompatible.authenticationMode == .litellmOAuthPKCE
                ? "LiteLLM"
                : "API"
            guard let host = Self.host(of: settings.openAICompatible.endpoint) else {
                self.init(
                    label: L10n.tr("\(family) · sem endpoint"),
                    detail: L10n.tr("Informe o endpoint nos Ajustes."),
                    isLocal: false
                )
                return
            }
            self.init(
                label: "\(family) · \(host)",
                detail: L10n.tr("Sai deste Mac para \(host)."),
                isLocal: false
            )
        case .cli:
            self.init(
                label: "\(settings.cli.kind.displayName) · CLI",
                detail: L10n.tr("Sai deste Mac pelo CLI instalado."),
                isLocal: false
            )
        }
    }

    /// Só o host: porta, caminho e query não dizem nada à pessoa e podem
    /// carregar identificador de time num proxy compartilhado.
    static func host(of endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let host = URLComponents(string: trimmed)?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return host
    }
}
