import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Desligar o grupo de event loops sem bloquear — a mesma razão de
/// `InitialLoaderImapTests`: o `defer` de um teste `async` roda no pool
/// cooperativo, e um bloqueio ali derruba a suíte inteira em silêncio.
private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
    grupo.shutdownGracefully { _ in }
}

/// O portão que deixa o teste segurar a carga no ponto exato.
///
/// Existe porque as duas provas de cancelamento precisam de um instante em que
/// a carga **já começou e ainda não terminou** — e um `Task.sleep` no teste,
/// esperando que a carga chegue lá, é a definição de teste intermitente.
private actor Portao {
    private var chegou = false
    private var esperando: [CheckedContinuation<Void, Never>] = []

    func abre() {
        chegou = true
        for continuation in esperando { continuation.resume() }
        esperando = []
    }

    func espera() async {
        if chegou { return }
        await withCheckedContinuation { esperando.append($0) }
    }
}

/// Quantas vezes o `imapConnect` do teste já foi chamado. A primeira é o teste
/// de conexão da adição; da segunda em diante é a carga.
private actor Contador {
    private var quantas = 0
    func proximo() -> Int { quantas += 1; return quantas }
}

@Suite("O diretor de contas")
struct AccountDirectorTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func roteiroImap() -> FakeImapServer.Script {
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

    /// O `connect` **interno**, com `allowInsecure`: o servidor falso fala em
    /// claro, e o `connect` público não tem como pedir conexão insegura — a
    /// promessa "produção sempre TLS" é do compilador.
    private func abre(porta: Int, grupo: any EventLoopGroup) async throws -> ImapSession {
        try await ImapSession.connect(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo, allowInsecure: true, teto: .seconds(5)
        )
    }

    private func diretor(
        db: SyncDatabase, secrets: any SecretStore, grupo: any EventLoopGroup, porta: Int,
        imapConnect: (@Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession)? = nil
    ) -> AccountDirector {
        AccountDirector(
            database: db,
            secrets: secrets,
            auth: GoogleAuth(
                config: GoogleAuthConfig(
                    clientID: "cliente-de-teste",
                    tokenEndpoint: URL(string: "https://oauth2.example/token")!,
                    revocationEndpoint: URL(string: "https://oauth2.example/revoke")!
                ),
                session: StubURLProtocol.session(),
                secrets: secrets,
                presenter: StubAuthorizationPresenter { url in
                    let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "state" }?.value ?? ""
                    return URL(string: "com.okamiops.okamiuni:/oauth?code=cod&state=\(state)")!
                },
                now: { self.agora }
            ),
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

    private func endpoint(_ porta: Int) -> ImapEndpoint {
        ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
    }

    @Test("O id da conta é derivado do endereço, estável e sem caractere solto")
    func idDaConta() {
        // Estável porque a chave estrangeira do banco e a entrada do Keychain
        // dependem dele: um id novo a cada adição órfã o que existia.
        #expect(AccountDirector.accountID(for: "Ricardo@Gmail.com")
            == AccountDirector.accountID(for: "ricardo@gmail.com"))
        #expect(!AccountDirector.accountID(for: "eu+tag@meu-site.com.br").contains("+"))
        #expect(AccountDirector.accountID(for: "a@b.com") != AccountDirector.accountID(for: "a@c.com"))
    }

    @Test("As cores das contas se repetem em ciclo — nada limita a quantidade")
    func coresCiclam() {
        let primeira = AccountTints.pair(forIndex: 0)
        #expect(primeira.light.hasPrefix("#"))
        #expect(primeira.dark.hasPrefix("#"))
        // A trigésima conta tem cor; ela não é a última nem a inválida.
        let trigesima = AccountTints.pair(forIndex: 29)
        #expect(trigesima.light.hasPrefix("#"))
    }

