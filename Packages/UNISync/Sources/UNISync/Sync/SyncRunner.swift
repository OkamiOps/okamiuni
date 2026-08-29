import Foundation
import NIOCore
import UNICore
import os

/// Um coordenador de sincronização por conta, ligado e desligado conforme a
/// lista de contas muda.
///
/// **Quem manda é o `AccountDirector`**, e ele manda pelo canal que já existe:
/// o fluxo de `statuses()`. Conta que entra ganha coordenador; conta que sai
/// perde o dela; conta que cai em `erroDeAutenticacao` tem o dela desligado até
/// a pessoa reconectar. Uma segunda ponte (o diretor chamando este tipo
/// diretamente) inverteria a dependência e criaria dois caminhos para a mesma
/// notícia — que é como duas listas de contas passam a discordar.
///
/// Ele é o irmão do `OutboxRunner`: a fila leva o que a pessoa fez ao servidor,
/// e isto traz o que o servidor tem de volta. Os dois vivem enquanto o app
/// estiver aberto, os dois são religáveis sem reiniciar nada.
public actor SyncRunner {
    private let database: SyncDatabase
    private let secrets: any SecretStore
    private let auth: GoogleAuth?
    private let urlSession: URLSession
    private let gmailBaseURL: URL
    private let eventLoopGroup: any EventLoopGroup
    private let director: AccountDirector
    private let imapConnect: @Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
    private let report: @Sendable (String, SyncError?) -> Void
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "SyncRunner")

    private var coordenadores: [String: AccountSyncCoordinator] = [:]
    private var assinatura: Task<Void, Never>?

    public init(
        database: SyncDatabase,
        secrets: any SecretStore,
        auth: GoogleAuth?,
        session: URLSession,
        gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!,
        eventLoopGroup: any EventLoopGroup,
        director: AccountDirector,
        imapConnect: @Sendable @escaping (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
            = { endpoint, grupo in try await ImapSession.connect(endpoint: endpoint, group: grupo) },
        report: @Sendable @escaping (String, SyncError?) -> Void = { _, _ in }
    ) {
        self.database = database
        self.secrets = secrets
        self.auth = auth
        self.urlSession = session
        self.gmailBaseURL = gmailBaseURL
        self.eventLoopGroup = eventLoopGroup
        self.director = director
        self.imapConnect = imapConnect
        self.report = report
    }

    /// Assina o diretor e passa a acertar os coordenadores a cada mudança.
    /// Idempotente: chamar duas vezes não abre duas assinaturas.
    public func start() {
        guard assinatura == nil else { return }
        assinatura = Task { [weak self, director] in
            for await lista in await director.statuses() {
                guard let self else { return }
                await self.reconcile(lista)
            }
        }
    }

    public func stop() async {
        assinatura?.cancel()
        assinatura = nil
        for (_, coordenador) in coordenadores { await coordenador.stop() }
        coordenadores = [:]
    }

    /// Acerta o conjunto de coordenadores contra a lista publicada.
    ///
    /// `public` e sem laço de propósito: é assim que o teste afirma quem liga e
    /// quem desliga sem depender do fluxo assíncrono do diretor — a mesma
    /// decisão que deixou `OutboxExecutor.drain` público.
    public func reconcile(_ statuses: [AccountStatus]) async {
        let devemViver = Set(statuses.filter { Self.deveSincronizar($0) }.map(\.accountID))

        for (id, coordenador) in coordenadores where !devemViver.contains(id) {
            await coordenador.stop()
            coordenadores[id] = nil
        }
        for id in devemViver where coordenadores[id] == nil {
            let coordenador = AccountSyncCoordinator(
                accountID: id, database: database, secrets: secrets, auth: auth,
                session: urlSession, gmailBaseURL: gmailBaseURL,
                eventLoopGroup: eventLoopGroup, imapConnect: imapConnect, report: report
            )
            coordenadores[id] = coordenador
            await coordenador.start()
        }
    }

    /// A conta merece um ciclo agora?
    ///
    /// - `.ativa` sim: é a conta pronta, e é para ela que a sincronização
    ///   contínua existe.
    /// - `.carregando` não: a carga inicial está correndo, e um delta em cima
    ///   dela leria um `sync_state` que ainda não foi carimbado — o incremental
    ///   veria "sem marcador" e mandaria **recarregar**, duas cargas da mesma
    ///   conta ao mesmo tempo.
    /// - `.erroDeAutenticacao` não: insistir a cada minuto numa credencial
    ///   recusada gasta viagens para chegar ao mesmo lugar e esconde da pessoa
    ///   a única coisa que ela pode fazer.
    static func deveSincronizar(_ status: AccountStatus) -> Bool {
        status.state == .ativa
    }

    /// Acorda todas as contas. É o que o `NetworkWatcher` chama quando o
    /// caminho de rede volta a ser satisfeito.
    public func wakeAll() {
        for coordenador in coordenadores.values { coordenador.wake() }
    }

    /// O coordenador de uma conta — a porta que o teste usa para afirmar o
    /// resto, e que a UI pode usar para um "sincronizar agora".
    public func coordinator(for accountID: String) -> AccountSyncCoordinator? {
        coordenadores[accountID]
    }
}
