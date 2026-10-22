import Foundation
import UNICore

/// Como o OAuth de um serviço de reunião é feito.
///
/// Um tipo de dados e não três implementações, porque Zoom, Teams e Zoho
/// diferem em quatro detalhes e mais nada: o endereço, o separador de escopos,
/// se há `client_secret` e o que vai a mais na URL de autorização. O fluxo —
/// PKCE S256, `state` conferido, troca do código, renovação antes de vencer —
/// é literalmente o mesmo nos três, e escrevê-lo três vezes garantiria três
/// comportamentos diferentes no primeiro erro.
public struct MeetingOAuthConfig: Sendable, Hashable {
    public let service: MeetingService
    public let clientID: String
    /// `nil` em cliente público. Zoom e Teams são públicos (PKCE no lugar do
    /// segredo); o Zoho exige **os dois**, PKCE e segredo, e a doc dele é
    /// explícita a respeito.
    public let clientSecret: String?
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let redirectURI: String
    public let scopes: [String]
    /// Espaço nos dois primeiros; vírgula no Zoho, que recusa espaço.
    public let scopeSeparator: String
    public let extraAuthorizationItems: [URLQueryItem]

    public init(
        service: MeetingService,
        clientID: String,
        clientSecret: String? = nil,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        redirectURI: String,
        scopes: [String],
        scopeSeparator: String = " ",
        extraAuthorizationItems: [URLQueryItem] = []
    ) {
        self.service = service
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.scopeSeparator = scopeSeparator
        self.extraAuthorizationItems = extraAuthorizationItems
    }

    public func authorizationURL(pkce: PKCEPair, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var itens = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: scopeSeparator)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        itens.append(contentsOf: extraAuthorizationItems)
        components.queryItems = itens
        return components.url!
    }
}

/// O que o redirect do navegador trouxe.
///
/// `location` e `accountsServer` existem para o Zoho, que não tem um endereço
/// só: o callback diz em qual data center a conta mora, e a troca do código
/// tem de ir **para lá**. Nos outros dois os dois campos vêm nulos e ninguém
/// os lê.
public struct MeetingOAuthCallback: Sendable, Hashable {
    public let code: String
    public let location: String?
    public let accountsServer: String?

    /// Lê o redirect conferindo o `state`.
    ///
    /// A conferência não é burocracia: sem ela, qualquer coisa capaz de fazer
    /// um GET em `127.0.0.1:53720` injetaria um código de autorização de
    /// **outra** conta no nosso fluxo, e o app conectaria o Zoom de outra
    /// pessoa achando que era o seu.
    public static func read(
        _ url: URL, expectedState: String, service: MeetingService
    ) throws -> MeetingOAuthCallback {
        guard let itens = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw MeetingConnectorError.refused(
                L10n.tr("O retorno do \(service.label) veio sem parâmetros.")
            )
        }
        func valor(_ nome: String) -> String? {
            itens.first { $0.name == nome }?.value?.nonEmpty
        }
        if let erro = valor("error") {
            if erro == "access_denied" { throw CancellationError() }
            throw MeetingConnectorError.refused(
                L10n.tr("O \(service.label) recusou a autorização: \(erro)")
            )
        }
        guard valor("state") == expectedState else {
            throw MeetingConnectorError.refused(
                L10n.tr("O retorno do \(service.label) veio com um `state` que não é o nosso.")
            )
        }
        guard let code = valor("code") else {
            throw MeetingConnectorError.refused(
                L10n.tr("O retorno do \(service.label) veio sem código de autorização.")
            )
        }
        return MeetingOAuthCallback(
            code: code,
            location: valor("location"),
            accountsServer: valor("accounts-server")
        )
    }
}

