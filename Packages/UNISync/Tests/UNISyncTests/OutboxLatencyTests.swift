import Foundation
import GRDB
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Um espelho que anota **quando** recebeu cada operação, e que pode demorar na
/// primeira.
///
/// Os outros testes da fila afirmam *o quê* chega ao servidor. Estes afirmam
/// *quando* — e para isso o espelho precisa de um relógio e de um jeito de
/// segurar a primeira operação enquanto a segunda é enfileirada.
actor EspelhoCronometrado: MailMirror {
    private(set) var recebidas: [(operacao: MailOperation, quando: ContinuousClock.Instant)] = []
    /// Quanto a **primeira** operação demora dentro do espelho. É assim que o
    /// teste põe uma segunda operação na fila com um dreno em andamento.
    private let atrasoDaPrimeira: Duration
    private var vezes = 0

    init(atrasoDaPrimeira: Duration = .zero) {
        self.atrasoDaPrimeira = atrasoDaPrimeira
    }

    func apply(
        _ operation: MailOperation, targets: [MessageCoordinate]
    ) async throws -> MessageCoordinate? {
        vezes += 1
        recebidas.append((operation, .now))
        if vezes == 1, atrasoDaPrimeira > .zero { try? await Task.sleep(for: atrasoDaPrimeira) }
        return nil
    }

    var quantas: Int { recebidas.count }
    func quando(_ indice: Int) -> ContinuousClock.Instant { recebidas[indice].quando }
    var operacoes: [MailOperation] { recebidas.map(\.operacao) }
}

/// **Quanto tempo uma ação leva para sair do app.**
///
/// O desenho da fila promete segundos: a porta de escrita enfileira, avisa pelo
/// `OutboxSignal` e o executor acorda. O que estes testes guardam é justamente
/// essa promessa — porque a alternativa, quando o aviso se perde, não é um
/// atraso pequeno: é o `intervaloOcioso`, um minuto redondo, que foi o que o
/// dono viu.
///
/// Relógio e espera de verdade, com teto folgado (dois segundos), porque o que
/// se mede aqui é o caminho inteiro — transação, aviso, ator acordando, dreno.
/// Um teto apertado transformaria uma máquina de CI ocupada em falha falsa; um
/// teto de dois segundos ainda pega o minuto com sobra de trinta vezes.
@Suite("O atraso entre agir e chegar ao servidor")
struct OutboxLatencyTests {
    /// O teto. Trinta vezes menor que o `intervaloOcioso` — se o aviso se
    /// perder, este número não tem como ser cumprido.
    private static let teto: Duration = .seconds(2)

