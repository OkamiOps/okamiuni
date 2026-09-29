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
            L10n.tr("O provedor exige uma atualização do protocolo/cliente. Atualize o OkamiUNI e tente novamente.")
        case .rateLimited:
            L10n.tr("O provedor limitou a atualização. Tente novamente em instantes.")
        case .redirectRefused:
            L10n.tr("O catálogo tentou redirecionar a sessão para outro endereço e foi bloqueado.")
        case .invalidResponse:
            L10n.tr("O provedor devolveu um catálogo de modelos inválido.")
        case .emptyCatalog:
            L10n.tr("A conta não devolveu nenhum modelo disponível.")
        case let .server(statusCode):
            L10n.tr("O catálogo de modelos respondeu com erro \(statusCode).")
        }
    }
}

/// Carrega somente o catálogo remoto da assinatura autenticada. Não existe
/// catálogo embutido nem fallback quando a API recusa ou não devolve modelos.
public struct AssistantProviderOAuthModelCatalog: Sendable {
    private let transport: any AssistantProviderOAuthHTTPTransport
    private let clientVersion: String
    private let codexClientVersion: String

    public init(
        transport: any AssistantProviderOAuthHTTPTransport = URLSessionAssistantProviderOAuthHTTPTransport(),
        clientVersion: String? = nil
    ) {
        self.transport = transport
        let normalized = clientVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.clientVersion = normalized.isEmpty ? Self.appVersion : normalized
        self.codexClientVersion = normalized.isEmpty ? AssistantProviderOAuthClient.codexProtocolVersion : normalized
    }

    public func models(
        configuration: AssistantProviderOAuthConfiguration,
        accessToken: String,
        accountID: String? = nil
    ) async throws -> [AssistantProviderModel] {
        let configuration = try configuration.validatedForAuthorization()
        let accessToken = try AssistantCredentialValidation.apiKey(accessToken)
        let codexAccountID: String?
        if configuration.kind == .codex {
            guard let validated = AssistantProviderOAuthClient.validatedCodexAccountID(accountID) else {
                throw AssistantProviderOAuthModelCatalogError.missingAuthorization
            }
            codexAccountID = validated
        } else {
            codexAccountID = nil
        }
        var request = URLRequest(url: try modelsURL(for: configuration.kind))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("OkamiUNI/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        if let codexAccountID {
            request.setValue(codexAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }

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
              let rawItems = (configuration.kind == .codex ? object["models"] : object["models"] ?? object["data"]) as? [Any]
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
            guard !id.isEmpty, id.count <= 256,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { continue }

            let visibility = (item?["visibility"] as? String)?.lowercased()
            guard visibility != "hide" && visibility != "hidden", item?["hidden"] as? Bool != true,
                  seen.insert(id).inserted
            else { continue }
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
            var components = URLComponents(string: "https://chatgpt.com/backend-api/codex/models")!
            components.queryItems = [.init(name: "client_version", value: codexClientVersion)]
            return components.url!
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
