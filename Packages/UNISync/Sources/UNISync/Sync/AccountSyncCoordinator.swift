import Foundation
import GRDB
import NIOCore
import UNICore
import os

/// A sincronização contínua de **uma** conta.
///
/// Ator pela mesma razão que o `OutboxExecutor` é: um ciclo por conta, nunca
/// dois. Dois ciclos sobrepostos leriam o mesmo `sync_state`, aplicariam o
/// mesmo intervalo duas vezes e carimbariam por cima um do outro — e o segundo
/// carimbo apagaria o trabalho do primeiro sem nada na tela dizendo isso.
///
/// ## Os dois ritmos
///
/// **Gmail** não tem push que um app de mesa possa ouvir sem servidor no meio,
/// então o ritmo é o relógio: um ciclo de `users.history.list` por minuto, que
/// custa uma ida e volta quando nada mudou.
///
/// **IMAP** tem `IDLE` (RFC 2177), e é o que faz a mensagem aparecer em
/// segundos em vez de em até um minuto: o servidor avisa, o coordenador acorda,
/// o delta corre. Servidor sem `IDLE` cai no mesmo relógio do Gmail — nada
/// aqui recusa provedor nenhum, e o que muda é só a latência.
///
/// ## O que ele não faz
///
/// Ele **não** fala com a UI. A tela lê o banco por `ValueObservation`
/// (`DatabaseMailSource`), e uma mensagem gravada aparece sozinha. Uma ponte
/// nova daqui para a tela seria um segundo caminho para o mesmo dado, e os dois
/// divergiriam no primeiro retrato.
public actor AccountSyncCoordinator {
    /// De quanto em quanto tempo o ciclo se repete quando não há `IDLE`.
    ///
    /// Um minuto: é o mesmo `intervaloOcioso` que a fila de saída já usa, e é
    /// o equilíbrio entre "a mensagem demora" e "a quota do provedor".
    public static let intervaloDePolling: TimeInterval = 60

    /// O teto de um `IDLE` antes de reengatar.
    ///
    /// O RFC 2177 recomenda menos de 29 minutos, e a razão é concreta: é isso
    /// que impede o servidor — e cada NAT no caminho — de dar a conexão por
    /// morta e a derrubar sem avisar. Vinte e cinco deixa margem.
    public static let idleMaximo: TimeInterval = 25 * 60

    /// O primeiro recuo depois de uma falha transitória, em segundos. Dobra
    /// até o teto, com o mesmo tremor da fila de saída — e pela mesma razão:
    /// um provedor que volta do ar não pode receber todas as contas de todos os
    /// clientes no mesmo instante.
    public static let recuoBase: TimeInterval = 5
    public static let recuoTeto: TimeInterval = 300

    /// O que um ciclo fez. Nunca lança: o erro é **dado**, e o laço decide o
    /// que fazer com ele.
    public struct Outcome: Sendable, Equatable {
        public var gravadas: Int
        public var apagadas: Int
        public var erro: SyncError?

        public init(gravadas: Int = 0, apagadas: Int = 0, erro: SyncError? = nil) {
            self.gravadas = gravadas
            self.apagadas = apagadas
            self.erro = erro
        }
    }

    private let accountID: String
    private let database: SyncDatabase
    private let secrets: any SecretStore
    private let auth: GoogleAuth?
    private let urlSession: URLSession
    private let gmailBaseURL: URL
    private let eventLoopGroup: any EventLoopGroup
    private let imapConnect: @Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
    private let now: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let report: @Sendable (String, SyncError?) -> Void
    private let reportSyncing: @Sendable (String, Bool) -> Void
    private let reportRemoteInbox: @Sendable (String, Int) -> Void
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "SyncCoordinator")

    private var loop: Task<Void, Never>?
    private var esperando: CheckedContinuation<Void, Never>?
    private var sinalPendente = false
    private var falhas = 0
    /// A sessão IMAP viva entre ciclos. Guardada porque o `IDLE` **é** uma
    /// sessão aberta: reconectar a cada ciclo trocaria o aviso do servidor por
    /// um `LOGIN` por minuto.
    private var sessao: ImapSession?
    /// O que o servidor anuncia saber. Lida uma vez por sessão — ela só muda
    /// quando a sessão muda.
    private var capacidades: Set<String> = []

    public init(
        accountID: String,
        database: SyncDatabase,
        secrets: any SecretStore,
        auth: GoogleAuth?,
        session: URLSession,
        gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!,
        eventLoopGroup: any EventLoopGroup,
        imapConnect: @Sendable @escaping (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
            = { endpoint, grupo in try await ImapSession.connect(endpoint: endpoint, group: grupo) },
        now: @Sendable @escaping () -> Date = Date.init,
        sleeper: @Sendable @escaping (TimeInterval) async throws -> Void = { segundos in
            try await Task.sleep(for: .seconds(segundos))
        },
        jitter: @Sendable @escaping () -> Double = { Double.random(in: 0...1) },
        report: @Sendable @escaping (String, SyncError?) -> Void = { _, _ in },
        reportSyncing: @Sendable @escaping (String, Bool) -> Void = { _, _ in },
        reportRemoteInbox: @Sendable @escaping (String, Int) -> Void = { _, _ in }
    ) {
        self.accountID = accountID
        self.database = database
        self.secrets = secrets
        self.auth = auth
        self.urlSession = session
        self.gmailBaseURL = gmailBaseURL
        self.eventLoopGroup = eventLoopGroup
        self.imapConnect = imapConnect
        self.now = now
        self.sleeper = sleeper
        self.jitter = jitter
        self.report = report
        self.reportSyncing = reportSyncing
        self.reportRemoteInbox = reportRemoteInbox
    }

    // MARK: O laço

    /// Começa a sincronizar. Idempotente: chamar duas vezes não cria dois
    /// laços — que é justamente o "ciclos nunca sobrepostos por conta".
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.umaVolta()
            }
        }
    }

    /// Para o laço e fecha a conexão. As mensagens já gravadas ficam — parar
    /// não desfaz nada.
    public func stop() async {
        loop?.cancel()
        loop = nil
        esperando?.resume()
        esperando = nil
        await descartaSessao()
    }

    /// Acorda o coordenador de fora, sem `await`. É o que o `NetworkWatcher`
    /// chama quando a rede volta.
    public nonisolated func wake() {
        Task { await self.acorda() }
    }

    private func acorda() {
        sinalPendente = true
        esperando?.resume()
        esperando = nil
    }

    /// Uma volta do laço: um ciclo, e depois a espera que o resultado pedir.
    ///
    /// Separada do laço para o teste poder afirmar o ritmo sem tempo passando
    /// — a mesma decisão que deixou `OutboxExecutor.drain` público e sem laço.
    func umaVolta() async {
        let resultado = await syncOnce()
        guard !Task.isCancelled else { return }

        if let erro = resultado.erro {
            if Self.ehPermanente(erro) {
                // Credencial recusada não passa por insistir: repetir a cada
                // minuto para sempre esconderia da pessoa a única coisa que ela
                // pode fazer. A conta fica marcada, o erro publicado, e o laço
                // dorme até alguém o acordar (rede que volta, conta re-adicionada).
                await espera(nil)
                return
            }
            falhas += 1
            await espera(Self.recuo(tentativas: falhas, jitter: jitter()))
            return
        }
        falhas = 0

        // O caminho vivo: quando o `IDLE` está disponível, a espera **é** ele —
        // e ele volta assim que o servidor avisar, para o delta correr na hora.
        if await esperaNoIdle() { return }
        await espera(Self.intervaloDePolling)
    }

    /// Espera `segundos`, ou até alguém acordar. `nil` espera só pelo sinal.
    private func espera(_ segundos: TimeInterval?) async {
        if sinalPendente {
            sinalPendente = false
            return
        }
        let sleeper = self.sleeper
        let relogio: Task<Void, Never>? = segundos.map { atraso in
            Task { [weak self] in
                try? await sleeper(atraso)
                await self?.acorda()
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                esperando = continuation
            }
        } onCancel: {
            Task { await self.acorda() }
        }
        relogio?.cancel()
        sinalPendente = false
    }

    // MARK: Um ciclo

    /// Um ciclo de sincronização, sem laço e sem espera.
    ///
    /// Nunca lança: o erro sai no `Outcome` porque quem decide o que fazer com
    /// ele é o laço — e porque um coordenador que lança obrigaria cada teste a
    /// encenar o laço para ver o resultado.
    @discardableResult
    public func syncOnce() async -> Outcome {
        guard let conta = try? await database.pool.read({ db in
            try AccountRecord.fetchOne(db, key: accountID)?.account
        }) else {
            // A conta saiu do banco entre uma volta e outra. Não é erro: é o
            // `remove` da pessoa, e o `SyncRunner` está a caminho para desligar
            // este coordenador.
            return Outcome()
        }

        reportSyncing(accountID, true)
        defer { reportSyncing(accountID, false) }

        do {
            let resultado: Outcome
            switch conta.provider {
            case .gmail: resultado = try await cicloDoGmail(conta)
            case .imap, .microsoft: resultado = try await cicloDoImap(conta)
            }
            report(accountID, nil)
            return resultado
        } catch is CancellationError {
            return Outcome()
        } catch {
            let erro = (error as? SyncError) ?? .rede(error.localizedDescription)
            await registra(erro, conta: conta)
            return Outcome(erro: erro)
        }
    }

    private func cicloDoGmail(_ conta: Account) async throws -> Outcome {
        guard let auth else { throw SyncError.semClientID }
        let id = conta.id
        let cliente = GmailClient(
            session: urlSession,
            accessToken: { try await auth.accessToken(for: id) },
            baseURL: gmailBaseURL
        )
        let saida = try await GmailIncrementalSync(database: database).run(
            account: conta, client: cliente,
            renewAccessToken: { _ = try await auth.renewedAccessToken(for: id) },
            now: now()
        )
        if let total = saida.remoteInboxCount {
            reportRemoteInbox(id, total)
        }
        await persisteAliasesGmail(conta, cliente: cliente)
        return Outcome(gravadas: saida.gravadas, apagadas: saida.apagadas)
    }

    private func persisteAliasesGmail(_ conta: Account, cliente: GmailClient) async {
        guard let remotos = try? await cliente.sendAsAliases() else { return }
        let fundidos = SendAlias.merging(
            gmail: remotos.map {
                ($0.email, $0.displayName, $0.isPrimary, $0.isDefault)
            },
            existing: conta.sendAliases,
            primary: conta.address
        )
        let atuais = SendAlias.normalized(conta.sendAliases, excluding: conta.address)
        guard fundidos != atuais else { return }
        _ = try? await database.pool.write { db in
            guard var registro = try AccountRecord.fetchOne(db, key: conta.id) else { return }
            registro.sendAliases = fundidos
            try registro.update(db)
        }
    }

    private func cicloDoImap(_ conta: Account) async throws -> Outcome {
        do {
            let sessao = try await sessaoAtiva(conta)
            let saida = try await ImapIncrementalSync(database: database).run(
                account: conta, session: sessao, now: now()
            )
            return Outcome(
                gravadas: saida.novas + saida.bandeiras, apagadas: saida.apagadas
            )
        } catch let erro as SyncError where ehDeConexao(erro) {
            // Conexão morta na prateleira — o caso mais provável de todos num
            // app aberto o dia inteiro. A sessão sai, e o erro sobe: a próxima
            // volta reconecta. É o mesmo idioma do `DatabaseBodyFetcher`.
            await descartaSessao()
            throw erro
        }
    }

    private func sessaoAtiva(_ conta: Account) async throws -> ImapSession {
        if let guardada = sessao { return guardada }
        guard let endpoint = conta.imap else {
            throw SyncError.resposta("A conta não tem servidor IMAP configurado.")
        }
        guard case .password(let senha)? = try secrets.secret(for: conta.id) else {
            throw SyncError.autenticacao
        }
        let nova = try await imapConnect(endpoint, eventLoopGroup)
        try await nova.login(user: conta.address, password: senha)
        // Depois do `LOGIN`, e não da saudação: o RFC manda reler, e servidor
        // que só oferece `IDLE` a sessão autenticada existe. Falhar aqui não
        // custa o ciclo — sem lista, o caminho é o relógio.
        capacidades = (try? await nova.capabilities()) ?? []
        sessao = nova
        return nova
    }

    private func descartaSessao() async {
        guard let velha = sessao else { return }
        sessao = nil
        capacidades = []
        await velha.logout()
    }

    // MARK: O IDLE

    /// Fica em `IDLE` até o servidor avisar, até o teto, ou até o cancelamento.
    /// Devolve `false` quando este caminho não se aplica — e aí o laço espera
    /// no relógio.
    ///
    /// A pasta selecionada é a **entrada**: é onde a mensagem nova chega, e é a
    /// única caixa em que segundos de latência mudam alguma coisa. O resto das
    /// pastas anda no delta que corre logo depois de o IDLE voltar.
    private func esperaNoIdle() async -> Bool {
        guard capacidades.contains("IDLE"), let sessao else { return false }
        do {
            guard let entrada = try await sessao.folders().first(where: { $0.role == .inbox })
            else { return false }
            _ = try await sessao.select(entrada)
            _ = try await sessao.idle(limite: .nanoseconds(Int64(Self.idleMaximo * 1_000_000_000)))
            return true
        } catch is CancellationError {
            return true
        } catch {
            // IDLE que falha não é o fim da conta: a sessão sai e a próxima
            // volta reconecta. Devolver `false` aqui faria o laço dormir um
            // minuto sobre um socket morto.
            await descartaSessao()
            log.notice("O IDLE de \(self.accountID, privacy: .private) caiu; reconectando na próxima volta.")
            return true
        }
    }

    // MARK: O erro

    /// Onde o erro vai parar: no estado da conta, no relato e no log.
    ///
    /// **A conta só é marcada quando o erro é dela.** Rede caída e quota não
    /// são culpa da credencial, e marcar `erroDeAutenticacao` faria a janela
    /// oferecer "Reconectar" para quem só precisa esperar o wi-fi — a mesma
    /// tabela que a carga inicial já usa (`InitialLoader.estadoPara`), e não uma
    /// segunda opinião sobre a mesma pergunta.
    private func registra(_ erro: SyncError, conta: Account) async {
        report(accountID, erro)
        if InitialLoader.estadoPara(erro) == .erroDeAutenticacao, conta.state != .erroDeAutenticacao {
            try? await InitialLoader(database: database).marca(accountID, estado: .erroDeAutenticacao)
        }
        log.error("""
            O ciclo de \(self.accountID, privacy: .private) falhou: \
            \(erro.mensagem, privacy: .public)
            """)
    }

    private func ehDeConexao(_ erro: SyncError) -> Bool {
        switch erro {
        case .rede, .tls: true
        default: false
        }
    }

    /// O que insistir não cura — a mesma linha que a fila de saída traça, e
    /// pela mesma razão: a ação que resolve, e não a gravidade.
    static func ehPermanente(_ erro: SyncError) -> Bool {
        switch erro {
        case .autenticacao, .autorizacaoRevogada, .semClientID: true
        default: false
        }
    }

    /// Recuo exponencial com tremor para baixo — a mesma forma do
    /// `OutboxExecutor`, com a base própria deste laço.
    static func recuo(tentativas: Int, jitter: Double) -> TimeInterval {
        let expoente = max(0, tentativas - 1)
        let cheio = min(recuoTeto, recuoBase * pow(2, Double(expoente)))
        return cheio * (0.5 + 0.5 * min(1, max(0, jitter)))
    }
}
