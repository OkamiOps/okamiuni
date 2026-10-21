import Foundation
import UNICore
import os

/// Como o OkamiUNI pede à pessoa o acesso à caixa Zoho dela.
///
/// É o par de `GoogleAuthConfig` para o Zoho, e as diferenças com o Google são
/// quatro, todas impostas por lá:
///
/// 1. **Escopos separados por vírgula.** O Zoho recusa espaço — é a mesma
///    regra que o `ZohoConnector` do Zoho Meeting já tinha aprendido.
/// 2. **Redirect por loopback.** O Zoho só aceita `http`/`https` no
///    `redirect_uri`; esquema próprio de app é recusado no cadastro. O retorno
///    vem em `http://127.0.0.1:53720/oauth2redirect`, o mesmo do Zoom e do
///    Zoho Meeting — e o mesmo que já está cadastrado no API Console.
/// 3. **PKCE e `client_secret`, os dois.** O cliente é "Server-based" no
///    console do Zoho, e a troca do código exige o segredo mesmo com PKCE
///    correto.
/// 4. **Multi data center.** O callback diz onde a conta mora, e a troca do
///    código, a renovação, o IMAP, o SMTP e a API têm de ir **todos** para lá.
///    Ver `ZohoDataCenter` e `ZohoMailEndpoints`.
///
/// O client ID e o segredo são os mesmos do Zoho Meeting (`MeetingClientIDs`,
/// alimentado por `Config/Meetings.xcconfig`): é o mesmo aplicativo registrado
/// no mesmo API Console, e dois cadastros só dariam à pessoa duas telas de
/// consentimento para a mesma empresa.
public struct ZohoMailAuthConfig: Sendable, Hashable {
    /// Ler a caixa por IMAP. É o escopo documentado em
    /// `zoho.com/mail/help/sasl-xoauth2-smtp-imap-pop-protocol-exchange.html`.
    public static let imapScope = "ZOHOMAIL.PROTOCOL.IMAP"
    /// Enviar por SMTP com o mesmo token.
    ///
    /// **É o único escopo desta lista que a documentação pública não nomeia.**
    /// A página do SASL XOAUTH2 (cujo endereço diz `…-smtp-imap-pop-…`, e cujo
    /// exemplo em base64 decodifica para `dummyAccessTokenForSMTP`) descreve a
    /// troca de IMAP e de POP e publica o escopo dos dois, mas não escreve o
    /// de SMTP. O nome aqui segue o padrão declarado na própria página —
    /// `ZOHOMAIL.PROTOCOL.<protocolo>` — e o consentimento **não aposta nele**:
    /// ver `fallbackScopes` e `ZohoMailAuth.connect`.
    public static let smtpScope = "ZOHOMAIL.PROTOCOL.SMTP"
    /// Ler qual é o endereço de verdade da conta que autorizou
    /// (`GET /api/accounts`). Sem ele o app teria de acreditar no que a pessoa
    /// digitou antes de clicar — e quem entra com outra conta no navegador
    /// acabaria com a caixa de uma pendurada no endereço da outra.
    public static let accountsScope = "ZohoMail.accounts.READ"
    /// Enviar pela API REST da caixa. Entra no mesmo consentimento porque é a
    /// saída de emergência de quem não conseguir o SMTP — pedir um segundo
    /// consentimento no dia do primeiro envio seria pedir no pior momento.
    public static let sendScope = "ZohoMail.messages.CREATE"

    /// O que o app pede. Um consentimento só, com tudo.
    public static let defaultScopes = [accountsScope, imapScope, smtpScope, sendScope]
    /// O que ele pede de novo quando o Zoho recusa a lista acima com
    /// `invalid_scope` — ou seja, quando `ZOHOMAIL.PROTOCOL.SMTP` não existe.
    /// A caixa continua inteira para ler; o envio passa pela API REST.
    public static let fallbackScopes = [accountsScope, imapScope, sendScope]

    public let clientID: String
    public let clientSecret: String
    public let redirectURI: String
    public let scopes: [String]
    public let fallbackScopes: [String]
    /// Para onde vai o consentimento quando ainda não se sabe o data center da
    /// pessoa. `accounts.zoho.com` é o padrão do Zoho, e é ele quem redireciona
    /// o login para o data center certo e devolve `accounts-server` no retorno.
    public let defaultAccountsServer: String

