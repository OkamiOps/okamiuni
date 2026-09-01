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
/// Existe porque as provas de cancelamento precisam de um instante em que a
/// carga **já começou e ainda não terminou** — e um `Task.sleep` no teste,
/// esperando que a carga chegue lá, é a definição de teste intermitente.
///
/// Conta as chegadas em vez de ser um interruptor: os testes de duas cargas
/// precisam distinguir "a primeira chegou" de "a segunda chegou".
private actor Portao {
    private var chegadas = 0
    private var vigias: [(alvo: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func chega() {
        chegadas += 1
        vigias.removeAll { vigia in
            guard chegadas >= vigia.alvo else { return false }
            vigia.continuation.resume()
            return true
        }
    }

    func espera(_ alvo: Int = 1) async {
        if chegadas >= alvo { return }
        await withCheckedContinuation { vigias.append((alvo, $0)) }
    }
}

/// O que uma carga deixa registrado ao morrer, e quantas estiveram vivas ao
/// mesmo tempo.
private actor Marcador {
    private(set) var encerradas = 0
    private(set) var vivas = 0
    private(set) var maximoVivas = 0

    func entra() {
        vivas += 1
        maximoVivas = max(maximoVivas, vivas)
    }

    /// O encerramento que o cancelamento **não** corta.
    func encerra() { vivas -= 1; encerradas += 1 }
}

/// O freio das ações da janela: prende quem chega até `libera()`.
///
/// Diferente do `Portao`, ele **bloqueia** — é o que permite afirmar que a
/// segunda ação não entrou enquanto a primeira estava presa.
private actor Freio {
    private var chegadas = 0
    private var liberado = false
    private var presos: [CheckedContinuation<Void, Never>] = []
    private var vigias: [(alvo: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func passa() async {
        chegadas += 1
        vigias.removeAll { vigia in
            guard chegadas >= vigia.alvo else { return false }
            vigia.continuation.resume()
            return true
        }
        if liberado { return }
        await withCheckedContinuation { presos.append($0) }
    }

    func esperaChegada(_ alvo: Int) async {
        if chegadas >= alvo { return }
        await withCheckedContinuation { vigias.append((alvo, $0)) }
    }

    func libera() {
        liberado = true
        for continuation in presos { continuation.resume() }
        presos = []
    }

    func quantasChegaram() -> Int { chegadas }
}

/// Quantas vezes o `imapConnect` do teste já foi chamado. A primeira é o teste
/// de conexão da adição; da segunda em diante é a carga.
private actor Contador {
    private var quantas = 0
    func proximo() -> Int { quantas += 1; return quantas }
}

/// Os números publicados, com uma espera **com prazo**.
///
/// Sem prazo, a asserção "o segundo valor chega" viraria um teste que trava
/// quando a observação some, em vez de um que falha — e teste que trava não é
/// prova de nada, é a suíte parada.
private actor CaixaDeNumeros {
    private var vistos: [Int] = []

    /// Guarda o valor novo. Repetição não entra: a publicação acontece por
    /// qualquer mudança do banco, e o que este teste afirma é a **sequência de
    /// números**, não quantas vezes a lista foi redesenhada.
    func anota(_ numero: Int) {
        guard vistos.last != numero else { return }
        vistos.append(numero)
    }

    /// Espera até haver `quantos` números, ou até o prazo acabar.
    func espera(ate quantos: Int, prazo: Duration = .seconds(3)) async -> [Int] {
        let passo = Duration.milliseconds(20)
        var gastos = Duration.zero
        while vistos.count < quantos, gastos < prazo {
            try? await Task.sleep(for: passo)
            gastos += passo
        }
        return vistos
    }
}

/// O último `AccountStatus` publicado, com a mesma espera **com prazo** da
/// caixa acima e pelo mesmo motivo.
///
/// Espera por uma **condição**, e não por uma contagem de publicações: a lista
/// é republicada por qualquer mudança do banco (a `ValueObservation` da fila,
/// entre outras), e contar redesenhos mediria isso em vez do que se afirma.
private actor CaixaDeStatus {
    private var ultimo: AccountStatus?

    func anota(_ status: AccountStatus) { ultimo = status }

    @discardableResult
    func espera(
        ate condicao: @Sendable (AccountStatus) -> Bool, prazo: Duration = .seconds(3)
    ) async -> AccountStatus? {
        let passo = Duration.milliseconds(20)
        var gastos = Duration.zero
        while !(ultimo.map(condicao) ?? false), gastos < prazo {
            try? await Task.sleep(for: passo)
            gastos += passo
        }
        return ultimo
    }
}

/// `.serialized` porque cada teste sobe um `FakeImapServer` e um
/// `MultiThreadedEventLoopGroup` próprios: em paralelo, uma dúzia deles
/// disputa portas e threads, e o teste que mede "a segunda carga não entrou"
/// passa a medir também o escalonador da máquina.
@Suite("O diretor de contas", .serialized)
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

    /// O selo "n aguardando" da linha da conta, e o que o faz mudar.
    ///
    /// Duas coisas se provam aqui, e a segunda é a que importa: o número é o da
    /// fila **daquela** conta, e ele anda sozinho quando a tabela muda — por
    /// `ValueObservation`, como o resto do app. Sem a observação, o número só
    /// se moveria nas ações que já publicam (adicionar, remover, um erro
    /// reportado), e a fila esvaziando em segundo plano deixaria "2 aguardando"
    /// na tela para sempre.
    @Test("O selo «n aguardando» conta a fila da conta e anda sozinho quando ela muda")
    func filaDeSaidaPublicada() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let db = try SyncDatabase.temporary()
        let conta = Account(
            id: "conta-a", address: "eu@meudominio.com.br", displayName: "Eu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
            imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
            state: .ativa
        )
        try await db.pool.write { try AccountRecord(conta, createdAt: self.agora).insert($0) }

        let porta = DatabaseCommandPort(database: db)
        try porta.move(to: .archived, accountID: "conta-a", messageIDs: ["conta-a:g:m1"])
        try porta.move(to: .later, accountID: "conta-a", messageIDs: ["conta-a:g:m2"])

        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: 0)
        let caixa = CaixaDeNumeros()
        let assinatura = Task {
            for await lista in await director.statuses() {
                guard let status = lista.first else { continue }
                await caixa.anota(status.pendingOperations)
            }
        }
        defer { assinatura.cancel() }

        #expect(await caixa.espera(ate: 1) == [2])

        // A fila anda: a operação feita **sai** da tabela (invariante do M3-2),
        // e a lista tem de ser publicada de novo sem ninguém pedir.
        //
        // MUTAÇÃO QUE ISTO PEGA: tirar a `ValueObservation` da fila
        // (`observaAFila`). O primeiro número continuaria certo, e o segundo
        // nunca chegaria — "2 aguardando" na tela de uma conta sem fila
        // nenhuma, para sempre.
        try await db.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        #expect(await caixa.espera(ate: 2) == [2, 0])
    }

    /// **O erro da fila e o do ciclo são duas prateleiras, e não uma.**
    ///
    /// O defeito visto no banco do dono: a `outbox` de `marcos@okamiops.com`
    /// com 3 operações `falhou` (arquivar, 09:21) e 2 `pendente` atrás delas —
    /// a fila daquela conta parada desde então — e a linha da conta dizendo
    /// "Sincronizada às 00:59 · 48 mensagens · 5 aguardando", sem falha
    /// nenhuma, sem causa e sem "Tentar de novo".
    ///
    /// A causa é uma prateleira só. A fila para e relata o erro; o ciclo de
    /// sincronização seguinte roda bem e relata `nil`; o `nil` do ciclo apaga
    /// o erro da fila. Os dois relatos convergem no mesmo `errors`, e a fila
    /// perde sempre — o ciclo passa a cada minuto.
    ///
    /// MUTAÇÃO QUE ISTO PEGA: fazer `reportQueue` escrever em `errors`, a
    /// prateleira do ciclo. Os dois primeiros `#expect` continuariam verdes e
    /// o terceiro cairia.
    @Test("O ciclo de sincronização que passou não apaga o erro da fila")
    func cicloNaoApagaOErroDaFila() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let db = try SyncDatabase.temporary()
        let conta = Account(
            id: "conta-a", address: "eu@meudominio.com.br", displayName: "Eu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
            imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
            state: .ativa
        )
        try await db.pool.write { try AccountRecord(conta, createdAt: self.agora).insert($0) }

        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: 0)
        let caixa = CaixaDeStatus()
        let assinatura = Task {
            for await lista in await director.statuses() {
                guard let status = lista.first else { continue }
                await caixa.anota(status)
            }
        }
        defer { assinatura.cancel() }

        // A fila para: o espelho recusou a autorização, e o executor relata.
        await director.reportQueue(accountID: "conta-a", error: .autorizacaoRevogada)
        #expect(await caixa.espera(ate: { $0.queueError == .autorizacaoRevogada }) != nil)

        // O ciclo de sincronização seguinte passa bem e relata `nil`. Ele
        // limpa o **dele** — a pessoa precisa ver que o ciclo voltou tanto
        // quanto viu a falha dele.
        await director.report(accountID: "conta-a", error: .quota)
        await caixa.espera(ate: { $0.error == .quota })
        await director.report(accountID: "conta-a", error: nil)
        let ultimo = await caixa.espera(ate: { $0.error == nil })
        #expect(ultimo?.error == nil)
        // E não o da fila, que ninguém tratou: a fila continua parada.
        #expect(ultimo?.queueError == .autorizacaoRevogada)
    }

    @Test("O ciclo incremental publica isSyncing e apaga quando termina")
    func cicloIncrementalPublicaIsSyncing() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let db = try SyncDatabase.temporary()
        let conta = Account(
            id: "conta-a", address: "eu@meudominio.com.br", displayName: "Eu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
            imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
            state: .ativa
        )
        try await db.pool.write { try AccountRecord(conta, createdAt: self.agora).insert($0) }

        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: 0)
        let caixa = CaixaDeStatus()
        let assinatura = Task {
            for await lista in await director.statuses() {
                guard let status = lista.first else { continue }
                await caixa.anota(status)
            }
        }
        defer { assinatura.cancel() }

        await director.reportSyncing(accountID: "conta-a", active: true)
        #expect(await caixa.espera(ate: { $0.isSyncing })?.isSyncing == true)

        await director.reportSyncing(accountID: "conta-a", active: false)
        #expect(await caixa.espera(ate: { $0.isSyncing == false })?.isSyncing == false)
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

    @Test("O segredo sai ANTES da linha: cofre que falha deixa a conta visível")
    func ordemDoRemove() async throws {
        // LACUNA DA AUDITORIA (G-c): inverter a ordem das duas escritas deixava
        // os 206 testes verdes.
        //
        // A ordem é escolhida, e o comentário da produção diz por quê: as duas
        // escritas não estão na mesma transação (uma é o Keychain, a outra é
        // SQLite), então uma delas vai ser a que falha sozinha. Falhando o
        // cofre primeiro, a conta fica na lista **com** o segredo dela — a
        // pessoa vê e manda remover de novo. Na ordem inversa, o `DELETE`
        // passaria e o Keychain falharia depois: a conta some da tela e a senha
        // fica no chaveiro, sem nada na interface que ainda saiba que ela
        // existe.
        //
        // MUTAÇÃO QUE ISTO PEGA: trocar as duas escritas de lugar.
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = CofreQueRecusaApagar()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        #expect(try cofre.secret(for: conta.id) != nil)

        cofre.recusa = true
        await #expect(throws: SyncError.self) { try await director.remove(accountID: conta.id) }

        // A linha continua lá — é isso que dá à pessoa a chance de tentar de
        // novo. O segredo também: nada foi apagado, e nada foi escondido.
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 1)
        #expect(try cofre.secret(for: conta.id) != nil)
    }

    @Test("Relato de uma carga já morta não move a barra da carga nova")
    func relatoDeGeracaoVelhaEhDescartado() async throws {
        // LACUNA DA AUDITORIA (G-d): apagar o `guard generations[...] == geracao`
        // de `registra` deixava os 206 testes verdes. A Task 15 declarou o token
        // **sem teste**, por não querer abrir porta de teste; a auditoria mediu
        // o preço, e a porta mínima (`registra`, `geracaoCorrente`,
        // `progressoCorrente` como `internal`) está aberta agora, justificada.
        //
        // O relato de progresso viaja num `Task` próprio, disparado de fora do
        // ator: o de uma carga já morta pode chegar **depois** de a seguinte
        // ter começado e mandar a barra para trás. Não há como encenar esse
        // atraso pela API pública sem depender de tempo — o único jeito honesto
        // de provar a regra é chamar `registra` com uma geração que não é a
        // corrente, que é exatamente o que a carga morta faria.
        //
        // MUTAÇÃO QUE ISTO PEGA: apagar esse `guard`.
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

        let corrente = try #require(await director.geracaoCorrente(de: conta.id))
        // O relato da carga corrente entra.
        await director.registra(
            LoadProgress(accountID: conta.id, done: 7, total: 10), geracao: corrente
        )
        #expect(await director.progressoCorrente(de: conta.id)?.done == 7)

        // O da carga morta — outra geração — é descartado, e a barra fica onde
        // estava em vez de voltar para trás.
        await director.registra(
            LoadProgress(accountID: conta.id, done: 1, total: 10), geracao: UUID()
        )
        #expect(await director.progressoCorrente(de: conta.id)?.done == 7)
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
    ///
    /// O ponto fino é o **encerramento**: ao ser cancelada, a carga ainda gasta
    /// 400 ms num `Task.detached` — que não herda cancelamento — antes de
    /// marcar que morreu. É esse atraso que distingue "cancelei" de "cancelei e
    /// esperei": sem ele, o cancelamento corta tudo no mesmo instante e as duas
    /// versões do `remove` são indistinguíveis.
    private func diretorComPortao(
        db: SyncDatabase, secrets: any SecretStore, grupo: any EventLoopGroup,
        porta: Int, portao: Portao, marcador: Marcador
    ) -> AccountDirector {
        let contador = Contador()
        return diretor(db: db, secrets: secrets, grupo: grupo, porta: porta) { _, grupo in
            // A primeira chamada é o teste de conexão da adição; ela passa.
            // Da segunda em diante é a carga, e é ela que fica presa até o
            // cancelamento chegar — `Task.sleep` acorda lançando `Cancellation-
            // Error`, que é exatamente o caminho que se quer provar.
            if await contador.proximo() > 1 {
                await marcador.entra()
                await portao.chega()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(400)) }.value
                    await marcador.encerra()
                    throw error
                }
                await marcador.encerra()
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
            db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta,
            portao: portao, marcador: Marcador()
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
        let marcador = Marcador()
        let director = diretorComPortao(
            db: db, secrets: cofre, grupo: grupo, porta: porta,
            portao: portao, marcador: marcador
        )
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )

        let carga = Task { await director.loadInitial(accountID: conta.id) }
        await portao.espera()
        try await director.remove(accountID: conta.id)

        // **A remoção esperou.** O encerramento da carga leva 400 ms que o
        // cancelamento não corta; se `remove` só mandasse cancelar e seguisse,
        // ela voltaria daqui com a carga ainda viva e a corrida de pé, só mais
        // curta — e o `DELETE` logo abaixo aconteceria com um carregador ainda
        // capaz de escrever.
        #expect(await marcador.encerradas == 1)

        await carga.value
        // A remoção completa: nada no banco, nada no cofre.
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
        #expect(try cofre.secret(for: conta.id) == nil)
    }

    @Test("Duas cargas na mesma conta: uma só fica viva, e nenhuma sobrevive ao remover")
    func umaCargaPorConta() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let portao = Portao()
        let marcador = Marcador()
        let director = diretorComPortao(
            db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta,
            portao: portao, marcador: marcador
        )
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )

        let primeira = Task { await director.loadInitial(accountID: conta.id) }
        await portao.espera(1)
        // A segunda carga da mesma conta: ela tem de matar a primeira, não
        // tomar-lhe o lugar no dicionário e deixá-la rodando sem dono.
        let segunda = Task { await director.loadInitial(accountID: conta.id) }
        await portao.espera(2)
        #expect(await marcador.maximoVivas == 1)

        try await director.remove(accountID: conta.id)
        await primeira.value
        await segunda.value

        // As duas morreram, e nada escreveu depois do `DELETE`: uma carga órfã
        // sobreviveria ao `remove` — que só conhece a última — e voltaria a
        // escrever com a conta já apagada.
        #expect(await marcador.vivas == 0)
        #expect(await marcador.encerradas == 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
    }

    // MARK: Re-adicionar e cores

    @Test("Re-adicionar a mesma conta troca a senha e preserva a história dela")
    func readicionarPreserva() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)
        let primeira = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-velha",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        await director.loadInitial(accountID: primeira.id)

        let antes = try #require(
            try await db.pool.read { try AccountRecord.fetchOne($0, key: primeira.id)?.account }
        )
        #expect(antes.state == .ativa)
        #expect(antes.lastSyncedAt != nil)

        // O caso de uso real: a pessoa trocou a senha de app e reconecta.
        let segunda = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-nova",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )

        #expect(try cofre.secret(for: primeira.id) == .password("senha-nova"))
        let depois = try #require(
            try await db.pool.read { try AccountRecord.fetchOne($0, key: primeira.id)?.account }
        )
        // Reconectar não é recomeçar: o estado, o carimbo de sync, a cor e as
        // mensagens são história da conta, e nada disso foi pedido de volta.
        #expect(depois.state == .ativa)
        #expect(depois.lastSyncedAt == antes.lastSyncedAt)
        #expect(depois.tintLightHex == antes.tintLightHex)
        #expect(segunda.state == .ativa)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 1)
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 1)
    }

    @Test("A cor de uma conta removida volta ao bolo — a próxima não colide com quem ficou")
    func corLiberadaNaoColide() async throws {
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
        try await director.remove(accountID: a.id)

        let c = try await director.addImapAccount(
            address: "c@terceiro.com", password: "s", endpoint: endpoint(porta),
            hostMark: "terceiro", displayName: "C"
        )
        // Contar contas daria a cor de B à C: duas linhas da mesma cor na
        // lateral, que é o oposto do que a cor existe para fazer.
        #expect(c.tintLightHex != b.tintLightHex)
        #expect(c.tintLightHex == a.tintLightHex)   // a cor liberada foi reaproveitada
    }

    @Test("Remover conta Google revoga no provedor e limpa banco e cofre")
    func removerGoogle() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let sessaoAuth = StubURLProtocol.session(routes: [
            "/token": [.json(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#)],
            "/revoke": [.json("{}")],
        ])
        let sessaoGmail = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/profile":
                [.json(#"{"emailAddress":"ricardo@gmail.com","historyId":"1"}"#)],
        ])
        let auth = GoogleAuth(
            config: GoogleAuthConfig(
                clientID: "cliente-de-teste",
                tokenEndpoint: URL(string: "https://oauth2.example/token")!,
                revocationEndpoint: URL(string: "https://oauth2.example/revoke")!
            ),
            session: sessaoAuth, secrets: cofre,
            presenter: StubAuthorizationPresenter { url in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""
                return URL(string: "com.okamiops.okamiuni:/oauth?code=cod&state=\(state)")!
            },
            now: { self.agora }
        )
        let director = AccountDirector(
            database: db, secrets: cofre, auth: auth, session: sessaoGmail,
            gmailBaseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!,
            eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("não deveria ser chamado") },
            now: { self.agora }
        )

        let conta = try await director.addGoogleAccount(address: "Ricardo@Gmail.com")
        #expect(conta.provider == .gmail)
        #expect(conta.address == "ricardo@gmail.com")
        #expect(try cofre.secret(for: conta.id) != nil)

        try await director.remove(accountID: conta.id)

        // A revogação avisou o Google — deixar a autorização de pé do lado
        // dele é conta removida aqui e app ainda autorizado lá.
        #expect(StubURLProtocol.requests(for: sessaoAuth).contains { $0.path == "/revoke" })
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        #expect(try cofre.secret(for: conta.id) == nil)
    }
}

