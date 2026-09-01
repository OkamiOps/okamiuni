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
    ///
    /// **As linhas `falhou` voltam para `pendente` antes de a trava sair**, e a
    /// ordem importa nas duas leituras da palavra. Sem devolvê-las, "tentar de
    /// novo" só destravava a fila: a operação que de fato falhou continuava
    /// marcada `falhou`, que nenhuma consulta do executor lê — ela nunca mais
    /// seria tentada, e a que estava atrás dela passaria na frente. Devolvidas,
    /// elas voltam a ser as primeiras da fila (a ordem é `createdAt, rowid`, e
    /// nada disso mudou), então a operação parada reexecuta antes da seguinte.
    ///
    /// `nextAttemptAt` volta para agora, e `attempts` para zero: quem mandou
    /// tentar de novo foi a pessoa, e fazê-la esperar o recuo acumulado de uma
    /// falha que ela já viu e já tratou seria responder a um pedido explícito
    /// com silêncio.
    public func retryAfterPermanentFailure() async {
        await requeueFalhadas()
        parada = nil
        report(accountID, nil)
        acorda()
    }

    private func requeueFalhadas() async {
        let conta = accountID
        let agora = now().timeIntervalSince1970
        do {
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE outbox
                        SET state = ?, attempts = 0, nextAttemptAt = ?, lastError = NULL
                        WHERE accountID = ? AND state = ?
                        """,
                    arguments: [
                        OutboxState.pendente.rawValue, agora, conta, OutboxState.falhou.rawValue,
                    ]
                )
            }
        } catch {
            log.error("Não foi possível devolver à fila as operações que falharam: \(error)")
        }
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
            // **A parada que a sessão anterior deixou.** `recupera()` só
            // devolve o que ficou `executando`; linha `falhou` continua
            // `falhou`, e nenhuma consulta daqui a lê. Sem este trecho, a
            // abertura seguinte encontrava a fila travada e não sabia disso:
            // não relatava nada — a conta aparecia saudável com a fila parada
            // desde a véspera — e ainda executava **por cima** da falha as
            // operações que estavam atrás dela, quebrando a ordem em silêncio.
            await libertaParadasLocais()
            if let gravada = await paradaGravada() {
                parada = gravada
                report(accountID, gravada)
            }
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
                let onde = try await mirror.apply(lote.operacao, targets: lote.alvos)
                await gravaAEnviada(lote.operacao, gravadaEm: onde)
                await conclui(lote.ids)
                executadas += lote.ids.count
            } catch {
                let erro = (error as? SyncError) ?? .rede(error.localizedDescription)
                if Self.ehPermanente(erro) {
                    await marca(lote.ids, estado: .falhou, causa: erro)
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
            let ilegivel = SyncError.resposta("Uma operação da fila não pôde ser lida.")
            await marca(coalescido.ids, estado: .falhou, causa: ilegivel)
            parada = ilegivel
            report(accountID, ilegivel)
            return nil
        }
        guard await reivindica(coalescido.ids) else { return nil }

        let messageIDs = operacao.messageIDs
        let remotos = messageIDs.filter { !MessageIdentity.isLocalDraft($0) }
        let targets = remotos.compactMap {
            MessageIdentity.parse($0, accountID: accountID)
        }
        let requiresTargets: Bool
        switch operacao {
        case .emptyTrash, .send:
            requiresTargets = false
        default:
            requiresTargets = true
        }
        if requiresTargets {
            if remotos.isEmpty {
                // Rascunho local: não há o que mandar ao servidor. Concluir
                // em silêncio **não** é o sucesso vazio que o invariante
                // proíbe — o espelho nem é chamado. Falhar permanente aqui
                // parava a fila e os deletes reais do Gmail ficavam presos.
                await conclui(coalescido.ids)
                return await proximoLote()
            }
            guard !remotos.isEmpty && targets.count == remotos.count else {
                // `compactMap` não pode transformar uma identidade inválida em
                // sucesso com lote vazio: o espelho não teria o que alterar e o
                // executor apagaria a operação como se o servidor a aceitasse.
                let invalid = SyncError.resposta(
                    "Uma operação da fila aponta para uma mensagem sem coordenada remota válida."
                )
                await marca(coalescido.ids, estado: .falhou, causa: invalid)
                parada = invalid
                report(accountID, invalid)
                return nil
            }
        }
        return Lote(
            ids: coalescido.ids,
            operacao: operacao,
            alvos: targets,
            tentativas: coalescido.tentativas
        )
    }

    /// Linhas `falhou` que só apontam para rascunho local: tira da frente
    /// para a fila voltar a andar. É o conserto da sessão que apagou um
    /// rascunho e, desde então, nada mais chegou no Gmail.
    private func libertaParadasLocais() async {
        let conta = accountID
        let falhou = OutboxState.falhou.rawValue
        let linhas = (try? await database.pool.read { db in
            try OutboxRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM outbox
                    WHERE accountID = ? AND state = ?
                    ORDER BY createdAt, rowid
                    """,
                arguments: [conta, falhou]
            )
        }) ?? []
        var libertar: [String] = []
        for linha in linhas {
            guard let operacao = linha.operation else { break }
            let ids = operacao.messageIDs
            guard !ids.isEmpty, ids.allSatisfy(MessageIdentity.isLocalDraft) else { break }
            libertar.append(linha.id)
        }
        await conclui(libertar)
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

    /// Operação feita **sai da tabela**.
    ///
    /// Marcá-la `feita` e deixá-la lá faria o `outbox` crescer para sempre: uma
    /// linha por ação, de toda conta, desde a instalação. O estado `feita` do
    /// enum continua existindo porque ele é o vocabulário da transição — mas
    /// ele é o instante entre executar e apagar, não uma prateleira.
    ///
    /// Isso **não** enfraquece o invariante: quem garante o "não executa em
    /// dobro" é a reivindicação (`pendente` → `executando`), que acontece antes
    /// de o espelho ser chamado. Uma linha apagada é uma linha que ninguém mais
    /// reivindica.
    private func conclui(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            try await database.pool.write { db in
                let marcadores = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM outbox WHERE id IN (\(marcadores))",
                    arguments: StatementArguments(ids)
                )
            }
        } catch {
            log.error("Não foi possível tirar da fila as operações concluídas: \(error)")
        }
    }

    /// A mensagem enviada vira linha da caixa Enviadas — **depois** de o
    /// servidor confirmar, e nunca antes.
    ///
    /// Aqui, e não no enfileiramento: a linha só existe quando a mensagem de
    /// fato saiu. Gravá-la no "Enviar" mostraria em Enviadas o que ainda está
    /// na fila, e o que a fila recusar (endereço inexistente) ficaria lá para
    /// sempre dizendo que foi enviado.
    ///
    /// E aqui, e não no espelho: o espelho fala com o servidor e não toca o
    /// banco — é isso que deixa os dois serem testados sem o outro. O que o
    /// espelho devolve é a coordenada; quem escreve é quem já escreve.
    ///
    /// Falhar aqui **não** desfaz o envio nem para a fila: a mensagem já saiu,
    /// e a cópia chega pela sincronização de qualquer jeito — o servidor
    /// guardou a dele. Vai para o log, como a falha do `APPEND`.
    private func gravaAEnviada(_ operacao: MailOperation, gravadaEm onde: MessageCoordinate?) async {
        guard case .send(let mensagem) = operacao, let onde else { return }
        let agora = now()
        let conta = accountID
        do {
            try await database.pool.write { db in
                // A chave da conversa sai daqui de dentro porque ela depende da
                // mensagem respondida, que está no banco — ver
                // `SentCopy.linhas(_:gravadaEm:accountID:now:threadKey:)`.
                let chave = try ThreadKeyResolver.resolve(
                    db, accountID: conta, messageID: mensagem.messageID,
                    inReplyTo: mensagem.inReplyTo, references: mensagem.references,
                    subject: mensagem.subject,
                    fallback: ThreadKey.rfc(accountID: conta, messageID: mensagem.messageID)
                )
                let linhas = SentCopy.linhas(
                    mensagem, gravadaEm: onde, accountID: conta, now: agora,
                    threadKey: chave
                )
                try linhas.folder.save(db)
                try MessageRecord(linhas.message, folderID: linhas.folder.id).savePreservingIntelligenceProjection(db)
                if !linhas.message.body.isEmpty {
                    try InitialLoader.gravaCorpo(
                        db, id: linhas.message.id, paragrafos: linhas.message.body,
                        // A cópia local não passa pelo decodificador MIME, mas
                        // precisa preservar o HTML que acabou de sair (inclui
                        // assinatura formatada). `nil` faria o leitor buscar
                        // de novo no servidor; `""` apagaria a formatação.
                        html: EmailSignature.sanitizedHTML(
                            mensagem.html, inlineResources: mensagem.inlineResources
                        ) ?? "", calendarICS: nil
                    )
                }
            }
        } catch {
            log.error("A mensagem enviada não pôde ser gravada em Enviadas: \(error)")
        }
    }

    /// A causa vai junto com o estado, na **mesma** escrita: uma linha `falhou`
    /// sem a causa ao lado é a fila parada sem ninguém que saiba por quê — e
    /// duas escritas separadas deixariam essa janela aberta de verdade, no
    /// intervalo entre elas.
    private func marca(_ ids: [String], estado: OutboxState, causa: SyncError? = nil) async {
        guard !ids.isEmpty else { return }
        let motivo = causa.flatMap { erro -> String? in
            guard let dados = try? JSONEncoder().encode(erro) else { return nil }
            return String(data: dados, encoding: .utf8)
        }
        do {
            try await database.pool.write { db in
                let marcadores = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE outbox SET state = ?, lastError = ? WHERE id IN (\(marcadores))",
                    arguments: StatementArguments(
                        [estado.rawValue, motivo] as [(any DatabaseValueConvertible)?]
                    ) + StatementArguments(ids)
                )
            }
        } catch {
            log.error("Não foi possível marcar operações como \(estado.rawValue): \(error)")
        }
    }

    /// A parada que a sessão anterior deixou gravada, se houver.
    ///
    /// Lê a **primeira** linha `falhou` da fila desta conta — na mesma ordem em
    /// que ela seria executada —, porque é ela que está na frente e é a causa
    /// dela que a pessoa precisa ver.
    private func paradaGravada() async -> SyncError? {
        let conta = accountID
        let linha = try? await database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT lastError FROM outbox
                    WHERE accountID = ? AND state = ?
                    ORDER BY createdAt, rowid LIMIT 1
                    """,
                arguments: [conta, OutboxState.falhou.rawValue]
            )
        }
        guard let linha = linha ?? nil else { return nil }
        let json: String? = linha["lastError"]
        guard let json, let dados = json.data(using: .utf8),
              let erro = try? JSONDecoder().decode(SyncError.self, from: dados)
        else {
            // Linha parada por uma versão anterior à v7, ou JSON que não
            // decodifica. A fila está parada de qualquer jeito, e dizer isso
            // sem a causa exata é o único caminho honesto: voltar a andar por
            // cima dela executaria a de trás na frente da que falhou.
            return .resposta("Uma operação da fila não pôde ser concluída.")
        }
        return erro
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
        // `.transitorio` é a resposta `4xx` do SMTP, que o RFC define como
        // "tente de novo" — greylisting, caixa ocupada, carga. É exatamente o
        // que o recuo existe para atravessar.
        case .rede, .quota, .transitorio:
            false
        case .servidor(let codigo, _):
            // `codigo: 0` é a forma como o `NO` do IMAP chega hoje —
            // `ImapSession.run` não tem número HTTP para dar. `NO` é recusa
            // **com motivo** ("mailbox não existe", "acima da cota de pastas",
            // "permissão negada na pasta"), e nenhum desses motivos passa por
            // insistir: repetir para sempre esconderia da pessoa a única frase
            // que diz o que aconteceu. Parar mostra a mensagem do servidor e
            // oferece "tentar de novo".
            //
            // O mapeamento fino dos códigos do `NO` (`[TRYCREATE]`, que pede
            // criar a pasta e repetir; `[INUSE]`, que pede esperar) fica para
            // quando o `ImapSession` estiver livre — está registrado no
            // relatório. Até lá, o lado seguro é o que não repete em silêncio.
            codigo == 0 || ((400..<500).contains(codigo) && codigo != 408 && codigo != 429)
        case .tls, .autenticacao, .autorizacaoRevogada, .keychain,
             .semClientID, .resposta, .banco, .recusado:
            true
        }
    }
}