/// O motor OAuth de um serviço de reunião: troca o código, renova e guarda.
///
/// Ator pelo mesmo motivo de `GoogleAuth`: a renovação precisa de exclusão
/// mútua de verdade. O Zoom **rotaciona** o refresh token a cada renovação, e
/// dois pedidos simultâneos com o token vencido fariam duas renovações — a
/// segunda chegaria com um refresh token que a primeira já queimou, e a
/// conexão cairia sozinha sem ninguém ter feito nada errado.
public actor MeetingOAuthEngine {
    private let config: MeetingOAuthConfig
    private let session: URLSession
    private let vault: MeetingTokenVault
    private let now: @Sendable () -> Date
    /// Uma renovação em voo por conta. Duas contas do mesmo serviço não podem
    /// dividir a mesma corrida: cada uma tem o seu refresh token.
    private var inFlight: [String: Task<MeetingTokens, any Error>] = [:]

    public init(
        config: MeetingOAuthConfig,
        session: URLSession,
        vault: MeetingTokenVault,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.session = session
        self.vault = vault
        self.now = now
    }

    public var service: MeetingService { config.service }

    public func authorizationURL(pkce: PKCEPair, state: String) -> URL {
        config.authorizationURL(pkce: pkce, state: state)
    }

    /// Troca o código pelo par de tokens. `tokenEndpoint` sobrepõe o da
    /// configuração — é por aqui que o Zoho manda a troca para o data center
    /// que o callback apontou.
    public func exchange(
        code: String, verifier: String, tokenEndpoint: URL? = nil
    ) async throws -> MeetingTokens {
        var campos = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
            "client_id": config.clientID,
        ]
        if let secret = config.clientSecret { campos["client_secret"] = secret }
        return try await post(campos, to: tokenEndpoint ?? config.tokenEndpoint, keeping: nil)
    }

    public func store(_ tokens: MeetingTokens) throws {
        try vault.save(tokens, for: config.service)
    }

    public func stored() -> MeetingTokens? { vault.load(config.service) }

    public func forget() { vault.clear(config.service) }

    /// O access token da conta padrão, renovando se preciso.
    public func accessToken() async throws -> String {
        try await accessToken(for: nil)
    }

    /// O access token de uma conta. `nil` é a padrão — a que `load` já devolvia.
    public func accessToken(for account: String?) async throws -> String {
        guard let guardados = vault.tokens(for: config.service, account: account) else {
            throw MeetingRoomError.notConnected(config.service)
        }
        guard guardados.isExpired(at: now()) else { return guardados.accessToken }
        guard let refresh = guardados.refreshToken else {
            // Sem refresh token não há o que renovar; quem resolve é a
            // pessoa, reconectando.
            throw MeetingRoomError.notConnected(config.service)
        }
        return try await renew(guardados, refreshToken: refresh).accessToken
    }

    /// Renova **agora**, com uma corrida só por conta.
    public func renewedAccessToken() async throws -> String {
        guard let guardados = vault.load(config.service),
              let refresh = guardados.refreshToken
        else { throw MeetingRoomError.notConnected(config.service) }
        return try await renew(guardados, refreshToken: refresh).accessToken
    }

    private func renew(
        _ guardados: MeetingTokens, refreshToken: String
    ) async throws -> MeetingTokens {
        let chave = MeetingTokenVault.slug(guardados.account ?? "")
        if let emVoo = inFlight[chave] { return try await emVoo.value }
        let tarefa = Task<MeetingTokens, any Error> { [config, vault] in
            var campos = [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": config.clientID,
            ]
            if let secret = config.clientSecret { campos["client_secret"] = secret }
            // O Teams quer os escopos de novo na renovação; mandar nos três
            // não faz mal e tira um ramo do código.
            campos["scope"] = config.scopes.joined(separator: config.scopeSeparator)
            do {
                let novos = try await self.post(
                    campos, to: self.refreshEndpoint(for: guardados), keeping: guardados
                )
                try vault.save(novos, for: config.service)
                return novos
            } catch let erro as MeetingRoomError {
                if case .notConnected = erro {
                    // O refresh token desta conta morreu. As outras contas do
                    // mesmo serviço ficam: quem revogou foi esta.
                    vault.remove(config.service, account: guardados.account)
                }
                throw erro
            }
        }
        inFlight[chave] = tarefa
        defer { inFlight[chave] = nil }
        return try await tarefa.value
    }

    /// A renovação do Zoho vai para o mesmo data center da troca original.
    private func refreshEndpoint(for guardados: MeetingTokens) -> URL {
        guard let server = guardados.accountsServer,
              let url = URL(string: "\(server)/oauth/v2/token")
        else { return config.tokenEndpoint }
        return url
    }

    // MARK: O POST do token

    private func post(
        _ campos: [String: String], to endpoint: URL, keeping anterior: MeetingTokens?
    ) async throws -> MeetingTokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(MeetingForm.encode(campos).utf8)

        let (dados, resposta): (Data, URLResponse)
        do {
            (dados, resposta) = try await session.data(for: request)
        } catch let erro as URLError {
            throw MeetingRoomError.failed(erro.localizedDescription)
        }
        guard let http = resposta as? HTTPURLResponse else {
            throw MeetingRoomError.failed(
                L10n.tr("O servidor de token do \(config.service.label) respondeu sem HTTP.")
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.tokenError(status: http.statusCode, body: dados, service: config.service)
        }

        struct Wire: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let api_domain: String?
            let error: String?
        }
        let fio: Wire
        do {
            fio = try JSONDecoder().decode(Wire.self, from: dados)
        } catch {
            throw MeetingRoomError.failed(
                L10n.tr("O \(config.service.label) devolveu um token num formato que não conhecemos.")
            )
        }
        // O Zoho responde 200 com `{"error":"invalid_code"}` — status não é
        // sinal suficiente lá.
        if let erro = fio.error, fio.access_token == nil {
            throw Self.tokenError(
                status: http.statusCode, body: dados, service: config.service, declared: erro
            )
        }
        guard let access = fio.access_token else {
            throw MeetingRoomError.failed(
                L10n.tr("O \(config.service.label) não devolveu access token.")
            )
        }
        return MeetingTokens(
            accessToken: access,
            // O Zoho não reenvia o refresh token na renovação; o Zoom
            // rotaciona e reenvia. Manter o anterior cobre os dois.
            refreshToken: fio.refresh_token ?? anterior?.refreshToken,
            expiresAt: now().addingTimeInterval(fio.expires_in ?? 3_600),
            account: anterior?.account,
            accountsServer: anterior?.accountsServer,
            zsoid: anterior?.zsoid
        )
    }

    private static func tokenError(
        status: Int, body: Data, service: MeetingService, declared: String? = nil
    ) -> MeetingRoomError {
        struct Wire: Decodable {
            let error: String?
            let error_description: String?
            let reason: String?
        }
        let fio = try? JSONDecoder().decode(Wire.self, from: body)
        let nome = declared ?? fio?.error ?? fio?.reason
        switch nome {
        case "invalid_grant", "invalid_code", "unauthorized_client", "access_denied",
             "invalid_client":
            return .notConnected(service)
        default:
            break
        }
        if status == 400 || status == 401 { return .notConnected(service) }
        let detalhe = fio?.error_description ?? nome
            ?? String(data: body, encoding: .utf8)
            ?? L10n.tr("sem detalhe")
        return .failed(
            L10n.tr("O \(service.label) respondeu \(String(status)) ao pedir o token: \(detalhe)")
        )
    }
}

