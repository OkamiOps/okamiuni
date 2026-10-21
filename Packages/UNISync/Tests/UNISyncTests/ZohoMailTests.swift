import Foundation
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// O mesmo desligamento sem bloqueio de `ImapSessionTests`: uma função de
/// teste `async` roda no pool cooperativo, e `syncShutdownGracefully()` o
/// trava.
private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
    grupo.shutdownGracefully { _ in }
}

/// O endpoint em claro do servidor falso. `.startTLS` com `allowInsecure`
/// nunca sobe o túnel — é como o resto da suíte de IMAP fala com ele.
private func endpoint(porta: Int) -> ImapEndpoint {
    ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
}

private let configZoho = ZohoMailAuthConfig(
    clientID: "1000.CLIENTE", clientSecret: "segredo",
    redirectURI: "http://127.0.0.1:53720/oauth2redirect"
)

/// Um "navegador" que bate na escuta de loopback como o de verdade bateria:
/// um GET em `127.0.0.1`. É o que torna o teste do consentimento uma prova de
/// que o ouvinte funciona, e não de que um dublê funciona — a mesma forma do
/// `RecordingBrowser` de `MeetingOAuthTests`, que é `private` lá.
private final class NavegadorFalso: SystemBrowserOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var abertas: [URL] = []
    private let redirect: @Sendable (URL, Int) -> URL?

    /// `redirect` recebe a URL de autorização e **qual** abertura é esta
    /// (0, 1, …) — a segunda volta do consentimento, quando o Zoho recusa um
    /// escopo, precisa responder diferente da primeira.
    init(redirect: @Sendable @escaping (URL, Int) -> URL?) {
        self.redirect = redirect
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return abertas
    }

    func open(_ url: URL) async -> Bool {
        let indice = registra(url)
        guard let destino = redirect(url, indice) else { return true }
        Task.detached {
            var pedido = URLRequest(url: destino)
            pedido.httpMethod = "GET"
            _ = try? await URLSession(configuration: .ephemeral).data(for: pedido)
        }
        return true
    }

    /// Fora do contexto `async`: `NSLock.lock()` é indisponível lá, e com
    /// razão — ele bloqueia a thread do pool cooperativo.
    private func registra(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        abertas.append(url)
        return abertas.count - 1
    }
}

/// Uma porta que o **sistema** diz estar livre agora, e fora da faixa que
/// `MeetingOAuthTests` sorteia.
///
/// Duas regras, e as duas doem quando faltam. O kernel escolher (um socket em
/// `127.0.0.1:0`, pergunta-se qual porta ele ganhou e fecha-se) evita o
/// sorteio às cegas. E ficar **fora de 50 000–59 000** evita a única faixa em
/// que outra suíte deste pacote sorteia para o mesmo fim: duas escutas de
/// loopback na mesma porta falham com `.portBusy`, e uma falha que aparece
/// uma vez em vinte execuções é pior do que nenhuma.
private func portaLivre() -> UInt16 {
    for _ in 0..<20 {
        let porta = portaDoKernel()
        if porta > 59_000 { return porta }
    }
    return UInt16.random(in: 59_100...59_900)
}

private func portaDoKernel() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return UInt16.random(in: 59_100...59_900) }
    defer { close(fd) }
    var endereco = sockaddr_in()
    endereco.sin_family = sa_family_t(AF_INET)
    endereco.sin_port = 0
    endereco.sin_addr.s_addr = INADDR_ANY.bigEndian
    let ligado = withUnsafePointer(to: &endereco) { ponteiro in
        ponteiro.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard ligado == 0 else { return UInt16.random(in: 59_100...59_900) }
    var devolvido = sockaddr_in()
    var tamanho = socklen_t(MemoryLayout<sockaddr_in>.size)
    let leu = withUnsafeMutablePointer(to: &devolvido) { ponteiro in
        ponteiro.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &tamanho)
        }
    }
    guard leu == 0 else { return UInt16.random(in: 59_100...59_900) }
    return UInt16(bigEndian: devolvido.sin_port)
}

