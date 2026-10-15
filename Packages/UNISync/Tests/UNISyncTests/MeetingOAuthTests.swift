import Foundation
import Testing
import UNICore
@testable import UNISync

/// Um apresentador que devolve o redirect que o roteiro mandar, sem abrir
/// navegador nenhum — e que **grava** a URL de autorização, que é o que
/// metade destes testes precisa afirmar.
private final class RecordingPresenter: AuthorizationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let reply: @Sendable (URL) throws -> URL

    init(reply: @Sendable @escaping (URL) throws -> URL) {
        self.reply = reply
    }

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        record(url)
        return try reply(url)
    }

    private func record(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var lastURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls.last
    }

    var scheme: String?
}

/// Um navegador de mentira: grava a URL que receberia e dispara o redirect
/// contra a escuta de loopback de verdade.
private final class RecordingBrowser: SystemBrowserOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    /// O que fazer com a URL de autorização. Devolve a URL de redirect que o
    /// "navegador" vai buscar, ou `nil` para não buscar nada.
    private let redirect: @Sendable (URL) -> URL?

    init(redirect: @Sendable @escaping (URL) -> URL?) {
        self.redirect = redirect
    }

    func open(_ url: URL) async -> Bool {
        record(url)
        guard let destino = redirect(url) else { return true }
        // Bate na escuta como um navegador bateria: um GET de verdade em
        // 127.0.0.1. É o que torna este teste uma prova de que o ouvinte
        // funciona, e não de que um dublê funciona.
        Task.detached {
            var pedido = URLRequest(url: destino)
            pedido.httpMethod = "GET"
            _ = try? await URLSession(configuration: .ephemeral).data(for: pedido)
        }
        return true
    }

    private func record(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var lastURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls.last
    }
}

private func query(_ url: URL) -> [String: String] {
    var saida: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        saida[item.name] = item.value
    }
    return saida
}

private func field(_ body: String, _ name: String) -> String? {
    for par in body.split(separator: "&") {
        let partes = par.split(separator: "=", maxSplits: 1)
        guard partes.count == 2, partes[0] == name else { continue }
        return String(partes[1]).replacingOccurrences(of: "%2F", with: "/")
    }
    return nil
}

private func pedido(
    service: MeetingService, title: String = "Revisão"
) -> MeetingRoomRequest {
    let start = Date(timeIntervalSince1970: 1_788_163_200)
    return MeetingRoomRequest(
        service: service,
        account: Account(
            id: "a", address: "a@x.com", displayName: "A",
            provider: .imap, host: "x",
            tintLightHex: "#000", tintDarkHex: "#fff"
        ),
        title: title,
        start: start,
        end: start.addingTimeInterval(1_800)
    )
}

/// Uma porta alta e distinta por teste: 53720 é a de produção, e dois testes
/// rodando em paralelo nela brigariam.
private func portaLivre() -> UInt16 {
    UInt16.random(in: 50_000...59_000)
}

@Suite("Ouvinte de loopback do OAuth")
struct LoopbackRedirectListenerTests {
    @Test("Recebe um GET de verdade em 127.0.0.1 e devolve a URL inteira")
    func receivesRealRequest() async throws {
        let porta = portaLivre()
        let escuta = LoopbackRedirectListener(port: porta)
        try escuta.start()
        defer { escuta.cancel() }

        #expect(escuta.redirectURI == "http://127.0.0.1:\(porta)/oauth2redirect")

        let alvo = URL(string: "\(escuta.redirectURI)?code=abc123&state=xyz")!
        Task.detached {
            _ = try? await URLSession(configuration: .ephemeral).data(from: alvo)
        }

        let recebido = try await escuta.wait(timeout: 10)
        let itens = query(recebido)
        #expect(itens["code"] == "abc123")
        #expect(itens["state"] == "xyz")
        #expect(recebido.path == "/oauth2redirect")
    }

    @Test("A página de retorno é em PT-BR e não carrega o código na URL")
    func returnsPortuguesePage() async throws {
        let porta = portaLivre()
        let escuta = LoopbackRedirectListener(port: porta)
        try escuta.start()
        defer { escuta.cancel() }

        let alvo = URL(string: "\(escuta.redirectURI)?code=segredo&state=s")!
        async let pagina = URLSession(configuration: .ephemeral).data(from: alvo)
        _ = try await escuta.wait(timeout: 10)
        let (dados, _) = try await pagina
        let html = try #require(String(data: dados, encoding: .utf8))

        #expect(html.contains("Pode voltar ao OkamiUNI"))
        #expect(html.contains("lang=\"pt-BR\""))
        // O código fica em memória; o HTML que o navegador — e qualquer
        // extensão nele — enxerga não o contém.
        #expect(!html.contains("segredo"))
    }

