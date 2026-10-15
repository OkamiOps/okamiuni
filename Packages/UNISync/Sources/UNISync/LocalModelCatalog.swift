import Foundation
import UNICore

/// Um modelo que um servidor **deste Mac** respondeu ter baixado.
///
/// `sizeBytes` existe porque o `/api/tags` do Ollama o informa e a tela usa o
/// número para dizer se o modelo cabe na memória da máquina. O `/v1/models`
/// compatível com OpenAI não tem esse campo, e aí ele é `nil` — a tela omite a
/// coluna em vez de inventar um tamanho.
public struct LocalModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let sizeBytes: Int64?

    public init(id: String, sizeBytes: Int64? = nil) {
        self.id = id
        self.sizeBytes = sizeBytes
    }

    /// `18 GB`, `820 MB`. `nil` quando o servidor não informou tamanho.
    public var sizeLabel: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        let giga = Double(sizeBytes) / 1_000_000_000
        if giga >= 1 {
            return L10n.tr("\(String(format: "%.0f", giga.rounded())) GB")
        }
        let mega = Double(sizeBytes) / 1_000_000
        return L10n.tr("\(String(format: "%.0f", mega.rounded())) MB")
    }
}

/// O que um servidor local respondeu quando a tela perguntou quais modelos tem.
public enum LocalServerState: Sendable, Hashable {
    /// Ainda não perguntamos nesta abertura de tela.
    case unknown
    case probing
    /// Respondeu, com a lista que ele devolveu (pode ser vazia: servidor de pé
    /// e sem modelo baixado é um estado diferente de servidor fora do ar).
    case running([LocalModel])
    /// Não respondeu. A tela diz "não está rodando" e oferece tentar de novo.
    case notRunning

    public var models: [LocalModel] {
        if case let .running(models) = self { return models }
        return []
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public enum LocalModelCatalogError: Error, Sendable, Equatable, LocalizedError {
    case invalidEndpoint
    case endpointIsNotLoopback
    case serverUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            L10n.tr("Endereço de servidor local inválido.")
        case .endpointIsNotLoopback:
            L10n.tr("Um servidor “neste Mac” tem de estar em localhost.")
        case .serverUnavailable:
            L10n.tr("O servidor não respondeu neste Mac.")
        }
    }
}

/// Pergunta a um servidor **de loopback** quais modelos ele tem.
///
/// Duas rotas, porque os dois servidores locais que a tela oferece falam
/// dialetos diferentes: o `/api/tags` nativo do Ollama (que informa tamanho) e
/// o `/v1/models` compatível com OpenAI (LM Studio, LiteLLM, qualquer servidor
/// da pessoa). A rota nativa é tentada primeiro e, se não existir, a compatível
/// responde — é o mesmo servidor, perguntado de outro jeito.
///
/// **Só loopback.** Um "modelo deste Mac" que viesse de outro host seria a
/// mesma promessa de privacidade feita sobre uma chamada de rede, e é esse o
/// erro que `endpointIsNotLoopback` impede. Nenhuma chave é enviada: estes
/// servidores não pedem autenticação, e mandar uma credencial para um processo
/// local não identificado seria pior do que não listar modelo nenhum.
public struct LocalModelCatalog: Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 4) {
        self.session = session
        // Esta chamada acontece com a tela aberta e a pessoa esperando. Quatro
        // segundos é generoso para um processo local e curto para quem está
        // olhando; abaixo de um segundo um Ollama frio perderia a resposta.
        self.timeout = min(max(timeout, 1), 15)
    }

    public static func loopbackHost(of endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased()
        else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"]
        return loopback.contains(host) ? host : nil
    }

    /// Os modelos de um endpoint compatível com OpenAI de loopback
    /// (`http://localhost:1234/v1` → `GET .../v1/models`), tentando antes o
    /// `/api/tags` do Ollama, que é o único que informa tamanho.
    public func models(endpoint: String) async throws -> [LocalModel] {
        guard let base = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.host != nil
        else { throw LocalModelCatalogError.invalidEndpoint }
        guard Self.loopbackHost(of: endpoint) != nil else {
            throw LocalModelCatalogError.endpointIsNotLoopback
        }

        if let tags = try? await ollamaTags(base: base), !tags.isEmpty {
            return tags
        }
        return try await openAIModels(base: base)
    }

    /// O estado que a tela desenha, sem lançar: servidor fora do ar é um
    /// estado da tela, não um erro para a pessoa ler.
    public func probe(endpoint: String) async -> LocalServerState {
        do {
            return .running(try await models(endpoint: endpoint))
        } catch {
            return .notRunning
        }
    }

    // MARK: As duas rotas

    /// `GET http://host:port/api/tags` — o inventário nativo do Ollama.
    private func ollamaTags(base: URLComponents) async throws -> [LocalModel] {
        var components = base
        components.path = "/api/tags"
        components.query = nil
        guard let url = components.url else { throw LocalModelCatalogError.invalidEndpoint }
        let data = try await get(url)
        struct Resposta: Decodable {
            struct Modelo: Decodable {
                let name: String
                let size: Int64?
            }
            let models: [Modelo]
        }
        guard let resposta = try? JSONDecoder().decode(Resposta.self, from: data) else {
            throw LocalModelCatalogError.serverUnavailable
        }
        return resposta.models
            .map { LocalModel(id: $0.name, sizeBytes: $0.size) }
            .filter { !$0.id.isEmpty }
    }

    /// `GET <base>/models` — a lista compatível com OpenAI. A base pode vir com
    /// ou sem `/v1`, e com ou sem barra no fim; o caminho é normalizado aqui do
    /// mesmo jeito que `chatCompletionsURL()` faz para a chamada de conversa.
    private func openAIModels(base: URLComponents) async throws -> [LocalModel] {
        var components = base
        var path = components.path
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        if path.hasSuffix("/models") {
            components.path = path
        } else if path.hasSuffix("/v1") {
            components.path = path + "/models"
        } else {
            components.path = (path == "/" ? "" : path) + "/v1/models"
        }
        components.query = nil
        guard let url = components.url else { throw LocalModelCatalogError.invalidEndpoint }
        let data = try await get(url)
        struct Resposta: Decodable {
            struct Modelo: Decodable { let id: String }
            let data: [Modelo]
        }
        guard let resposta = try? JSONDecoder().decode(Resposta.self, from: data) else {
            throw LocalModelCatalogError.serverUnavailable
        }
        return resposta.data.map { LocalModel(id: $0.id) }.filter { !$0.id.isEmpty }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Um servidor local não pede credencial, e este pedido não leva
        // nenhuma: nem chave, nem cookie, nem token de sessão.
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalModelCatalogError.serverUnavailable
        }
        // Um servidor local pode devolver um catálogo grande; um megabyte é
        // folgado para uma lista de nomes e impede que um processo qualquer
        // escutando na porta encha a memória da tela.
        guard data.count <= 1_000_000 else { throw LocalModelCatalogError.serverUnavailable }
        return data
    }
}