private func parametros(_ url: URL) -> [String: String] {
    var saida: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        saida[item.name] = item.value
    }
    return saida
}

@Suite("Zoho: a credencial sem senha")
struct ZohoMailCredentialTests {
    // MARK: A parte pura — a credencial SASL

    @Test("A credencial XOAUTH2 usa 0x01 como separador, e não espaço")
    func credencialTemOsBytesCertos() throws {
        let base64 = SASLXOAuth2.initialResponse(
            user: "marina@aempresa.com", accessToken: "1000.token"
        )
        let bytes = try #require(Data(base64Encoded: base64))
        let texto = try #require(String(data: bytes, encoding: .utf8))
        // O separador é invisível em qualquer log: errá-lo dá "Invalid
        // credentials" e manda a pessoa trocar uma senha que não existe.
        #expect(texto == "user=marina@aempresa.com\u{01}auth=Bearer 1000.token\u{01}\u{01}")
        #expect(bytes.filter { $0 == 0x01 }.count == 3)
    }

    @Test("O AUTHENTICATE do IMAP leva a resposta inicial na mesma linha, sem aspas")
    func comandoDoImap() {
        let comando = ImapWire.authenticateXOAuth2(
            tag: "A0001", user: "eu@zoho.com", accessToken: "t"
        )
        let esperado = SASLXOAuth2.initialResponse(user: "eu@zoho.com", accessToken: "t")
        #expect(comando == "A0001 AUTHENTICATE XOAUTH2 \(esperado)")
        // Base64 é átomo no IMAP: aspas em volta fariam o servidor dizer BAD.
        #expect(!comando.contains("\""))
    }

    @Test("O AUTH do SMTP usa exatamente a mesma credencial do IMAP")
    func comandoDoSmtp() {
        let smtp = SmtpWire.authXOAuth2(user: "eu@zoho.com", accessToken: "t")
        let imap = ImapWire.authenticateXOAuth2(tag: "A1", user: "eu@zoho.com", accessToken: "t")
        let credencial = SASLXOAuth2.initialResponse(user: "eu@zoho.com", accessToken: "t")
        #expect(smtp == "AUTH XOAUTH2 \(credencial)")
        #expect(imap.hasSuffix(credencial))
    }

    // MARK: A URL do consentimento