    public init(
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        scopes: [String] = ZohoMailAuthConfig.defaultScopes,
        fallbackScopes: [String] = ZohoMailAuthConfig.fallbackScopes,
        defaultAccountsServer: String = "https://accounts.zoho.com"
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.fallbackScopes = fallbackScopes
        self.defaultAccountsServer = defaultAccountsServer
    }

    /// As credenciais do bundle, as mesmas do Zoho Meeting. `nil` quando o
    /// build não trouxe uma das duas — e aí a rota não existe e o botão não
    /// aparece, em vez de abrir um navegador que só pode dar erro.
    public static func fromBundle(
        _ bundle: Bundle = .main,
        redirectURI: String = LoopbackEndpoint.standard.redirectURI
    ) -> ZohoMailAuthConfig? {
        guard let id = MeetingClientIDs.clientID(for: .zoho, bundle: bundle),
              let segredo = MeetingClientIDs.clientSecret(for: .zoho, bundle: bundle)
        else { return nil }
        return ZohoMailAuthConfig(clientID: id, clientSecret: segredo, redirectURI: redirectURI)
    }

    /// A URL do consentimento.
    ///
    /// `scopes` entra por parâmetro, e não pela propriedade, porque a segunda
    /// tentativa (sem o escopo de SMTP) é a mesma URL com outra lista — e
    /// montá-la por outro caminho acabaria com duas URLs que divergem no dia
    /// em que alguém mexer numa só.
    public func authorizationURL(
        scopes: [String], pkce: PKCEPair, state: String, loginHint: String?
    ) -> URL {
        var components = URLComponents(
            string: "\(defaultAccountsServer)/oauth/v2/auth"
        )!
        var itens = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            // Vírgula: o Zoho recusa espaço entre escopos.
            URLQueryItem(name: "scope", value: scopes.joined(separator: ",")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Sem `access_type=offline` não vem refresh token, e a caixa
            // pararia de sincronizar uma hora depois de ser adicionada.
            URLQueryItem(name: "access_type", value: "offline"),
            // `prompt=consent` faz o refresh token vir também para quem já
            // tinha autorizado antes — reconectar depois de um erro precisa.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint, !loginHint.isEmpty {
            // O Zoho chama de `login_id`; o nome do Google (`login_hint`) é
            // ignorado lá, e mandar os dois não custa nada.
            itens.append(URLQueryItem(name: "login_id", value: loginHint))
        }
        components.queryItems = itens
        return components.url!
    }
}

/// O Zoho não reconheceu um dos escopos pedidos.
///
/// Tipo próprio e **interno**: ele nasce em `postToken`, é pego em `connect` e
/// morre ali — a segunda tentativa, com a lista documentada, é a resposta
/// inteira. Nunca chega à interface, e por isso não é um caso de `SyncError`:
/// um caso novo lá obrigaria toda tela de conta a escrever uma frase para um
/// estado que elas nunca veem.
struct ZohoScopeRefused: Error {}

/// O que um consentimento concluído produziu.
public struct ZohoConsent: Sendable, Hashable {
    public let tokens: OAuthTokens
    /// `https://accounts.zoho.eu`, já canônico. Ele também vai dentro de
    /// `tokens`; sai aqui porque quem chama o usa antes de guardar nada.
    public let accountsServer: String

    public init(tokens: OAuthTokens, accountsServer: String) {
        self.tokens = tokens
        self.accountsServer = accountsServer
    }
}

extension OAuthTokens {
    /// Este par de tokens é de uma caixa Zoho?
    ///
    /// O discriminador é o `accountsServer`: só o Zoho o preenche, e o Google
    /// nunca. Um `case` novo em `Secret` resolveria a mesma pergunta e custaria
    /// uma migração do que já está gravado no Keychain de quem usa o app hoje.
    public var isZohoMail: Bool { accountsServer != nil }

    /// O token concedeu o envio por SMTP? Vazio (token antigo, ou servidor que
    /// não devolveu a lista) conta como **sim**: tentar o SMTP e cair é melhor
    /// do que desviar para a API sem necessidade.
    public var canSendOverZohoSMTP: Bool {
        scopes.isEmpty || scopes.contains { $0.caseInsensitiveCompare(
            ZohoMailAuthConfig.smtpScope
        ) == .orderedSame }
    }
}

