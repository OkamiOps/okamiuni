import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Um relato que atravessa a fronteira de isolação — é como o teste afirma que
/// o erro do ciclo chegou a quem desenha a linha da conta.
private final class Relatos: @unchecked Sendable {
    private let lock = NSLock()
    private var todos: [(String, SyncError?)] = []

    func registra(_ conta: String, _ erro: SyncError?) {
        lock.lock()
        todos.append((conta, erro))
        lock.unlock()
    }

    var lista: [(String, SyncError?)] {
        lock.lock()
        defer { lock.unlock() }
        return todos
    }
}

/// O coordenador de uma conta e o corredor que liga e desliga os coordenadores.
///
/// **Nada aqui toca rede externa**: o servidor IMAP é o falso, em `127.0.0.1`.
@Suite("O coordenador de sincronização")
struct AccountSyncCoordinatorTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func conta(estado: Account.State = .ativa) -> Account {
        Account(
            id: "conta-i", address: "ricardo@angulos.com", displayName: "Trabalho",
            provider: .imap, host: "angulos",
            tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4",
            imap: ImapEndpoint(host: "127.0.0.1", port: 1, security: .startTLS),
            state: estado
        )
    }

    private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
        grupo.shutdownGracefully { _ in }
    }

    private func banco(_ conta: Account) async throws -> SyncDatabase {
        let db = try SyncDatabase.temporary()
        let agora = agora
        try await db.pool.write { try AccountRecord(conta, createdAt: agora).insert($0) }
        return db
    }

    /// O roteiro mínimo de um ciclo IMAP: entrar, listar, selecionar, procurar.
    private func roteiroDeCiclo(uid: Int64) -> FakeImapServer.Script {
        .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "CAPABILITY": ["* CAPABILITY IMAP4rev1", "TAG OK CAPABILITY completed"],
            "LIST": ["* LIST (\\HasNoChildren \\Inbox) \"/\" \"INBOX\"", "TAG OK LIST completed"],
            "SELECT": [
                "* 1 EXISTS",
                "* OK [UIDVALIDITY 55] UIDs valid",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            "UID SEARCH": ["* SEARCH \(uid)", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                """
                * 1 FETCH (UID \(uid) FLAGS () INTERNALDATE "25-Aug-2026 09:00:00 -0300" \
                ENVELOPE ("Mon, 25 Aug 2026 09:00:00 -0300" "Chegou agora" \
                (("Marina" NIL "marina" "clientepremium.com")) NIL NIL \
                (("Ricardo" NIL "ricardo" "angulos.com")) NIL NIL NIL NIL))
                """,
                "TAG OK UID FETCH completed",
            ],
            FakeImapServer.chaveDeBandeiras: [
                "* 1 FETCH (UID \(uid) FLAGS ())",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["* BYE tchau", "TAG OK LOGOUT completed"],
        ])
    }

    private func coordenador(
        _ db: SyncDatabase, porta: Int, grupo: MultiThreadedEventLoopGroup,
        cofre: any SecretStore, relatos: Relatos = Relatos()
    ) -> AccountSyncCoordinator {
        AccountSyncCoordinator(
            accountID: "conta-i", database: db, secrets: cofre, auth: nil,
            session: StubURLProtocol.session(), eventLoopGroup: grupo,
            imapConnect: { _, elg in
                try await ImapSession.connectForRehearsal(
                    endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                    group: elg
                )
            },
            now: { self.agora },
            report: { conta, erro in relatos.registra(conta, erro) }
        )
    }

    // MARK: Um ciclo de verdade

    @Test("Um ciclo traz a mensagem nova ao banco — e é só o banco que a UI lê")
    func cicloTrazMensagem() async throws {
        let db = try await banco(conta())
        let cofre = InMemorySecretStore()
        try cofre.store(.password("senha-de-app"), for: "conta-i")

        let servidor = FakeImapServer(script: roteiroDeCiclo(uid: 42))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let coordenador = coordenador(db, porta: porta, grupo: grupo, cofre: cofre)
        let saida = await coordenador.syncOnce()
        await coordenador.stop()

        #expect(saida.erro == nil)
        #expect(saida.gravadas == 1)
        let linhas = try await db.pool.read { try MessageRecord.fetchAll($0) }
        // A mensagem está no banco, e é dele que a `ValueObservation` do
        // `DatabaseMailSource` tira o próximo retrato: nenhuma ponte nova para
        // a tela foi inventada, e é essa a promessa.
        #expect(linhas.map(\.subject) == ["Chegou agora"])
    }

    @Test("Dois ciclos seguidos não duplicam nada, e a conexão é reaproveitada")
    func doisCiclosNaoDuplicam() async throws {
        let db = try await banco(conta())
        let cofre = InMemorySecretStore()
        try cofre.store(.password("senha-de-app"), for: "conta-i")

        let servidor = FakeImapServer(script: roteiroDeCiclo(uid: 42))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let coordenador = coordenador(db, porta: porta, grupo: grupo, cofre: cofre)
        await coordenador.syncOnce()
        await coordenador.syncOnce()
        await coordenador.stop()

        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 1)
        // Um `LOGIN` só: reconectar a cada ciclo trocaria o aviso do servidor
        // por uma autenticação por minuto — e o `IDLE`, que **é** uma sessão
        // aberta, deixaria de existir.
        #expect(servidor.commands.filter { $0.contains(" LOGIN ") }.count == 1)
    }

    // MARK: O erro

    @Test("Sem senha no cofre, a conta cai em erro de autenticação e o relato sai")
    func semSenhaMarcaAConta() async throws {
        let db = try await banco(conta())
        let relatos = Relatos()

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let coordenador = coordenador(
            db, porta: 1, grupo: grupo, cofre: InMemorySecretStore(), relatos: relatos
        )
        let saida = await coordenador.syncOnce()
        await coordenador.stop()

        #expect(saida.erro == .autenticacao)
        // O estado da conta é o que a lateral e a janela de Contas desenham:
        // sem esta marca, a conta apareceria como se estivesse bem, parada.
        let estado = try await db.pool.read {
            try AccountRecord.fetchOne($0, key: "conta-i")?.account.state
        }
        #expect(estado == .erroDeAutenticacao)
        #expect(relatos.lista.contains { $0.0 == "conta-i" && $0.1 == .autenticacao })
    }

    @Test("Conta que já saiu do banco não é erro — é a remoção da pessoa")
    func contaRemovidaNaoEhErro() async throws {
        let db = try SyncDatabase.temporary()
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let coordenador = coordenador(db, porta: 1, grupo: grupo, cofre: InMemorySecretStore())
        let saida = await coordenador.syncOnce()
        await coordenador.stop()

        #expect(saida.erro == nil)
        #expect(saida.gravadas == 0)
    }

    @Test("A linha entre o que insistir cura e o que não cura")
    func oQueEhPermanente() {
        // A linha é traçada pela **ação que resolve**, não pela gravidade:
        // rede caída e quota pedem esperar; credencial recusada pede a pessoa.
        #expect(AccountSyncCoordinator.ehPermanente(.autenticacao))
        #expect(AccountSyncCoordinator.ehPermanente(.autorizacaoRevogada))
        #expect(AccountSyncCoordinator.ehPermanente(.semClientID))
        #expect(!AccountSyncCoordinator.ehPermanente(.rede("wi-fi caiu")))
        #expect(!AccountSyncCoordinator.ehPermanente(.quota))
        #expect(!AccountSyncCoordinator.ehPermanente(.servidor(codigo: 503, mensagem: "ocupado")))
    }

    @Test("O teto do reengate cabe na recomendação do RFC 2177")
    func tetoDoReengate() {
        // Menos de 29 minutos: é isso que impede o servidor — e cada NAT no
        // caminho — de dar a conexão por morta e a derrubar sem avisar.
        #expect(AccountSyncCoordinator.idleMaximo < 29 * 60)
        #expect(AccountSyncCoordinator.idleMaximo == 25 * 60)
    }

    @Test("O recuo dobra, respeita o teto e o tremor puxa para baixo")
    func recuoExponencial() {
        // Sem tremor, um provedor que ficou fora do ar dez minutos recebe todas
        // as contas de todos os clientes no minuto em que volta — e cai de novo.
        #expect(AccountSyncCoordinator.recuo(tentativas: 1, jitter: 1) == 5)
        #expect(AccountSyncCoordinator.recuo(tentativas: 2, jitter: 1) == 10)
        #expect(AccountSyncCoordinator.recuo(tentativas: 3, jitter: 1) == 20)
        // O tremor é **para baixo**: entre metade e o cheio, para nunca somar
        // ao teto.
        #expect(AccountSyncCoordinator.recuo(tentativas: 1, jitter: 0) == 2.5)
        #expect(AccountSyncCoordinator.recuo(tentativas: 40, jitter: 1)
            == AccountSyncCoordinator.recuoTeto)
    }

    // MARK: O relato chegando à janela

    @Test("O erro do ciclo chega ao estado publicado da conta, e some quando passa")
    func relatoChegaAoEstadoPublicado() async throws {
        // Antes desta porta, o `report` do corredor e o da fila caíam num
        // no-op: a falha ficava no log e a janela de Contas mostrava a conta
        // como se nada tivesse acontecido.
        let db = try await banco(conta())
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let director = AccountDirector(
            database: db, secrets: InMemorySecretStore(), auth: nil,
            session: StubURLProtocol.session(), eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("sem servidor no teste") }
        )

        await director.report(accountID: "conta-i", error: .quota)
        #expect(await primeiroStatus(de: director)?.error == .quota)

        // E some quando o ciclo seguinte passa: a pessoa precisa ver isso tanto
        // quanto viu a falha.
        await director.report(accountID: "conta-i", error: nil)
        #expect(await primeiroStatus(de: director)?.error == nil)
    }

    private func primeiroStatus(de director: AccountDirector) async -> AccountStatus? {
        for await lista in await director.statuses() { return lista.first }
        return nil
    }

    // MARK: O corredor

    private func status(_ id: String, _ estado: Account.State) -> AccountStatus {
        AccountStatus(
            accountID: id, address: "\(id)@x.com", hostMark: "x", state: estado,
            messageCount: 0, lastSyncedAt: nil, error: nil, progress: nil
        )
    }

    @Test("Só conta ativa ganha coordenador")
    func soAtivaSincroniza() {
        #expect(SyncRunner.deveSincronizar(status("a", .ativa)))
        // Carregando não: a carga inicial ainda não carimbou o `sync_state`, e
        // o incremental leria "sem marcador" e mandaria recarregar — duas
        // cargas da mesma conta ao mesmo tempo.
        #expect(!SyncRunner.deveSincronizar(status("b", .carregando)))
        // Erro de autenticação não: insistir a cada minuto numa credencial
        // recusada esconde da pessoa a única coisa que ela pode fazer.
        #expect(!SyncRunner.deveSincronizar(status("c", .erroDeAutenticacao)))
    }

    @Test("O corredor liga a conta que entra e desliga a que sai ou trava")
    func corredorAcertaOsCoordenadores() async throws {
        let db = try await banco(conta())
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let director = AccountDirector(
            database: db, secrets: InMemorySecretStore(), auth: nil,
            session: StubURLProtocol.session(), eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("sem servidor no teste") }
        )
        let corredor = SyncRunner(
            database: db, secrets: InMemorySecretStore(), auth: nil,
            session: StubURLProtocol.session(), eventLoopGroup: grupo, director: director,
            imapConnect: { _, _ in throw SyncError.rede("sem servidor no teste") }
        )

        await corredor.reconcile([status("conta-i", .ativa)])
        #expect(await corredor.coordinator(for: "conta-i") != nil)

        // A conta caiu em erro de autenticação: o coordenador dela sai.
        await corredor.reconcile([status("conta-i", .erroDeAutenticacao)])
        #expect(await corredor.coordinator(for: "conta-i") == nil)

        // Voltou a ser ativa (a pessoa reconectou): ele volta.
        await corredor.reconcile([status("conta-i", .ativa)])
        #expect(await corredor.coordinator(for: "conta-i") != nil)

        // A conta saiu da lista: nada mais sincroniza por ela.
        await corredor.reconcile([])
        #expect(await corredor.coordinator(for: "conta-i") == nil)
        await corredor.stop()
    }

    @Test("Reconciliar a mesma lista duas vezes NÃO troca o coordenador")
    func reconciliarEhIdempotente() async throws {
        let db = try await banco(conta())
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let director = AccountDirector(
            database: db, secrets: InMemorySecretStore(), auth: nil,
            session: StubURLProtocol.session(), eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("sem servidor no teste") }
        )
        let corredor = SyncRunner(
            database: db, secrets: InMemorySecretStore(), auth: nil,
            session: StubURLProtocol.session(), eventLoopGroup: grupo, director: director,
            imapConnect: { _, _ in throw SyncError.rede("sem servidor no teste") }
        )

        await corredor.reconcile([status("conta-i", .ativa)])
        let primeiro = await corredor.coordinator(for: "conta-i")
        await corredor.reconcile([status("conta-i", .ativa)])
        let segundo = await corredor.coordinator(for: "conta-i")

        // O diretor publica a lista inteira a cada mudança — inclusive quando
        // nada que interesse aqui mudou. Recriar o coordenador em toda
        // publicação mataria a sessão IMAP (e o `IDLE` dela) sem razão.
        #expect(primeiro === segundo)
        await corredor.stop()
    }
}