    @Test("Os escopos vão separados por vírgula — o Zoho recusa espaço")
    func urlDeAutorizacao() throws {
        let pkce = PKCEPair.make(from: Array(repeating: 7, count: 32))
        let url = configZoho.authorizationURL(
            scopes: ZohoMailAuthConfig.defaultScopes, pkce: pkce,
            state: "estado", loginHint: "marina@aempresa.com"
        )
        let itens = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        func valor(_ nome: String) -> String? { itens.first { $0.name == nome }?.value }

        #expect(url.host == "accounts.zoho.com")
        #expect(url.path == "/oauth/v2/auth")
        #expect(valor("scope") == "ZohoMail.accounts.READ,ZOHOMAIL.PROTOCOL.IMAP,"
            + "ZOHOMAIL.PROTOCOL.SMTP,ZohoMail.messages.CREATE")
        #expect(valor("scope")?.contains(" ") == false)
        // Sem estes dois não vem refresh token, e a caixa morreria em uma hora.
        #expect(valor("access_type") == "offline")
        #expect(valor("prompt") == "consent")
        #expect(valor("code_challenge_method") == "S256")
        #expect(valor("code_challenge") == pkce.challenge)
        #expect(valor("state") == "estado")
        #expect(valor("redirect_uri") == "http://127.0.0.1:53720/oauth2redirect")
        #expect(valor("login_id") == "marina@aempresa.com")
    }

    @Test("A lista de reserva é a documentada: sem o escopo de SMTP")
    func listaDeReserva() {
        #expect(ZohoMailAuthConfig.fallbackScopes
            .contains(ZohoMailAuthConfig.smtpScope) == false)
        #expect(ZohoMailAuthConfig.fallbackScopes.contains(ZohoMailAuthConfig.imapScope))
        #expect(ZohoMailAuthConfig.fallbackScopes.contains(ZohoMailAuthConfig.sendScope))
    }

    // MARK: O retorno do navegador

    @Test("O retorno com `state` de outro é recusado, e não vira login de ninguém")
    func stateConferido() {
        let url = URL(string: "http://127.0.0.1:53720/oauth2redirect?code=abc&state=outro")!
        #expect(throws: (any Error).self) {
            try ZohoMailCallback.read(url, expectedState: "o-nosso")
        }
    }

    @Test("O retorno traz o data center, e ele é o que decide tudo depois")
    func callbackTrazDataCenter() throws {
        let url = URL(
            string: "http://127.0.0.1:53720/oauth2redirect"
                + "?code=abc&state=s&location=eu&accounts-server=https%3A%2F%2Faccounts.zoho.eu"
        )!
        let retorno = try ZohoMailCallback.read(url, expectedState: "s")
        #expect(retorno.code == "abc")
        #expect(retorno.accountsServer == "https://accounts.zoho.eu")
        #expect(retorno.location == "eu")
    }

    // MARK: A troca do código, com transporte simulado

    @Test("A troca do código vai ao data center do callback e guarda o servidor")
    func trocaDoCodigoVaiAoDataCenter() async throws {
        let sessao = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json("""
            {"access_token":"1000.acesso","refresh_token":"1000.refresh",
             "expires_in":3600,"scope":"ZohoMail.accounts.READ,ZOHOMAIL.PROTOCOL.IMAP",
             "api_domain":"https://www.zohoapis.eu"}
            """)],
        ])
        let auth = ZohoMailAuth(
            config: configZoho, session: sessao, secrets: InMemorySecretStore(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        let tokens = try await auth.postToken(
            ["grant_type": "authorization_code", "code": "abc"],
            at: "https://accounts.zoho.eu", keeping: nil, keepingScopes: []
        )

        let pedido = try #require(StubURLProtocol.requests(for: sessao).first)
        // O `.eu` é o ponto: a mesma troca no `.com` volta `invalid_code`.
        #expect(pedido.host == "accounts.zoho.eu")
        #expect(tokens.accountsServer == "https://accounts.zoho.eu")
        #expect(tokens.isZohoMail)
        #expect(tokens.accessToken == "1000.acesso")
        #expect(tokens.refreshToken == "1000.refresh")
        // Escopos separados por vírgula na volta também.
        #expect(tokens.scopes == ["ZohoMail.accounts.READ", "ZOHOMAIL.PROTOCOL.IMAP"])
        // Sem o escopo de SMTP concedido, o envio não tenta o SMTP.
        #expect(tokens.canSendOverZohoSMTP == false)
    }

    @Test("A renovação vai ao MESMO data center do token guardado")
    func renovacaoVaiAoMesmoDataCenter() async throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "velho", refreshToken: "1000.refresh",
            expiresAt: Date(timeIntervalSince1970: 0),
            scopes: [ZohoMailAuthConfig.imapScope],
            accountsServer: "https://accounts.zoho.in"
        )), for: "conta")
        let sessao = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json("""
            {"access_token":"1000.novo","expires_in":3600}
            """)],
        ])
        let auth = ZohoMailAuth(
            config: configZoho, session: sessao, secrets: cofre,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let token = try await auth.renewedAccessToken(for: "conta")
        #expect(token == "1000.novo")

        let pedido = try #require(StubURLProtocol.requests(for: sessao).first)
        #expect(pedido.host == "accounts.zoho.in")
        #expect(pedido.body.contains("grant_type=refresh_token"))
        // O Zoho **não** reenvia o refresh token na renovação; perdê-lo aqui
        // mataria a conta na renovação seguinte.
        guard case .oauth(let guardados)? = try cofre.secret(for: "conta") else {
            Issue.record("o cofre perdeu os tokens"); return
        }
        #expect(guardados.refreshToken == "1000.refresh")
        #expect(guardados.accountsServer == "https://accounts.zoho.in")
        // E os escopos concedidos sobrevivem: a resposta da renovação não os
        // repete, e esquecê-los desligaria o envio por SMTP sem motivo.
        #expect(guardados.scopes == [ZohoMailAuthConfig.imapScope])
    }

    @Test("200 com `{\"error\":…}` é falha — no Zoho o status não é sinal de nada")
    func duzentosComErro() async throws {
        let sessao = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json(#"{"error":"invalid_code"}"#)],
        ])
        let auth = ZohoMailAuth(
            config: configZoho, session: sessao, secrets: InMemorySecretStore()
        )
        await #expect(throws: SyncError.autorizacaoRevogada) {
            _ = try await auth.postToken(
                ["grant_type": "authorization_code"], at: "https://accounts.zoho.com",
                keeping: nil, keepingScopes: []
            )
        }
    }

    @Test("`invalid_scope` não chega à pessoa: é o aviso de repetir sem o escopo em dúvida")
    func escopoRecusadoNaoViraErroDeConta() {
        #expect(
            ZohoMailAuth.tokenError(status: 400, name: "invalid_scope", detail: nil)
                is ZohoScopeRefused
        )
        #expect(
            ZohoMailAuth.tokenError(status: 400, name: "invalid_client", detail: nil)
                as? SyncError == .semClientID
        )
    }

    // MARK: O consentimento inteiro, com o navegador encenado

    @Test("O consentimento inteiro: o navegador volta do .eu e o token nasce lá")
    func consentimentoNoDataCenterEuropeu() async throws {
        let porta = portaLivre()
        let sessao = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json("""
            {"access_token":"1000.acesso","refresh_token":"1000.refresh","expires_in":3600,
             "scope":"ZohoMail.accounts.READ,ZOHOMAIL.PROTOCOL.IMAP,ZOHOMAIL.PROTOCOL.SMTP"}
            """)],
        ])
        let navegador = NavegadorFalso { url, _ in
            let estado = parametros(url)["state"] ?? ""
            return URL(string: "http://127.0.0.1:\(porta)/oauth2redirect"
                + "?code=c&state=\(estado)&location=eu"
                + "&accounts-server=https%3A%2F%2Faccounts.zoho.eu")
        }
        let auth = ZohoMailAuth(
            config: configZoho, session: sessao, secrets: InMemorySecretStore(),
            browser: navegador, loopback: LoopbackEndpoint(port: porta),
            now: { Date(timeIntervalSince1970: 0) }
        )

        let consentimento = try await auth.connect(loginHint: "marina@aempresa.com")
        #expect(consentimento.accountsServer == "https://accounts.zoho.eu")
        #expect(consentimento.tokens.accountsServer == "https://accounts.zoho.eu")
        #expect(consentimento.tokens.canSendOverZohoSMTP)

        let troca = try #require(StubURLProtocol.requests(for: sessao).first)
        #expect(troca.host == "accounts.zoho.eu")
        #expect(troca.body.contains("client_secret=segredo"))
        #expect(troca.body.contains("code_verifier="))
        #expect(navegador.urls.count == 1)
    }

    @Test("`invalid_scope` repete o consentimento sem o escopo de SMTP, uma vez só")
    func consentimentoRepetidoSemOEscopoDeSMTP() async throws {
        // É a aposta que o app não faz: o escopo de SMTP é o único que a
        // documentação pública do Zoho não nomeia, e um `invalid_scope` na
        // cara da pessoa derrubaria a conexão inteira por causa dele.
        let porta = portaLivre()
        let sessao = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [
                .json(#"{"error":"invalid_scope"}"#),
                .json("""
                {"access_token":"1000.acesso","refresh_token":"1000.refresh","expires_in":3600,
                 "scope":"ZohoMail.accounts.READ,ZOHOMAIL.PROTOCOL.IMAP,ZohoMail.messages.CREATE"}
                """),
            ],
        ])
        let navegador = NavegadorFalso { url, _ in
            let estado = parametros(url)["state"] ?? ""
            return URL(string: "http://127.0.0.1:\(porta)/oauth2redirect?code=c&state=\(estado)")
        }
        let auth = ZohoMailAuth(
            config: configZoho, session: sessao, secrets: InMemorySecretStore(),
            browser: navegador, loopback: LoopbackEndpoint(port: porta),
            now: { Date(timeIntervalSince1970: 0) }
        )

        let consentimento = try await auth.connect(loginHint: nil)
        #expect(navegador.urls.count == 2)
        let primeira = parametros(navegador.urls[0])["scope"]
        let segunda = parametros(navegador.urls[1])["scope"]
        #expect(primeira?.contains(ZohoMailAuthConfig.smtpScope) == true)
        #expect(segunda?.contains(ZohoMailAuthConfig.smtpScope) == false)
        #expect(segunda?.contains(ZohoMailAuthConfig.imapScope) == true)
        // E o envio sabe que não tem SMTP: ele diz a causa em vez de relatar
        // "credencial recusada" na primeira mensagem da pessoa.
        #expect(consentimento.tokens.canSendOverZohoSMTP == false)
        // Sem o `.com` no meio: nenhum data center foi anunciado, e o padrão
        // é o que o Zoho documenta.
        #expect(consentimento.accountsServer == "https://accounts.zoho.com")
    }

    // MARK: Onde fica a caixa

    @Test("Domínio próprio tenta imappro primeiro; domínio do Zoho tenta imap")
    func ordemDosCandidatos() {
        let empresa = ZohoMailEndpoints.candidates(
            accountsServer: "https://accounts.zoho.eu", address: "marina@aempresa.com"
        )
        #expect(empresa.map(\.host) == ["imappro.zoho.eu", "imap.zoho.eu"])
        #expect(empresa.allSatisfy { $0.port == 993 && $0.security == .tls })

        let pessoal = ZohoMailEndpoints.candidates(
            accountsServer: "https://accounts.zoho.com", address: "marina@zohomail.com"
        )
        // A organização **gratuita** também fala em `imap.`, e é por isso que
        // os dois candidatos existem nos dois sentidos.
        #expect(pessoal.map(\.host) == ["imap.zoho.com", "imappro.zoho.com"])
    }

    @Test("Um data center desconhecido não vira host inventado")
    func dataCenterDesconhecido() {
        #expect(ZohoMailEndpoints.imap(
            accountsServer: "https://accounts.zoho.example", organization: true
        ) == nil)
        #expect(ZohoMailEndpoints.apiBase(accountsServer: "https://accounts.zoho.example") == nil)
        #expect(ZohoMailEndpoints.apiBase(accountsServer: "https://accounts.zohocloud.ca")
            == URL(string: "https://mail.zohocloud.ca/api/"))
    }

    @Test("O SMTP da organização é smtppro — a troca ingênua de prefixo erraria")
    func smtpDoZoho() {
        #expect(ZohoMailEndpoints.smtp(forImapHost: "imappro.zoho.eu")
            == SmtpEndpoint(host: "smtppro.zoho.eu", port: 465, security: .tls))
        #expect(ZohoMailEndpoints.smtp(forImapHost: "imap.zoho.com")
            == SmtpEndpoint(host: "smtp.zoho.com", port: 465, security: .tls))
        // Nada que não seja Zoho passa por aqui: o resto segue o caminho comum.
        #expect(ZohoMailEndpoints.smtp(forImapHost: "imap.fastmail.com") == nil)

        // E é esta a função que a fila de saída chama. Sem a exceção, o
        // `SmtpDiscovery` devolveria `smtp.imappro.zoho.eu`, que não existe.
        #expect(MailboxAuthenticator.smtp(
            forImap: ImapEndpoint(host: "imappro.zoho.eu", port: 993, security: .tls)
        )?.host == "smtppro.zoho.eu")
        #expect(MailboxAuthenticator.smtp(
            forImap: ImapEndpoint(host: "imap.fastmail.com", port: 993, security: .tls)
        )?.host == "smtp.fastmail.com")
    }

    // MARK: Quem decide LOGIN × XOAUTH2

    @Test("O cofre decide a forma de autenticar, e nada mais")
    func formaVemDoCofre() throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.password("senha-de-app"), for: "com-senha")
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "a", refreshToken: "r", expiresAt: .distantFuture,
            accountsServer: "https://accounts.zoho.com"
        )), for: "com-token")
        // Token do Google numa conta IMAP não existe hoje, e inventar um
        // caminho para ele seria adivinhar: a resposta é "reconecte".
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "a", refreshToken: "r", expiresAt: .distantFuture
        )), for: "sem-data-center")

        let autenticador = MailboxAuthenticator(secrets: cofre)
        #expect(try autenticador.forma(for: "com-senha") == .senha)
        #expect(try autenticador.forma(for: "com-token") == .xoauth2)
        #expect(throws: SyncError.autenticacao) {
            _ = try autenticador.forma(for: "sem-data-center")
        }
        #expect(throws: SyncError.autenticacao) {
            _ = try autenticador.forma(for: "inexistente")
        }
    }
}

