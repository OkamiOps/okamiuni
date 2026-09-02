import Foundation
import GRDB
import Observation
import UNICore

/// O consentimento para analisar o que **já estava** na caixa.
///
/// A regra do §1.8 é que o opt-in cobre mensagens novas, e ela é boa: ligar
/// um interruptor não pode mandar cinco anos de email para um servidor. Mas a
/// consequência é que o dono liga a análise automática e o dashboard continua
/// vazio, porque nenhuma mensagem que ele já tem foi triada.
///
/// A saída não é afrouxar o carimbo — é um segundo consentimento, explícito,
/// com o número exato de mensagens e o destino na tela antes de qualquer byte
/// sair. E ele fica **escrito**: uma linha por mensagem aprovada, para o
/// roteador poder responder "esta aqui, sim" sem depender de nenhum estado em
/// memória que um relançamento do app perderia.
public struct AnalysisBacklogConsentStore: Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    /// Escreve o consentimento de uma vez só. `INSERT OR REPLACE` porque
    /// aprovar duas vezes a mesma mensagem é a mesma decisão, não um erro.
    public func approve(_ messageIDs: [String], at: Date = Date()) throws {
        guard !messageIDs.isEmpty else { return }
        try database.pool.write { db in
            for id in messageIDs {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO analysis_backlog_consent
                          (messageID, approvedAt) VALUES (?, ?)
                        """,
                    arguments: [id, at.timeIntervalSince1970]
                )
            }
        }
    }

    public func approvedIDs() throws -> Set<String> {
        try database.pool.read { db in
            try String.fetchSet(db, sql: "SELECT messageID FROM analysis_backlog_consent")
        }
    }

    /// "Parar" apaga o consentimento inteiro. O que já foi analisado está
    /// analisado; o que ainda não saiu daqui deixa de ter permissão para
    /// sair, que é exatamente o que a palavra "parar" promete.
    public func clear() throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM analysis_backlog_consent")
        }
    }

    /// Quantas das aprovadas ainda não têm triagem — o progresso da ação.
    public func remainingCount() throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM analysis_backlog_consent c
                LEFT JOIN message_intelligence i ON i.messageID = c.messageID
                WHERE i.triage IS NULL
                """) ?? 0
        }
    }
}

/// O que a caixa tem para analisar e o que a pessoa vai ler antes de dizer
/// sim. O plano é calculado uma vez, mostrado, e só então executado — a
/// contagem que ela leu é a contagem que sai.
public struct BacklogAnalysisPlan: Sendable, Hashable {
    public let messageIDs: [String]
    public let destination: AssistantDestination

    public init(messageIDs: [String], destination: AssistantDestination) {
        self.messageIDs = messageIDs
        self.destination = destination
    }

    public var count: Int { messageIDs.count }
    public var isEmpty: Bool { messageIDs.isEmpty }

    /// A frase do diálogo. O número exato e o destino nomeado, porque é isso
    /// que a pessoa precisa saber para poder dizer não.
    public var confirmationText: String {
        "Isto envia \(count) mensagens (assunto e corpo) para \(destination.label). Continuar?"
    }

    public static let actionTitle = "Analisar as mensagens já recebidas"
    public static let confirmTitle = "Analisar"
    public static let cancelTitle = "Cancelar"
}

/// Monta o plano e escreve o consentimento. Não manda nada: quem manda é a
/// fila de sempre, pelo motor de sempre — a única coisa que muda é que estas
/// mensagens passam a ser roteadas para o provedor configurado.
public struct BacklogAnalysisService: Sendable {
    private let database: SyncDatabase
    private let settingsStore: AssistantSettingsStore
    private let consent: AnalysisBacklogConsentStore

    public init(database: SyncDatabase, settingsStore: AssistantSettingsStore) {
        self.database = database
        self.settingsStore = settingsStore
        self.consent = AnalysisBacklogConsentStore(database: database)
    }

