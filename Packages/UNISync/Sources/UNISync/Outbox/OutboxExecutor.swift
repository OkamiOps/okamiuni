import Foundation
import GRDB
import UNICore
import os

/// Quem leva a fila de saída de **uma conta** ao servidor.
///
/// Um ator por conta, e a razão é a mesma do `ImapSession`: a fila é ordenada,
/// e ordem só existe se houver um consumidor de cada vez. Duas contas correm em
/// paralelo (é o caso normal de quem tem trabalho e pessoal); duas operações da
/// mesma conta, nunca.
///
/// ## O invariante
///
/// **Nenhuma operação se perde, nenhuma executa em dobro.** Ele se apoia em
/// três coisas, e cada uma tem teste que morre se ela sair:
///
/// 1. **Reivindicação atômica.** Uma operação só é executada por quem
///    conseguiu virá-la de `pendente` para `executando` num `UPDATE … WHERE
///    state = 'pendente'` que mudou linha. Quem não mudou não executa.
/// 2. **Recuperação na partida.** Linha em `executando` na abertura é
///    operação de uma execução que morreu no meio (app fechado, processo
///    morto): ela volta para `pendente` e é tentada de novo. Sem isso, ela
///    ficaria parada para sempre — a operação perdida.
/// 3. **Idempotência da operação.** Reexecutar é seguro porque as operações
///    do espelho são idempotentes: `batchModify` e `UID STORE` põem ou tiram,
///    nunca invertem; o mover do IMAP, que é o único `COPY` não idempotente,
///    pergunta ao destino antes de copiar (ver `ImapMirror.moveUm`).
///
/// O ponto 3 é o que torna o 2 possível: recuperar é reexecutar, e reexecutar
/// só é seguro porque não duplica efeito. Um timeout ambíguo — o servidor
/// aplicou e a resposta não chegou — cai exatamente nesse caminho.
public actor OutboxExecutor {
    /// O que uma passada da fila fez. É o que o teste afirma, e é o que o laço
    /// usa para saber quando acordar de novo.
    public struct Outcome: Sendable, Equatable {
        /// Quantas linhas do `outbox` saíram como `feita`.
        public var executadas: Int
        /// A falha que **parou** a fila desta conta. Nula é fila viva.
        public var falhaPermanente: SyncError?
        /// Quando a próxima tentativa está marcada, se houver alguma esperando.
        public var proximaTentativa: Date?
        /// Quantas operações continuam esperando (pendentes ou paradas). É o
        /// número que a linha da conta mostra como "n aguardando".
        public var pendentes: Int
    }

    private let accountID: String
    private let database: SyncDatabase
    private let mirror: any MailMirror
    private let now: @Sendable () -> Date
    /// Injetável para o teste não levar minutos esperando um recuo real.
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    /// O tremor do recuo, entre 0 e 1. Injetável porque um teste que afirma o
    /// instante da próxima tentativa não pode depender de sorte.
    private let jitter: @Sendable () -> Double
    /// Para onde vai a falha permanente: é assim que o erro chega ao
    /// `AccountStatus`, que a janela de Contas e a lateral já mostram.
    private let report: @Sendable (String, SyncError?) -> Void

    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "OutboxExecutor")

    private var loop: Task<Void, Never>?
    private var esperando: CheckedContinuation<Void, Never>?
    private var sinalPendente = false
    private var recuperou = false
    /// A falha que parou a fila. Enquanto ela existir, o executor não tenta
    /// mais nada — é o "para a fila daquela conta" da spec, e não um descarte:
    /// as operações continuam no banco, marcadas, esperando a pessoa mandar
    /// tentar de novo.
    private var parada: SyncError?

    /// O primeiro recuo, em segundos. Dobra a cada tentativa até o teto.
    public static let recuoBase: TimeInterval = 2
    public static let recuoTeto: TimeInterval = 300
    /// De quanto em quanto tempo o laço reconfere a fila quando não há nada
    /// marcado nem sinal. Rede que volta sem aviso é o caso que isto cobre até
    /// o `NWPathMonitor` da tarefa 3 chegar.
    public static let intervaloOcioso: TimeInterval = 60

    public init(
        accountID: String,
        database: SyncDatabase,
        mirror: any MailMirror,
        now: @Sendable @escaping () -> Date = Date.init,
        sleeper: @Sendable @escaping (TimeInterval) async throws -> Void = { segundos in
            try await Task.sleep(for: .seconds(segundos))
        },
        jitter: @Sendable @escaping () -> Double = { Double.random(in: 0...1) },
        report: @Sendable @escaping (String, SyncError?) -> Void = { _, _ in }
    ) {
        self.accountID = accountID
        self.database = database
        self.mirror = mirror
        self.now = now
        self.sleeper = sleeper
        self.jitter = jitter
        self.report = report
    }

    // MARK: O laço

    /// Começa a consumir. Idempotente: chamar duas vezes não cria dois laços.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let resultado = await self.drain()
                // Fila parada não gira em falso: ela espera um sinal (a pessoa
                // mandando tentar de novo, ou uma ação nova) para reavaliar.
                await self.espera(
                    ate: resultado.falhaPermanente == nil ? resultado.proximaTentativa : nil
                )
            }
        }
    }

    /// Para o laço. As operações continuam no banco — parar não descarta nada.
    public func stop() {
        loop?.cancel()
        loop = nil
        esperando?.resume()
        esperando = nil
    }

    /// Acorda o executor de fora, sem `await` — é o que a porta de escrita
    /// chama pelo `OutboxSignal` quando enfileira.
    public nonisolated func wake() {
        Task { await self.acorda() }
    }

    /// Religa uma fila parada por falha permanente e tenta de novo. É o "tentar
    /// de novo" que a UI oferece ao lado do erro.
    public func retryAfterPermanentFailure() {
        parada = nil
        report(accountID, nil)
        acorda()
    }

    private func acorda() {
        sinalPendente = true
        esperando?.resume()
        esperando = nil
    }

    private func espera(ate prazo: Date?) async {
        if sinalPendente {
            sinalPendente = false
            return
        }
        let atraso = prazo.map { max(0, $0.timeIntervalSince(now())) } ?? Self.intervaloOcioso
        let sleeper = self.sleeper
        let relogio = Task { [weak self] in
            try? await sleeper(atraso)
            await self?.acorda()
        }
        await withCheckedContinuation { continuation in
            esperando = continuation
        }
        relogio.cancel()
        sinalPendente = false
    }

    // MARK: Uma passada

    /// Consome tudo o que está pronto agora, em ordem, e para no primeiro que
    /// não puder ser feito.
    ///
    /// Pública e sem laço de propósito: é assim que os testes afirmam ordem,
    /// coalescência, recuo e parada sem depender de tempo passando.
    @discardableResult
    public func drain() async -> Outcome {
        if !recuperou {
            recuperou = true
            await recupera()
        }
        guard parada == nil else {
            return Outcome(
                executadas: 0, falhaPermanente: parada,
                proximaTentativa: nil, pendentes: (try? await conta()) ?? 0
            )
        }

        var executadas = 0
        while let lote = await proximoLote() {
            do {
                try await mirror.apply(lote.operacao, targets: lote.alvos)
                await marca(lote.ids, estado: .feita)
                executadas += lote.ids.count
            } catch {
                let erro = (error as? SyncError) ?? .rede(error.localizedDescription)
                if Self.ehPermanente(erro) {
                    await marca(lote.ids, estado: .falhou)
                    parada = erro
                    report(accountID, erro)
                    log.error("""
                        A fila de \(self.accountID, privacy: .private) parou: \
                        \(erro.mensagem, privacy: .public)
                        """)
                    break
                }
                // Transitório: a operação volta para `pendente`, com uma
                // tentativa a mais e o instante da próxima. Ela **não** sai da
                // fila, e o resto da fila não passa na frente dela — ordem é
                // ordem.
                await adia(lote.ids, tentativas: lote.tentativas)
                break
            }
        }

        let pendentes = (try? await conta()) ?? 0
        return Outcome(
            executadas: executadas, falhaPermanente: parada,
            proximaTentativa: (try? await proximoPrazo()) ?? nil, pendentes: pendentes
        )
    }

    // MARK: A leitura da fila

    /// Um lote pronto para ir ao servidor: uma operação, os ids das linhas que
    /// ela representa e os alvos já decodificados.
    private struct Lote {
        let ids: [String]
        let operacao: MailOperation
        let alvos: [MessageCoordinate]
        let tentativas: Int
    }

    private func proximoLote() async -> Lote? {
        guard let prontas = try? await prontas(), !prontas.isEmpty else { return nil }
        let coalescido = Self.coalesce(prontas)
        guard let operacao = coalescido.operacao else {
            // Linha com JSON que não decodifica: não dá para executar e não dá
            // para fingir que foi feita. Ela para a fila, como qualquer falha
            // permanente — nunca é descartada em silêncio.
            await marca(coalescido.ids, estado: .falhou)
            parada = .resposta("Uma operação da fila não pôde ser lida.")
            report(accountID, parada)
            return nil
        }
        guard await reivindica(coalescido.ids) else { return nil }
        return Lote(
            ids: coalescido.ids,
            operacao: operacao,
            alvos: operacao.messageIDs.compactMap {
                MessageIdentity.parse($0, accountID: accountID)
            },
            tentativas: coalescido.tentativas
        )
    }

    /// A coalescência, e só ela: **N `setRead` consecutivos do mesmo valor
    /// viram um**.
    ///
    /// Consecutivos, e do mesmo valor, porque é só aí que juntar preserva o
    /// resultado. Juntar `ler` com `não-ler` inverteria o sentido de uma das
    /// duas; juntar por cima de um `move` que está entre elas mudaria a ordem
    /// em que o servidor vê as coisas. O ganho é o que a spec pede: uma seleção
    /// de trinta mensagens marcada como lida vira **um** `batchModify` (ou um
    /// `UID STORE` por pasta), e não trinta idas e voltas.
    ///
    /// `internal` para o teste poder afirmá-la sem banco.
    static func coalesce(_ registros: [OutboxRecord]) -> (ids: [String], operacao: MailOperation?, tentativas: Int) {
        guard let primeiro = registros.first else { return ([], nil, 0) }
        guard case .setRead(let isRead, let ids)? = primeiro.operation else {
            return ([primeiro.id], primeiro.operation, primeiro.attempts)
        }
        var linhas = [primeiro.id]
        var alvos = ids
        var tentativas = primeiro.attempts
        for registro in registros.dropFirst() {
            guard case .setRead(let outroValor, let outrosIDs)? = registro.operation,
                  outroValor == isRead
            else { break }
            linhas.append(registro.id)
            alvos.append(contentsOf: outrosIDs)
            tentativas = max(tentativas, registro.attempts)
        }
        // A ordem dos ids não importa para o servidor, mas a repetição sim:
        // mandar o mesmo id duas vezes num `batchModify` é desperdício, e num
        // `UID STORE` é um UID repetido no conjunto.
        var vistos = Set<String>()
        let unicos = alvos.filter { vistos.insert($0).inserted }
        return (linhas, .setRead(isRead: isRead, messageIDs: unicos), tentativas)
    }

    private func prontas() async throws -> [OutboxRecord] {
        let agora = now()
        let conta = accountID
        return try await database.pool.read { db in
            try OutboxRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM outbox
                    WHERE accountID = ? AND state = ? AND nextAttemptAt <= ?
                    ORDER BY createdAt, rowid
                    """,
                arguments: [conta, OutboxState.pendente.rawValue, agora.timeIntervalSince1970]
            )
        }
    }

    private func conta() async throws -> Int {
        let conta = accountID
        return try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM outbox WHERE accountID = ? AND state <> ?",
                arguments: [conta, OutboxState.feita.rawValue]
            ) ?? 0
        }
    }

    private func proximoPrazo() async throws -> Date? {
        let conta = accountID
        let bruto = try await database.pool.read { db in
            try Double.fetchOne(
                db,
                sql: """
                    SELECT min(nextAttemptAt) FROM outbox
                    WHERE accountID = ? AND state = ?
                    """,
                arguments: [conta, OutboxState.pendente.rawValue]
            )
        }
        return bruto.map(Date.init(timeIntervalSince1970:))
    }

    // MARK: As transições

    /// Devolve `pendente` o que ficou `executando` de uma execução que morreu
    /// no meio. **É a metade "não se perde" do invariante.**
    private func recupera() async {
        let conta = accountID
        do {
            let quantas = try await database.pool.write { db -> Int in
                try db.execute(
                    sql: "UPDATE outbox SET state = ? WHERE accountID = ? AND state = ?",
                    arguments: [OutboxState.pendente.rawValue, conta, OutboxState.executando.rawValue]
                )
                return db.changesCount
            }
            if quantas > 0 {
                log.notice("""
                    \(quantas, privacy: .public) operações interrompidas de \
                    \(self.accountID, privacy: .private) voltaram para a fila.
                    """)
            }
        } catch {
            log.error("Não foi possível recuperar a fila: \(error)")
        }
    }

    /// A reivindicação atômica. **É a metade "não executa em dobro".**
    ///
    /// O `WHERE state = 'pendente'` é o que faz duas passadas concorrentes não
    /// executarem a mesma operação: a segunda muda zero linhas e desiste.
    private func reivindica(_ ids: [String]) async -> Bool {
        let conta = accountID
        do {
            return try await database.pool.write { db -> Bool in
                let marcadores = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: """
                        UPDATE outbox SET state = ?
                        WHERE id IN (\(marcadores)) AND accountID = ? AND state = ?
                        """,
                    arguments: StatementArguments(
                        [OutboxState.executando.rawValue] + ids + [conta, OutboxState.pendente.rawValue]
                    )
                )
                return db.changesCount == ids.count
            }
        } catch {
            log.error("Não foi possível reivindicar operações da fila: \(error)")
            return false
        }
    }

    private func marca(_ ids: [String], estado: OutboxState) async {
        guard !ids.isEmpty else { return }
        do {
            try await database.pool.write { db in
                let marcadores = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE outbox SET state = ? WHERE id IN (\(marcadores))",
                    arguments: StatementArguments([estado.rawValue] + ids)
                )
            }
        } catch {
            log.error("Não foi possível marcar operações como \(estado.rawValue): \(error)")
        }
    }

    private func adia(_ ids: [String], tentativas: Int) async {
        let quando = now().addingTimeInterval(Self.recuo(tentativas: tentativas + 1, jitter: jitter()))
        do {
            try await database.pool.write { db in
                let marcadores = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: """
                        UPDATE outbox
                        SET state = ?, attempts = attempts + 1, nextAttemptAt = ?
                        WHERE id IN (\(marcadores))
                        """,
                    arguments: StatementArguments(
                        [OutboxState.pendente.rawValue, quando.timeIntervalSince1970]
                            + ids as [any DatabaseValueConvertible]
                    )
                )
            }
        } catch {
            log.error("Não foi possível adiar operações da fila: \(error)")
        }
    }

    // MARK: As duas tabelas de decisão

    /// Recuo exponencial com tremor.
    ///
    /// O tremor não é enfeite: sem ele, um provedor que ficou fora do ar por
    /// dez minutos recebe, no minuto em que volta, todas as filas de todos os
    /// clientes no mesmo instante — e cai de novo. O tremor é **para baixo**
    /// (entre metade e o cheio do recuo), para que ele nunca some ao teto.
    static func recuo(tentativas: Int, jitter: Double) -> TimeInterval {
        let expoente = max(0, tentativas - 1)
        let cheio = min(recuoTeto, recuoBase * pow(2, Double(expoente)))
        return cheio * (0.5 + 0.5 * min(1, max(0, jitter)))
    }

    /// O que retry não cura.
    ///
    /// A linha é traçada pela **ação que resolve**, e não pela gravidade: um
    /// 503 e uma rede caída pedem esperar, e esperar é o que o recuo faz; uma
    /// autorização revogada e um certificado inválido pedem que a pessoa faça
    /// alguma coisa, e repeti-los para sempre só esconde isso dela. `4xx` que
    /// não é 408 nem 429 é pedido malformado da nossa parte — repetir não
    /// conserta.
    static func ehPermanente(_ erro: SyncError) -> Bool {
        switch erro {
        case .rede, .quota:
            false
        case .servidor(let codigo, _):
            (400..<500).contains(codigo) && codigo != 408 && codigo != 429
        case .tls, .autenticacao, .autorizacaoRevogada, .keychain,
             .semClientID, .resposta, .banco:
            true
        }
    }
}
