import Foundation
import GRDB
import NIOCore
import UNICore
import os

/// Um executor por conta, vivo enquanto o app estiver aberto.
///
/// É a amarração que falta entre a porta de escrita (que enfileira) e os
/// espelhos (que escrevem no servidor): ela lê quais contas existem, monta o
/// espelho certo para o provedor de cada uma, liga o executor e o inscreve no
/// `OutboxSignal` para acordar assim que a pessoa arquivar alguma coisa.
///
/// Mora no `UNISync`, e não no alvo do app, pela mesma razão que a
/// `AppComposition`: o alvo do app não tem testes, e "a fila começa a andar ao
/// abrir" é comportamento, não fiação.
public actor OutboxRunner {
    private let database: SyncDatabase
    private let secrets: any SecretStore
    private let auth: GoogleAuth?
    private let session: URLSession
    private let gmailBaseURL: URL
    private let eventLoopGroup: any EventLoopGroup
    private let signal: OutboxSignal
    private let imapConnect: @Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
    /// Como abrir a conexão de **envio**. Injetável pela mesma razão da de
    /// leitura: o servidor SMTP falso dos testes fala em claro no loopback, e
    /// exigir TLS ali seria gerar um certificado só para provar coisas que não
    /// são sobre TLS.
    private let smtpConnect: @Sendable (SmtpEndpoint, any EventLoopGroup) async throws -> SmtpSession
    private let report: @Sendable (String, SyncError?) -> Void
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "OutboxRunner")

    private var executores: [String: OutboxExecutor] = [:]
    private var assinatura: Task<Void, Never>?

    public init(
        database: SyncDatabase,
        secrets: any SecretStore,
        auth: GoogleAuth?,
        session: URLSession,
        gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!,
        eventLoopGroup: any EventLoopGroup,
        signal: OutboxSignal,
        imapConnect: @Sendable @escaping (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
            = { endpoint, grupo in try await ImapSession.connect(endpoint: endpoint, group: grupo) },
        smtpConnect: @Sendable @escaping (SmtpEndpoint, any EventLoopGroup) async throws -> SmtpSession
            = { endpoint, grupo in try await SmtpSession.connect(endpoint: endpoint, group: grupo) },
        report: @Sendable @escaping (String, SyncError?) -> Void = { _, _ in }
    ) {
        self.database = database
        self.secrets = secrets
        self.auth = auth
        self.session = session
        self.gmailBaseURL = gmailBaseURL
        self.eventLoopGroup = eventLoopGroup
        self.signal = signal
        self.imapConnect = imapConnect
        self.smtpConnect = smtpConnect
        self.report = report
    }

    /// Liga (ou religa) um executor para cada conta do banco.
    ///
    /// Chamável de novo sem medo: conta que já tem executor é deixada em paz, e
    /// conta que sumiu tem o executor parado e esquecido. É assim que adicionar
    /// ou remover uma conta acerta a fila sem reiniciar o app.
    public func start() async {
        let contas: [Account]
        do {
            contas = try await database.pool.read { db in
                try AccountRecord.order(Column("createdAt")).fetchAll(db).map(\.account)
            }
        } catch {
            log.error("Não foi possível listar as contas para a fila: \(error)")
            return
        }

        let vivos = Set(contas.map(\.id))
        for (id, executor) in executores where !vivos.contains(id) {
            await executor.stop()
            executores[id] = nil
            signal.forget(accountID: id)
        }

        for conta in contas where executores[conta.id] == nil {
            guard let espelho = espelho(para: conta) else { continue }
            let executor = OutboxExecutor(
                accountID: conta.id, database: database, mirror: espelho, report: report
            )
            executores[conta.id] = executor
            signal.register(accountID: conta.id) { [weak executor] in executor?.wake() }
            await executor.start()
        }
    }

    /// Religa a fila a cada mudança na lista de contas.
    ///
    /// `start()` roda uma vez na abertura — e era só isso: a conta adicionada
    /// com o app aberto nunca ganhava executor, e as ações dela ficavam
    /// `pendente`, com zero tentativas, até o próximo reinício. A
    /// sincronização já assinava o diretor (`SyncRunner.start`); a fila
    /// assina o mesmo fluxo. `start()` é idempotente de propósito, então cada
    /// publicação só liga o que falta e desliga o que sobrou.
    public func follow(_ statuses: AsyncStream<[AccountStatus]>) {
        guard assinatura == nil else { return }
        assinatura = Task { [weak self] in
            for await _ in statuses {
                guard let self else { return }
                await self.start()
            }
        }
    }

    public func stop() async {
        assinatura?.cancel()
        assinatura = nil
        for (id, executor) in executores {
            await executor.stop()
            signal.forget(accountID: id)
        }
        executores = [:]
    }

    /// O executor de uma conta — a porta que a UI usa para o "tentar de novo"
    /// de uma fila parada, e que o teste usa para afirmar o resto.
    public func executor(for accountID: String) -> OutboxExecutor? { executores[accountID] }

    private func espelho(para conta: Account) -> (any MailMirror)? {
        switch conta.provider {
        case .gmail:
            guard let auth else {
                log.notice("Sem OAuth, a fila do Gmail não tem por onde sair.")
                return nil
            }
            let id = conta.id
            return GmailMirror(client: GmailClient(
                session: session,
                accessToken: { try await auth.accessToken(for: id) },
                baseURL: gmailBaseURL
            ))
        case .imap, .microsoft:
            guard let endpoint = conta.imap else { return nil }
            let secrets = self.secrets
            let grupo = eventLoopGroup
            let conectar = imapConnect
            let conectarSmtp = smtpConnect
            let id = conta.id
            let endereco = conta.address
            // O servidor de envio é **derivado** do de leitura — ver
            // `SmtpDiscovery`. Nenhuma tela nova foi pedida à pessoa por
            // causa disto: a mesma senha de app que lê a caixa é a que
            // manda, que é como todo provedor de submissão funciona.
            var abreSmtp: (@Sendable () async throws -> SmtpSession)?
            if let destino = SmtpDiscovery.endpoint(forImap: endpoint) {
                abreSmtp = {
                    guard case .password(let senha)? = try secrets.secret(for: id) else {
                        throw SyncError.autenticacao
                    }
                    let sessao = try await conectarSmtp(destino, grupo)
                    do {
                        try await sessao.login(user: endereco, password: senha)
                    } catch {
                        await sessao.quit()
                        throw error
                    }
                    return sessao
                }
            }
            return ImapMirror(
                connect: {
                    guard case .password(let senha)? = try secrets.secret(for: id) else {
                        throw SyncError.autenticacao
                    }
                    let sessao = try await conectar(endpoint, grupo)
                    try await sessao.login(user: endereco, password: senha)
                    return sessao
                },
                smtp: abreSmtp
            )
        }
    }
}
