import Foundation

/// O fluxo OAuth do Google, do consentimento ao refresh.
///
/// Ator porque o estado que ele guarda — a corrida de refresh em voo, por
/// conta — precisa de exclusão mútua de verdade. Sem ela, dez requisições
/// simultâneas com o token vencido disparam dez refreshes, e o Google invalida
/// um refresh token usado em paralelo: a conta cai sozinha em
/// `erroDeAutenticacao` sem ninguém ter feito nada errado.
public actor GoogleAuth {
    private let config: GoogleAuthConfig
    private let session: URLSession
    private let secrets: any SecretStore
    private let presenter: any AuthorizationPresenter
    private let now: @Sendable () -> Date

    /// A renovação em voo, por conta. É o single-flight.
    private var inFlight: [String: Task<OAuthTokens, any Error>] = [:]

    public init(
        config: GoogleAuthConfig,
        session: URLSession,
        secrets: any SecretStore,
        presenter: any AuthorizationPresenter,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.session = session
        self.secrets = secrets
        self.presenter = presenter
        self.now = now
    }

    // MARK: Primeiro consentimento

    /// Abre o consentimento, troca o código por tokens e os guarda.
    public func connect(accountID: String, loginHint: String?) async throws -> OAuthTokens {
        let pkce = PKCEPair.random()
        // Mesma fonte de aleatoriedade do `verifier` — não `UUID`, que é
        // pensado para unicidade e não para imprevisibilidade criptográfica.
        let state = PKCEPair.randomToken()
        let url = config.authorizationURL(pkce: pkce, state: state, loginHint: loginHint)

        let callback = try await presenter.authorize(url: url, callbackScheme: config.callbackScheme)
        let code = try OAuthCallback.code(from: callback, expectedState: state)

        // O Google exige `client_secret` também no client de app desktop —
        // sem ele o endpoint devolve `400 client_secret is missing`, PKCE ou
        // não. Vai junto sempre que a configuração o tiver.
        var campos = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": pkce.verifier,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
        ]
        campos["client_secret"] = config.clientSecret
        let tokens = try await postToken(campos, keepingRefreshToken: nil)

        try secrets.store(.oauth(tokens), for: accountID)
        return tokens
    }

    // MARK: Token para usar agora

    /// O access token corrente da conta, renovando se preciso.
    ///
    /// É o que `GmailClient` chama antes de cada requisição.
    public func accessToken(for accountID: String) async throws -> String {
        guard case .oauth(let guardados)? = try secrets.secret(for: accountID) else {
            // Sem tokens não há o que renovar: quem pode resolver isto é o
            // usuário, reconectando. `autenticacao` é o que a janela traduz
            // em "Reconectar".
            throw SyncError.autenticacao
        }
        guard guardados.isExpired(at: now()) else { return guardados.accessToken }
        return try await refresh(accountID: accountID, using: guardados).accessToken
    }

    /// Renova **agora**, sem perguntar ao relógio local.
    ///
    /// `accessToken(for:)` só renova quando o token que está no cofre já
    /// venceu **segundo este computador**, e é aí que ele erra: um relógio
    /// adiantado do lado do Google, um token revogado no meio da carga, uma
    /// sessão encerrada no painel da conta — em todos, o token continua
    /// "válido" para nós e o servidor devolve 401. Sem esta porta, o replay
    /// pós-401 reenviaria exatamente o mesmo token e tomaria o mesmo 401: uma
    /// carga de 90 dias morreria por diferença de relógio.
    ///
    /// Passa pela mesma corrida por conta de `refresh`: N chamadas simultâneas
    /// disparam **um** refresh, não N — e o Google invalida refresh token usado
    /// em paralelo. O laço da carga inicial é sequencial e sozinho nunca
    /// produziria esse aperto; quem produz é o resto do app em volta dele —
    /// duas contas do mesmo Google, a leitura de corpo por demanda enquanto a
    /// carga roda, o sync incremental do Marco 3.
    public func renewedAccessToken(for accountID: String) async throws -> String {
        guard case .oauth(let guardados)? = try secrets.secret(for: accountID) else {
            throw SyncError.autenticacao
        }
        return try await refresh(accountID: accountID, using: guardados).accessToken
    }

    /// A renovação, com uma corrida por conta.
    private func refresh(accountID: String, using guardados: OAuthTokens) async throws -> OAuthTokens {
        if let emVoo = inFlight[accountID] { return try await emVoo.value }

        let tarefa = Task<OAuthTokens, any Error> { [config, secrets] in
            do {
                var campos = [
                    "grant_type": "refresh_token",
                    "refresh_token": guardados.refreshToken,
                    "client_id": config.clientID,
                ]
                campos["client_secret"] = config.clientSecret
                let novos = try await self.postToken(
                    campos, keepingRefreshToken: guardados.refreshToken)
                try secrets.store(.oauth(novos), for: accountID)
                return novos
            } catch SyncError.autorizacaoRevogada {
                // O refresh token morreu no servidor (revogado, senha
                // trocada, 6 meses parado): deixá-lo no cofre é lixo que só
                // seria descoberto na próxima tentativa de uso — ou nunca,
                // se a conta for removida antes. Reconectar já assume que
                // não há nada válido guardado, então tira agora.
                try? secrets.remove(for: accountID)
                throw SyncError.autorizacaoRevogada
            }
        }
        inFlight[accountID] = tarefa
        defer { inFlight[accountID] = nil }
        return try await tarefa.value
    }

    // MARK: Revogação

    /// Avisa o Google e limpa o cofre.
    ///
    /// O aviso pode falhar (a máquina pode estar offline quando o usuário
    /// remove a conta) e mesmo assim o segredo local sai: deixar o token no
    /// Keychain de uma conta que a pessoa mandou remover é pior do que uma
    /// autorização órfã do lado do Google, que ela revoga na conta dela.
    public func revoke(accountID: String) async throws {
        defer { try? secrets.remove(for: accountID) }
        guard case .oauth(let guardados)? = try secrets.secret(for: accountID) else { return }

        var request = URLRequest(url: config.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(["token": guardados.refreshToken]).utf8)

        let (_, resposta) = try await enviar(request)
        guard let http = resposta as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Revogar já revogado devolve 400 — não é motivo para a remoção
            // parar. O `defer` acima já limpou o cofre.
            return
        }
    }

    // MARK: O POST do token

    private func postToken(
        _ campos: [String: String], keepingRefreshToken anterior: String?
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(campos).utf8)

        let (dados, resposta) = try await enviar(request)
        guard let http = resposta as? HTTPURLResponse else {
            throw SyncError.resposta("O servidor de token respondeu sem cabeçalho HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw tokenError(status: http.statusCode, body: dados)
        }

        struct Wire: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let fio: Wire
        do {
            fio = try JSONDecoder().decode(Wire.self, from: dados)
        } catch {
            throw SyncError.resposta("O servidor de token respondeu num formato que não conhecemos.")
        }
        guard let refresh = fio.refresh_token ?? anterior else {
            // Primeiro consentimento sem refresh token: a conta funcionaria uma
            // hora e morreria. Melhor falhar agora, dizendo o que aconteceu.
            throw SyncError.resposta(
                "O Google não devolveu refresh token. Reconecte a conta pedindo consentimento de novo."
            )
        }
        return OAuthTokens(
            accessToken: fio.access_token,
            refreshToken: refresh,
            expiresAt: now().addingTimeInterval(fio.expires_in ?? 3_600)
        )
    }

    /// Cada falha do servidor de token vira o caso que pede a ação certa.
    private func tokenError(status: Int, body: Data) -> SyncError {
        struct Wire: Decodable { let error: String?; let error_description: String? }
        let fio = try? JSONDecoder().decode(Wire.self, from: body)
        if status == 429 || fio?.error == "rateLimitExceeded" { return .quota }
        switch fio?.error {
        case "invalid_grant", "unauthorized_client", "access_denied":
            // O refresh token morreu (revogado, senha trocada, 6 meses parado).
            // Só reconectar resolve.
            return .autorizacaoRevogada
        case "invalid_client":
            return .semClientID
        default:
            return .servidor(
                codigo: status,
                mensagem: fio?.error_description ?? fio?.error ?? "sem detalhe"
            )
        }
    }

    private func enviar(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let erro as URLError {
            // Rede é rede; TLS é TLS. A janela oferece ações diferentes para
            // os dois, e um erro só mandaria a pessoa tentar a coisa errada.
            switch erro.code {
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                throw SyncError.tls(erro.localizedDescription)
            default:
                throw SyncError.rede(erro.localizedDescription)
            }
        } catch {
            throw SyncError.rede(error.localizedDescription)
        }
    }

    /// Os caracteres não reservados do RFC 3986 (`-`, `.`, `_`, `~`) somados
    /// aos alfanuméricos.
    ///
    /// `.alphanumerics` sozinho escapa o `_` e o `-` em `%5F`/`%2D` — que é
    /// legal em `application/x-www-form-urlencoded`, mas rebenta todo campo
    /// que carrega esses caracteres por natureza: `grant_type=authorization_code`
    /// vira `authorization%5Fcode`, e o `code_verifier` do PKCE, que é
    /// base64url e portanto cheio de `-`/`_`, sai irreconhecível no corpo.
    private static let formValueCharacters: CharacterSet = {
        var conjunto = CharacterSet.alphanumerics
        conjunto.insert(charactersIn: "-._~")
        return conjunto
    }()

    private func form(_ campos: [String: String]) -> String {
        campos
            .sorted { $0.key < $1.key }
            .map { chave, valor in
                let escapado = valor.addingPercentEncoding(
                    withAllowedCharacters: Self.formValueCharacters
                ) ?? valor
                return "\(chave)=\(escapado)"
            }
            .joined(separator: "&")
    }
}
