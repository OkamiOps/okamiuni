import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
    grupo.shutdownGracefully { _ in }
}

/// O freio das ações da janela: prende quem chega até `libera()`.
///
/// Bloquear é o ponto — é o que permite afirmar que a segunda ação **não**
/// entrou enquanto a primeira estava presa, em vez de torcer para que a
/// máquina as escalone na ordem que o teste esperava.
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

/// Conta as chamadas ao `imapConnect` e avisa quando a n-ésima chega.
private actor Batidas {
    private var quantas = 0
    private var vigias: [(alvo: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func bate() -> Int {
        quantas += 1
        vigias.removeAll { vigia in
            guard quantas >= vigia.alvo else { return false }
            vigia.continuation.resume()
            return true
        }
        return quantas
    }

    func espera(_ alvo: Int) async {
        if quantas >= alvo { return }
        await withCheckedContinuation { vigias.append((alvo, $0)) }
    }
}

/// `.serialized` pela mesma razão de `AccountDirectorTests`: cada teste sobe
/// servidor e event loops próprios, e os que medem "a segunda não entrou"
/// passariam a medir o escalonador da máquina.
@Suite("O modelo da janela de Contas", .serialized)
struct AccountsModelTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func roteiro() -> FakeImapServer.Script {
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

    private func diretor(
        db: SyncDatabase, secrets: any SecretStore, grupo: any EventLoopGroup, porta: Int,
        imapConnect: (@Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession)? = nil
    ) -> AccountDirector {
        AccountDirector(
            database: db, secrets: secrets, auth: nil,
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

    // MARK: Os repasses

    @Test("Testar, adicionar, listar, carregar e remover passam pelo diretor")
    func repasses() async throws {
        let servidor = FakeImapServer(script: roteiro())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)
        let modelo = await AccountsModel(director: director)

        // 1. Testar não grava.
        #expect(await modelo.testImap(
            address: "contato@meusite.com", password: "senha-de-app", endpoint: endpoint(porta)
        ))
        #expect(await modelo.lastError == nil)
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)

        // 2. Adicionar grava.
        await modelo.addImap(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        #expect(await modelo.lastError == nil)
        let id = AccountDirector.accountID(for: "contato@meusite.com")
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 1)

        // 3. Carregar até o fim, explicitamente.
        await modelo.loadInitial(id)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 1)

        // 4. Listar: o fluxo publica e o modelo desenha.
        let assinatura = Task { await modelo.start() }
        defer { assinatura.cancel() }
        try await esperaAte { await modelo.statuses.count == 1 }
        #expect(await modelo.statuses.first?.address == "contato@meusite.com")
        #expect(await modelo.statuses.first?.messageCount == 1)

        // 5. Remover apaga dos dois lugares.
        await modelo.remove(id)
        #expect(await modelo.lastError == nil)
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        #expect(try cofre.secret(for: id) == nil)
    }

    @Test("Uma ação que falha vira `lastError` com o caso certo, e o ocupado desliga")
    func erroDeAcao() async throws {
        var script = roteiro()
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
        let modelo = await AccountsModel(director: director)
        #expect(await modelo.testImap(
            address: "contato@meusite.com", password: "errada", endpoint: endpoint(porta)
        ) == false)
        #expect(await modelo.lastError == .autenticacao)
        #expect(await modelo.isBusy == false)
    }

    // MARK: O ocupado e a fila

    @Test("Adicionar devolve o controle antes de a carga terminar")
    func adicionarNaoEsperaACarga() async throws {
        let servidor = FakeImapServer(script: roteiro())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let batidas = Batidas()
        // A primeira conexão é o teste da adição; a segunda é a carga, e ela
        // demora. Se `addImap` a esperasse, a janela ficaria travada por todo
        // o tempo de baixar noventa dias.
        let director = diretor(
            db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta
        ) { _, grupo in
            if await batidas.bate() > 1 { try await Task.sleep(for: .seconds(5)) }
            return try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                group: grupo, allowInsecure: true, teto: .seconds(5)
            )
        }
        let modelo = await AccountsModel(director: director)

        await modelo.addImap(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        // Voltou com a conta gravada, o ocupado desligado — e a carga ainda
        // rolando, que é o estado `carregando` no banco.
        #expect(await modelo.isBusy == false)
        #expect(await modelo.lastError == nil)
        let id = AccountDirector.accountID(for: "contato@meusite.com")
        #expect(try await db.pool.read { try AccountRecord.fetchOne($0, key: id)?.account.state }
            == .carregando)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)

        // A carga de fundo existe mesmo: ela já chegou à segunda conexão.
        await batidas.espera(2)
        // E some limpa com a conta.
        await modelo.remove(id)
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
    }

    @Test("Duas ações simultâneas correm em fila, nunca ao mesmo tempo")
    func acoesEmFila() async throws {
        let servidor = FakeImapServer(script: roteiro())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let freio = Freio()
        let director = diretor(
            db: try SyncDatabase.temporary(), secrets: InMemorySecretStore(),
            grupo: grupo, porta: porta
        ) { _, grupo in
            await freio.passa()
            return try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                group: grupo, allowInsecure: true, teto: .seconds(5)
            )
        }
        let modelo = await AccountsModel(director: director)

        let primeira = Task {
            await modelo.testImap(
                address: "a@meusite.com", password: "s", endpoint: self.endpoint(porta)
            )
        }
        await freio.esperaChegada(1)
        let segunda = Task {
            await modelo.testImap(
                address: "b@meusite.com", password: "s", endpoint: self.endpoint(porta)
            )
        }
        // A segunda ação está na fila, não no servidor: sem a vez, as duas
        // escreveriam no mesmo `lastError` e a segunda apagaria o relato da
        // primeira antes de a janela o ter mostrado.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await freio.quantasChegaram() == 1)

        await freio.libera()
        #expect(await primeira.value)
        #expect(await segunda.value)
        #expect(await freio.quantasChegaram() == 2)
        #expect(await modelo.isBusy == false)
    }

    /// Espera uma condição virar verdadeira, com teto — a assinatura do fluxo
    /// entrega o primeiro valor por `Task`, e não há evento a que se prender.
    private func esperaAte(
        _ limite: Int = 100, _ condicao: @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<limite {
            if await condicao() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("A condição não virou verdadeira dentro do teto.")
    }
}