/// Um cofre que guarda e lê normalmente, mas pode ser mandado **recusar** o
/// apagamento. É o único jeito de observar a ordem das duas escritas do
/// `remove`: elas não estão na mesma transação, então a prova é fazer uma
/// falhar e olhar o que sobrou.
private final class CofreQueRecusaApagar: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var guardados: [String: Secret] = [:]
    /// `nonisolated(unsafe)` seria mentira: quem escreve é o teste, antes de
    /// chamar o `remove`. O cadeado cobre as leituras do ator.
    var recusa: Bool {
        get { lock.lock(); defer { lock.unlock() }; return recusaInterna }
        set { lock.lock(); recusaInterna = newValue; lock.unlock() }
    }
    private var recusaInterna = false

    func store(_ secret: Secret, for accountID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guardados[accountID] = secret
    }

    func secret(for accountID: String) throws -> Secret? {
        lock.lock(); defer { lock.unlock() }
        return guardados[accountID]
    }

    func remove(for accountID: String) throws {
        lock.lock()
        let vaiRecusar = recusaInterna
        lock.unlock()
        // O caso real: Keychain travado, item em uso, permissão negada.
        if vaiRecusar { throw SyncError.keychain(status: -25_308) }
        lock.lock(); defer { lock.unlock() }
        guardados[accountID] = nil
    }
}
