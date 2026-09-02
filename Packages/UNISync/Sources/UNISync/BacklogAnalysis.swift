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
///
/// **O consentimento vale para UMA análise.** Duas guardas, e as duas são
/// necessárias:
///
/// 1. A linha é gasta quando a mensagem ganha triagem. É a definição literal
///    de "uma análise": o que ele autorizou aconteceu.
/// 2. A linha carrega a `modelVersion` do motor a que o consentimento se
///    referia. Sem isto, a próxima subida de versão devolveria essas mesmas
///    mensagens à fila e elas sairiam de novo para o provedor **sem diálogo
///    nenhum** — exatamente o caminho que esta ação existe para fechar. E a
///    guarda 1 sozinha não bastaria: uma análise que voltou sem triagem
///    (o modelo não devolveu nenhuma) deixaria a linha viva para sempre.
public struct AnalysisBacklogConsentStore: Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    /// Escreve o consentimento de uma vez só, carimbado com a versão do motor
    /// a que ele se refere. `INSERT OR REPLACE` porque aprovar duas vezes a
    /// mesma mensagem é a mesma decisão, não um erro — e porque um
    /// consentimento novo, para uma versão nova, tem de substituir o velho.
    ///
    /// Uma transação só para as N linhas: N transações numa caixa grande é o
    /// que fazia esta escrita valer meio segundo de janela congelada.
    public func approve(
        _ messageIDs: [String],
        modelVersion: String,
        at: Date = Date()
    ) throws {
        guard !messageIDs.isEmpty else { return }
        try database.pool.write { db in
            for id in messageIDs {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO analysis_backlog_consent
                          (messageID, approvedAt, modelVersion) VALUES (?, ?, ?)
                        """,
                    arguments: [id, at.timeIntervalSince1970, modelVersion]
                )
            }
        }
    }

    /// Esta mensagem pode sair daqui agora?
    ///
    /// Só quando existe linha de consentimento **para esta versão de motor** e
    /// a mensagem ainda não tem triagem. As duas condições numa consulta só,
    /// porque a fila pergunta isto uma vez por mensagem analisada.
    public func covers(messageID: String, modelVersion: String) -> Bool {
        let resposta = try? database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM analysis_backlog_consent c
                    LEFT JOIN message_intelligence i ON i.messageID = c.messageID
                    WHERE c.messageID = ? AND c.modelVersion = ? AND i.triage IS NULL
                    """,
                arguments: [messageID, modelVersion]
            )
        }
        return (resposta ?? nil) ?? false
    }

    /// "Parar" apaga o consentimento inteiro. O que já foi analisado está
    /// analisado; o que ainda não saiu deixa de ter permissão para sair, que é
    /// exatamente o que a palavra "parar" promete.
    public func clear() throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM analysis_backlog_consent")
        }
    }

    /// Recolhe as linhas já gastas — a mensagem ganhou triagem, o
    /// consentimento cumpriu o que autorizava. `covers` já as trataria como
    /// mortas; apagá-las é higiene, para a tabela não crescer sem limite e
    /// para "o que ainda falta" ser uma contagem de linhas vivas.
    @discardableResult
    public func purgeSpent() throws -> Int {
        try database.pool.write { db in
            try db.execute(sql: """
                DELETE FROM analysis_backlog_consent
                WHERE messageID IN (
                  SELECT c.messageID FROM analysis_backlog_consent c
                  JOIN message_intelligence i ON i.messageID = c.messageID
                  WHERE i.triage IS NOT NULL
                )
                """)
            return db.changesCount
        }
    }

    /// Quantas das aprovadas ainda não foram analisadas — o progresso da ação.
    public func remainingCount(modelVersion: String) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM analysis_backlog_consent c
                LEFT JOIN message_intelligence i ON i.messageID = c.messageID
                WHERE c.modelVersion = ? AND i.triage IS NULL
                """, arguments: [modelVersion]) ?? 0
        }
    }
}

/// O que a caixa tem para analisar e o que a pessoa vai ler antes de dizer
/// sim. O plano é calculado uma vez, mostrado, e só então executado — a
/// contagem que ela leu é a contagem que sai.
public struct BacklogAnalysisPlan: Sendable, Hashable {
    public let messageIDs: [String]
    public let destination: AssistantDestination
    /// A versão do motor a que este consentimento se refere. Viaja com o
    /// plano para o carimbo gravado ser exatamente o do motor que a pessoa
    /// autorizou, e não o de um motor que mudou entre o diálogo e o clique.
    public let modelVersion: String

    public init(messageIDs: [String], destination: AssistantDestination, modelVersion: String) {
        self.messageIDs = messageIDs
        self.destination = destination
        self.modelVersion = modelVersion
    }

    public var count: Int { messageIDs.count }
    public var isEmpty: Bool { messageIDs.isEmpty }

    /// A frase do diálogo. O número exato e o destino nomeado, porque é isso
    /// que a pessoa precisa saber para poder dizer não.
    ///
    /// "assunto, remetente, data e corpo" e não "assunto e corpo": é
    /// literalmente o que `MessageIntelligenceCoordinator.input(for:)` monta e
    /// o que `AssistantEmailContext` manda. A frase antiga omitia dois campos
    /// que saem do Mac, e uma tela de consentimento que subdeclara o que envia
    /// não é consentimento.
    public var confirmationText: String {
        "Isto envia \(count) \(count == 1 ? "mensagem" : "mensagens") "
            + "(assunto, remetente, data e corpo) para \(destination.label). Continuar?"
    }

    public static let actionTitle = "Analisar as mensagens já recebidas"
    public static let confirmTitle = "Analisar"
    public static let cancelTitle = "Cancelar"

    /// As caixas que nunca entram: spam é quarentena, lixeira é o que ela já
    /// jogou fora, e rascunho e enviada são texto **dela**, não trabalho que
    /// chegou. O ranking do dashboard já as exclui pela mesma razão; mandá-las
    /// para um provedor seria pior, porque aqui elas saem da máquina.
    static let excludedBuckets: [String] = [
        TriageBucket.junk.rawValue,
        TriageBucket.trash.rawValue,
        TriageBucket.drafts.rawValue,
        TriageBucket.sent.rawValue,
    ]
}

/// Monta o plano e escreve o consentimento. Não manda nada: quem manda é a
/// fila de sempre, pelo motor de sempre — a única coisa que muda é que estas
/// mensagens passam a ser roteadas para o provedor configurado.
public struct BacklogAnalysisService: Sendable {
    private let database: SyncDatabase
    private let settingsStore: AssistantSettingsStore
    private let consent: AnalysisBacklogConsentStore
    /// A versão do motor remoto. Fechada, e não o analisador inteiro, porque
    /// o serviço não analisa nada — ele só precisa saber sob qual carimbo o
    /// consentimento vale.
    private let configuredModelVersion: @Sendable () -> String

    public init(
        database: SyncDatabase,
        settingsStore: AssistantSettingsStore,
        configuredModelVersion: @escaping @Sendable () -> String = {
            TextAssistantMessageAnalyzer.currentModelVersion
        }
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.consent = AnalysisBacklogConsentStore(database: database)
        self.configuredModelVersion = configuredModelVersion
    }

    public var modelVersion: String { configuredModelVersion() }

    /// Só a contagem, por `COUNT(*)`, sem materializar id nenhum.
    ///
    /// Existe porque a tela precisa saber se **oferece** o botão, e ela
    /// reavalia o corpo muitas vezes; montar a lista inteira de ids a cada
    /// avaliação era varrer a caixa toda para responder "maior que zero?".
    public func availableCount() throws -> Int {
        guard let filtro = candidateFilter() else { return 0 }
        return try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message m \(Self.candidateJoins) WHERE \(filtro.sql)",
                arguments: filtro.arguments
            ) ?? 0
        }
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
        let destination = AssistantDestination(settings: settingsStore.snapshot())
        guard let filtro = candidateFilter() else {
            return BacklogAnalysisPlan(
                messageIDs: [], destination: destination, modelVersion: modelVersion
            )
        }
        let ids = try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT m.id FROM message m \(Self.candidateJoins)
                    WHERE \(filtro.sql)
                    ORDER BY m.receivedAt DESC, m.id ASC
                    """,
                arguments: filtro.arguments
            )
        }
        return BacklogAnalysisPlan(
            messageIDs: ids, destination: destination, modelVersion: modelVersion
        )
    }

    public func approve(_ plan: BacklogAnalysisPlan, at: Date = Date()) throws {
        try consent.approve(plan.messageIDs, modelVersion: plan.modelVersion, at: at)
    }

    public func stop() throws {
        try consent.clear()
    }

    public func remainingCount() throws -> Int {
        try consent.purgeSpent()
        return try consent.remainingCount(modelVersion: modelVersion)
    }

    /// A leitura que o roteador faz por mensagem, com a versão do motor que
    /// vai de fato analisá-la.
    public func covers(messageID: String, modelVersion: String) -> Bool {
        consent.covers(messageID: messageID, modelVersion: modelVersion)
    }

    // MARK: - A consulta, escrita uma vez

    private static let candidateJoins = """
        JOIN message_body b ON b.messageID = m.id
        LEFT JOIN message_intelligence i ON i.messageID = m.id
        """

    /// O `WHERE` das candidatas, ou `nil` quando não há rota remota nenhuma.
    ///
    /// Tudo em SQL, inclusive o carimbo do opt-in: fazer o corte do carimbo em
    /// Swift obrigava a trazer uma linha por mensagem da caixa só para
    /// descartar quase todas, e era isso que impedia a contagem por `COUNT(*)`.
    private func candidateFilter() -> (sql: String, arguments: StatementArguments)? {
        let settings = settingsStore.snapshot()
        guard settings.automaticAnalysis == .configuredProvider,
              !AssistantDestination(settings: settings).isLocal
        else { return nil }
        // Sem carimbo, nada é coberto pelo opt-in e tudo é acervo. O futuro
        // distante deixa a comparação verdadeira para toda linha, sem um
        // segundo caminho de consulta.
        let since = settings.automaticAnalysisSince ?? .distantFuture
        let buckets = BacklogAnalysisPlan.excludedBuckets
        let vagas = Array(repeating: "?", count: buckets.count).joined(separator: ", ")
        let sql = """
            b.plain != ''
            AND i.triage IS NULL
            AND m.bucket NOT IN (\(vagas))
            AND MIN(m.receivedAt, COALESCE(m.firstSeenAt, m.receivedAt)) < ?
            """
        return (sql, StatementArguments(buckets + [since.timeIntervalSince1970]))
    }
}