/// O fluxo OAuth da caixa Zoho, do consentimento ao refresh.
///
/// Ator pela razão de sempre, a mesma escrita no alto de `GoogleAuth`: a
/// renovação precisa de exclusão mútua de verdade. Aqui ela é **por conta**,
/// porque duas caixas Zoho no mesmo app são duas credenciais independentes, e
/// porque o laço da fila de saída e o ciclo de sincronização podem pedir token
/// no mesmo instante.
public actor ZohoMailAuth {
    private let config: ZohoMailAuthConfig
    private let session: URLSession
    private let secrets: any SecretStore
    private let browser: any SystemBrowserOpening
    private let loopback: LoopbackEndpoint
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "ZohoMailAuth")

    /// A renovação em voo, por conta. É o single-flight.
    private var inFlight: [String: Task<OAuthTokens, any Error>] = [:]

    public init(
        config: ZohoMailAuthConfig,
        session: URLSession,
        secrets: any SecretStore,
        browser: any SystemBrowserOpening = AppKitBrowserOpener(),
        loopback: LoopbackEndpoint = .standard,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.session = session
        self.secrets = secrets
        self.browser = browser
        self.loopback = loopback
        self.now = now
    }

    // MARK: Primeiro consentimento

    /// Abre o navegador, espera o retorno, troca o código e **devolve** — sem
    /// gravar.
    ///
    /// Não grava de propósito, e é a lição que `AccountDirector.reconnectGoogle`
    /// pagou caro: com o token na mão é que se descobre de quem ele é, e
    /// guardá-lo antes da conferência penduraria a credencial de uma pessoa no
    /// id de outra. Quem chama guarda depois de saber o endereço.
    public func connect(loginHint: String?) async throws -> ZohoConsent {
        do {
            return try await consent(scopes: config.scopes, loginHint: loginHint)
        } catch is ZohoScopeRefused {
            // O Zoho não reconheceu um dos escopos — na prática, o de SMTP,
            // que é o único desta lista que a documentação pública não nomeia.
            // A segunda volta pede o conjunto documentado, e o envio passa a
            // sair pela API REST da caixa.
            log.notice("O Zoho recusou a lista de escopos; repetindo sem o de SMTP.")
            return try await consent(scopes: config.fallbackScopes, loginHint: loginHint)
        }
    }

    private func consent(scopes: [String], loginHint: String?) async throws -> ZohoConsent {
        let escuta = loopback.make()
        try escuta.start()
        defer { escuta.cancel() }

        let pkce = PKCEPair.random()
        let state = PKCEPair.randomToken()
        let url = config.authorizationURL(
            scopes: scopes, pkce: pkce, state: state, loginHint: loginHint
        )
        guard await browser.open(url) else {
            throw SyncError.resposta(
                L10n.tr("Não foi possível abrir o navegador para o login do Zoho.")
            )
        }

        let retorno = try await escuta.wait()
        let callback = try ZohoMailCallback.read(retorno, expectedState: state)

        let bruto = callback.accountsServer ?? config.defaultAccountsServer
        guard let servidor = ZohoDataCenter.canonicalAccountsServer(bruto) else {
            throw SyncError.resposta(
                L10n.tr("O Zoho voltou de um data center que não conhecemos: \(bruto)")
            )
        }

        // O `scope` não vai na troca: o Zoho o ignora aqui e o devolve na
        // resposta, que é de onde `postToken` o lê — e `keepingScopes` cobre
        // o servidor que não o devolve.
        let campos = [
            "grant_type": "authorization_code",
            "code": callback.code,
            "redirect_uri": config.redirectURI,
            "code_verifier": pkce.verifier,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
        ]
        let tokens = try await postToken(
            campos, at: servidor, keeping: nil, keepingScopes: scopes
        )
        return ZohoConsent(tokens: tokens, accountsServer: servidor)
    }

    // MARK: Token para usar agora

    /// O access token corrente da conta, renovando se preciso.
    public func accessToken(for accountID: String) async throws -> String {
        guard case .oauth(let guardados)? = try secrets.secret(for: accountID) else {
            throw SyncError.autenticacao
        }
        guard guardados.isExpired(at: now()) else { return guardados.accessToken }
        return try await refresh(accountID: accountID, using: guardados).accessToken
    }

    /// Renova **agora**, sem perguntar ao relógio local — a porta do replay
    /// pós-recusa, igual à do Google. Um `NO` do IMAP com um token que este
    /// Mac considera válido é exatamente o caso em que o relógio errou.
    public func renewedAccessToken(for accountID: String) async throws -> String {
        guard case .oauth(let guardados)? = try secrets.secret(for: accountID) else {
            throw SyncError.autenticacao
        }
        return try await refresh(accountID: accountID, using: guardados).accessToken
    }

    /// Os tokens guardados, sem tocar na rede. Quem precisa saber o data center
    /// ou os escopos concedidos lê daqui.
    public func stored(for accountID: String) -> OAuthTokens? {
        guard case .oauth(let guardados)? = try? secrets.secret(for: accountID) else { return nil }
        return guardados
    }

    public func store(_ tokens: OAuthTokens, for accountID: String) throws {
        try secrets.store(.oauth(tokens), for: accountID)
    }

    private func refresh(accountID: String, using guardados: OAuthTokens) async throws -> OAuthTokens {
        if let emVoo = inFlight[accountID] { return try await emVoo.value }

        // A renovação vai para o **mesmo** data center da troca original. Sem
        // isto, um token nascido em `accounts.zoho.eu` seria renovado no
        // `.com` e voltaria `invalid_code`, sem dizer por quê.
        let servidor = guardados.accountsServer ?? config.defaultAccountsServer
        let tarefa = Task<OAuthTokens, any Error> { [config, secrets] in
            do {
                let campos = [
                    "grant_type": "refresh_token",
                    "refresh_token": guardados.refreshToken,
                    "client_id": config.clientID,
                    "client_secret": config.clientSecret,
                ]
                let novos = try await self.postToken(
                    campos, at: servidor, keeping: guardados,
                    keepingScopes: guardados.scopes
                )
                try secrets.store(.oauth(novos), for: accountID)
                return novos
            } catch SyncError.autorizacaoRevogada {
                // O refresh token morreu no servidor. Deixá-lo no cofre é lixo
                // que só seria descoberto na próxima tentativa — ou nunca.
                try? secrets.remove(for: accountID)
                throw SyncError.autorizacaoRevogada
            }
        }
        inFlight[accountID] = tarefa
        defer { inFlight[accountID] = nil }
        return try await tarefa.value
    }

    // MARK: Revogação

    /// Avisa o Zoho e some com o segredo. Falhar o aviso não impede a remoção
    /// local — a mesma regra do `GoogleAuth.revoke`, e pelo mesmo motivo.
    public func revoke(accountID: String) async throws {
        defer { try? secrets.remove(for: accountID) }
        guard case .oauth(let guardados)? = try secrets.secret(for: accountID),
              guardados.isZohoMail
        else { return }
        let servidor = guardados.accountsServer ?? config.defaultAccountsServer
        var components = URLComponents(string: "\(servidor)/oauth/v2/token/revoke")!
        components.queryItems = [URLQueryItem(name: "token", value: guardados.refreshToken)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
    }

    // MARK: O POST do token

    func postToken(
        _ campos: [String: String], at accountsServer: String,
        keeping anterior: OAuthTokens?, keepingScopes anteriores: [String]
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "\(accountsServer)/oauth/v2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(MeetingForm.encode(campos).utf8)

        let (dados, resposta) = try await enviar(request)
        guard let http = resposta as? HTTPURLResponse else {
            throw SyncError.resposta(
                L10n.tr("O servidor de token do Zoho respondeu sem cabeçalho HTTP.")
            )
        }

        struct Wire: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
            let error: String?
            let error_description: String?
        }
        let fio = try? JSONDecoder().decode(Wire.self, from: dados)

        // O Zoho responde **200 com `{"error":"…"}`**: o status sozinho não é
        // sinal de nada aqui, e confiar nele faria `invalid_code` passar como
        // sucesso e explodir mais tarde, longe da causa.
        if let nome = fio?.error, fio?.access_token == nil {
            throw Self.tokenError(status: http.statusCode, name: nome, detail: fio?.error_description)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.tokenError(
                status: http.statusCode, name: fio?.error, detail: fio?.error_description
            )
        }
        guard let fio, let access = fio.access_token else {
            throw SyncError.resposta(
                L10n.tr("O Zoho não devolveu access token.")
            )
        }
        guard let refresh = fio.refresh_token ?? anterior?.refreshToken else {
            // Sem refresh token a conta funcionaria uma hora e morreria.
            // Melhor falhar agora, dizendo o que aconteceu.
            throw SyncError.resposta(
                L10n.tr("O Zoho não devolveu refresh token. Conecte a conta de novo pedindo o consentimento.")
            )
        }
        // O Zoho separa escopos por vírgula na ida e por espaço na volta;
        // aceitar os dois é mais honesto que escolher um e perder a lista.
        let concedidos = Self.parseScopes(fio.scope)
        return OAuthTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now().addingTimeInterval(fio.expires_in ?? 3_600),
            scopes: concedidos.isEmpty ? anteriores : concedidos,
            accountsServer: accountsServer
        )
    }

    static func parseScopes(_ raw: String?) -> [String] {
        (raw ?? "")
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Cada falha do servidor de token vira o caso que pede a ação certa.
    ///
    /// Devolve `any Error` e não `SyncError` por causa de **um** caso: a
    /// recusa de escopo não é uma falha que a pessoa veja nem resolva — ela é
    /// tratada e consumida aqui dentro, por `connect`, que repete o
    /// consentimento sem o escopo em dúvida. Promovê-la a caso de `SyncError`
    /// obrigaria toda tela que mostra conta a escrever uma frase para um
    /// estado que nunca chega até lá.
    static func tokenError(status: Int, name: String?, detail: String?) -> any Error {
        switch name {
        case "invalid_scope", "invalid_scopes":
            return ZohoScopeRefused()
        case "invalid_code", "invalid_grant", "access_denied", "unauthorized_client":
            return SyncError.autorizacaoRevogada
        case "invalid_client", "invalid_client_secret":
            return SyncError.semClientID
        default:
            break
        }
        if status == 429 { return SyncError.quota }
        if status == 400 || status == 401 { return SyncError.autorizacaoRevogada }
        return SyncError.servidor(
            codigo: status, mensagem: detail ?? name ?? L10n.tr("sem detalhe")
        )
    }

    private func enviar(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let erro as URLError {
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
}

/// O que o redirect do navegador trouxe, conferido.
///
/// É irmão de `MeetingOAuthCallback` e não o mesmo tipo porque aquele fala a
/// língua de `MeetingConnectorError` ("o retorno do **Zoho Meeting**…"), e uma
/// pessoa adicionando a caixa de e-mail não entenderia por que o app está
/// falando de reunião. A regra que importa — **conferir o `state`** — é a
/// mesma, e é a que impede alguém capaz de fazer um GET em `127.0.0.1:53720`
/// de injetar o código de autorização de outra conta no nosso fluxo.
public enum ZohoMailCallback {
    public struct Result: Sendable, Hashable {
        public let code: String
        public let accountsServer: String?
        public let location: String?
    }

    public static func read(_ url: URL, expectedState: String) throws -> Result {
        guard let itens = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw SyncError.resposta(L10n.tr("O retorno do Zoho veio sem parâmetros."))
        }
        func valor(_ nome: String) -> String? {
            let bruto = itens.first { $0.name == nome }?.value ?? ""
            let limpo = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
            return limpo.isEmpty ? nil : limpo
        }
        if let erro = valor("error") {
            if erro == "access_denied" { throw CancellationError() }
            throw SyncError.resposta(L10n.tr("O Zoho recusou a autorização: \(erro)"))
        }
        guard valor("state") == expectedState else {
            throw SyncError.resposta(
                L10n.tr("O retorno do Zoho veio com um `state` que não é o nosso.")
            )
        }
        guard let code = valor("code") else {
            throw SyncError.resposta(
                L10n.tr("O retorno do Zoho veio sem código de autorização.")
            )
        }
        return Result(
            code: code, accountsServer: valor("accounts-server"), location: valor("location")
        )
    }
}
