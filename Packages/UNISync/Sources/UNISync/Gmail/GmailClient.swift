import Foundation

/// A Gmail API, tipada, sobre `URLSession`. Sem SDK.
///
/// `accessToken` é uma closure, e não uma string, de propósito: o token vale
/// uma hora e a carga inicial dura mais que isso. Pedi-lo **por requisição**
/// faz o refresh transparente do `GoogleAuth` chegar aqui sem que este arquivo
/// precise saber que refresh existe.
public struct GmailClient: Sendable {
    private let session: URLSession
    private let accessToken: @Sendable () async throws -> String
    private let baseURL: URL

    public init(
        session: URLSession,
        accessToken: @Sendable @escaping () async throws -> String,
        baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    ) {
        self.session = session
        self.accessToken = accessToken
        self.baseURL = baseURL
    }

    public func profile() async throws -> GmailProfile {
        struct Wire: Decodable { let emailAddress: String; let historyId: String }
        let fio: Wire = try await get(path: "profile", query: [])
        return GmailProfile(emailAddress: fio.emailAddress, historyID: fio.historyId)
    }

    public func labels() async throws -> [GmailLabel] {
        struct Wire: Decodable {
            struct Label: Decodable { let id: String; let name: String }
            let labels: [Label]?
        }
        let fio: Wire = try await get(path: "labels", query: [])
        return (fio.labels ?? []).map { GmailLabel(id: $0.id, name: $0.name) }
    }

    public func messageIDs(query: String, pageToken: String?) async throws -> GmailPage {
        struct Wire: Decodable {
            struct Item: Decodable { let id: String }
            let messages: [Item]?
            let nextPageToken: String?
        }
        var itens = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "500"),
        ]
        if let pageToken { itens.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let fio: Wire = try await get(path: "messages", query: itens)
        // `messages` some do JSON quando não há nenhuma. Ausência é lista
        // vazia, não erro: conta nova não está quebrada, está vazia.
        return GmailPage(ids: (fio.messages ?? []).map(\.id), nextPageToken: fio.nextPageToken)
    }

    public func message(id: String, format: GmailFormat) async throws -> GmailMessage {
        var itens = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata {
            for nome in ["From", "To", "Cc", "Subject", "Date"] {
                itens.append(URLQueryItem(name: "metadataHeaders", value: nome))
            }
        }
        let dados = try await getData(path: "messages/\(id)", query: itens)
        return try GmailMessageParser.parse(dados)
    }

    // MARK: O cano

    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        let dados = try await getData(path: path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: dados)
        } catch {
            throw SyncError.resposta("A Gmail API respondeu `\(path)` num formato que não conhecemos.")
        }
    }

    private func getData(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (dados, resposta): (Data, URLResponse)
        do {
            (dados, resposta) = try await session.data(for: request)
        } catch let erro as URLError {
            switch erro.code {
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                throw SyncError.tls(erro.localizedDescription)
            default:
                throw SyncError.rede(erro.localizedDescription)
            }
        }

        guard let http = resposta as? HTTPURLResponse else {
            throw SyncError.resposta("A Gmail API respondeu sem cabeçalho HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else { throw apiError(status: http.statusCode, body: dados) }
        return dados
    }

    /// Cada código vira o caso que pede a ação certa: 401 manda reconectar,
    /// 429 manda esperar, 503 manda tentar de novo. Uma frase só para os três
    /// mandaria a pessoa fazer a coisa errada duas vezes em três.
    ///
    /// **O 403 depende do corpo, e é por isso que ele é lido.** A Gmail API
    /// devolve 403 para `userRateLimitExceeded`, `rateLimitExceeded` e
    /// `quotaExceeded` — excesso de uso, não escopo insuficiente. Tratar todo
    /// 403 como revogação fazia uma carga de 90 dias que esbarrasse na quota
    /// morrer inteira (`derrubaACarga` trata `.autorizacaoRevogada` como fatal)
    /// e a janela oferecer "Reconectar" para quem só precisava esperar — a ação
    /// errada com convicção, e a única que a pessoa não pode desfazer sozinha.
    ///
    /// A regra não é nova neste pacote: `GoogleAuth.tokenError` já lê
    /// `rateLimitExceeded` do corpo do servidor de token. Aqui ela é a mesma,
    /// no lugar que faltava.
    private func apiError(status: Int, body: Data) -> SyncError {
        struct Wire: Decodable {
            struct Razao: Decodable { let reason: String? }
            struct Detalhe: Decodable {
                let message: String?
                let status: String?
                let errors: [Razao]?
            }
            let error: Detalhe?
        }
        let fio = (try? JSONDecoder().decode(Wire.self, from: body))?.error
        let mensagem = fio?.message ?? "sem detalhe"
        switch status {
        case 401: return .autenticacao
        case 403:
            let razoes = Set((fio?.errors ?? []).compactMap(\.reason))
            if !razoes.isDisjoint(with: Self.razoesDeQuota) { return .quota }
            // `PERMISSION_DENIED` é o `status` canônico do escopo insuficiente.
            // Sem razão nenhuma no corpo (403 de um proxy, corpo vazio, HTML de
            // portal cativo) a resposta continua sendo revogação: é o caso que
            // pede ação da pessoa, e errar para o lado de pedir é melhor que
            // errar para o lado de repetir para sempre uma chamada que nunca vai
            // passar.
            return .autorizacaoRevogada
        case 429: return .quota
        default: return .servidor(codigo: status, mensagem: mensagem)
        }
    }

    /// As três razões de excesso que a Gmail API devolve **com 403**.
    private static let razoesDeQuota: Set<String> = [
        "userRateLimitExceeded", "rateLimitExceeded", "quotaExceeded",
    ]
}