@Suite("Zoho: o XOAUTH2 no fio")
struct ZohoXOAuth2WireTests {
    @Test("Token aceito autentica sem nenhum LOGIN na conexão")
    func autenticaComToken() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "AUTHENTICATE": ["TAG OK Success"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        try await sessao.authenticateXOAuth2(user: "eu@zoho.com", accessToken: "1000.token")
        await sessao.logout()

        let credencial = SASLXOAuth2.initialResponse(user: "eu@zoho.com", accessToken: "1000.token")
        #expect(servidor.commands.contains { $0.hasSuffix("AUTHENTICATE XOAUTH2 \(credencial)") })
        #expect(servidor.commands.contains { $0.contains(" LOGIN ") } == false)
    }

    @Test("A continuação da recusa é respondida com linha vazia, e a frase do servidor sobe")
    func continuacaoDaRecusa() async throws {
        // É o caso que trava a conexão quando o cliente não responde: o
        // servidor fica esperando, o comando morre de teto de tempo e o app
        // relata silêncio do servidor onde houve credencial recusada.
        let servidor = FakeImapServer(script: .init(
            replies: [
                "AUTHENTICATE": ["+ eyJzdGF0dXMiOiI0MDEifQ=="],
                FakeImapServer.chaveDaLinhaVazia: [
                    "TAG NO [AUTHENTICATIONFAILED] Invalid credentials(Failure)",
                ],
                "LOGOUT": ["TAG OK LOGOUT completed"],
            ]
        ))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        await #expect(throws: SyncError.loginRecusado(
            resposta: "[AUTHENTICATIONFAILED] Invalid credentials(Failure)"
        )) {
            try await sessao.authenticateXOAuth2(user: "eu@zoho.com", accessToken: "vencido")
        }
        await sessao.logout()
        #expect(servidor.commands.contains("<linha vazia>"))
    }

    @Test("Recusa com token vencido dispara UM refresh e autentica na segunda")
    func replayDepoisDaRecusa() async throws {
        // O espelho do replay pós-401 do Gmail: o token no cofre pode estar
        // morto do lado do servidor enquanto este Mac ainda o considera
        // válido. Sem o replay, uma diferença de relógio derrubaria a conta
        // para a faixa de "Reconectar".
        let servidor = FakeImapServer(script: .init(
            replies: [
                FakeImapServer.chaveDaLinhaVazia: [
                    "TAG NO [AUTHENTICATIONFAILED] Invalid credentials(Failure)",
                ],
                "LOGOUT": ["TAG OK LOGOUT completed"],
            ],
            rounds: [
                "AUTHENTICATE": [
                    ["+ eyJzdGF0dXMiOiI0MDEifQ=="],
                    ["TAG OK Success"],
                ],
            ]
        ))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "1000.vencido", refreshToken: "1000.refresh",
            // Vale por uma hora **segundo este Mac** — é exatamente o caso em
            // que `accessToken(for:)` não renova e o servidor recusa.
            expiresAt: Date(timeIntervalSince1970: 10_000),
            accountsServer: "https://accounts.zoho.com"
        )), for: "conta")
        let http = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json(#"{"access_token":"1000.novo","expires_in":3600}"#)],
        ])
        let auth = ZohoMailAuth(
            config: configZoho, session: http, secrets: cofre,
            now: { Date(timeIntervalSince1970: 0) }
        )
        let autenticador = MailboxAuthenticator(secrets: cofre, zoho: auth)

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        try await autenticador.login(sessao, accountID: "conta", address: "eu@zoho.com")
        await sessao.logout()

        // Uma renovação, e só uma.
        #expect(StubURLProtocol.requests(for: http).count == 1)
        let novo = SASLXOAuth2.initialResponse(user: "eu@zoho.com", accessToken: "1000.novo")
        #expect(servidor.commands.contains { $0.hasSuffix("AUTHENTICATE XOAUTH2 \(novo)") })
    }

    @Test("No SMTP o token entra pelo AUTH XOAUTH2, sem precisar do anúncio no EHLO")
    func smtpAutenticaComToken() async throws {
        // O EHLO deste servidor anuncia só `PLAIN` — é o caso real da
        // submissão do Zoho, e recusar antes de tentar deixaria a caixa sem
        // envio por causa de uma linha que o servidor não publicou.
        let servidor = FakeSmtpServer(script: .init(replies: [
            "EHLO": ["250-okamiuni.falso", "250 AUTH PLAIN"],
            "AUTH": ["235 2.7.0 autenticado"],
            "QUIT": ["221 tchau"],
        ]))
        let porta = try servidor.start()
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { servidor.stop(); encerra(grupo) }

        let sessao = try await SmtpSession.connect(
            endpoint: SmtpEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        try await sessao.loginXOAuth2(user: "eu@zoho.com", accessToken: "1000.token")
        await sessao.quit()

        let credencial = SASLXOAuth2.initialResponse(user: "eu@zoho.com", accessToken: "1000.token")
        #expect(servidor.comandos.contains("AUTH XOAUTH2 \(credencial)"))
    }

    @Test("O 334 do SMTP é recusa: linha vazia, 535, e `autenticacao`")
    func smtpRecusaComContinuacao() async throws {
        let servidor = FakeSmtpServer(script: .init(
            replies: [
                "EHLO": ["250-okamiuni.falso", "250 AUTH PLAIN"],
                "AUTH": ["334 eyJzdGF0dXMiOiI0MDEifQ=="],
                FakeSmtpServer.chaveDaLinhaVazia: ["535 5.7.8 Authentication credentials invalid"],
                "QUIT": ["221 tchau"],
            ]
        ))
        let porta = try servidor.start()
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { servidor.stop(); encerra(grupo) }

        let sessao = try await SmtpSession.connect(
            endpoint: SmtpEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        await #expect(throws: SyncError.autenticacao) {
            try await sessao.loginXOAuth2(user: "eu@zoho.com", accessToken: "vencido")
        }
        await sessao.quit()
        // Sem a linha vazia o servidor fica esperando e o envio morre de teto
        // de tempo, culpando a rede por uma credencial recusada.
        #expect(servidor.comandos.contains(""))
    }

    @Test("Conta com senha de app continua falando LOGIN — nada mudou para ela")
    func contaComSenhaContinuaNoLogin() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let cofre = InMemorySecretStore()
        try cofre.store(.password("senha-de-app"), for: "conta")
        let autenticador = MailboxAuthenticator(secrets: cofre)

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        try await autenticador.login(sessao, accountID: "conta", address: "eu@x.com")
        await sessao.logout()

        #expect(servidor.commands.contains { $0.contains("LOGIN \"eu@x.com\"") })
        #expect(servidor.commands.contains { $0.contains("AUTHENTICATE") } == false)
    }
}