    @Test("Um caminho que não é o nosso não termina a espera")
    func ignoresOtherPaths() async throws {
        let porta = portaLivre()
        let escuta = LoopbackRedirectListener(port: porta)
        try escuta.start()
        defer { escuta.cancel() }

        let favicon = URL(string: "http://127.0.0.1:\(porta)/favicon.ico")!
        _ = try? await URLSession(configuration: .ephemeral).data(from: favicon)

        let alvo = URL(string: "\(escuta.redirectURI)?code=ok&state=s")!
        Task.detached {
            _ = try? await URLSession(configuration: .ephemeral).data(from: alvo)
        }
        let recebido = try await escuta.wait(timeout: 10)
        #expect(query(recebido)["code"] == "ok")
    }

    @Test("Porta ocupada dá erro que diz qual porta é")
    func reportsBusyPort() async throws {
        let porta = portaLivre()
        let primeira = LoopbackRedirectListener(port: porta)
        try primeira.start()
        defer { primeira.cancel() }

        let segunda = LoopbackRedirectListener(port: porta)
        // O `NWListener` pode recusar no `init` ou só ao entrar em `.failed`;
        // os dois caminhos chegam ao mesmo erro, e o teste aceita os dois.
        var erro: (any Error)?
        do {
            try segunda.start()
            _ = try await segunda.wait(timeout: 10)
        } catch {
            erro = error
        }
        segunda.cancel()
        let encontrado = try #require(erro as? LoopbackRedirectError)
        #expect(encontrado == .portBusy(porta))
        #expect(encontrado.errorDescription?.contains("\(porta)") == true)
    }

    @Test("O prazo vence com erro próprio e fecha a porta")
    func timesOut() async throws {
        let porta = portaLivre()
        let escuta = LoopbackRedirectListener(port: porta)
        try escuta.start()
        await #expect(throws: LoopbackRedirectError.timedOut) {
            // O mínimo imposto é 1 s; o teste mede que o caminho existe, não
            // o relógio.
            _ = try await escuta.wait(timeout: 0)
        }
        // Com a porta liberada, outra escuta sobe no mesmo número.
        let segunda = LoopbackRedirectListener(port: porta)
        try segunda.start()
        segunda.cancel()
    }

    @Test("Cancelar derruba a espera")
    func cancels() async throws {
        let porta = portaLivre()
        let escuta = LoopbackRedirectListener(port: porta)
        try escuta.start()
        Task.detached { escuta.cancel() }
        await #expect(throws: CancellationError.self) {
            _ = try await escuta.wait(timeout: 30)
        }
    }
}

@Suite("Data centers do Zoho")
struct ZohoDataCenterTests {
    @Test("accounts.zoho.<dc> vira meeting.zoho.<dc> nos nove data centers")
    func mapsEveryDataCenter() {
        let esperado: [String: String] = [
            "https://accounts.zoho.com": "meeting.zoho.com",
            "https://accounts.zoho.eu": "meeting.zoho.eu",
            "https://accounts.zoho.in": "meeting.zoho.in",
            "https://accounts.zoho.com.au": "meeting.zoho.com.au",
            "https://accounts.zoho.jp": "meeting.zoho.jp",
            "https://accounts.zohocloud.ca": "meeting.zohocloud.ca",
            "https://accounts.zoho.sa": "meeting.zoho.sa",
            "https://accounts.zoho.uk": "meeting.zoho.uk",
            "https://accounts.zoho.com.cn": "meeting.zoho.com.cn",
        ]
        for (servidor, host) in esperado {
            #expect(ZohoDataCenter.meetingHost(accountsServer: servidor) == host)
        }
        #expect(esperado.count == ZohoDataCenter.domains.count)
    }

    @Test("Sem esquema também vale; domínio desconhecido devolve nada")
    func normalizesAndRefuses() {
        #expect(ZohoDataCenter.meetingHost(accountsServer: "accounts.zoho.eu") == "meeting.zoho.eu")
        #expect(ZohoDataCenter.canonicalAccountsServer("ACCOUNTS.ZOHO.EU") == "https://accounts.zoho.eu")
        #expect(ZohoDataCenter.meetingHost(accountsServer: "accounts.zoho.example") == nil)
        #expect(ZohoDataCenter.meetingHost(accountsServer: "evil.com") == nil)
        #expect(ZohoDataCenter.canonicalAccountsServer("") == nil)
    }
}

@Suite("OAuth de usuário do Zoom")
@MainActor
struct ZoomConnectorTests {
    private func vault() -> MeetingTokenVault {
        MeetingTokenVault(secrets: InMemorySecretStore())
    }