    /// As mensagens guardadas que ainda não têm triagem e que o carimbo do
    /// opt-in **não** cobre — as que ficariam para sempre sem análise remota
    /// se ninguém pedisse. As que o carimbo já cobre saem daqui de qualquer
    /// jeito e não podem entrar na contagem: contá-las seria pedir
    /// autorização duas vezes para a mesma coisa.
    ///
    /// Plano vazio quando a rota é este Mac: não há para onde mandar, e um
    /// botão que oferece enviar para lugar nenhum é pior do que botão nenhum.
    public func plan() throws -> BacklogAnalysisPlan {
        let settings = settingsStore.snapshot()
        let destination = AssistantDestination(settings: settings)
        guard settings.automaticAnalysis == .configuredProvider, !destination.isLocal else {
            return BacklogAnalysisPlan(messageIDs: [], destination: destination)
        }
        let ids = try database.pool.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS messageID, m.receivedAt, m.firstSeenAt
                FROM message m
                JOIN message_body b ON b.messageID = m.id
                LEFT JOIN message_intelligence i ON i.messageID = m.id
                WHERE b.plain != '' AND i.triage IS NULL
                ORDER BY m.receivedAt DESC, m.id ASC
                """)
            return rows.compactMap { row -> String? in
                let recebida = Date(timeIntervalSince1970: row["receivedAt"])
                let vista = (row["firstSeenAt"] as Double?).map(Date.init(timeIntervalSince1970:))
                let chegou = vista.map { min(recebida, $0) } ?? recebida
                guard !settings.automaticAnalysisCoversMessage(receivedAt: chegou) else {
                    return nil
                }
                return row["messageID"]
            }
        }
        return BacklogAnalysisPlan(messageIDs: ids, destination: destination)
    }

    public func approve(_ plan: BacklogAnalysisPlan, at: Date = Date()) throws {
        try consent.approve(plan.messageIDs, at: at)
    }

    public func stop() throws {
        try consent.clear()
    }

    public func remainingCount() throws -> Int {
        try consent.remainingCount()
    }

    /// A leitura que o roteador faz por mensagem. Síncrona e barata: uma
    /// chave primária por análise, e a fila é serial.
    public func covers(messageID: String) -> Bool {
        ((try? database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM analysis_backlog_consent WHERE messageID = ?",
                arguments: [messageID]
            )
        }) ?? nil) ?? false
    }
}

/// O estado que a tela de Ajustes desenha enquanto o acervo é analisado.
///
/// Vive aqui, e não na `View`, porque ele guarda o consentimento e a fila —
/// e porque "parar" tem de continuar valendo se a janela for fechada no meio.
@MainActor
@Observable
public final class BacklogAnalysisController {
    /// O plano que a pessoa está sendo convidada a confirmar. `nil` quando o
    /// diálogo não está na tela.
    public private(set) var pendingPlan: BacklogAnalysisPlan?
    public private(set) var total = 0
    public private(set) var remaining = 0
    public private(set) var isRunning = false
    public private(set) var failure: String?

    private let service: BacklogAnalysisService
    private let coordinator: MessageIntelligenceCoordinator
    private var task: Task<Void, Never>?

    public init(service: BacklogAnalysisService, coordinator: MessageIntelligenceCoordinator) {
        self.service = service
        self.coordinator = coordinator
    }

    /// Quantas mensagens o botão ofereceria agora. A tela usa isto para não
    /// mostrar um botão que não tem o que fazer.
    public var availableCount: Int { (try? service.plan().count) ?? 0 }

    /// O clique no botão: monta o plano e pede a confirmação. **Nada sai
    /// daqui nesta etapa** — este passo só produz a frase com o número.
    public func requestConfirmation() {
        failure = nil
        do {
            let plan = try service.plan()
            pendingPlan = plan.isEmpty ? nil : plan
        } catch {
            failure = error.localizedDescription
            pendingPlan = nil
        }
    }

    public func cancel() {
        pendingPlan = nil
    }

    /// O "Analisar" do diálogo. Só aqui o consentimento é escrito, e só
    /// depois dele a fila pode rotear estas mensagens para o provedor.
    public func confirm() {
        guard let plan = pendingPlan else { return }
        pendingPlan = nil
        do {
            try service.approve(plan)
        } catch {
            failure = error.localizedDescription
            return
        }
        total = plan.count
        remaining = plan.count
        isRunning = true
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let feitas = await self.coordinator.processPending()
                let faltam = (try? self.service.remainingCount()) ?? 0
                self.remaining = faltam
                if faltam == 0 || feitas == 0 { break }
            }
            self.isRunning = false
        }
    }

    /// "Parar". Cancela a rodada e **apaga o consentimento**: o que ainda não
    /// saiu deixa de ter permissão para sair.
    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        try? service.stop()
        remaining = 0
    }

    /// O texto do progresso. Uma frase, no lugar do botão.
    public var progressText: String {
        "Analisando… faltam \(remaining) de \(total)."
    }
}

/// A caixa que quebra o ovo-e-galinha da composição: o roteador precisa saber
/// consultar o consentimento, e o serviço que o consulta precisa do banco,
/// que só é aberto depois do roteador. A caixa nasce vazia — respondendo
/// "não", que é o lado seguro — e recebe o serviço quando ele existe.
final class BacklogConsentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var service: BacklogAnalysisService?

    func attach(_ service: BacklogAnalysisService) {
        lock.withLock { self.service = service }
    }

    func covers(_ messageID: String) -> Bool {
        guard let service = lock.withLock({ self.service }) else { return false }
        return service.covers(messageID: messageID)
    }
}
