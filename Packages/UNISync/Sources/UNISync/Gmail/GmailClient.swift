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

    /// `users.history.list` — o que mudou desde um `historyId`.
    ///
    /// **É a peça que faz a conta continuar sincronizando** depois da carga
    /// inicial: sem ela, o app baixa noventa dias uma vez e nunca mais vê nada
    /// chegar.
    ///
    /// Os quatro `historyTypes` são pedidos por nome, e a lista não é
    /// decorativa: sem `historyTypes` o Gmail devolve **todos** os tipos, e os
    /// que sobram (mudanças de rascunho, de thread) viram viagens de rede para
    /// mensagens que nunca entram na triagem.
    ///
    /// **404 é resposta esperada, e não defeito.** O Gmail guarda o histórico
    /// por tempo limitado; um `historyId` velho demais (app fechado por uma
    /// semana) devolve 404, que o `apiError` traduz para
    /// `.servidor(codigo: 404, …)`. Quem chama reconhece esse caso e recarrega
    /// a janela — ver `GmailIncrementalSync`.
    public func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage {
        var itens = [
            URLQueryItem(name: "startHistoryId", value: startHistoryID),
            URLQueryItem(name: "maxResults", value: "500"),
        ]
        for tipo in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] {
            itens.append(URLQueryItem(name: "historyTypes", value: tipo))
        }
        if let pageToken { itens.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let dados = try await getData(path: "history", query: itens)
        return try GmailHistoryParser.parse(dados)
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

    // MARK: A escrita — o espelho da triagem

    /// `messages.batchModify`: adiciona e remove rótulos de até mil mensagens
    /// numa chamada.
    ///
    /// **É naturalmente idempotente**, e é isso que faz o retry depois de um
    /// timeout ambíguo ser seguro: "adicione `TRASH`, tire `INBOX`" aplicado
    /// duas vezes deixa o mesmo estado que aplicado uma. Não há contador nem
    /// alternância — por isso o `setRead` é `removeLabelIds: [UNREAD]`, e nunca
    /// um "inverta o que estiver lá".
    ///
    /// A resposta é `204 No Content`, sem corpo: nada a decodificar.
    public func batchModify(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws {
        guard !ids.isEmpty else { return }
        let corpo: [String: any Sendable] = [
            "ids": ids, "addLabelIds": addLabelIDs, "removeLabelIds": removeLabelIDs,
        ]
        _ = try await postData(path: "messages/batchModify", body: corpo)
    }

    /// `messages.trash` — o caminho canônico para a lixeira.
    ///
    /// **E não `batchModify` com `addLabelIds: ["TRASH"]`.** A Gmail API
    /// documenta que `TRASH` não pode ser *aplicado* por `modify`/`batchModify`
    /// (só removido), então a rota antiga era um pedido que o servidor tinha
    /// todo o direito de recusar — e "apagar" é a ação em que falhar em
    /// silêncio é mais caro: a mensagem some da tela e continua na caixa de
    /// entrada da pessoa.
    ///
    /// É por mensagem, e não em lote: `messages.trash` não tem variante
    /// `batch`. O preço é uma ida e volta por mensagem, e ele é pago de bom
    /// grado — o endpoint funciona com qualquer escopo de escrita, e é
    /// idempotente (mandar para a lixeira o que já está lá é o mesmo estado).
    public func trash(ids: [String]) async throws {
        for id in ids {
            _ = try await postData(path: "messages/\(id)/trash", body: [:])
        }
    }

    /// `messages.untrash`: o caminho de volta. Inofensivo em quem não está na
    /// lixeira — o Gmail simplesmente devolve a mensagem como ela está.
    public func untrash(ids: [String]) async throws {
        for id in ids {
            _ = try await postData(path: "messages/\(id)/untrash", body: [:])
        }
    }

    /// `messages.batchDelete`: apagamento **definitivo**, sem passar pela
    /// lixeira. É o que "apagar definitivamente" e "esvaziar lixeira" pedem —
    /// e **só** eles: mandar para a lixeira é `trash(ids:)`.
    ///
    /// Exige o escopo `https://mail.google.com/`; `gmail.modify` não o cobre.
    /// É a razão de `GoogleAuthConfig.defaultScopes` ter deixado de pedir o par
    /// `modify` + `send`.
    public func batchDelete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await postData(path: "messages/batchDelete", body: ["ids": ids])
    }

    /// `labels.create`. Devolve o id do rótulo recém-criado.
    ///
    /// `409 Conflict` é a resposta do Gmail para "esse rótulo já existe", e ela
    /// **não** é erro aqui: o espelho cria `OkamiUNI/Depois` no primeiro uso, e
    /// duas execuções da mesma operação (o retry do timeout ambíguo, de novo)
    /// chegariam as duas neste ponto. Quem chama relê a lista e acha o id.
    public func createLabel(name: String) async throws -> String? {
        struct Wire: Decodable { let id: String }
        let corpo: [String: any Sendable] = [
            "name": name,
            "labelListVisibility": "labelShow",
            "messageListVisibility": "show",
        ]
        do {
            let dados = try await postData(path: "labels", body: corpo)
            return (try? JSONDecoder().decode(Wire.self, from: dados))?.id
        } catch SyncError.servidor(let codigo, _) where codigo == 409 {
            return nil
        }
    }

    // MARK: O cano

    private func postData(path: String, body: [String: any Sendable]) async throws -> Data {
        // `.sortedKeys` porque um corpo com a mesma intenção tem de sair
        // **byte a byte igual** nas duas tentativas de um retry: sem isso a
        // ordem das chaves de um dicionário varia entre execuções, e "o mesmo
        // pedido" deixa de ser afirmável — nem por nós, nem por quem for ler
        // um log de rede tentando entender uma duplicata.
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await enviar(path: path, query: [], method: "POST", body: json)
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        let dados = try await getData(path: path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: dados)
        } catch {
            throw SyncError.resposta("A Gmail API respondeu `\(path)` num formato que não conhecemos.")
        }
    }

    private func getData(path: String, query: [URLQueryItem]) async throws -> Data {
        try await enviar(path: path, query: query, method: "GET", body: nil)
    }

    /// O único lugar que fala com a rede — GET e POST pela mesma porta.
    ///
    /// Uma porta só porque a tradução de erro (`apiError`) é a parte que mais
    /// importa acertar, e ela vale igual para as duas: um 403 de quota numa
    /// escrita pede a mesma espera que numa leitura, e um 401 pede a mesma
    /// reconexão. Duplicar o cano duplicaria essa tabela, e a cópia divergiria
    /// no primeiro código novo.
    private func enviar(
        path: String, query: [URLQueryItem], method: String, body: Data?
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

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