    @Test("A URL de autorização leva PKCE S256, o escopo e o redirect de loopback")
    func authorizationURL() async throws {
        let porta = portaLivre()
        let session = StubURLProtocol.session(routes: [
            "/oauth/token": [.json(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#)],
            "/v2/users/me": [.json(#"{"email":"marcos@okamiops.com"}"#)],
        ])
        let navegador = RecordingBrowser { url in
            let state = query(url)["state"]!
            return URL(string: "http://127.0.0.1:\(porta)/oauth2redirect?code=c0de&state=\(state)")
        }
        let conector = ZoomConnector(
            clientID: "zoom-client",
            session: session,
            vault: vault(),
            browser: navegador,
            loopback: LoopbackEndpoint(port: porta),
            apiBase: URL(string: "https://api.zoom.example/v2/")!,
            authorizationEndpoint: URL(string: "https://zoom.example/oauth/authorize")!,
            tokenEndpoint: URL(string: "https://zoom.example/oauth/token")!
        )
        #expect(conector.isAvailable)

        let conta = try await conector.connect()
        #expect(conta == "marcos@okamiops.com")

        let autorizacao = try #require(navegador.lastURL)
        let itens = query(autorizacao)
        #expect(itens["client_id"] == "zoom-client")
        #expect(itens["response_type"] == "code")
        #expect(itens["code_challenge_method"] == "S256")
        #expect(itens["code_challenge"]?.isEmpty == false)
        #expect(itens["scope"] == "meeting:write:meeting")
        #expect(itens["redirect_uri"] == "http://127.0.0.1:\(porta)/oauth2redirect")
        #expect(itens["state"]?.isEmpty == false)
    }

    @Test("A troca do código vai sem Authorization: cliente público não tem segredo")
    func exchangeHasNoClientSecret() async throws {
        let porta = portaLivre()
        let session = StubURLProtocol.session(routes: [
            "/oauth/token": [.json(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#)],
            "/v2/users/me": [.json(#"{"email":"m@okamiops.com"}"#)],
        ])
        let navegador = RecordingBrowser { url in
            URL(string: "http://127.0.0.1:\(porta)/oauth2redirect?code=c0de&state=\(query(url)["state"]!)")
        }
        let conector = ZoomConnector(
            clientID: "zoom-client",
            session: session,
            vault: vault(),
            browser: navegador,
            loopback: LoopbackEndpoint(port: porta),
            apiBase: URL(string: "https://api.zoom.example/v2/")!,
            authorizationEndpoint: URL(string: "https://zoom.example/oauth/authorize")!,
            tokenEndpoint: URL(string: "https://zoom.example/oauth/token")!
        )
        _ = try await conector.connect()

        let troca = try #require(
            StubURLProtocol.requests(for: session).first { $0.path == "/oauth/token" }
        )
        #expect(troca.authorization == nil)
        #expect(field(troca.body, "grant_type") == "authorization_code")
        #expect(field(troca.body, "code") == "c0de")
        #expect(field(troca.body, "client_id") == "zoom-client")
        #expect(field(troca.body, "code_verifier")?.isEmpty == false)
        #expect(troca.body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A\(porta)"))
        #expect(!troca.body.contains("client_secret"))
    }

    @Test("Um `state` trocado é recusado")
    func rejectsForgedState() async throws {
        let porta = portaLivre()
        let session = StubURLProtocol.session(routes: [:])
        let navegador = RecordingBrowser { _ in
            URL(string: "http://127.0.0.1:\(porta)/oauth2redirect?code=injetado&state=do-atacante")
        }
        let conector = ZoomConnector(
            clientID: "zoom-client",
            session: session,
            vault: vault(),
            browser: navegador,
            loopback: LoopbackEndpoint(port: porta),
            authorizationEndpoint: URL(string: "https://zoom.example/oauth/authorize")!,
            tokenEndpoint: URL(string: "https://zoom.example/oauth/token")!
        )
        await #expect(throws: MeetingConnectorError.self) {
            _ = try await conector.connect()
        }
        // Nada foi trocado: o código do atacante nunca virou token.
        #expect(StubURLProtocol.requests(for: session).isEmpty)
    }

    @Test("Sem client ID não está disponível e connect lança")
    func unavailableWithoutClientID() async {
        let conector = ZoomConnector(
            clientID: nil, session: StubURLProtocol.session(), vault: vault(),
            browser: RecordingBrowser { _ in nil }
        )
        #expect(conector.isAvailable == false)
        await #expect(throws: MeetingConnectorError.missingClientID(.zoom)) {
            _ = try await conector.connect()
        }
    }

    @Test("Renova antes de vencer e guarda o refresh token rotacionado")
    func refreshesExpiredToken() async throws {
        let cofre = vault()
        let agora = Date(timeIntervalSince1970: 1_800_000_000)
        try cofre.save(
            MeetingTokens(
                accessToken: "velho", refreshToken: "r1",
                expiresAt: agora.addingTimeInterval(-10), account: "m@okamiops.com"
            ),
            for: .zoom
        )
        let session = StubURLProtocol.session(routes: [
            "/oauth/token": [.json(
                #"{"access_token":"novo","refresh_token":"r2","expires_in":3600}"#
            )],
        ])
        let motor = MeetingOAuthEngine(
            config: MeetingOAuthConfig(
                service: .zoom, clientID: "zoom-client",
                authorizationEndpoint: URL(string: "https://zoom.example/oauth/authorize")!,
                tokenEndpoint: URL(string: "https://zoom.example/oauth/token")!,
                redirectURI: "http://127.0.0.1:53720/oauth2redirect",
                scopes: ZoomConnector.scopes
            ),
            session: session, vault: cofre, now: { agora }
        )
        #expect(try await motor.accessToken() == "novo")

        let renovacao = try #require(StubURLProtocol.requests(for: session).first)
        #expect(field(renovacao.body, "grant_type") == "refresh_token")
        #expect(field(renovacao.body, "refresh_token") == "r1")
        #expect(!renovacao.body.contains("client_secret"))
        // O Zoom rotaciona: o novo tem de ficar no cofre, ou a próxima
        // renovação usaria um refresh token já queimado.
        #expect(cofre.load(.zoom)?.refreshToken == "r2")
        #expect(cofre.load(.zoom)?.account == "m@okamiops.com")
    }

    @Test("Refresh token morto limpa o cofre em vez de deixar lixo")
    func deadRefreshTokenClearsVault() async throws {
        let cofre = vault()
        let agora = Date(timeIntervalSince1970: 1_800_000_000)
        try cofre.save(
            MeetingTokens(accessToken: "v", refreshToken: "r", expiresAt: agora.addingTimeInterval(-1)),
            for: .zoom
        )
        let session = StubURLProtocol.session(routes: [
            "/oauth/token": [.json(#"{"error":"invalid_grant"}"#, status: 400)],
        ])
        let motor = MeetingOAuthEngine(
            config: MeetingOAuthConfig(
                service: .zoom, clientID: "c",
                authorizationEndpoint: URL(string: "https://zoom.example/oauth/authorize")!,
                tokenEndpoint: URL(string: "https://zoom.example/oauth/token")!,
                redirectURI: "http://127.0.0.1:53720/oauth2redirect",
                scopes: ZoomConnector.scopes
            ),
            session: session, vault: cofre, now: { agora }
        )
        await #expect(throws: MeetingRoomError.notConnected(.zoom)) {
            _ = try await motor.accessToken()
        }
        #expect(cofre.load(.zoom) == nil)
    }

    @Test("Desconectar apaga do cofre")
    func disconnectClearsVault() async throws {
        let cofre = vault()
        try cofre.save(
            MeetingTokens(accessToken: "a", expiresAt: .distantFuture, account: "m@x.com"),
            for: .zoom
        )
        let conector = ZoomConnector(
            clientID: "c", session: StubURLProtocol.session(), vault: cofre,
            browser: RecordingBrowser { _ in nil }
        )
        #expect(await conector.currentAccount() == "m@x.com")
        await conector.disconnect()
        #expect(await conector.currentAccount() == nil)
        #expect(cofre.load(.zoom) == nil)
    }

    @Test("Cria a reunião em users/me/meetings e devolve o join_url")
    func mintsRoom() async throws {
        let session = StubURLProtocol.session(routes: [
            "/v2/users/me/meetings": [.json(
                #"{"join_url":"https://zoom.us/j/987654321?pwd=x"}"#
            )],
        ])
        let link = try await ZoomMeetingClient(
            session: session,
            accessToken: { "zoom-token" },
            apiBase: URL(string: "https://api.zoom.example/v2/")!
        ).create(pedido(service: .zoom))

        #expect(link == "https://zoom.us/j/987654321?pwd=x")
        let criacao = try #require(StubURLProtocol.requests(for: session).first)
        #expect(criacao.authorization == "Bearer zoom-token")
        #expect(criacao.body.contains("\"type\":2"))
        #expect(criacao.body.contains("Revisão"))
    }

    @Test("Resposta sem link não devolve sala")
    func refusesRoomWithoutLink() async {
        let session = StubURLProtocol.session(routes: [
            "/v2/users/me/meetings": [.json(#"{"id":123}"#)],
        ])
        await #expect(throws: MeetingRoomError.self) {
            _ = try await ZoomMeetingClient(
                session: session, accessToken: { "t" },
                apiBase: URL(string: "https://api.zoom.example/v2/")!
            ).create(pedido(service: .zoom))
        }
    }
}

@Suite("OAuth de usuário do Microsoft Teams")
@MainActor
struct TeamsConnectorTests {
    private func vault() -> MeetingTokenVault {
        MeetingTokenVault(secrets: InMemorySecretStore())
    }

    @Test("A autorização usa tenant common, PKCE e os quatro escopos")
    func authorizationURL() async throws {
        let session = StubURLProtocol.session(routes: [
            "/common/oauth2/v2.0/token": [.json(
                #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#
            )],
            "/v1.0/me": [.json(#"{"mail":"marcos@okamiops.com"}"#)],
        ])
        let apresentador = RecordingPresenter { url in
            URL(string: "com.okamiops.okamiuni:/oauth2redirect?code=c0de&state=\(query(url)["state"]!)")!
        }
        let conector = TeamsConnector(
            clientID: "ms-client",
            session: session,
            vault: vault(),
            presenter: apresentador,
            graphBase: URL(string: "https://graph.example/v1.0/")!,
            authorizationEndpoint: URL(
                string: "https://login.example/common/oauth2/v2.0/authorize"
            )!,
            tokenEndpoint: URL(string: "https://login.example/common/oauth2/v2.0/token")!
        )
        let conta = try await conector.connect()
        #expect(conta == "marcos@okamiops.com")

        let autorizacao = try #require(apresentador.lastURL)
        #expect(autorizacao.path == "/common/oauth2/v2.0/authorize")
        let itens = query(autorizacao)
        #expect(itens["client_id"] == "ms-client")
        #expect(itens["code_challenge_method"] == "S256")
        #expect(itens["redirect_uri"] == "com.okamiops.okamiuni:/oauth2redirect")
        #expect(
            itens["scope"]
                == "offline_access Calendars.ReadWrite OnlineMeetings.ReadWrite User.Read"
        )

        let troca = try #require(
            StubURLProtocol.requests(for: session).first { $0.path.hasSuffix("/token") }
        )
        #expect(!troca.body.contains("client_secret"))
        #expect(field(troca.body, "code_verifier")?.isEmpty == false)
    }

    @Test("userPrincipalName serve quando a conta não tem `mail`")
    func fallsBackToUPN() async throws {
        let session = StubURLProtocol.session(routes: [
            "/common/oauth2/v2.0/token": [.json(
                #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#
            )],
            "/v1.0/me": [.json(#"{"userPrincipalName":"pessoa@outlook.com"}"#)],
        ])
        let conector = TeamsConnector(
            clientID: "ms-client", session: session, vault: vault(),
            presenter: RecordingPresenter { url in
                URL(string: "com.okamiops.okamiuni:/oauth2redirect?code=c&state=\(query(url)["state"]!)")!
            },
            graphBase: URL(string: "https://graph.example/v1.0/")!,
            authorizationEndpoint: URL(string: "https://login.example/common/oauth2/v2.0/authorize")!,
            tokenEndpoint: URL(string: "https://login.example/common/oauth2/v2.0/token")!
        )
        #expect(try await conector.connect() == "pessoa@outlook.com")
    }

    @Test("Conta de trabalho cria em /me/onlineMeetings e nem toca em /me/events")
    func usesOnlineMeetings() async throws {
        let session = StubURLProtocol.session(routes: [
            "/v1.0/me/onlineMeetings": [.json(
                #"{"joinWebUrl":"https://teams.microsoft.com/l/meetup-join/abc"}"#
            )],
        ])
        let link = try await TeamsMeetingClient(
            session: session, accessToken: { "graph-token" },
            graphBase: URL(string: "https://graph.example/v1.0/")!
        ).create(pedido(service: .teams))

        #expect(link == "https://teams.microsoft.com/l/meetup-join/abc")
        let caminhos = StubURLProtocol.requests(for: session).map(\.path)
        #expect(caminhos == ["/v1.0/me/onlineMeetings"])
    }

    @Test("Conta pessoal cai para /me/events com isOnlineMeeting e sem provider")
    func fallsBackToCalendarEvent() async throws {
        let session = StubURLProtocol.session(routes: [
            "/v1.0/me/onlineMeetings": [.json(
                #"{"error":{"code":"Forbidden","message":"not supported for personal accounts"}}"#,
                status: 403
            )],
            "/v1.0/me/events": [.json(
                #"{"id":"e1","onlineMeeting":{"joinUrl":"https://teams.live.com/meet/9876"}}"#
            )],
        ])
        let link = try await TeamsMeetingClient(
            session: session, accessToken: { "graph-token" },
            graphBase: URL(string: "https://graph.example/v1.0/")!
        ).create(pedido(service: .teams))

        #expect(link == "https://teams.live.com/meet/9876")
        let pedidos = StubURLProtocol.requests(for: session)
        #expect(pedidos.map(\.path) == ["/v1.0/me/onlineMeetings", "/v1.0/me/events"])
        let evento = try #require(pedidos.last)
        #expect(evento.body.contains("\"isOnlineMeeting\":true"))
        // Mandar `teamsForBusiness` numa conta pessoal faz o Graph recusar o
        // evento inteiro. A ausência é de propósito.
        #expect(!evento.body.contains("onlineMeetingProvider"))
    }

    @Test("Sem link nos dois caminhos, o erro diz isso e nenhuma sala é devolvida")
    func refusesRoomWithoutLink() async throws {
        let session = StubURLProtocol.session(routes: [
            "/v1.0/me/onlineMeetings": [.json(#"{}"#, status: 404)],
            "/v1.0/me/events": [.json(#"{"id":"e1"}"#)],
        ])
        var capturado: (any Error)?
        do {
            _ = try await TeamsMeetingClient(
                session: session, accessToken: { "t" },
                graphBase: URL(string: "https://graph.example/v1.0/")!
            ).create(pedido(service: .teams))
        } catch {
            capturado = error
        }
        let erro = try #require(capturado as? MeetingRoomError)
        let frase = try #require(erro.errorDescription)
        #expect(frase.contains("não devolveu link de entrada"))
    }
}

@Suite("OAuth de usuário do Zoho Meeting")
@MainActor
struct ZohoConnectorTests {
    private func vault() -> MeetingTokenVault {
        MeetingTokenVault(secrets: InMemorySecretStore())
    }

    @Test("A autorização pede vírgula nos escopos, offline e consent")
    func authorizationURL() async throws {
        let porta = portaLivre()
        let cofre = vault()
        let session = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json(
                #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#
            )],
            "/api/v2/user.json": [.json(
                #"{"userDetails":{"zsoid":123456,"emailId":"marcos@okamiops.com"}}"#
            )],
        ])
        let navegador = RecordingBrowser { url in
            URL(string: "http://127.0.0.1:\(porta)/oauth2redirect?code=c0de&state=\(query(url)["state"]!)&location=us&accounts-server=https%3A%2F%2Faccounts.zoho.com")
        }
        let conector = ZohoConnector(
            clientID: "zoho-client",
            clientSecret: "zoho-secret",
            session: session,
            vault: cofre,
            browser: navegador,
            loopback: LoopbackEndpoint(port: porta),
            authorizationEndpoint: URL(string: "https://accounts.zoho.example/oauth/v2/auth")!
        )
        #expect(conector.isAvailable)
        #expect(try await conector.connect() == "marcos@okamiops.com")

        let itens = query(try #require(navegador.lastURL))
        #expect(itens["scope"] == "ZohoMeeting.meeting.CREATE,ZohoMeeting.manageOrg.READ")
        #expect(itens["access_type"] == "offline")
        #expect(itens["prompt"] == "consent")
        #expect(itens["code_challenge_method"] == "S256")
        #expect(itens["redirect_uri"] == "http://127.0.0.1:\(porta)/oauth2redirect")

        let guardados = try #require(cofre.load(.zoho))
        #expect(guardados.accountsServer == "https://accounts.zoho.com")
        #expect(guardados.zsoid == "123456")
    }

    @Test("Sem o segredo não está disponível: o Zoho exige PKCE e secret")
    func needsBothCredentials() async {
        let conector = ZohoConnector(
            clientID: "zoho-client", clientSecret: nil,
            session: StubURLProtocol.session(), vault: vault(),
            browser: RecordingBrowser { _ in nil }
        )
        #expect(conector.isAvailable == false)
        await #expect(throws: MeetingConnectorError.missingClientID(.zoho)) {
            _ = try await conector.connect()
        }
    }

    @Test("A troca leva client_secret e PKCE juntos")
    func exchangeCarriesSecretAndPKCE() async throws {
        let porta = portaLivre()
        let session = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json(
                #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#
            )],
            "/api/v2/user.json": [.json(#"{"userDetails":{"zsoid":"7","emailId":"m@x.com"}}"#)],
        ])
        let conector = ZohoConnector(
            clientID: "zoho-client", clientSecret: "zoho-secret",
            session: session, vault: vault(),
            browser: RecordingBrowser { url in
                URL(string: "http://127.0.0.1:\(porta)/oauth2redirect?code=c&state=\(query(url)["state"]!)")
            },
            loopback: LoopbackEndpoint(port: porta),
            authorizationEndpoint: URL(string: "https://accounts.zoho.example/oauth/v2/auth")!
        )
        _ = try await conector.connect()

        let troca = try #require(
            StubURLProtocol.requests(for: session).first { $0.path == "/oauth/v2/token" }
        )
        #expect(field(troca.body, "client_secret") == "zoho-secret")
        #expect(field(troca.body, "code_verifier")?.isEmpty == false)
        #expect(field(troca.body, "grant_type") == "authorization_code")
    }

    /// **O teste que importa no Zoho.** Uma conta europeia não existe em
    /// `zoho.com`: a troca do token tem de ir para `accounts.zoho.eu` e a
    /// criação da sala para `meeting.zoho.eu`. Trocar o `.eu` pelo `.com` no
    /// meio do caminho dá `invalid_code` sem dizer por quê.
    @Test("Conta no DC europeu troca em accounts.zoho.eu e cria em meeting.zoho.eu")
    func europeanDataCenterEndToEnd() async throws {
        let porta = portaLivre()
        let cofre = vault()
        let session = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [
                .json(#"{"access_token":"a-eu","refresh_token":"r-eu","expires_in":3600}"#),
                .json(#"{"access_token":"a-eu-2","expires_in":3600}"#),
            ],
            "/api/v2/user.json": [.json(
                #"{"userDetails":{"zsoid":889900,"emailId":"anne@exemplo.eu"}}"#
            )],
            "/api/v2/889900/sessions.json": [.json(
                #"{"session":{"joinLink":"https://meeting.zoho.eu/meeting/join?key=42"}}"#
            )],
        ])
        let conector = ZohoConnector(
            clientID: "zoho-client", clientSecret: "zoho-secret",
            session: session, vault: cofre,
            browser: RecordingBrowser { url in
                URL(string: "http://127.0.0.1:\(porta)/oauth2redirect?code=c&state=\(query(url)["state"]!)&location=eu&accounts-server=https%3A%2F%2Faccounts.zoho.eu")
            },
            loopback: LoopbackEndpoint(port: porta),
            authorizationEndpoint: URL(string: "https://accounts.zoho.com/oauth/v2/auth")!
        )
        #expect(try await conector.connect() == "anne@exemplo.eu")

        let pedidos = StubURLProtocol.requests(for: session)
        let troca = try #require(pedidos.first { $0.path == "/oauth/v2/token" })
        #expect(troca.host == "accounts.zoho.eu")
        let usuario = try #require(pedidos.first { $0.path == "/api/v2/user.json" })
        #expect(usuario.host == "meeting.zoho.eu")
        #expect(usuario.authorization == "Zoho-oauthtoken a-eu")

        let guardados = try #require(cofre.load(.zoho))
        #expect(guardados.accountsServer == "https://accounts.zoho.eu")
        #expect(guardados.zsoid == "889900")

        // E a sala: no host do DC, no caminho com o zsoid.
        let fabrica = MeetingRoomFactory(session: session, tokens: [conector.tokenSource])
        let minted = try await fabrica.mint(pedido(service: .zoho))
        #expect(minted.link == "https://meeting.zoho.eu/meeting/join?key=42")
        let criacao = try #require(
            StubURLProtocol.requests(for: session).first {
                $0.path == "/api/v2/889900/sessions.json"
            }
        )
        #expect(criacao.host == "meeting.zoho.eu")
        #expect(criacao.authorization == "Zoho-oauthtoken a-eu")
    }

    @Test("A renovação volta ao data center guardado, não ao .com")
    func refreshesAtStoredDataCenter() async throws {
        let cofre = vault()
        let agora = Date(timeIntervalSince1970: 1_800_000_000)
        try cofre.save(
            MeetingTokens(
                accessToken: "velho", refreshToken: "r-eu",
                expiresAt: agora.addingTimeInterval(-5),
                account: "anne@exemplo.eu",
                accountsServer: "https://accounts.zoho.eu",
                zsoid: "889900"
            ),
            for: .zoho
        )
        let session = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json(#"{"access_token":"novo-eu","expires_in":3600}"#)],
        ])
        let motor = MeetingOAuthEngine(
            config: MeetingOAuthConfig(
                service: .zoho, clientID: "c", clientSecret: "s",
                authorizationEndpoint: URL(string: "https://accounts.zoho.com/oauth/v2/auth")!,
                tokenEndpoint: URL(string: "https://accounts.zoho.com/oauth/v2/token")!,
                redirectURI: "http://127.0.0.1:53720/oauth2redirect",
                scopes: ZohoConnector.scopes, scopeSeparator: ","
            ),
            session: session, vault: cofre, now: { agora }
        )
        #expect(try await motor.accessToken() == "novo-eu")

        let renovacao = try #require(StubURLProtocol.requests(for: session).first)
        #expect(renovacao.host == "accounts.zoho.eu")
        #expect(field(renovacao.body, "grant_type") == "refresh_token")
        #expect(field(renovacao.body, "client_secret") == "s")
        // O Zoho não reenvia o refresh token; manter o anterior é o que
        // impede a conexão de morrer na primeira renovação.
        let guardados = try #require(cofre.load(.zoho))
        #expect(guardados.refreshToken == "r-eu")
        #expect(guardados.accountsServer == "https://accounts.zoho.eu")
        #expect(guardados.zsoid == "889900")
    }

    @Test("Um data center desconhecido é recusado em vez de virar host inventado")
    func refusesUnknownDataCenter() async throws {
        let porta = portaLivre()
        let session = StubURLProtocol.session(routes: [:])
        let conector = ZohoConnector(
            clientID: "c", clientSecret: "s", session: session, vault: vault(),
            browser: RecordingBrowser { url in
                URL(string: "http://127.0.0.1:\(porta)/oauth2redirect?code=c&state=\(query(url)["state"]!)&accounts-server=https%3A%2F%2Faccounts.zoho.evil")
            },
            loopback: LoopbackEndpoint(port: porta),
            authorizationEndpoint: URL(string: "https://accounts.zoho.example/oauth/v2/auth")!
        )
        await #expect(throws: MeetingConnectorError.self) {
            _ = try await conector.connect()
        }
        #expect(StubURLProtocol.requests(for: session).isEmpty)
    }

    @Test("Erro 200 com corpo de erro do Zoho também é falha")
    func treatsBodyErrorAsFailure() async throws {
        let cofre = vault()
        let session = StubURLProtocol.session(routes: [
            "/oauth/v2/token": [.json(#"{"error":"invalid_code"}"#)],
        ])
        let motor = MeetingOAuthEngine(
            config: MeetingOAuthConfig(
                service: .zoho, clientID: "c", clientSecret: "s",
                authorizationEndpoint: URL(string: "https://accounts.zoho.example/oauth/v2/auth")!,
                tokenEndpoint: URL(string: "https://accounts.zoho.example/oauth/v2/token")!,
                redirectURI: "http://127.0.0.1:53720/oauth2redirect",
                scopes: ZohoConnector.scopes, scopeSeparator: ","
            ),
            session: session, vault: cofre
        )
        await #expect(throws: MeetingRoomError.notConnected(.zoho)) {
            _ = try await motor.exchange(code: "c", verifier: "v")
        }
    }
}

@Suite("A fábrica usa o token da pessoa")
@MainActor
struct MeetingRoomFactoryTokenTests {
    @Test("Sem conexão não oferece mintar, e mintar lança notConnected")
    func refusesWithoutConnection() async throws {
        let cofre = MeetingTokenVault(secrets: InMemorySecretStore())
        let session = StubURLProtocol.session(routes: [:])
        let zoom = ZoomConnector(
            clientID: "c", session: session, vault: cofre,
            browser: RecordingBrowser { _ in nil }
        )
        let fabrica = MeetingRoomFactory(session: session, tokens: [zoom.tokenSource])
        let conta = Account(
            id: "a", address: "a@x.com", displayName: "A", provider: .imap, host: "x",
            tintLightHex: "#000", tintDarkHex: "#fff"
        )
        #expect(fabrica.canMint(.zoom, account: conta) == false)
        await #expect(throws: MeetingRoomError.notConnected(.zoom)) {
            _ = try await fabrica.mint(pedido(service: .zoom))
        }

        try cofre.save(
            MeetingTokens(accessToken: "t", expiresAt: .distantFuture, account: "m@x.com"),
            for: .zoom
        )
        #expect(fabrica.canMint(.zoom, account: conta))
        #expect(fabrica.connectedAccount(.zoom) == "m@x.com")
    }

    @Test("Cada compromisso recebe um link novo, nunca o anterior")
    func mintsFreshLinkEveryTime() async throws {
        let cofre = MeetingTokenVault(secrets: InMemorySecretStore())
        try cofre.save(
            MeetingTokens(accessToken: "t", expiresAt: .distantFuture), for: .zoom
        )
        let session = StubURLProtocol.session(routes: [
            "/v2/users/me/meetings": [
                .json(#"{"join_url":"https://zoom.us/j/111"}"#),
                .json(#"{"join_url":"https://zoom.us/j/222"}"#),
            ],
        ])
        let zoom = ZoomConnector(
            clientID: "c", session: session, vault: cofre,
            browser: RecordingBrowser { _ in nil },
            apiBase: URL(string: "https://api.zoom.us/v2/")!
        )
        let fabrica = MeetingRoomFactory(session: session, tokens: [zoom.tokenSource])
        let primeira = try await fabrica.mint(pedido(service: .zoom, title: "Uma"))
        let segunda = try await fabrica.mint(pedido(service: .zoom, title: "Outra"))
        #expect(primeira.link == "https://zoom.us/j/111")
        #expect(segunda.link == "https://zoom.us/j/222")
    }
}