/// O estado que a tela de Ajustes desenha enquanto o acervo é analisado.
///
/// Vive aqui, e não na `View`, porque ele guarda o consentimento e a fila —
/// e porque "parar" tem de continuar valendo se a janela for fechada no meio.
///
/// **Nenhum toque no banco acontece no ator principal.** Contar, aprovar e
/// apagar são consultas SQLite síncronas; feitas aqui dentro elas congelariam
/// os Ajustes numa caixa grande. Todas passam por `Task.detached`.
@MainActor
@Observable
public final class BacklogAnalysisController {
    /// O plano que a pessoa está sendo convidada a confirmar. `nil` quando o
    /// diálogo não está na tela.
    public private(set) var pendingPlan: BacklogAnalysisPlan?
    /// Quantas mensagens o botão ofereceria agora. Campo, e não função: ler
    /// isto no corpo da view era uma varredura da caixa por redesenho.
    public private(set) var availableCount = 0
    public private(set) var total = 0
    public private(set) var remaining = 0
    public private(set) var isRunning = false
    public private(set) var failure: String?

    private let service: BacklogAnalysisService
    private let coordinator: MessageIntelligenceCoordinator
    private var task: Task<Void, Never>?

    /// Quanto esperar antes de olhar de novo quando o ciclo de fundo está
    /// ocupado. Curto: é só para não girar em vazio.
    static let busyRetryNanoseconds: UInt64 = 200_000_000
    /// Um teto para a espera do caso ocupado — 600 voltas de 200 ms são dois
    /// minutos. Sem ele, um ciclo de fundo travado deixaria esta barra girando
    /// para sempre; com ele, a barra desiste e a pessoa vê o botão de novo.
    static let maximumBusyWaits = 600

