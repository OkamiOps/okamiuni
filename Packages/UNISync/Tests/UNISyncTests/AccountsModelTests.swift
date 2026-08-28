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

    /// Solta **um** dos presos, sem abrir o freio para quem vier depois.
    ///
    /// É o que permite parar o relógio exatamente entre duas ações: a primeira
    /// termina, a segunda chega e fica presa, e o teste observa o `isBusy`
    /// naquele instante — em vez de o observar no fim, quando ele é falso das
    /// duas maneiras.
    func liberaUm() {
        guard !presos.isEmpty else { return }
        presos.removeFirst().resume()
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

    /// Quantas até agora. É por ela que se afirma que uma re-adição **não**
    /// disparou carga nenhuma.
    func total() -> Int { quantas }
}

/// As transições de `isBusy` observadas, na ordem, **depois** de o observador
/// entrar. Guarda o valor NOVO de cada mudança.
private actor Transicoes {
    private(set) var todas: [Bool] = []
    func registra(_ valor: Bool) { todas.append(valor) }
}

extension AccountsModel {
    /// Passa a acompanhar `isBusy` e anota cada mudança.
    ///
    /// `withObservationTracking` avisa **antes** da escrita e vale por uma
    /// mudança só, então o observador se re-registra de dentro do próprio aviso
    /// e lê o valor já escrito num salto seguinte. É a forma de observar uma
    /// sequência de mudanças sem sondar em laço — sondar seria correr com o
    /// escalonador, que é exatamente o que este teste não pode fazer.
    fileprivate func observaOcupado(em destino: Transicoes) {
        withObservationTracking {
            _ = isBusy
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await destino.registra(self.isBusy)
                self.observaOcupado(em: destino)
            }
        }
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

    @Test("`isBusy` só desliga na ÚLTIMA da fila, e não na primeira que termina")
    func ocupadoSegueAteAUltima() async throws {
        // LACUNA DA AUDITORIA (G-e): trocar `if pendentes == 0 { isBusy = false }`
        // por `isBusy = false` incondicional deixava os 206 testes verdes. O
        // `acoesEmFila` acima só olha o `isBusy` **no fim de tudo**, quando ele é
        // falso das duas maneiras.
        //
        // O que se afirma aqui é o meio: no instante em que a primeira ação
        // termina e a segunda ainda está na fila, o ocupado continua ligado —
        // senão o botão para de girar no meio do trabalho.
        //
        // MUTAÇÃO QUE ISTO PEGA: `isBusy = false` incondicional.
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
        // A segunda entra na fila enquanto a primeira está presa no freio.
        let segunda = Task {
            await modelo.testImap(
                address: "b@meusite.com", password: "s", endpoint: self.endpoint(porta)
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await modelo.isBusy)

        // O instante que separa as duas versões é **um salto do MainActor**:
        // entre a primeira ação escrever o seu último `isBusy` e a segunda
        // retomar. Ler `isBusy` de fora ali é uma corrida com o escalonador — e
        // foi assim que a primeira versão deste teste passou verde com a
        // mutação aplicada. O que não é corrida é contar as **transições**: a
        // `@Observable` avisa em toda escrita que muda o valor.
        //
        // Correto:  false→true (primeira entra) … true→false (última sai) = 2.
        // Mutado:   false→true, true→false, false→true, true→false      = 4.
        let transicoes = Transicoes()
        await modelo.observaOcupado(em: transicoes)

        await freio.libera()
        _ = await primeira.value
        _ = await segunda.value
        #expect(await modelo.isBusy == false)

        // A ordem importa mais que o número: o ocupado não pode ter passado por
        // `false` no meio, com ação ainda na fila.
        let vistas = await transicoes.todas
        #expect(vistas == [false], "o ocupado piscou com a fila ainda andando: \(vistas)")
    }

    @Test("Re-adicionar uma conta que já existe NÃO rebaixa 90 dias de novo")
    func readicionarNaoRecarrega() async throws {
        // LACUNA DA AUDITORIA (G-a): apagar o `guard conta.state == .carregando`
        // de `carregaEmSegundoPlano` deixava os 206 testes verdes. Quem só
        // trocou a senha de app não pediu para baixar tudo outra vez — e numa
        // caixa grande isso são minutos de rede e a barra voltando ao começo.
        //
        // MUTAÇÃO QUE ISTO PEGA: apagar esse `guard`.
        let servidor = FakeImapServer(script: roteiro())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let db = try SyncDatabase.temporary()
        let batidas = Batidas()
        let director = diretor(
            db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta
        ) { _, grupo in
            _ = await batidas.bate()
            return try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                group: grupo, allowInsecure: true, teto: .seconds(5)
            )
        }
        let modelo = await AccountsModel(director: director)

        // Primeira adição: conta nova, nasce `carregando`, e a carga corre.
        await modelo.addImap(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        try await esperaAte {
            let quantas = (try? await db.pool.read { try MessageRecord.fetchCount($0) }) ?? 0
            return quantas > 0
        }
        let depoisDaPrimeira = await batidas.total()

        // Re-adição: a conta volta com o estado que já tinha (`.ativa`).
        await modelo.addImap(
            address: "contato@meusite.com", password: "outra-senha",
            endpoint: endpoint(porta), hostMark: "meusite", displayName: "Site"
        )
        // Uma folga generosa: a carga é solta num `Task`, e afirmar "não
        // aconteceu" sem dar tempo de acontecer não afirma nada.
        try await Task.sleep(for: .milliseconds(300))

        // A conexão do `addImapAccount` (o teste da senha nova) conta uma;
        // a da carga contaria outra. É a segunda que não pode existir.
        let depoisDaSegunda = await batidas.total()
        #expect(
            depoisDaSegunda == depoisDaPrimeira + 1,
            "a re-adição disparou carga: \(depoisDaPrimeira) → \(depoisDaSegunda)"
        )
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