    private func banco() throws -> SyncDatabase {
        let db = try SyncDatabase.temporary()
        try db.pool.write { conexao in
            try AccountRecord(
                Account(
                    id: "conta-a", address: "eu@meudominio.com.br", displayName: "Meu",
                    provider: .imap, host: "meudominio",
                    tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
                    imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
                    state: .ativa
                ),
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(conexao)
        }
        return db
    }

    private func idIMAP(_ uid: Int64) -> String {
        MessageIdentity.imap(
            accountID: "conta-a", folderID: "conta-a/INBOX", uidValidity: 42, uid: uid
        )
    }

    /// Espera uma condição, com teto. Devolve quanto esperou.
    @discardableResult
    private func esperaAte(
        _ condicao: @Sendable () async -> Bool, teto: Duration = OutboxLatencyTests.teto,
        _ oQue: String
    ) async throws -> Duration {
        let inicio = ContinuousClock.now
        while ContinuousClock.now - inicio < teto {
            if await condicao() { return ContinuousClock.now - inicio }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(oQue) não aconteceu dentro de \(teto).")
        return ContinuousClock.now - inicio
    }

    /// Monta o trio real: executor de verdade, sinal de verdade, porta de
    /// verdade. Só o espelho é falso — ele é o servidor.
    private func trio(
        _ db: SyncDatabase, _ espelho: EspelhoCronometrado
    ) -> (OutboxExecutor, DatabaseCommandPort, OutboxSignal) {
        let sinal = OutboxSignal()
        let executor = OutboxExecutor(accountID: "conta-a", database: db, mirror: espelho)
        sinal.register(accountID: "conta-a") { [weak executor] in executor?.wake() }
        return (executor, DatabaseCommandPort(database: db, signal: sinal), sinal)
    }

    @Test("Ação enfileirada com o executor já ocioso chega ao servidor em segundos")
    func avisoComOExecutorOcioso() async throws {
        let db = try banco()
        let espelho = EspelhoCronometrado()
        let (executor, porta, _) = trio(db, espelho)
        await executor.start()
        // O executor precisa estar **dentro** da espera para o teste valer:
        // enfileirar antes disso mediria o primeiro dreno, que acontece de
        // qualquer jeito. Um dreno vazio é instantâneo; cem milissegundos são
        // folga de sobra para o laço chegar lá.
        try await Task.sleep(for: .milliseconds(100))

        try porta.setRead(true, accountID: "conta-a", messageIDs: [idIMAP(1)])
        let atraso = try await esperaAte(
            { await espelho.quantas == 1 }, "A operação chegar ao espelho"
        )

        #expect(atraso < Self.teto)
        #expect(await espelho.operacoes == [.setRead(isRead: true, messageIDs: [idIMAP(1)])])
        await executor.stop()
    }

    @Test("Ação enfileirada com um dreno em andamento não espera o ciclo ocioso")
    func avisoDuranteODreno() async throws {
        let db = try banco()
        // Meio segundo dentro do espelho: tempo de sobra para a segunda ação
        // ser enfileirada e avisada **enquanto** a primeira ainda está no ar.
        let espelho = EspelhoCronometrado(atrasoDaPrimeira: .milliseconds(500))
        let (executor, porta, _) = trio(db, espelho)
        await executor.start()
        try await Task.sleep(for: .milliseconds(100))

        try porta.setRead(true, accountID: "conta-a", messageIDs: [idIMAP(1)])
        try await esperaAte({ await espelho.quantas == 1 }, "A primeira chegar ao espelho")

        // Agora, com a primeira presa no espelho, a segunda entra na fila. É
        // este o aviso que precisa ficar guardado: ele chega com o ator ocupado.
        // Uma operação **diferente** de propósito — a coalescência junta
        // `setRead` consecutivos do mesmo valor, e uma fila de uma chamada só
        // não provaria nada sobre o segundo despertar.
        try porta.move(to: .archived, accountID: "conta-a", messageIDs: [idIMAP(2)])

        try await esperaAte(
            { await espelho.quantas == 2 },
            // O teto conta a partir de agora e engloba o meio segundo que falta
            // da primeira operação: a fila é serial, e a segunda espera a
            // primeira por desenho, não por defeito.
            teto: .milliseconds(500) + Self.teto,
            "A segunda chegar ao espelho"
        )

        // O guarda não é zelo: sem o aviso, a segunda nunca chega, e ler o
        // instante dela derrubaria o processo inteiro em vez de falhar o teste
        // — as outras falhas do arquivo sumiriam junto.
        try #require(await espelho.quantas == 2)
        let entreAsDuas = try await espelho.quando(1) - espelho.quando(0)
        #expect(entreAsDuas < .milliseconds(500) + Self.teto)
        await executor.stop()
    }

    /// Quantas tentativas a (única) linha da fila já gastou.
    private func tentativas(_ db: SyncDatabase) throws -> Int? {
        try db.pool.read { try Int.fetchOne($0, sql: "SELECT attempts FROM outbox") }
    }

    @Test("O aviso atravessa a fiação real: porta → sinal → runner → executor")
    func avisoAtravessaORunner() async throws {
        // Os três testes acima registram o ouvinte à mão, como o executor pede.
        // Este não: quem registra no app é o `OutboxRunner`, e um sinal que a
        // composição instanciasse duas vezes — um para a porta, outro para a
        // fila — quebraria o aviso sem quebrar teste nenhum dos outros.
        let db = try banco()
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { grupo.shutdownGracefully { _ in } }
        let cofre = InMemorySecretStore()
        try cofre.store(.password("senha"), for: "conta-a")
        let sinal = OutboxSignal()
        let runner = OutboxRunner(
            database: db, secrets: cofre, auth: nil, session: .shared,
            eventLoopGroup: grupo, signal: sinal,
            // Nenhum teste daqui toca rede: a conexão falha na hora, e a falha
            // é transitória de propósito — o que se afirma é o **despertar**,
            // não o sucesso.
            imapConnect: { _, _ in throw SyncError.rede("sem servidor neste teste") }
        )
        await runner.start()
        try await Task.sleep(for: .milliseconds(100))

        let porta = DatabaseCommandPort(database: db, signal: sinal)
        try porta.setRead(true, accountID: "conta-a", messageIDs: [idIMAP(1)])

        // A tentativa gasta é a prova: sem o aviso, ela só apareceria no
        // próximo ciclo ocioso — o minuto que o dono viu.
        let atraso = try await esperaAte(
            { (try? self.tentativas(db)) == 1 }, "O executor tentar a operação"
        )
        #expect(atraso < Self.teto)
        await runner.stop()
    }

    @Test("Uma rajada de ações sai inteira sem esperar o ciclo ocioso")
    func rajada() async throws {
        let db = try banco()
        let espelho = EspelhoCronometrado(atrasoDaPrimeira: .milliseconds(300))
        let (executor, porta, _) = trio(db, espelho)
        await executor.start()
        try await Task.sleep(for: .milliseconds(100))

        // Três operações que a coalescência **não** junta (valores e tipos
        // diferentes), enfileiradas em sequência: a primeira segura o dreno, e
        // as outras duas chegam com o ator ocupado.
        try porta.setRead(true, accountID: "conta-a", messageIDs: [idIMAP(1)])
        try porta.setRead(false, accountID: "conta-a", messageIDs: [idIMAP(2)])
        try porta.move(to: .archived, accountID: "conta-a", messageIDs: [idIMAP(3)])

        try await esperaAte(
            { await espelho.quantas == 3 }, teto: .milliseconds(300) + Self.teto,
            "As três chegarem ao espelho"
        )
        #expect(await espelho.quantas == 3)
        await executor.stop()
    }
}
