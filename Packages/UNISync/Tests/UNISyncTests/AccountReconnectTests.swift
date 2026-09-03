import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Reconectar é reautenticar **a conta que já existe** — não adicionar outra
/// por baixo do pano.
///
/// A queixa do dono foi literal: "falta um reconnect aqui, porque agora caiu e
/// o que eu faço, eu tenho que remover a minha conta toda e adicionar de novo?"
/// Remover apagava 1.446 mensagens locais e uma fila de saída com item pendente
/// para resolver uma credencial vencida. Estes testes são a régua do conserto:
/// o id não muda, o banco não é tocado, e uma falha no meio deixa a credencial
/// velha exatamente onde estava.
@Suite("Reconectar preserva a conta")
struct AccountReconnectTests {

    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
        grupo.shutdownGracefully { _ in }
    }

    // MARK: Qual causa oferece reconectar

    @Test("causa de sessão pede reconexão; causa que depende do app, não")
    func quemPedeReconexao() {
        #expect(SyncError.autenticacao.pedeReconexao)
        #expect(SyncError.autorizacaoRevogada.pedeReconexao)
        // Falta o Client ID **no aplicativo**: não há credencial de sessão para
        // refazer, e um botão "Reconectar" aqui abriria um OAuth que não tem
        // com que se identificar. É o caso exato da captura do dono.
        #expect(!SyncError.semClientID.pedeReconexao)
        #expect(!SyncError.rede("sem rota").pedeReconexao)
        #expect(!SyncError.quota.pedeReconexao)
        #expect(!SyncError.keychain(status: -25_300).pedeReconexao)
    }

    // MARK: IMAP

    @Test("reconectar IMAP grava a senha nova por cima e não troca o id")
    func imapGravaPorCima() async throws {
        let servidor = FakeImapServer(script: Self.roteiro())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-velha",
            endpoint: Self.endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        await director.loadInitial(accountID: conta.id)
        let mensagensAntes = try await db.pool.read { try MessageRecord.fetchCount($0) }
        let antes = try #require(
            try await db.pool.read { try AccountRecord.fetchOne($0, key: conta.id)?.account }
        )

        let depois = try await director.reconnectImap(
            accountID: conta.id, address: "contato@meusite.com",
            password: "senha-nova", endpoint: Self.endpoint(porta)
        )

        #expect(depois.id == conta.id)
        #expect(try cofre.secret(for: conta.id) == .password("senha-nova"))
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 1)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == mensagensAntes)
        #expect(depois.tintLightHex == antes.tintLightHex)
        #expect(depois.lastSyncedAt == antes.lastSyncedAt)
        // Reconectou: a conta volta a ser uma conta viva.
        #expect(depois.state == .ativa)
    }

    @Test("endereço diferente é recusado, e a credencial antiga fica")
    func enderecoDiferenteERecusado() async throws {
        let servidor = FakeImapServer(script: Self.roteiro())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-velha",
            endpoint: Self.endpoint(porta), hostMark: "meusite", displayName: "Site"
        )

        await #expect(throws: SyncError.contaDiferente(
            esperado: "contato@meusite.com", recebido: "outro@meusite.com"
        )) {
            _ = try await director.reconnectImap(
                accountID: conta.id, address: "outro@meusite.com",
                password: "senha-nova", endpoint: Self.endpoint(porta)
            )
        }
        // Nada foi tocado: nem o cofre, nem a lista de contas.
        #expect(try cofre.secret(for: conta.id) == .password("senha-velha"))
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 1)
    }

    @Test("falha no meio preserva a credencial antiga")
    func falhaPreservaCredencial() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let servidor = FakeImapServer(script: Self.roteiro())
        let porta = try servidor.start()
        defer { servidor.stop() }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-velha",
            endpoint: Self.endpoint(porta), hostMark: "meusite", displayName: "Site"
        )

        // O servidor recusa a senha nova. Nada pode ser apagado por causa disso.
        let recusa = diretor(
            db: db, secrets: cofre, grupo: grupo, porta: porta,
            imapConnect: { _, _ in throw SyncError.autenticacao }
        )
        await #expect(throws: SyncError.autenticacao) {
            _ = try await recusa.reconnectImap(
                accountID: conta.id, address: "contato@meusite.com",
                password: "senha-que-nao-serve", endpoint: Self.endpoint(porta)
            )
        }
        #expect(try cofre.secret(for: conta.id) == .password("senha-velha"))
    }

    @Test("reconectar uma conta que não existe não cria conta nenhuma")
    func contaInexistente() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(
            db: db, secrets: cofre, grupo: grupo, porta: 0,
            imapConnect: { _, _ in throw SyncError.rede("não deveria ser chamado") }
        )
        await #expect(throws: SyncError.self) {
            _ = try await director.reconnectImap(
                accountID: "nao-existe", address: "x@y.com",
                password: "s", endpoint: Self.endpoint(993)
            )
        }
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
    }

    // MARK: Google

    @Test("sem client ID, reconectar Google diz o que falta em vez de falhar mudo")
    func googleSemClientID() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        try await Self.gravaContaGoogle(db, cofre: cofre)

        let director = AccountDirector(
            database: db, secrets: cofre, auth: nil,
            session: StubURLProtocol.session(),
            gmailBaseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!,
            eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("não deveria ser chamado") },
            now: { self.agora }
        )
        await #expect(throws: SyncError.semClientID) {
            _ = try await director.reconnectGoogle(accountID: "conta-google")
        }
        #expect(try cofre.secret(for: "conta-google") != nil)
    }

    @Test("reconectar Google troca o token da conta que já existe, sem mudar o id")
    func googleTrocaOToken() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        try await Self.gravaContaGoogle(db, cofre: cofre)

        let sessao = StubURLProtocol.session(routes: [
            "/token": [.json("""
                {"access_token":"novo","refresh_token":"r-novo","expires_in":3600,
                 "scope":"https://mail.google.com/","token_type":"Bearer"}
                """)],
            "/gmail/v1/users/me/profile": [
                .json(#"{"emailAddress":"marcos@okamiops.com","historyId":"1"}"#)
            ],
        ])
        let director = Self.diretorGoogle(db: db, cofre: cofre, grupo: grupo, sessao: sessao)

        let conta = try await director.reconnectGoogle(accountID: "conta-google")
        #expect(conta.id == "conta-google")
        #expect(conta.address == "marcos@okamiops.com")
        #expect(conta.state == .ativa)
        guard case .oauth(let tokens)? = try cofre.secret(for: "conta-google") else {
            Issue.record("o cofre devia guardar o token novo")
            return
        }
        #expect(tokens.accessToken == "novo")
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 1)
        // O rascunho da reconexão não pode ficar para trás no chaveiro.
        #expect(cofre.storedAccountIDs.count == 1)
    }

    @Test("Google com outro endereço é recusado, e o token velho continua lá")
    func googleEnderecoDiferente() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        try await Self.gravaContaGoogle(db, cofre: cofre)

        let sessao = StubURLProtocol.session(routes: [
            "/token": [.json("""
                {"access_token":"novo","refresh_token":"r-novo","expires_in":3600,
                 "scope":"https://mail.google.com/","token_type":"Bearer"}
                """)],
            "/gmail/v1/users/me/profile": [
                .json(#"{"emailAddress":"outra@gmail.com","historyId":"1"}"#)
            ],
        ])
        let director = Self.diretorGoogle(db: db, cofre: cofre, grupo: grupo, sessao: sessao)

        await #expect(throws: SyncError.contaDiferente(
            esperado: "marcos@okamiops.com", recebido: "outra@gmail.com"
        )) {
            _ = try await director.reconnectGoogle(accountID: "conta-google")
        }
        // A credencial velha sobreviveu, e nenhuma conta nova entrou.
        guard case .oauth(let tokens)? = try cofre.secret(for: "conta-google") else {
            Issue.record("o token antigo devia continuar no cofre")
            return
        }
        #expect(tokens.accessToken == "velho")
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 1)
        #expect(cofre.storedAccountIDs.count == 1)
    }

    // MARK: Montagem

    private static func gravaContaGoogle(
        _ db: SyncDatabase, cofre: InMemorySecretStore
    ) async throws {
        let conta = Account(
            id: "conta-google", address: "marcos@okamiops.com", displayName: "Marcos",
            provider: .gmail, host: "gmail",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7",
            state: .erroDeAutenticacao
        )
        try await db.pool.write { db in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(db)
        }
        try cofre.store(
            .oauth(OAuthTokens(
                accessToken: "velho", refreshToken: "r-velho",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000), scopes: []
            )),
            for: "conta-google"
        )
    }

    private static func diretorGoogle(
        db: SyncDatabase, cofre: InMemorySecretStore,
        grupo: any EventLoopGroup, sessao: URLSession
    ) -> AccountDirector {
        AccountDirector(
            database: db,
            secrets: cofre,
            auth: GoogleAuth(
                config: GoogleAuthConfig(
                    clientID: "cliente-de-teste",
                    tokenEndpoint: URL(string: "https://oauth2.example/token")!,
                    revocationEndpoint: URL(string: "https://oauth2.example/revoke")!
                ),
                session: sessao,
                secrets: cofre,
                presenter: StubAuthorizationPresenter { url in
                    let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "state" }?.value ?? ""
                    return URL(string: "com.okamiops.okamiuni:/oauth?code=cod&state=\(state)")!
                },
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            session: sessao,
            gmailBaseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!,
            eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("não deveria ser chamado") },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func diretor(
        db: SyncDatabase, secrets: any SecretStore, grupo: any EventLoopGroup, porta: Int,
        imapConnect: (@Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession)? = nil
    ) -> AccountDirector {
        AccountDirector(
            database: db,
            secrets: secrets,
            auth: nil,
            session: StubURLProtocol.session(),
            gmailBaseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!,
            eventLoopGroup: grupo,
            imapConnect: imapConnect ?? { _, grupo in
                try await ImapSession.connect(
                    endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                    group: grupo, allowInsecure: true, teto: .seconds(5)
                )
            },
            now: { self.agora }
        )
    }

    private static func endpoint(_ porta: Int) -> ImapEndpoint {
        ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
    }

    private static func roteiro() -> FakeImapServer.Script {
        .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LIST": ["* LIST (\\HasNoChildren) \"/\" \"INBOX\"", "TAG OK LIST completed"],
            "SELECT": [
                "* 1 EXISTS",
                "* OK [UIDVALIDITY 1755000000] UIDs valid",
                "* OK [UIDNEXT 9002] Predicted next UID",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            "UID SEARCH": ["* SEARCH 9001", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                "* 1 FETCH (UID 9001 FLAGS () INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" "
                + "ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"Oi\" "
                + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL NIL NIL NIL NIL NIL))",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ])
    }
}
