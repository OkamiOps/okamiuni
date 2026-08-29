import Foundation
import Testing
@testable import UNISync

@Suite("OAuth do Google, contra servidor local")
struct GoogleAuthTests {
    private let config = GoogleAuthConfig(
        clientID: "cliente-de-teste.apps.googleusercontent.com",
        tokenEndpoint: URL(string: "https://oauth2.example/token")!,
        revocationEndpoint: URL(string: "https://oauth2.example/revoke")!
    )

    /// Monta um `GoogleAuth` sobre uma `URLSession` isolada — seu próprio
    /// roteiro, seu próprio log de requisições — para poder rodar ao mesmo
    /// tempo que `GmailClientTests` sem uma pisar no roteiro da outra.
    private func auth(
        secrets: any SecretStore,
        routes: [String: [StubURLProtocol.Reply]] = [:],
        redirect: @Sendable @escaping (URL) throws -> URL = { url in
            URL(string: "com.okamiops.okamiuni:/oauth?code=codigo-devolvido&state="
                + (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""))!
        },
        now: @Sendable @escaping () -> Date = { Date(timeIntervalSince1970: 10_000) }
    ) -> (auth: GoogleAuth, session: URLSession) {
        let session = StubURLProtocol.session(routes: routes)
        let auth = GoogleAuth(
            config: config, session: session, secrets: secrets,
            presenter: StubAuthorizationPresenter(redirect: redirect), now: now
        )
        return (auth, session)
    }

    // MARK: PKCE e a URL de autorização

    @Test("O challenge é o SHA-256 do verifier em base64url sem padding")
    func pkceS256() {
        // Vetor OFICIAL do RFC 7636, apêndice B.1 — os octetos, o verifier e o
        // challenge são os três publicados no RFC, não recalculados a partir
        // de um deles. (A rodada de conserto 1 corrigiu um typo aqui: o array
        // de octetos original não hasheava para o verifier/challenge que o
        // teste afirmava, e a correção anterior tinha "consertado" isso
        // recalculando os dois lados a partir do array errado — um vetor
        // autoconsistente, mas que já não era o do RFC.)
        let bytes: [UInt8] = [
            116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173,
            187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83,
            132, 141, 121,
        ]
        let par = PKCEPair.make(from: bytes)
        #expect(par.verifier == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(par.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        // base64url: sem '+', sem '/', sem '='.
        #expect(!par.challenge.contains("+"))
        #expect(!par.challenge.contains("/"))
        #expect(!par.challenge.contains("="))
    }

    @Test("Dois pares aleatórios não se repetem e têm tamanho legal")
    func pkceAleatorio() {
        let a = PKCEPair.random()
        let b = PKCEPair.random()
        #expect(a.verifier != b.verifier)
        // RFC 7636: entre 43 e 128 caracteres.
        #expect(a.verifier.count >= 43 && a.verifier.count <= 128)
    }

