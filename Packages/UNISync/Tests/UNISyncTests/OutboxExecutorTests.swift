import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// Um espelho falso: guarda o que recebeu e devolve o que o roteiro mandar.
///
/// **É a razão de `MailMirror` existir como protocolo.** Provar ordem,
/// coalescência, recuo e parada não precisa de rede nenhuma — precisa de um
/// servidor que responda o que o teste quiser, na ordem que o teste quiser.
actor EspelhoFalso: MailMirror {
    /// A n-ésima chamada devolve o n-ésimo erro; `nil` é sucesso, e a lista
    /// acabando significa "daqui em diante, sucesso".
    private var roteiro: [SyncError?]
    private(set) var chamadas: [(MailOperation, [MessageCoordinate])] = []

    init(roteiro: [SyncError?] = []) {
        self.roteiro = roteiro
    }

    func apply(_ operation: MailOperation, targets: [MessageCoordinate]) async throws {
        chamadas.append((operation, targets))
        guard !roteiro.isEmpty else { return }
        if let erro = roteiro.removeFirst() { throw erro }
    }

    var operacoes: [MailOperation] { chamadas.map(\.0) }
}

@Suite("O executor da fila de saída")
struct OutboxExecutorTests {
    private let conta = Account(
        id: "conta-a", address: "eu@meudominio.com.br", displayName: "Meu",
        provider: .imap, host: "meudominio",
        tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
        imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
        state: .ativa
    )