    public init(service: BacklogAnalysisService, coordinator: MessageIntelligenceCoordinator) {
        self.service = service
        self.coordinator = coordinator
    }

    /// Recarrega a contagem oferecida. A tela chama isto ao abrir e quando as
    /// configurações mudam — não a cada redesenho.
    public func refreshAvailability() async {
        let service = self.service
        let contagem = await Task.detached { (try? service.availableCount()) ?? 0 }.value
        availableCount = contagem
    }

    /// O clique no botão: monta o plano e pede a confirmação. **Nada sai
    /// daqui nesta etapa** — este passo só produz a frase com o número.
    public func requestConfirmation() async {
        failure = nil
        let service = self.service
        let resultado = await Task.detached { Result { try service.plan() } }.value
        switch resultado {
        case let .success(plan):
            pendingPlan = plan.isEmpty ? nil : plan
            availableCount = plan.count
        case let .failure(error):
            failure = error.localizedDescription
            pendingPlan = nil
        }
    }

    public func cancel() {
        pendingPlan = nil
    }

    /// O "Analisar" do diálogo. Só aqui o consentimento é escrito, e só
    /// depois dele a fila pode rotear estas mensagens para o provedor.
    ///
    /// **O plano vem por parâmetro, e não de `pendingPlan`.** O SwiftUI põe a
    /// binding do `confirmationDialog` em `false` ao dispensá-lo e só então
    /// roda a ação do botão: lendo o estado, `confirm()` encontrava
    /// `pendingPlan` já zerado pelo `cancel()` do `set:` e voltava sem fazer
    /// nada — o botão "Analisar" não analisava. Quem desenhou o diálogo já
    /// tinha o plano na mão; passá-lo tira a corrida do caminho.
    public func confirm(_ plan: BacklogAnalysisPlan) {
        pendingPlan = nil
        guard !plan.isEmpty else { return }
        total = plan.count
        remaining = plan.count
        isRunning = true
        failure = nil
        task?.cancel()
        let service = self.service
        let coordinator = self.coordinator
        task = Task { [weak self] in
            do {
                try await Task.detached { try service.approve(plan) }.value
            } catch {
                self?.failure = error.localizedDescription
                self?.isRunning = false
                return
            }
            var esperas = 0
            while !Task.isCancelled {
                let resultado = await coordinator.runPass()
                let faltam = await Task.detached {
                    (try? service.remainingCount()) ?? 0
                }.value
                guard let self, !Task.isCancelled else { return }
                self.remaining = faltam
                if faltam == 0 { break }
                switch resultado {
                case .busy:
                    // O ciclo de fundo está trabalhando nestas mesmas
                    // mensagens. A barra **fica**: sumir aqui era o bug que
                    // devolvia o botão enquanto o envio continuava.
                    esperas += 1
                    if esperas >= Self.maximumBusyWaits { break }
                    try? await Task.sleep(nanoseconds: Self.busyRetryNanoseconds)
                    continue
                case .blocked:
                    // Fila pausada ou motor fora do ar: girar não adianta, e a
                    // barra lateral já diz o motivo.
                    break
                case let .finished(feitas):
                    esperas = 0
                    if feitas > 0 { continue }
                }
                break
            }
            guard let self else { return }
            self.isRunning = false
            await self.refreshAvailability()
        }
    }

    /// "Parar". Cancela a rodada e **apaga o consentimento**: o que ainda não
    /// saiu deixa de ter permissão para sair.
    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        remaining = 0
        let service = self.service
        Task { [weak self] in
            await Task.detached { try? service.stop() }.value
            await self?.refreshAvailability()
        }
    }

    /// O texto do progresso. Uma frase, no lugar do botão.
    public var progressText: String {
        "Analisando… \(remaining == 1 ? "falta 1" : "faltam \(remaining)") de \(total)."
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

    func covers(_ messageID: String, modelVersion: String) -> Bool {
        guard let service = lock.withLock({ self.service }) else { return false }
        return service.covers(messageID: messageID, modelVersion: modelVersion)
    }
}