    @Test("A URL de autorização leva client, redirect, escopos, S256 e o state")
    func urlDeAutorizacao() throws {
        let par = PKCEPair.make(from: Array(repeating: 7, count: 32))
        let url = config.authorizationURL(pkce: par, state: "estado-123", loginHint: "eu@gmail.com")
        let itens = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func valor(_ nome: String) -> String? { itens.first { $0.name == nome }?.value }

        #expect(valor("client_id") == config.clientID)
        // O redirect é DERIVADO do client ID — a forma que o client Desktop do
        // Google aceita (o esquema custom fixo era recusado com
        // redirect_uri_mismatch na tela de consentimento, no mundo real).
        #expect(valor("redirect_uri") == "com.googleusercontent.apps.cliente-de-teste:/oauth")
        #expect(GoogleAuthConfig.reversedScheme(
            forClientID: "297014925436-abc.apps.googleusercontent.com"
        ) == "com.googleusercontent.apps.297014925436-abc")
        #expect(valor("response_type") == "code")
        #expect(valor("code_challenge_method") == "S256")
        #expect(valor("code_challenge") == par.challenge)
        #expect(valor("state") == "estado-123")
        #expect(valor("login_hint") == "eu@gmail.com")
        // `access_type=offline` é o que faz o Google devolver refresh_token.
        // Sem ele a conta funciona por uma hora e depois cai em
        // erroDeAutenticacao sem ter o que renovar.
        #expect(valor("access_type") == "offline")
        #expect(valor("prompt") == "consent")

        let escopos = try #require(valor("scope")).split(separator: " ").map(String.init)
        // Um escopo de Gmail só. `gmail.modify` não cobre
        // `messages.batchDelete` — o apagamento definitivo do Marco 3 — e o
        // 403 dele pararia a fila da conta. `mail.google.com` é superconjunto
        // de `modify` + `send`: uma tela de consentimento, o marco inteiro.
        #expect(escopos.contains("https://mail.google.com/"))
        #expect(escopos.contains("https://www.googleapis.com/auth/userinfo.email"))
        #expect(!escopos.contains("https://www.googleapis.com/auth/gmail.modify"))
    }

    // MARK: O redirect de volta

    @Test("O código sai do redirect quando o state confere")
    func callbackComCodigo() throws {
        let url = URL(string: "com.okamiops.okamiuni:/oauth?code=abc123&state=estado-123")!
        #expect(try OAuthCallback.code(from: url, expectedState: "estado-123") == "abc123")
    }

    @Test("State trocado é recusado — é a defesa contra o redirect injetado")
    func callbackComStateErrado() {
        let url = URL(string: "com.okamiops.okamiuni:/oauth?code=abc123&state=outro")!
        #expect(throws: SyncError.resposta("O redirect do Google veio com um `state` que não é o nosso.")) {
            try OAuthCallback.code(from: url, expectedState: "estado-123")
        }
    }

    @Test("`access_denied` vira autorização revogada, não erro genérico")
    func callbackNegado() {
        let url = URL(string: "com.okamiops.okamiuni:/oauth?error=access_denied&state=estado-123")!
        #expect(throws: SyncError.autorizacaoRevogada) {
            try OAuthCallback.code(from: url, expectedState: "estado-123")
        }
    }

    @Test("Redirect sem `code` e sem `error` não é engolido")
    func callbackVazio() {
        let url = URL(string: "com.okamiops.okamiuni:/oauth?state=estado-123")!
        #expect(throws: (any Error).self) {
            try OAuthCallback.code(from: url, expectedState: "estado-123")
        }
    }

    // MARK: Troca e refresh

    @Test("Conectar troca o código por tokens e os guarda no cofre")
    func trocaGuardaTokens() async throws {
        let cofre = InMemorySecretStore()
        let (login, http) = auth(secrets: cofre, routes: [
            "/token": [.json("""
                {"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])

        let tokens = try await login.connect(accountID: "conta-g", loginHint: "eu@gmail.com")

        #expect(tokens.accessToken == "at-1")
        #expect(tokens.refreshToken == "rt-1")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 13_600))
        #expect(try cofre.secret(for: "conta-g") == .oauth(tokens))

        let pedido = try #require(StubURLProtocol.requests(for: http).first)
        #expect(pedido.body.contains("grant_type=authorization_code"))
        #expect(pedido.body.contains("code=codigo-devolvido"))
        #expect(pedido.body.contains("code_verifier="))
        // Client de desktop é público: não há segredo nenhum no corpo.
        #expect(!pedido.body.contains("client_secret"))
    }

    @Test("Token válido é devolvido sem tocar a rede")
    func tokenValidoNaoRenova() async throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-vivo", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 99_999)
        )), for: "conta-g")

        let (login, http) = auth(secrets: cofre)
        #expect(try await login.accessToken(for: "conta-g") == "at-vivo")
        #expect(StubURLProtocol.requests(for: http).isEmpty)
    }

    @Test("Token vencido é renovado, e o refresh antigo é preservado quando o Google não manda um novo")
    func refreshPreservaRefreshToken() async throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt-guardado",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        let (login, _) = auth(secrets: cofre, routes: [
            "/token": [.json("""
                {"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])

        #expect(try await login.accessToken(for: "conta-g") == "at-2")

        // O Google só devolve `refresh_token` no primeiro consentimento.
        // Sobrescrevê-lo com vazio derrubaria a conta na renovação seguinte.
        guard case .oauth(let guardados)? = try cofre.secret(for: "conta-g") else {
            Issue.record("esperava tokens no cofre"); return
        }
        #expect(guardados.refreshToken == "rt-guardado")
        #expect(guardados.accessToken == "at-2")
    }

    @Test("Refresh recusado marca `autorizacaoRevogada` — e não deixa token morto no cofre")
    func refreshRecusado() async throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt-morto",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        let (login, _) = auth(secrets: cofre, routes: [
            "/token": [.json("""
                {"error":"invalid_grant","error_description":"Token has been expired or revoked."}
                """, status: 400)],
        ])

        await #expect(throws: SyncError.autorizacaoRevogada) {
            _ = try await login.accessToken(for: "conta-g")
        }

        // O nome promete que não fica token morto no cofre — a asserção que
        // prova isso, não só o erro certo. `invalid_grant` significa que o
        // `rt-morto` nunca mais vai funcionar; deixá-lo no cofre é lixo que
        // só a Task 15 (ou o próximo refresh) descobriria de novo.
        #expect(try cofre.secret(for: "conta-g") == nil)
    }

    @Test("Refresh falho não deixa a corrida presa: o próximo pedido tenta de novo, não repete o erro velho")
    func refreshFalhoLiberaAVaga() async throws {
        // Sem o `defer { inFlight[accountID] = nil }`, a tarefa fracassada
        // fica pendurada no dicionário para sempre, e todo pedido seguinte
        // reusaria — e repetiria — o erro de uma corrida que já morreu, em
        // vez de tentar de novo.
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")
        let (login, http) = auth(secrets: cofre, routes: [
            "/token": [
                .json("{\"error\":\"internal_failure\"}", status: 500),
                .json("""
                    {"access_token":"at-segunda-tentativa","expires_in":3600,"token_type":"Bearer"}
                    """),
            ],
        ])

        await #expect(throws: SyncError.self) {
            _ = try await login.accessToken(for: "conta-g")
        }

        let token = try await login.accessToken(for: "conta-g")
        #expect(token == "at-segunda-tentativa")
        #expect(StubURLProtocol.requests(for: http).filter { $0.path == "/token" }.count == 2)
    }

    @Test("`renewedAccessToken` renova mesmo com o token válido pelo relógio local")
    func renovacaoForcada() async throws {
        // É o que dá ao 401 uma segunda chance. `accessToken(for:)` olharia o
        // relógio **deste** computador, veria um token que só vence daqui a
        // uma hora e devolveria o mesmo token — que o servidor acabou de
        // recusar. Um relógio adiantado, ou uma revogação no painel da conta,
        // mataria uma carga de noventa dias.
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-que-o-servidor-recusou", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 999_999)
        )), for: "conta-g")
        let (login, http) = auth(secrets: cofre, routes: [
            "/token": [.json("{\"access_token\":\"at-renovado\",\"expires_in\":3600}")],
        ])

        // Pelo relógio local o token está ótimo: este é o caminho que não
        // renova.
        #expect(try await login.accessToken(for: "conta-g") == "at-que-o-servidor-recusou")
        #expect(StubURLProtocol.requests(for: http).isEmpty)

        #expect(try await login.renewedAccessToken(for: "conta-g") == "at-renovado")
        #expect(StubURLProtocol.requests(for: http).filter { $0.path == "/token" }.count == 1)
        // E o token novo fica no cofre: o replay o encontra pelo caminho
        // normal, sem o chamador ter de carregá-lo na mão.
        guard case .oauth(let guardados)? = try cofre.secret(for: "conta-g") else {
            Issue.record("o refresh tem de guardar o token novo"); return
        }
        #expect(guardados.accessToken == "at-renovado")
    }

    @Test("Dez renovações forçadas ao mesmo tempo fazem UMA requisição ao `/token`")
    func renovacaoForcadaEhUmaSoCorrida() async throws {
        // O Google invalida um refresh token usado em paralelo: dez refreshes
        // simultâneos derrubariam a conta em `erroDeAutenticacao` sem ninguém
        // ter feito nada errado. A rota tem **uma** resposta só — uma segunda
        // requisição não acharia rota e viraria erro de rede, que é como este
        // teste ficaria vermelho se a corrida deixasse de existir.
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-recusado", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 999_999)
        )), for: "conta-g")
        let (login, http) = auth(secrets: cofre, routes: [
            "/token": [.json("{\"access_token\":\"at-renovado\",\"expires_in\":3600}")],
        ])

        try await withThrowingTaskGroup(of: String.self) { grupo in
            for _ in 0..<10 {
                grupo.addTask { try await login.renewedAccessToken(for: "conta-g") }
            }
            for try await token in grupo { #expect(token == "at-renovado") }
        }

        #expect(StubURLProtocol.requests(for: http).filter { $0.path == "/token" }.count == 1)
    }

    @Test("Falha de rede no refresh vira `.rede`, e o refresh token continua no cofre")
    func refreshComFalhaDeRede() async throws {
        // Nenhuma rota para `/token`: o `StubURLProtocol` dispara um
        // `URLError`, que é falha de transporte — não recusa do servidor.
        // A distinção importa: `.rede` manda tentar de novo, e
        // `.autorizacaoRevogada` mandaria reconectar — a pessoa perderia a
        // conta por causa de uma rede instável, não de um token morto.
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt-preservado",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        let (login, _) = auth(secrets: cofre)

        do {
            _ = try await login.accessToken(for: "conta-g")
            Issue.record("esperava erro de rede")
        } catch SyncError.rede {
            // esperado
        } catch {
            Issue.record("esperava .rede, veio \(error)")
        }

        guard case .oauth(let guardados)? = try cofre.secret(for: "conta-g") else {
            Issue.record("erro de rede não pode apagar o refresh token do cofre"); return
        }
        #expect(guardados.refreshToken == "rt-preservado")
    }

    @Test("Quota do servidor de token não vira erro genérico")
    func refreshComQuota() async throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        let (login, _) = auth(secrets: cofre, routes: [
            "/token": [.json("{\"error\":\"rateLimitExceeded\"}", status: 429)],
        ])

        await #expect(throws: SyncError.quota) {
            _ = try await login.accessToken(for: "conta-g")
        }
    }

    @Test("Dez pedidos simultâneos com token vencido fazem UM refresh só")
    func corridaDeRefreshEhUnica() async throws {
        // A prova de que o single-flight existe. Sem ele, dez chamadas
        // disparariam dez POSTs, e o Google invalida o refresh token quando
        // ele é usado em paralelo — a conta cairia sozinha em erro.
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")
        let (login, http) = auth(secrets: cofre, routes: [
            "/token": [.json("""
                {"access_token":"at-unico","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])

        let tokens = try await withThrowingTaskGroup(of: String.self) { grupo in
            for _ in 0..<10 { grupo.addTask { try await login.accessToken(for: "conta-g") } }
            var todos: [String] = []
            for try await token in grupo { todos.append(token) }
            return todos
        }

        #expect(tokens == Array(repeating: "at-unico", count: 10))
        #expect(StubURLProtocol.requests(for: http).count == 1)
    }

    @Test("Conta sem segredo nenhum pede autenticação em vez de estourar")
    func semSegredo() async {
        let (login, _) = auth(secrets: InMemorySecretStore())
        await #expect(throws: SyncError.autenticacao) {
            _ = try await login.accessToken(for: "fantasma")
        }
    }

    @Test("Revogar avisa o Google e limpa o cofre")
    func revogar() async throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 99_999)
        )), for: "conta-g")

        let (login, http) = auth(secrets: cofre, routes: ["/revoke": [.init(status: 200)]])

        try await login.revoke(accountID: "conta-g")
        #expect(try cofre.secret(for: "conta-g") == nil)
        #expect(StubURLProtocol.requests(for: http).contains { $0.path == "/revoke" })
    }

    @Test("Sem client ID no bundle, a configuração diz o que falta")
    func semClientID() {
        #expect(throws: SyncError.semClientID) {
            _ = try GoogleAuthConfig.fromBundle(Bundle(for: BundleAnchor.self))
        }
    }
}

/// Âncora para pegar um `Bundle` que não tem a chave do client ID.
private final class BundleAnchor {}

import AuthenticationServices

@Suite("O retorno do navegador, traduzido fora da fila principal")
struct AuthorizationPresenterTests {
    // As três chamadas acontecem num contexto nonisolated de propósito: o
    // completion do ASWebAuthenticationSession chega numa fila do XPC, e um
    // `traduz` isolado ao MainActor nem compilaria daqui — o teste trava a
    // forma que causou o SIGTRAP no login real.
    @Test("O callback que veio é sucesso")
    func callbackViraSucesso() async throws {
        let url = URL(string: "com.exemplo:/oauth?code=abc")!
        let resultado = await Task.detached {
            WebAuthorizationPresenter.traduz(url, nil)
        }.value
        #expect(try resultado.get() == url)
    }

    @Test("Cancelar o login é autorização revogada, não erro de rede")
    func cancelarEhRevogada() async {
        let erro = ASWebAuthenticationSessionError(.canceledLogin)
        let resultado = await Task.detached {
            WebAuthorizationPresenter.traduz(nil, erro)
        }.value
        guard case .failure(.autorizacaoRevogada) = resultado else {
            Issue.record("esperava .autorizacaoRevogada, veio \(resultado)")
            return
        }
    }

    @Test("Qualquer outro fim sem callback é erro de rede com a causa")
    func outroFimEhRede() async {
        let erro = NSError(domain: "teste", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "caiu a ponte"])
        let resultado = await Task.detached {
            WebAuthorizationPresenter.traduz(nil, erro)
        }.value
        guard case .failure(.rede(let causa)) = resultado else {
            Issue.record("esperava .rede, veio \(resultado)")
            return
        }
        #expect(causa == "caiu a ponte")
    }
}
