import Foundation
import Testing
@testable import UNISync

@Suite("OAuth do Google, contra servidor local", .serialized)
struct GoogleAuthTests {
    private let config = GoogleAuthConfig(
        clientID: "cliente-de-teste.apps.googleusercontent.com",
        tokenEndpoint: URL(string: "https://oauth2.example/token")!,
        revocationEndpoint: URL(string: "https://oauth2.example/revoke")!
    )

    private func auth(
        secrets: any SecretStore,
        redirect: @Sendable @escaping (URL) throws -> URL = { url in
            URL(string: "com.okamiops.okamiuni:/oauth?code=codigo-devolvido&state="
                + (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""))!
        },
        now: @Sendable @escaping () -> Date = { Date(timeIntervalSince1970: 10_000) }
    ) -> GoogleAuth {
        GoogleAuth(
            config: config, session: StubURLProtocol.session(), secrets: secrets,
            presenter: StubAuthorizationPresenter(redirect: redirect), now: now
        )
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
        #expect(valor("redirect_uri") == "com.okamiops.okamiuni:/oauth")
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
        #expect(escopos.contains("https://www.googleapis.com/auth/gmail.modify"))
        #expect(escopos.contains("https://www.googleapis.com/auth/gmail.send"))
        #expect(escopos.contains("https://www.googleapis.com/auth/userinfo.email"))
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
        StubURLProtocol.install([
            "/token": [.json("""
                {"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        let tokens = try await auth(secrets: cofre).connect(accountID: "conta-g", loginHint: "eu@gmail.com")

        #expect(tokens.accessToken == "at-1")
        #expect(tokens.refreshToken == "rt-1")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 13_600))
        #expect(try cofre.secret(for: "conta-g") == .oauth(tokens))

        let pedido = try #require(StubURLProtocol.requests.first)
        #expect(pedido.body.contains("grant_type=authorization_code"))
        #expect(pedido.body.contains("code=codigo-devolvido"))
        #expect(pedido.body.contains("code_verifier="))
        // Client de desktop é público: não há segredo nenhum no corpo.
        #expect(!pedido.body.contains("client_secret"))
    }

    @Test("Token válido é devolvido sem tocar a rede")
    func tokenValidoNaoRenova() async throws {
        StubURLProtocol.install([:])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-vivo", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 99_999)
        )), for: "conta-g")

        #expect(try await auth(secrets: cofre).accessToken(for: "conta-g") == "at-vivo")
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test("Token vencido é renovado, e o refresh antigo é preservado quando o Google não manda um novo")
    func refreshPreservaRefreshToken() async throws {
        StubURLProtocol.install([
            "/token": [.json("""
                {"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt-guardado",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        #expect(try await auth(secrets: cofre).accessToken(for: "conta-g") == "at-2")

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
        StubURLProtocol.install([
            "/token": [.json("""
                {"error":"invalid_grant","error_description":"Token has been expired or revoked."}
                """, status: 400)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt-morto",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        await #expect(throws: SyncError.autorizacaoRevogada) {
            _ = try await self.auth(secrets: cofre).accessToken(for: "conta-g")
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
        StubURLProtocol.install([
            "/token": [
                .json("{\"error\":\"internal_failure\"}", status: 500),
                .json("""
                    {"access_token":"at-segunda-tentativa","expires_in":3600,"token_type":"Bearer"}
                    """),
            ],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")
        let sessao = auth(secrets: cofre)

        await #expect(throws: SyncError.self) {
            _ = try await sessao.accessToken(for: "conta-g")
        }

        let token = try await sessao.accessToken(for: "conta-g")
        #expect(token == "at-segunda-tentativa")
        #expect(StubURLProtocol.requests.filter { $0.path == "/token" }.count == 2)
    }

    @Test("Falha de rede no refresh vira `.rede`, e o refresh token continua no cofre")
    func refreshComFalhaDeRede() async throws {
        // Nenhuma rota para `/token`: o `StubURLProtocol` dispara um
        // `URLError`, que é falha de transporte — não recusa do servidor.
        // A distinção importa: `.rede` manda tentar de novo, e
        // `.autorizacaoRevogada` mandaria reconectar — a pessoa perderia a
        // conta por causa de uma rede instável, não de um token morto.
        StubURLProtocol.install([:])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt-preservado",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        do {
            _ = try await self.auth(secrets: cofre).accessToken(for: "conta-g")
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
        StubURLProtocol.install([
            "/token": [.json("{\"error\":\"rateLimitExceeded\"}", status: 429)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        await #expect(throws: SyncError.quota) {
            _ = try await self.auth(secrets: cofre).accessToken(for: "conta-g")
        }
    }

    @Test("Dez pedidos simultâneos com token vencido fazem UM refresh só")
    func corridaDeRefreshEhUnica() async throws {
        // A prova de que o single-flight existe. Sem ele, dez chamadas
        // disparariam dez POSTs, e o Google invalida o refresh token quando
        // ele é usado em paralelo — a conta cairia sozinha em erro.
        StubURLProtocol.install([
            "/token": [.json("""
                {"access_token":"at-unico","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")
        let auth = auth(secrets: cofre)

        let tokens = try await withThrowingTaskGroup(of: String.self) { grupo in
            for _ in 0..<10 { grupo.addTask { try await auth.accessToken(for: "conta-g") } }
            var todos: [String] = []
            for try await token in grupo { todos.append(token) }
            return todos
        }

        #expect(tokens == Array(repeating: "at-unico", count: 10))
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("Conta sem segredo nenhum pede autenticação em vez de estourar")
    func semSegredo() async {
        StubURLProtocol.install([:])
        defer { StubURLProtocol.reset() }
        await #expect(throws: SyncError.autenticacao) {
            _ = try await self.auth(secrets: InMemorySecretStore()).accessToken(for: "fantasma")
        }
    }

    @Test("Revogar avisa o Google e limpa o cofre")
    func revogar() async throws {
        StubURLProtocol.install(["/revoke": [.init(status: 200)]])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 99_999)
        )), for: "conta-g")

        try await auth(secrets: cofre).revoke(accountID: "conta-g")
        #expect(try cofre.secret(for: "conta-g") == nil)
        #expect(StubURLProtocol.requests.contains { $0.path == "/revoke" })
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