/// Quem sabe entregar um token de usuário válido de um serviço de reunião.
///
/// Struct e não ator, com uma leitura **síncrona** do cofre: `canMint` da
/// fábrica é síncrono (a tela pergunta antes de desenhar o botão) e o
/// `SecretStore` é síncrono de propósito. A renovação, que é a parte que
/// precisa de exclusão mútua, mora no ator atrás de `accessToken()`.
public struct MeetingTokenSource: Sendable {
    public let service: MeetingService
    private let vault: MeetingTokenVault
    private let engine: MeetingOAuthEngine

    public init(service: MeetingService, vault: MeetingTokenVault, engine: MeetingOAuthEngine) {
        self.service = service
        self.vault = vault
        self.engine = engine
    }

    public var isConnected: Bool { vault.isConnected(service) }

    public var account: String? { vault.load(service)?.account }

    public var tokens: MeetingTokens? { vault.load(service) }

    /// Os e-mails conectados, na ordem em que entraram.
    public func accounts() -> [String] {
        vault.accounts(service).compactMap { $0.account?.nonEmptyValue }
    }

    public func tokens(matching account: String?) -> MeetingTokens? {
        vault.tokens(for: service, account: account)
    }

    public func accessToken() async throws -> String {
        try await engine.accessToken()
    }

    public func accessToken(for account: String?) async throws -> String {
        try await engine.accessToken(for: account)
    }

    public func save(_ tokens: MeetingTokens) throws {
        try vault.save(tokens, for: service)
    }
}

enum MeetingForm {
    /// Os caracteres não reservados do RFC 3986 somados aos alfanuméricos.
    ///
    /// `.alphanumerics` sozinho escaparia `-` e `_`, e o `code_verifier` do
    /// PKCE é base64url — cheio dos dois. Sairia irreconhecível no corpo.
    private static let valueCharacters: CharacterSet = {
        var conjunto = CharacterSet.alphanumerics
        conjunto.insert(charactersIn: "-._~")
        return conjunto
    }()

    static func encode(_ campos: [String: String]) -> String {
        campos
            .sorted { $0.key < $1.key }
            .map { chave, valor in
                let escapado = valor.addingPercentEncoding(
                    withAllowedCharacters: valueCharacters
                ) ?? valor
                return "\(chave)=\(escapado)"
            }
            .joined(separator: "&")
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let limpo = trimmingCharacters(in: .whitespacesAndNewlines)
        return limpo.isEmpty ? nil : limpo
    }
}
