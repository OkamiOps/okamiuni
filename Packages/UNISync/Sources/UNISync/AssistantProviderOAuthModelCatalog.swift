import UNICore
import Foundation

/// Um item do catálogo publicado pelo provedor para a conta autenticada.
/// Somente metadados de apresentação atravessam esta fronteira; tokens e
/// respostas brutas permanecem no cliente de rede.
public struct AssistantProviderModel: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        let normalized = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = normalized.isEmpty ? id : normalized
    }
}

public enum AssistantProviderOAuthModelCatalogError:
    Error, Sendable, Equatable, LocalizedError {

    case missingAuthorization
    case authenticationFailed
    case subscriptionNotEligible
    case upgradeRequired
    case rateLimited
    case redirectRefused
    case invalidResponse
    case emptyCatalog
    case managedByCodexRuntime
    case server(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .missingAuthorization:
            L10n.tr("Conecte a assinatura antes de carregar os modelos.")
        case .authenticationFailed:
            L10n.tr("A sessão expirou. Entre novamente para atualizar os modelos.")
        case .subscriptionNotEligible:
            L10n.tr("Esta assinatura não liberou um catálogo de modelos para este cliente.")
        case .upgradeRequired:
            L10n.tr("A API xAI exige uma versão mais nova do OkamiUNI. Atualize o app e tente novamente.")
        case .rateLimited:
            L10n.tr("O provedor limitou a atualização. Tente novamente em instantes.")
        case .redirectRefused:
            L10n.tr("O catálogo tentou redirecionar a sessão para outro endereço e foi bloqueado.")
        case .invalidResponse:
            L10n.tr("O provedor devolveu um catálogo de modelos inválido.")
        case .emptyCatalog:
            L10n.tr("A conta não devolveu nenhum modelo disponível.")
        case .managedByCodexRuntime:
            L10n.tr("Os modelos ChatGPT são carregados pelo runtime oficial do Codex.")
        case let .server(statusCode):
            L10n.tr("O catálogo de modelos respondeu com erro \(statusCode).")
        }
    }
}

/// Carrega o catálogo xAI publicado pela API direta da assinatura.
/// ChatGPT/Codex é carregado pelo app-server oficial, sem entregar bearer ao
/// OkamiUNI. Redirecionamentos continuam recusados para xAI.
public struct AssistantProviderOAuthModelCatalog: Sendable {
    private let transport: any AssistantProviderOAuthHTTPTransport
    private let clientVersion: String

    public init(
        transport: any AssistantProviderOAuthHTTPTransport = URLSessionAssistantProviderOAuthHTTPTransport(),
        clientVersion: String? = nil
    ) {
        self.transport = transport
        let normalized = clientVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.clientVersion = normalized.isEmpty ? Self.appVersion : normalized
    }

    public func models(
        configuration: AssistantProviderOAuthConfiguration,
        accessToken: String
    ) async throws -> [AssistantProviderModel] {
        let configuration = try configuration.validatedForAuthorization()
        guard configuration.kind == .xAI else {
            throw AssistantProviderOAuthModelCatalogError.managedByCodexRuntime
        }
        let accessToken = try AssistantCredentialValidation.apiKey(accessToken)
        var request = URLRequest(url: try modelsURL(for: configuration.kind))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("OkamiUNI/\(clientVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
        if (300..<400).contains(response.statusCode) {
            throw AssistantProviderOAuthModelCatalogError.redirectRefused
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            throw AssistantProviderOAuthModelCatalogError.authenticationFailed
        case 403:
            throw AssistantProviderOAuthModelCatalogError.subscriptionNotEligible
        case 426:
            throw AssistantProviderOAuthModelCatalogError.upgradeRequired
        case 429:
            throw AssistantProviderOAuthModelCatalogError.rateLimited
        default:
            throw AssistantProviderOAuthModelCatalogError.server(statusCode: response.statusCode)
        }

        guard !data.isEmpty, data.count <= 2_097_152,
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let rawItems = (object["models"] ?? object["data"]) as? [Any]
        else {
            throw AssistantProviderOAuthModelCatalogError.invalidResponse
        }

        var seen = Set<String>()
        var result: [AssistantProviderModel] = []
        result.reserveCapacity(min(rawItems.count, 128))
        for rawItem in rawItems.prefix(512) {
            let item = rawItem as? [String: Any]
            let rawID: String? = if let value = rawItem as? String {
                value
            } else {
                item?["slug"] as? String
                    ?? item?["id"] as? String
                    ?? item?["model"] as? String
            }
            guard let rawID else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 256, seen.insert(id).inserted else { continue }

            let visibility = (item?["visibility"] as? String)?.lowercased()
            guard visibility != "hide" && visibility != "hidden" else { continue }
            let displayName = item?["display_name"] as? String
                ?? item?["label"] as? String
                ?? item?["name"] as? String
            result.append(.init(id: id, displayName: displayName))
        }

        guard !result.isEmpty else {
            throw AssistantProviderOAuthModelCatalogError.emptyCatalog
        }
        return result
    }

    private func modelsURL(for kind: AssistantProviderOAuthKind) throws -> URL {
        switch kind {
        case .codex:
            throw AssistantProviderOAuthModelCatalogError.managedByCodexRuntime
        case .xAI:
            return URL(string: "https://api.x.ai/v1/language-models")!
        }
    }

    private static var appVersion: String {
        let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "0.1.0" : normalized
    }
}