    @Test("Testar IMAP com senha certa passa e não grava nada")
    func testarImapOK() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)

        try await director.testImap(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta)
        )
        // Testar é só testar: nada no banco, nada no Keychain.
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        #expect(try cofre.secret(for: AccountDirector.accountID(for: "contato@meusite.com")) == nil)
    }

    @Test("Testar IMAP com senha errada devolve `autenticacao`, não uma frase genérica")
    func testarImapSenhaErrada() async throws {
        var script = roteiroImap()
        script.replies["LOGIN"] = ["TAG NO [AUTHENTICATIONFAILED] Invalid credentials"]
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let director = diretor(
            db: try SyncDatabase.temporary(), secrets: InMemorySecretStore(),
            grupo: grupo, porta: porta
        )
        await #expect(throws: SyncError.autenticacao) {
            try await director.testImap(
                address: "contato@meusite.com", password: "errada",
                endpoint: self.endpoint(porta)
            )
        }
    }

    @Test("Adicionar IMAP grava a conta no banco e a senha no cofre — e a senha não vai para o banco")
    func adicionarImap() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)

        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        #expect(conta.provider == .imap)
        #expect(conta.host == "meusite")
        #expect(conta.imap?.port == porta)

        #expect(try cofre.secret(for: conta.id) == .password("senha-de-app"))
        let gravada = try await db.pool.read { try AccountRecord.fetchOne($0, key: conta.id) }
        #expect(gravada?.address == "contato@meusite.com")
        // A senha não pode estar em coluna nenhuma.
        let linha = try await db.pool.read { conexao -> String in
            try String.fetchOne(
                conexao,
                sql: "SELECT group_concat(id || address || displayName || host || signature) FROM account"
            ) ?? ""
        }
        #expect(!linha.contains("senha-de-app"))
    }

    @Test("A carga inicial roda e o estado da conta anda: carregando → ativa")
    func cargaInicialAnda() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        // Recém-adicionada, ela nasce `carregando` — é o que a lista mostra
        // enquanto a barra anda.
        let inicial = try await db.pool.read { try AccountRecord.fetchOne($0, key: conta.id)?.account }
        #expect(inicial?.state == .carregando)

        await director.loadInitial(accountID: conta.id)

        let final = try await db.pool.read { try AccountRecord.fetchOne($0, key: conta.id)?.account }
        #expect(final?.state == .ativa)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 1)
    }

    @Test("O estado publicado traz endereço, contagem e erro")
    func statusPublicado() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        await director.loadInitial(accountID: conta.id)

        var recebidos: [[AccountStatus]] = []
        for await lista in await director.statuses() {
            recebidos.append(lista)
            break
        }
        let status = try #require(recebidos.first?.first)
        #expect(status.accountID == conta.id)
        #expect(status.address == "contato@meusite.com")
        #expect(status.hostMark == "meusite")
        #expect(status.messageCount == 1)
        #expect(status.state == .ativa)
        #expect(status.error == nil)
        // A carga acabou: nada de barra pendurada em 1.0 para sempre.
        #expect(status.progress == nil)
    }

    @Test("Remover apaga banco e Keychain — os dois, sempre")
    func removerApagaOsDois() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        await director.loadInitial(accountID: conta.id)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 1)

        try await director.remove(accountID: conta.id)

        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        // A cascata da migração v1: pastas, mensagens, corpos e estado de sync
        // saem junto com a conta.
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
        #expect(try await db.pool.read { try FolderRecord.fetchCount($0) } == 0)
        #expect(try await db.pool.read { try MessageBodyRecord.fetchCount($0) } == 0)
        #expect(try await db.pool.read { try SyncStateRecord.fetchCount($0) } == 0)
        // Deixar o segredo para trás é a definição de "removi e não removi":
        // a conta some da lista e a senha continua no chaveiro da pessoa.
        #expect(try cofre.secret(for: conta.id) == nil)
    }

    @Test("Adicionar duas contas dá duas cores diferentes e nenhuma quantidade máxima")
    func duasContas() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta)
        let a = try await director.addImapAccount(
            address: "a@meusite.com", password: "s", endpoint: endpoint(porta),
            hostMark: "meusite", displayName: "A"
        )
        let b = try await director.addImapAccount(
            address: "b@outro.com", password: "s", endpoint: endpoint(porta),
            hostMark: "outro", displayName: "B"
        )
        #expect(a.tintLightHex != b.tintLightHex)
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 2)
    }

    @Test("Sem client ID, a rota Google explica o que falta em vez de falhar mudo")
    func googleSemClientID() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let director = AccountDirector(
            database: try SyncDatabase.temporary(),
            secrets: InMemorySecretStore(),
            auth: nil,   // é assim que a composição entrega "sem client ID"
            session: StubURLProtocol.session(),
            gmailBaseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!,
            eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("não deveria ser chamado") },
            now: { self.agora }
        )
        await #expect(throws: SyncError.semClientID) {
            _ = try await director.addGoogleAccount(address: "ricardo@gmail.com")
        }
    }

    // MARK: Cancelamento

    /// Um diretor cuja carga trava no portão, para o teste cancelar no meio.
    private func diretorComPortao(
        db: SyncDatabase, secrets: any SecretStore, grupo: any EventLoopGroup,
        porta: Int, portao: Portao
    ) -> AccountDirector {
        let contador = Contador()
        return diretor(db: db, secrets: secrets, grupo: grupo, porta: porta) { _, grupo in
            // A primeira chamada é o teste de conexão da adição; ela passa.
            // Da segunda em diante é a carga, e é ela que fica presa até o
            // cancelamento chegar — `Task.sleep` acorda lançando `Cancellation-
            // Error`, que é exatamente o caminho que se quer provar.
            if await contador.proximo() > 1 {
                await portao.abre()
                try await Task.sleep(for: .seconds(5))
            }
            return try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                group: grupo, allowInsecure: true, teto: .seconds(5)
            )
        }
    }

    @Test("Carga cancelada não deixa a conta presa em `carregando`")
    func cancelarNaoPrende() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let portao = Portao()
        let director = diretorComPortao(
            db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta, portao: portao
        )
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        // Ela nasce `carregando`: sem a recuperação, cancelar aqui a deixaria
        // assim para sempre, girando uma roda que nunca mais para.
        #expect(try await db.pool.read { try AccountRecord.fetchOne($0, key: conta.id)?.account.state }
            == .carregando)

        let carga = Task { await director.loadInitial(accountID: conta.id) }
        await portao.espera()
        carga.cancel()
        await carga.value

        let depois = try await db.pool.read { try AccountRecord.fetchOne($0, key: conta.id)?.account }
        #expect(depois?.state == .ativa)
        // E a carga **parou**: cancelar o chamador tem de alcançar a tarefa
        // que faz o trabalho. Uma `Task` sem estrutura não herda cancelamento,
        // e sem a ponte explícita ela seguiria baixando a caixa inteira depois
        // de a janela ter sido fechada.
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
    }

    @Test("Remover no meio da carga: a carga morre limpa e a remoção completa")
    func removerDuranteACarga() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let portao = Portao()
        let director = diretorComPortao(
            db: db, secrets: cofre, grupo: grupo, porta: porta, portao: portao
        )
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )

        let carga = Task { await director.loadInitial(accountID: conta.id) }
        await portao.espera()
        try await director.remove(accountID: conta.id)
        await carga.value

        // A remoção completa: nada no banco, nada no cofre. Uma carga ainda
        // viva escreveria a conta de volta — é isso que o cancelamento evita.
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
        #expect(try cofre.secret(for: conta.id) == nil)
    }
}