    private func banco() throws -> SyncDatabase {
        let db = try SyncDatabase.temporary()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
        }
        return db
    }

    /// Enfileira direto, sem passar pela projeção — estes testes são sobre o
    /// executor, e a transação da porta já tem os testes dela.
    @discardableResult
    private func enfileira(
        _ db: SyncDatabase, _ operacao: MailOperation, criadaEm: TimeInterval,
        prontaEm: TimeInterval = 0
    ) throws -> String {
        let registro = try OutboxRecord(
            accountID: "conta-a", operation: operacao,
            nextAttemptAt: Date(timeIntervalSince1970: prontaEm),
            createdAt: Date(timeIntervalSince1970: criadaEm)
        )
        try db.pool.write { try registro.insert($0) }
        return registro.id
    }

    private func estado(_ db: SyncDatabase, _ id: String) throws -> String? {
        try db.pool.read { try String.fetchOne($0, sql: "SELECT state FROM outbox WHERE id = ?", arguments: [id]) }
    }

    private func executor(
        _ db: SyncDatabase, _ espelho: EspelhoFalso,
        agora: TimeInterval = 1_000,
        report: @Sendable @escaping (String, SyncError?) -> Void = { _, _ in }
    ) -> OutboxExecutor {
        OutboxExecutor(
            accountID: "conta-a", database: db, mirror: espelho,
            now: { Date(timeIntervalSince1970: agora) },
            sleeper: { _ in },
            jitter: { 1 },
            report: report
        )
    }

    /// Um id nosso de mensagem IMAP, no formato que `MessageIdentity` escreve.
    private func idIMAP(_ uid: Int64, pasta: String = "INBOX") -> String {
        MessageIdentity.imap(
            accountID: "conta-a", folderID: "conta-a/\(pasta)", uidValidity: 42, uid: uid
        )
    }

    // MARK: - Ordem

    @Test("A fila é consumida na ordem em que foi escrita")
    func ordem() async throws {
        let db = try banco()
        let espelho = EspelhoFalso()
        try enfileira(db, .setFlagged(isFlagged: true, messageIDs: [idIMAP(1)]), criadaEm: 10)
        try enfileira(db, .move(bucket: "arquivar", messageIDs: [idIMAP(2)]), criadaEm: 20)
        try enfileira(db, .delete(messageIDs: [idIMAP(3)]), criadaEm: 30)

        let resultado = await executor(db, espelho).drain()

        #expect(resultado.executadas == 3)
        #expect(resultado.pendentes == 0)
        #expect(await espelho.operacoes == [
            .setFlagged(isFlagged: true, messageIDs: [idIMAP(1)]),
            .move(bucket: "arquivar", messageIDs: [idIMAP(2)]),
            .delete(messageIDs: [idIMAP(3)]),
        ])
    }

    @Test("Operação marcada para o futuro não é tentada antes da hora")
    func prazo() async throws {
        let db = try banco()
        let espelho = EspelhoFalso()
        let futura = try enfileira(
            db, .delete(messageIDs: [idIMAP(9)]), criadaEm: 10, prontaEm: 5_000
        )

        let resultado = await executor(db, espelho, agora: 1_000).drain()

        #expect(resultado.executadas == 0)
        #expect(await espelho.chamadas.isEmpty)
        #expect(try estado(db, futura) == "pendente")
        #expect(resultado.proximaTentativa == Date(timeIntervalSince1970: 5_000))
    }

    // MARK: - Coalescência

    @Test("N setRead consecutivos do mesmo valor viram um só")
    func coalescencia() async throws {
        let db = try banco()
        let espelho = EspelhoFalso()
        try enfileira(db, .setRead(isRead: true, messageIDs: [idIMAP(1)]), criadaEm: 10)
        try enfileira(db, .setRead(isRead: true, messageIDs: [idIMAP(2), idIMAP(3)]), criadaEm: 20)
        try enfileira(db, .setRead(isRead: true, messageIDs: [idIMAP(3)]), criadaEm: 30)

        let resultado = await executor(db, espelho).drain()

        #expect(resultado.executadas == 3)
        // Uma chamada só, com os três alvos e **sem repetir** o que apareceu
        // duas vezes.
        #expect(await espelho.operacoes == [
            .setRead(isRead: true, messageIDs: [idIMAP(1), idIMAP(2), idIMAP(3)]),
        ])
    }

    @Test("A coalescência para no primeiro que não é o mesmo setRead")
    func coalescenciaNaoAtravessa() async throws {
        let db = try banco()
        let espelho = EspelhoFalso()
        try enfileira(db, .setRead(isRead: true, messageIDs: [idIMAP(1)]), criadaEm: 10)
        try enfileira(db, .move(bucket: "depois", messageIDs: [idIMAP(2)]), criadaEm: 20)
        try enfileira(db, .setRead(isRead: true, messageIDs: [idIMAP(3)]), criadaEm: 30)
        // Ler e não-ler nunca se juntam: o resultado seria o inverso de uma
        // das duas.
        try enfileira(db, .setRead(isRead: false, messageIDs: [idIMAP(4)]), criadaEm: 40)

        await executor(db, espelho).drain()

        #expect(await espelho.operacoes == [
            .setRead(isRead: true, messageIDs: [idIMAP(1)]),
            .move(bucket: "depois", messageIDs: [idIMAP(2)]),
            .setRead(isRead: true, messageIDs: [idIMAP(3)]),
            .setRead(isRead: false, messageIDs: [idIMAP(4)]),
        ])
    }

    // MARK: - Retry com recuo

    @Test("Falha de rede não perde a operação: ela volta para a fila, adiada")
    func retryDepoisDeFalhaDeRede() async throws {
        let db = try banco()
        let espelho = EspelhoFalso(roteiro: [.rede("cabo na tomada")])
        let id = try enfileira(db, .delete(messageIDs: [idIMAP(7)]), criadaEm: 10)

        let primeira = await executor(db, espelho, agora: 1_000).drain()

        #expect(primeira.executadas == 0)
        #expect(primeira.falhaPermanente == nil)
        #expect(primeira.pendentes == 1)
        #expect(try estado(db, id) == "pendente")
        // Recuo base com o tremor no máximo: dois segundos cheios.
        #expect(primeira.proximaTentativa == Date(timeIntervalSince1970: 1_002))
        let tentativas = try await db.pool.read {
            try Int.fetchOne($0, sql: "SELECT attempts FROM outbox WHERE id = ?", arguments: [id])
        }
        #expect(tentativas == 1)

        // A rede voltou: a mesma operação é executada, uma vez só.
        let segunda = await executor(db, espelho, agora: 2_000).drain()
        #expect(segunda.executadas == 1)
        #expect(try estado(db, id) == "feita")
        #expect(await espelho.chamadas.count == 2)
    }

    @Test("O recuo dobra e o tremor nunca soma ao teto")
    func recuo() {
        #expect(OutboxExecutor.recuo(tentativas: 1, jitter: 1) == 2)
        #expect(OutboxExecutor.recuo(tentativas: 2, jitter: 1) == 4)
        #expect(OutboxExecutor.recuo(tentativas: 3, jitter: 1) == 8)
        // O tremor puxa para baixo, entre metade e o cheio.
        #expect(OutboxExecutor.recuo(tentativas: 3, jitter: 0) == 4)
        // E nunca passa do teto.
        #expect(OutboxExecutor.recuo(tentativas: 40, jitter: 1) == OutboxExecutor.recuoTeto)
    }

    @Test("A operação que falhou não deixa a de trás passar na frente")
    func ordemSobrevive() async throws {
        let db = try banco()
        let espelho = EspelhoFalso(roteiro: [.rede("caiu")])
        try enfileira(db, .delete(messageIDs: [idIMAP(1)]), criadaEm: 10)
        try enfileira(db, .delete(messageIDs: [idIMAP(2)]), criadaEm: 20)

        await executor(db, espelho).drain()

        #expect(await espelho.operacoes == [.delete(messageIDs: [idIMAP(1)])])
    }

    // MARK: - Falha permanente

    @Test("Autorização revogada para a fila da conta e marca o erro nela")
    func falhaPermanenteParaAFila() async throws {
        let db = try banco()
        let espelho = EspelhoFalso(roteiro: [.autorizacaoRevogada])
        let primeira = try enfileira(db, .delete(messageIDs: [idIMAP(1)]), criadaEm: 10)
        let segunda = try enfileira(db, .delete(messageIDs: [idIMAP(2)]), criadaEm: 20)

        let relatados = Relator()
        let executor = executor(db, espelho, report: { conta, erro in relatados.anota(conta, erro) })
        let resultado = await executor.drain()

        #expect(resultado.falhaPermanente == .autorizacaoRevogada)
        #expect(try estado(db, primeira) == "falhou")
        // A de trás **não** é tentada: a fila parou, e ela continua no banco.
        #expect(try estado(db, segunda) == "pendente")
        #expect(await espelho.chamadas.count == 1)
        #expect(relatados.ultimo == .autorizacaoRevogada)
        // Nada de descarte silencioso: as duas continuam contando como
        // pendentes para a linha da conta.
        #expect(resultado.pendentes == 2)

        // Uma segunda passada não tenta nada enquanto a fila estiver parada.
        let denovo = await executor.drain()
        #expect(await espelho.chamadas.count == 1)
        #expect(denovo.falhaPermanente == .autorizacaoRevogada)
    }

    @Test("O que retry cura e o que não cura")
    func classificacao() {
        #expect(!OutboxExecutor.ehPermanente(.rede("timeout")))
        #expect(!OutboxExecutor.ehPermanente(.quota))
        #expect(!OutboxExecutor.ehPermanente(.servidor(codigo: 503, mensagem: "")))
        #expect(!OutboxExecutor.ehPermanente(.servidor(codigo: 429, mensagem: "")))
        #expect(OutboxExecutor.ehPermanente(.autorizacaoRevogada))
        #expect(OutboxExecutor.ehPermanente(.autenticacao))
        #expect(OutboxExecutor.ehPermanente(.servidor(codigo: 400, mensagem: "")))
    }

    // MARK: - O invariante: nada se perde, nada executa em dobro

    @Test("Operação interrompida no meio volta para a fila na partida seguinte")
    func recuperaOExecutando() async throws {
        let db = try banco()
        let id = try enfileira(db, .delete(messageIDs: [idIMAP(5)]), criadaEm: 10)
        // O app morreu com a operação em voo: a linha ficou em `executando`.
        try await db.pool.write {
            try $0.execute(sql: "UPDATE outbox SET state = 'executando' WHERE id = ?", arguments: [id])
        }

        let espelho = EspelhoFalso()
        let resultado = await executor(db, espelho).drain()

        // **A mutação:** apagar a recuperação em `OutboxExecutor.recupera`
        // deixa esta linha parada em `executando` para sempre — a operação
        // perdida — e as três afirmações abaixo caem.
        #expect(resultado.executadas == 1)
        #expect(try estado(db, id) == "feita")
        #expect(await espelho.operacoes == [.delete(messageIDs: [idIMAP(5)])])
    }

    @Test("Dois executores da mesma conta não executam a mesma operação duas vezes")
    func reivindicacaoAtomica() async throws {
        let db = try banco()
        let espelho = EspelhoFalso()
        try enfileira(db, .delete(messageIDs: [idIMAP(1)]), criadaEm: 10)

        // Duas passadas concorrentes sobre a mesma fila. Só uma pode executar:
        // a reivindicação (`UPDATE … WHERE state = 'pendente'`) é quem decide.
        async let a = executor(db, espelho).drain()
        async let b = executor(db, espelho).drain()
        _ = await (a, b)

        #expect(await espelho.chamadas.count == 1)
        let feitas = try await db.pool.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox WHERE state = 'feita'")
        }
        #expect(feitas == 1)
    }

    @Test("O timeout ambíguo reexecuta, e a operação continua sendo uma só")
    func timeoutAmbiguo() async throws {
        let db = try banco()
        // O servidor aplicou e a resposta se perdeu: do nosso lado é erro de
        // rede, e a operação volta para a fila.
        let espelho = EspelhoFalso(roteiro: [.rede("a resposta nunca chegou")])
        let id = try enfileira(db, .setRead(isRead: true, messageIDs: [idIMAP(1)]), criadaEm: 10)

        await executor(db, espelho, agora: 1_000).drain()
        await executor(db, espelho, agora: 2_000).drain()

        // A operação mandada é idêntica das duas vezes — "marque como lida",
        // nunca "inverta". É isso que faz a reexecução ser inofensiva no
        // servidor, e é o contrato que `GmailMirror` e `ImapMirror` honram.
        #expect(await espelho.operacoes == [
            .setRead(isRead: true, messageIDs: [idIMAP(1)]),
            .setRead(isRead: true, messageIDs: [idIMAP(1)]),
        ])
        // E a fila registra uma execução, não duas.
        #expect(try estado(db, id) == "feita")
        let feitas = try await db.pool.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox WHERE state = 'feita'")
        }
        #expect(feitas == 1)
    }

    // MARK: - As coordenadas

    @Test("O id da mensagem carrega as coordenadas do servidor, ida e volta")
    func coordenadas() {
        let gmail = MessageIdentity.gmail(accountID: "conta-a", serverID: "18f2c")
        #expect(MessageIdentity.parse(gmail, accountID: "conta-a") == .gmail(serverID: "18f2c"))

        let imap = MessageIdentity.imap(
            accountID: "conta-a", folderID: "conta-a/OkamiUNI/Depois", uidValidity: 42, uid: 9001
        )
        #expect(MessageIdentity.parse(imap, accountID: "conta-a")
            == .imap(folderName: "OkamiUNI/Depois", uidValidity: 42, uid: 9001))

        // Pasta com `:` no nome — legal no IMAP — continua saindo inteira,
        // porque a leitura é de trás para a frente.
        let esquisita = MessageIdentity.imap(
            accountID: "conta-a", folderID: "conta-a/Notas:2026", uidValidity: 7, uid: 3
        )
        #expect(MessageIdentity.parse(esquisita, accountID: "conta-a")
            == .imap(folderName: "Notas:2026", uidValidity: 7, uid: 3))

        // Id de outra conta não é decodificado como se fosse desta.
        #expect(MessageIdentity.parse(gmail, accountID: "conta-b") == nil)
    }

    @Test("Apagar definitivamente ainda alcança o servidor com a linha local já apagada")
    func apagaComALinhaJaSumida() async throws {
        let db = try banco()
        // É o que `DatabaseCommandPort.deletePermanently` faz: apaga a linha de
        // `message` **na mesma transação** do enfileiramento. Quando o executor
        // acorda, não há linha para consultar — e a operação tem de chegar ao
        // servidor mesmo assim.
        let espelho = EspelhoFalso()
        try enfileira(db, .deletePermanently(messageIDs: [idIMAP(77, pasta: "Trash")]), criadaEm: 10)

        let resultado = await executor(db, espelho).drain()

        #expect(resultado.executadas == 1)
        #expect(await espelho.chamadas.first?.1 == [
            .imap(folderName: "Trash", uidValidity: 42, uid: 77),
        ])
    }

    // MARK: - O disparo

    @Test("A porta de escrita acorda o executor ao enfileirar")
    func acordaAoEnfileirar() async throws {
        let db = try banco()
        try await db.pool.write { conexao in
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(
                Message(
                    id: idIMAP(1), accountID: "conta-a",
                    from: Contact(name: "Marina", address: "marina@clientepremium.com"),
                    receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    subject: "Oi", snippet: "Trecho", body: ["Corpo"],
                    tags: [], bucket: .today, isRead: false,
                    summary: nil, detectedEvent: nil,
                    serverID: "1", uidValidity: 42
                ),
                folderID: "conta-a/INBOX"
            ).insert(conexao)
        }

        let sinal = OutboxSignal()
        let espelho = EspelhoFalso()
        // Relógio de verdade aqui, e só aqui: quem enfileira é a porta, que
        // carimba `nextAttemptAt` com o `Date()` real. Um relógio congelado no
        // passado faria a operação parecer marcada para o futuro.
        let executor = OutboxExecutor(
            accountID: "conta-a", database: db, mirror: espelho, jitter: { 1 }
        )
        sinal.register(accountID: "conta-a") { [weak executor] in executor?.wake() }
        await executor.start()

        let porta = DatabaseCommandPort(database: db, signal: sinal)
        try porta.setRead(true, accountID: "conta-a", messageIDs: [idIMAP(1)])

        // O executor acorda sozinho — sem o aviso, ele só olharia a fila no
        // próximo ciclo ocioso, um minuto depois.
        try await esperaAte { await espelho.chamadas.count == 1 }
        #expect(await espelho.operacoes == [.setRead(isRead: true, messageIDs: [idIMAP(1)])])
        await executor.stop()
    }

    /// Espera uma condição virar verdadeira, com teto. É o único lugar destes
    /// testes que depende de tempo passando — e ele depende de um laço acordar,
    /// não de um relógio bater.
    private func esperaAte(
        _ condicao: @Sendable () async -> Bool, teto: Int = 200
    ) async throws {
        for _ in 0..<teto {
            if await condicao() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("A condição não se cumpriu dentro do teto.")
    }
}

/// Um relator de erros de conta, para o teste afirmar que a falha permanente
/// chega ao `AccountStatus`.
final class Relator: @unchecked Sendable {
    private let lock = NSLock()
    private var erros: [(String, SyncError?)] = []

    func anota(_ conta: String, _ erro: SyncError?) {
        lock.lock()
        erros.append((conta, erro))
        lock.unlock()
    }

    var ultimo: SyncError? {
        lock.lock()
        defer { lock.unlock() }
        return erros.last?.1
    }
}
