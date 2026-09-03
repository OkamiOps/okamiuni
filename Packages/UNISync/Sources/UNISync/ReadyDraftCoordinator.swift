import Foundation
import GRDB
import UNICore
import os

/// A fila que escreve a resposta **antes** de a pessoa pedir.
///
/// É irmã de `MessageIntelligenceCoordinator`, e de propósito: mesma
/// observação reativa do banco (corpo novo ou triagem nova acordam o ciclo),
/// mesmo ator serial (duas gerações concorrentes só disputariam memória),
/// mesma pausa de três faltas de ambiente, mesmo cuidado de não deixar uma
/// mensagem sem rota travar o backlog atrás dela.
///
/// O que **não** é igual, e é a decisão desta tarefa: a fila da análise anda
/// para toda mensagem com corpo; esta anda só para quem a análise já disse que
/// espera resposta, e que não é disparo em massa. Escrever rascunho de
/// newsletter seria pagar um modelo para responder a uma máquina.
public actor ReadyDraftCoordinator {
    private let database: SyncDatabase
    private let store: ReadyDraftStore
    private let assistant: any TextAssisting
    private let settingsStore: AssistantSettingsStore
    private var agenda: @Sendable () -> [AgendaItem]
    private let now: @Sendable () -> Date
    private let nowMinute: @Sendable () -> Int
    private let timeZone: @Sendable () -> TimeZone

    /// Falhas de ambiente seguidas. Zera em qualquer sucesso.
    private var consecutivePolicyFailures = 0
    private var observationTask: Task<Void, Never>?
    private var isProcessing = false
    /// A pausa mora **em memória**, e não em `analysis_queue_state`.
    ///
    /// A tabela da v15 é o que a barra lateral lê para dizer "a análise
    /// parou"; escrever aqui faria uma chave de API errada parar a análise da
    /// caixa inteira porque um rascunho falhou. A consequência aceita é que
    /// esta pausa não sobrevive a fechar o app — e ela não precisa: na próxima
    /// abertura a fila tenta de novo, e três falhas a param de novo em
    /// segundos, sem ter mandado a caixa inteira para um endpoint que recusa.
    private var pausedReason: String?

    /// Três seguidas, como na análise. Uma falha é ruído de rede; três é
    /// configuração errada.
    public static let failuresBeforePause = MessageIntelligenceCoordinator.failuresBeforePause

    /// Quantas folgas o prompt carrega, e por quantos dias ele olha. Catorze
    /// dias é o que a spec pede; três folgas é o que cabe numa frase que uma
    /// pessoa lê antes de clicar em "Enviar".
    /// O tamanho da página da fila. Vinte é o lote padrão de uma rodada; a
    /// página não fica menor do que ele para uma caixa comum resolver-se numa
    /// consulta só.
    static let pageSize = 20

    public static let agendaDays = 14
    public static let agendaMinimumMinutes = 60
    public static let agendaSlotLimit = 3

    private static let log = Logger(
        subsystem: "com.okamiops.okamiuni",
        category: "ReadyDraft"
    )

    public init(
        database: SyncDatabase,
        assistant: any TextAssisting,
        settingsStore: AssistantSettingsStore,
        agenda: @escaping @Sendable () -> [AgendaItem] = { [] },
        now: @escaping @Sendable () -> Date = { Date() },
        nowMinute: @escaping @Sendable () -> Int = {
            let componentes = Calendar.current.dateComponents([.hour, .minute], from: Date())
            return (componentes.hour ?? 0) * 60 + (componentes.minute ?? 0)
        },
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.database = database
        self.store = ReadyDraftStore(database: database)
        self.assistant = assistant
        self.settingsStore = settingsStore
        self.agenda = agenda
        self.now = now
        self.nowMinute = nowMinute
        self.timeZone = timeZone
    }

    /// Começa a observar. Idempotente, como a fila da análise.
    ///
    /// A observação conta as três tabelas que decidem o trabalho: corpo novo,
    /// triagem nova e rascunho gravado. A terceira é o que fecha o ciclo — sem
    /// ela, gravar um rascunho não acordaria a fila para a próxima mensagem, e
    /// a caixa andaria um rascunho por sincronização.
    public func start() {
        guard observationTask == nil else { return }
        let pool = database.pool
        observationTask = Task { [weak self] in
            do {
                let changes = ValueObservation.tracking { db in
                    try MessageBodyRecord.fetchCount(db)
                        &+ MessageIntelligenceRecord.fetchCount(db)
                        &+ ReadyDraftRecord.fetchCount(db)
                }
                for try await _ in changes.values(
                    in: pool, bufferingPolicy: .bufferingNewest(1)
                ) {
                    guard let self, !Task.isCancelled else { return }
                    _ = await self.processPending()
                }
            } catch is CancellationError {
                return
            } catch {
                Self.log.error("Observação do rascunho antecipado terminou: \(error)")
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Troca de onde a fila lê a agenda.
    ///
    /// A composição não alcança o EventKit: a agenda de verdade nasce no
    /// `MailStore`, no ator principal, depois desta fila existir. Sem esta
    /// porta a fila proporia horário olhando só os compromissos que o próprio
    /// app criou — e ofereceria terça 15h por cima de uma reunião do
    /// calendário do trabalho.
    public func useAgenda(_ agenda: @escaping @Sendable () -> [AgendaItem]) {
        self.agenda = agenda
    }

    /// O que a fila está fazendo. `paused` traz o motivo, como a da análise.
    public func queueState() -> AnalysisQueueState {
        pausedReason.map { AnalysisQueueState.paused(reason: $0) } ?? .running
    }

    /// Destrava a fila e tenta de novo.
    public func resumeAfterPause() async {
        pausedReason = nil
        consecutivePolicyFailures = 0
        _ = await processPending()
    }

    /// Quantos rascunhos esta rodada escreveu.
    @discardableResult
    public func processPending(limit: Int = 20) async -> Int {
        await runPass(limit: limit).completedCount
    }

    public func runPass(limit: Int = 20) async -> AnalysisPassResult {
        guard limit > 0 else { return .finished(0) }
        guard !isProcessing else { return .busy }
        guard pausedReason == nil else { return .blocked }
        isProcessing = true
        defer { isProcessing = false }

        let trabalho: [ReadyDraftWork]
        do {
            trabalho = try pendingWork(limit: limit)
        } catch {
            Self.log.error("Não foi possível ler a fila de rascunhos: \(error)")
            return .finished(0)
        }
        guard !trabalho.isEmpty else { return .finished(0) }

        // A sonda geral, uma vez por rodada: um Mac sem Apple Intelligence e
        // sem provedor não tem para onde mandar nada, e girar a fila inteira
        // para descobrir isso é trabalho por trabalho nenhum.
        guard await assistant.availability() == .available else { return .blocked }

        var escritos = 0
        for item in trabalho {
            if Task.isCancelled { break }
            // **Sem rota não é falha.** É o caso "a pessoa não deu opt-in", e
            // ele é o normal: a mensagem fica sem rascunho, a fila não conta
            // falta, e nada aparece na tela dizendo que algo quebrou.
            guard routeIsAllowed(for: item) else { continue }

            do {
                let semente = item.usesAgenda ? agendaSeed() : ""
                let texto = try await assistant.transform(
                    semente,
                    using: .draftReply,
                    context: AssistantMailContext(message: item.message)
                )
                // A mesma validação da resposta sob demanda: um motor que
                // devolve espaço em branco não escreveu rascunho nenhum, e
                // gravá-lo faria o dashboard prometer "a resposta já está
                // escrita" sobre um campo vazio.
                let limpo = try FoundationModelsTextAssistantValidation.response(texto)
                try store.save(
                    ReadyDraft(
                        messageID: item.message.id, text: limpo,
                        contentHash: item.contentHash,
                        modelVersion: assistant.modelVersion,
                        usedAgenda: item.usesAgenda
                    ),
                    at: now()
                )
                escritos += 1
                consecutivePolicyFailures = 0
            } catch is CancellationError {
                break
            } catch {
                // Resposta vazia ou inválida é defeito **desta** geração, não
                // do ambiente: a mensagem simplesmente fica sem rascunho, e a
                // volta seguinte tenta de novo se o corpo mudar.
                guard MessageIntelligenceCoordinator.isEnvironmentFailure(error) else {
                    Self.log.error("O rascunho de uma mensagem não saiu: \(error)")
                    continue
                }
                consecutivePolicyFailures += 1
                if consecutivePolicyFailures >= Self.failuresBeforePause {
                    let motivo = (error as? any LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    pausedReason = motivo
                    Self.log.error("Fila de rascunhos pausada: \(motivo, privacy: .public)")
                    break
                }
            }
        }
        return .finished(escritos)
    }

    /// Os rascunhos que a **pessoa** pediu, agora, para estas mensagens.
    ///
    /// É a mesma geração da fila, com uma diferença que é a razão de existir: o
    /// portão do opt-in não se aplica. Aquele portão pergunta "posso mandar
    /// isto sem você ter pedido?"; aqui ela pediu, na tela, com o dedo dela, e
    /// a rota é a que ela mesma configurou — é a mesma natureza do "Gerar
    /// resposta" que o leitor já tem, e que nunca consultou o opt-in.
    ///
    /// O que continua valendo: disparo em massa não ganha rascunho, o hash
    /// descartado continua descartado, e um motor indisponível não escreve
    /// nada. Devolve quantos saíram.
    @discardableResult
    public func generateOnDemand(messageIDs: [String]) async -> Int {
        let pedidos = Set(messageIDs)
        guard !pedidos.isEmpty else { return 0 }
        guard !isProcessing else { return 0 }
        isProcessing = true
        defer { isProcessing = false }

        let trabalho: [ReadyDraftWork]
        do {
            trabalho = try pendingWork(limit: pedidos.count + Self.pageSize)
                .filter { pedidos.contains($0.message.id) }
        } catch {
            Self.log.error("Não foi possível ler a fila de rascunhos: \(error)")
            return 0
        }
        guard !trabalho.isEmpty else { return 0 }
        guard await assistant.availability() == .available else { return 0 }

        var escritos = 0
        for item in trabalho {
            if Task.isCancelled { break }
            do {
                escritos += try await escreve(item) ? 1 : 0
            } catch is CancellationError {
                break
            } catch {
                // Um pedido explícito não pausa a fila de fundo: a pessoa vê
                // que nada apareceu e tenta de novo se quiser.
                Self.log.error("O rascunho pedido não saiu: \(error)")
            }
        }
        // Um pedido bem-sucedido é prova de que o ambiente voltou.
        if escritos > 0 {
            pausedReason = nil
            consecutivePolicyFailures = 0
        }
        return escritos
    }

    /// Escreve **um** rascunho e o grava. Lança o que o motor lançar — quem
    /// chama decide se aquilo pausa a fila.
    private func escreve(_ item: ReadyDraftWork) async throws -> Bool {
        let semente = item.usesAgenda ? agendaSeed() : ""
        let texto = try await assistant.transform(
            semente,
            using: .draftReply,
            context: AssistantMailContext(message: item.message)
        )
        let limpo = try FoundationModelsTextAssistantValidation.response(texto)
        try store.save(
            ReadyDraft(
                messageID: item.message.id, text: limpo,
                contentHash: item.contentHash,
                modelVersion: assistant.modelVersion,
                usedAgenda: item.usesAgenda
            ),
            at: now()
        )
        return true
    }

    // MARK: - O portão do consentimento

    /// Esta mensagem pode ser escrita por **este** motor?
    ///
    /// É literalmente o portão da análise automática, e não uma segunda regra
    /// parecida: o Foundation Models sempre pode (nada sai do Mac), e o
    /// provedor remoto só cobre o que chegou depois do clique no opt-in —
    /// `AssistantSettings.automaticAnalysisCoversMessage(receivedAt:)`, com o
    /// mesmo `arrivedLocallyAt` que `MessageAnalysisInput` já calcula (o menor
    /// entre a data do cabeçalho e a primeira vez que o app viu a mensagem).
    ///
    /// O consentimento por mensagem do acervo (`analysis_backlog_consent`)
    /// **não** entra aqui de propósito: ele foi dado para uma análise, com uma
    /// contagem e um destino na tela. Escrever rascunhos com ele seria usar um
    /// "sim" para outra pergunta.
    func routeIsAllowed(for work: ReadyDraftWork) -> Bool {
        let settings = settingsStore.snapshot()
        if settings.provider == .foundationModels { return true }
        return settings.automaticAnalysisCoversMessage(receivedAt: work.arrivedLocallyAt)
    }

    // MARK: - A fila

    /// O que ainda precisa de rascunho, do mais recente para o mais antigo.
    ///
    /// A ordem é a da análise (`receivedAt DESC`) pela mesma razão: o que
    /// chegou agora é o que a pessoa vai abrir agora.
    func pendingWork(limit: Int) throws -> [ReadyDraftWork] {
        guard limit > 0 else { return [] }
        let versao = assistant.modelVersion
        let tamanhoDaPagina = max(limit, Self.pageSize)
        var trabalho: [ReadyDraftWork] = []
        var pulados = 0
        while trabalho.count < limit {
            let linhas = try pendingRows(limit: tamanhoDaPagina, offset: pulados)
            guard !linhas.isEmpty else { break }
            pulados += linhas.count
            for linha in linhas {
                guard let item = try Self.work(linha, modelVersion: versao) else { continue }
                trabalho.append(item)
                if trabalho.count >= limit { break }
            }
            if linhas.count < tamanhoDaPagina { break }
        }
        return trabalho
    }

    /// **Uma página** da fila. O `LIMIT` é a metade importante: quem pula
    /// (disparo em massa, hash já escrito, descartado) só é conhecido depois
    /// de ler o corpo, e sem página a observação — que acorda a cada mudança
    /// de corpo, triagem ou rascunho — recarregava **todos** os corpos
    /// `needsReply` do acervo para usar vinte.
    ///
    /// A margem para os pulados é a página seguinte, e não uma consulta
    /// maior: uma caixa cuja frente é toda disparo não pode deixar a fila
    /// morrer de fome.
    nonisolated func pendingRows(limit: Int, offset: Int) throws -> [Row] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*, b.paragraphs, b.plain, i.triage AS triage,
                           r.content_hash AS draftHash,
                           r.model_version AS draftModel, r.discarded_hash AS discardedHash
                    FROM message m
                    JOIN message_body b ON b.messageID = m.id
                    JOIN message_intelligence i ON i.messageID = m.id
                    LEFT JOIN ready_draft r ON r.message_id = m.id
                    WHERE i.triage_needs_reply = 1 AND b.plain != ''
                    ORDER BY m.receivedAt DESC, m.id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [limit, offset]
            )
        }
    }

    /// A tradução de uma linha em trabalho — ou `nil` quando não há trabalho.
    static func work(_ row: Row, modelVersion: String) throws -> ReadyDraftWork? {
        let registro = try MessageRecord(row: row)
        let mensagem = registro.message(body: paragraphs(row["paragraphs"]))
        // A barreira determinística, como no ranking: o cabeçalho não é
        // palpite, e um disparo em massa não pede resposta por mais que o
        // texto peça.
        guard !mensagem.effectiveBulkMarks.isBulk else { return nil }

        let hash = ReadyDraft.contentHash(for: mensagem)
        if (row["discardedHash"] as String?) == hash { return nil }
        if (row["draftHash"] as String?) == hash,
           (row["draftModel"] as String?) == modelVersion {
            return nil
        }
        let triagem = MessageTriage.decoded(row["triage"])
        return ReadyDraftWork(
            message: mensagem,
            contentHash: hash,
            arrivedLocallyAt: registro.firstSeenAt.map { min(registro.receivedAt, $0) }
                ?? registro.receivedAt,
            usesAgenda: ReadyDraftPrompt.needsAvailability(
                triage: triagem, message: mensagem
            )
        )
    }

    /// Os parágrafos do corpo, como `message_body.paragraphs` os guarda.
    /// A mesma decodificação de `MessageBodyRecord.body`, sem montar o
    /// registro inteiro — a consulta já trouxe a coluna.
    static func paragraphs(_ json: String?) -> [String] {
        guard let dados = json?.data(using: .utf8),
              let lista = try? JSONDecoder().decode([String].self, from: dados)
        else { return [] }
        return lista
    }

    // MARK: - A agenda no pedido

    private func agendaSeed() -> String {
        let folgas = FreeSlots.next(
            days: Self.agendaDays,
            minMinutes: Self.agendaMinimumMinutes,
            agenda: agenda(),
            now: now(),
            nowMinute: nowMinute()
        )
        return ReadyDraftPrompt.agendaSeed(
            slots: Array(folgas.prefix(Self.agendaSlotLimit)), now: now()
        )
    }
}

/// Uma mensagem esperando rascunho.
public struct ReadyDraftWork: Sendable, Equatable {
    public let message: Message
    /// A versão do texto que este rascunho vai responder — a coluna
    /// `content_hash` da v20.
    public let contentHash: String
    /// Quando a mensagem apareceu **neste Mac**. É o que o portão do opt-in
    /// compara com o carimbo, e é o menor entre o cabeçalho e a primeira vez
    /// vista, pela mesma razão de `MessageAnalysisInput.arrivedLocallyAt`.
    public let arrivedLocallyAt: Date
    /// A resposta precisa propor horário.
    public let usesAgenda: Bool
}

/// O pedaço do pedido que o rascunho antecipado acrescenta.
public enum ReadyDraftPrompt {

    /// Esta resposta precisa olhar a agenda?
    ///
    /// Duas portas, e a segunda existe porque a primeira falha em silêncio: a
    /// triagem diz `.scheduling` quando o assunto é marcar horário, mas um
    /// "me passa sua disponibilidade" dentro de um pedido comum sai como
    /// `.request` — e responder isso sem olhar a agenda é como o app promete
    /// horário que já está ocupado.
    public static func needsAvailability(triage: MessageTriage?, message: Message) -> Bool {
        if triage?.intent == .scheduling { return true }
        let texto = ([message.subject, message.snippet] + message.body)
            .joined(separator: "\n")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return availabilityPhrases.contains { texto.contains($0) }
    }

    /// As frases que pedem horário, já sem acento e em minúsculas — a mesma
    /// forma em que o texto é dobrado antes da comparação.
    static let availabilityPhrases = [
        "disponibilidade", "que horario", "qual horario", "quais horarios",
        "voce tem tempo", "tem tempo", "podemos marcar", "marcar uma",
        "sua agenda", "esta livre", "estara livre", "melhor horario",
    ]

    /// As folgas em português, prontas para entrar no pedido.
    ///
    /// **Fecha o horário que o modelo pode oferecer.** Sem esta frase final o
    /// modelo escreve "que tal quinta às 10h?" a partir do nada, e o app passa
    /// a marcar reunião em cima de compromisso — que é exatamente o erro que
    /// olhar a agenda existia para evitar.
    public static func agendaSeed(slots: [FreeSlots.Slot], now: Date) -> String {
        guard !slots.isEmpty else {
            return """
                Não tenho horário livre no expediente dos próximos dias. \
                Não proponha horário nenhum; peça alternativas.
                """
        }
        let lista = slots.map { label(for: $0, now: now) }.joined(separator: "; ")
        return """
            Minha disponibilidade nos próximos dias: \(lista). \
            Proponha um destes horários; não invente outro nem prometa nada \
            fora desta lista.
            """
    }

    /// "terça 8/9 15h–17h".
    ///
    /// Dia da semana **e** data: o dia da semana é como uma pessoa combina
    /// horário, e a data é o que impede "terça" de virar a terça errada quando
    /// a resposta for lida no dia seguinte.
    static func label(for slot: FreeSlots.Slot, now: Date, calendar: Calendar = .current) -> String {
        let dia = calendar.date(byAdding: .day, value: slot.day, to: now) ?? now
        let componentes = calendar.dateComponents([.day, .month, .weekday], from: dia)
        let semana = weekdayNames[(componentes.weekday ?? 1) - 1]
        let data = "\(componentes.day ?? 1)/\(componentes.month ?? 1)"
        return "\(semana) \(data) \(hour(slot.start))–\(hour(slot.end))"
    }

    /// "15h", "15h30". O mesmo idioma do `MinuteFormat.duration`: hora cheia
    /// não vira "15h00".
    static func hour(_ minute: Int) -> String {
        let horas = minute / 60
        let resto = minute % 60
        return resto == 0 ? "\(horas)h" : String(format: "%dh%02d", horas, resto)
    }

    /// Domingo primeiro, como o calendário gregoriano numera.
    static let weekdayNames = [
        "domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado",
    ]
}
