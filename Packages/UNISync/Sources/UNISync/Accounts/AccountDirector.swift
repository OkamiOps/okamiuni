import Foundation
import GRDB
import NIOCore
import UNICore
import os

/// Quem adiciona, testa, remove e carrega contas.
///
/// Ator porque tudo aqui é estado compartilhado com corrida óbvia: duas
/// adições simultâneas, uma remoção durante uma carga, um `refresh` no meio de
/// um `loadInitial`. O estado publicado sai por `AsyncStream`, e quem desenha é
/// `AccountsModel`, que é `@MainActor`.
public actor AccountDirector {
    private let database: SyncDatabase
    private let secrets: any SecretStore
    /// Nulo quando não há OAuth Client ID no bundle. **Não é um erro de
    /// construção**: o app continua inteiro pela rota IMAP, e a rota Google
    /// explica o que falta.
    private let auth: GoogleAuth?
    private let session: URLSession
    private let gmailBaseURL: URL
    private let eventLoopGroup: any EventLoopGroup
    private let imapConnect: @Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "AccountDirector")

    private var errors: [String: SyncError] = [:]
    private var progresses: [String: LoadProgress] = [:]
    private var subscribers: [UUID: AsyncStream<[AccountStatus]>.Continuation] = [:]
    /// A carga em curso de cada conta. Guardada para poder ser **cancelada**:
    /// remover uma conta no meio da carga dela precisa matar a carga primeiro,
    /// senão a escrita seguinte do carregador ressuscita a linha que a remoção
    /// acabou de apagar.
    private var loads: [String: Task<Void, Never>] = [:]
    /// Qual carga é a **corrente** de cada conta. Um relato de progresso é
    /// assíncrono por natureza — ele viaja num `Task` próprio, disparado de
    /// fora do ator —, então o relato de uma carga já morta pode chegar depois
    /// de a seguinte ter começado e mandar a barra para trás. O token diz de
    /// quem é o relato, e o que não é da geração corrente é descartado.
    private var generations: [String: UUID] = [:]

    public init(
        database: SyncDatabase,
        secrets: any SecretStore,
        auth: GoogleAuth?,
        session: URLSession,
        gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!,
        eventLoopGroup: any EventLoopGroup,
        imapConnect: @Sendable @escaping (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
            = { endpoint, grupo in try await ImapSession.connect(endpoint: endpoint, group: grupo) },
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.database = database
        self.secrets = secrets
        self.auth = auth
        self.session = session
        self.gmailBaseURL = gmailBaseURL
        self.eventLoopGroup = eventLoopGroup
        self.imapConnect = imapConnect
        self.now = now
    }

    /// O id de uma conta, derivado do endereço.
    ///
    /// Estável e determinístico porque a chave estrangeira do banco e a entrada
    /// do Keychain dependem dele: um id novo a cada adição deixaria órfão tudo
    /// o que a conta já tinha. Caixa baixa e só o que é seguro em id.
    public static func accountID(for address: String) -> String {
        let dobrado = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let permitidos = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.-_"))
        return String(dobrado.unicodeScalars.map { permitidos.contains($0) ? Character($0) : "-" })
    }

    // MARK: Publicação

    /// A lista publicada, por conta. Cada assinante recebe a lista inteira
    /// sempre que qualquer coisa muda — a janela desenha a tabela toda, não
    /// uma linha isolada, e um fluxo por conta obrigaria quem lê a costurá-las.
    public func statuses() -> AsyncStream<[AccountStatus]> {
        AsyncStream { continuation in
            let chave = UUID()
            subscribers[chave] = continuation
            continuation.onTermination = { _ in
                Task { await self.desassina(chave) }
            }
            // O primeiro valor sai sozinho: quem assina não deve ter de esperar
            // a próxima mudança para desenhar a lista que já existe.
            Task { await self.refresh() }
        }
    }

    private func desassina(_ chave: UUID) { subscribers[chave] = nil }

    /// Relê o banco e publica.
    public func refresh() async {
        let lista = (try? await montaStatuses()) ?? []
        for continuation in subscribers.values { continuation.yield(lista) }
    }

    private func montaStatuses() async throws -> [AccountStatus] {
        let contas = try await database.pool.read { db -> [Linha] in
            try AccountRecord.order(Column("createdAt")).fetchAll(db).map { registro in
                let quantas = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM message WHERE accountID = ?",
                    arguments: [registro.id]
                ) ?? 0
                return Linha(conta: registro.account, mensagens: quantas)
            }
        }
        return contas.map { linha in
            AccountStatus(
                accountID: linha.conta.id, address: linha.conta.address,
                hostMark: linha.conta.host, state: linha.conta.state,
                messageCount: linha.mensagens, lastSyncedAt: linha.conta.lastSyncedAt,
                error: errors[linha.conta.id], progress: progresses[linha.conta.id]
            )
        }
    }

    /// O par conta+contagem que atravessa a fronteira da leitura do banco.
    private struct Linha: Sendable {
        let conta: Account
        let mensagens: Int
    }

    // MARK: Adicionar

    /// Conecta uma conta Google: consentimento, perfil, gravação.
    @discardableResult
    public func addGoogleAccount(address: String) async throws -> Account {
        // Sem client ID a rota não existe — e dizer isso é a única coisa
        // honesta a fazer. A janela mostra a mensagem apontando o roteiro.
        guard let auth else { throw SyncError.semClientID }

        let id = Self.accountID(for: address)
        do {
            _ = try await auth.connect(accountID: id, loginHint: address)
            let cliente = GmailClient(
                session: session,
                accessToken: { try await auth.accessToken(for: id) },
                baseURL: gmailBaseURL
            )
            let perfil = try await cliente.profile()
            let conta = try await grava(
                id: id, address: perfil.emailAddress, displayName: perfil.emailAddress,
                provider: .gmail, hostMark: "gmail", endpoint: nil
            )
            errors[id] = nil
            await refresh()
            return conta
        } catch let erro as SyncError {
            errors[id] = erro
            await refresh()
            throw erro
        }
    }

    /// Só testa: conecta, autentica, sai. Não grava nada.
    ///
    /// Separado de `addImapAccount` porque a janela promete "Testar e
    /// adicionar" com o resultado do teste explicado — e um teste que já grava
    /// não é teste, é adição com uma etiqueta errada.
    public func testImap(address: String, password: String, endpoint: ImapEndpoint) async throws {
        let sessao = try await imapConnect(endpoint, eventLoopGroup)
        do {
            try await sessao.login(user: address, password: password)
            await sessao.logout()
        } catch {
            await sessao.logout()
            throw error
        }
    }

    @discardableResult
    public func addImapAccount(
        address: String, password: String, endpoint: ImapEndpoint,
        hostMark: String, displayName: String
    ) async throws -> Account {
        let id = Self.accountID(for: address)
        do {
            // O teste vem **antes** da gravação: uma conta que entra na lista
            // e só descobre na carga que a senha está errada faz a pessoa
            // remover e adicionar de novo para corrigir o que ela nunca
            // chegou a confirmar.
            try await testImap(address: address, password: password, endpoint: endpoint)
            // O segredo primeiro: uma conta no banco sem senha no Keychain
            // nasceria em erro de autenticação sem a pessoa ter feito nada.
            try secrets.store(.password(password), for: id)
            let conta = try await grava(
                id: id, address: address, displayName: displayName,
                provider: .imap, hostMark: hostMark, endpoint: endpoint
            )
            errors[id] = nil
            await refresh()
            return conta
        } catch let erro as SyncError {
            errors[id] = erro
            await refresh()
            throw erro
        }
    }

    /// Grava a conta — nova, ou **atualizada** se ela já existia.
    ///
    /// Adicionar de novo uma conta que já está na lista não é um engano a
    /// recusar: é o caminho normal de quem trocou a senha de app ou precisou
    /// reautenticar. Por isso a re-adição atualiza o que veio do formulário
    /// (endereço, nome, marca do host, servidor) e **preserva** o que é
    /// história da conta: estado, último sync, cor e assinatura — e, por
    /// tabela, as mensagens, que ninguém tocou. Recriar a linha do zero
    /// devolveria a conta a `carregando`, apagaria o carimbo de sincronização
    /// e trocaria a cor por baixo de quem já a reconhece pela cor.
    private func grava(
        id: String, address: String, displayName: String,
        provider: Account.Provider, hostMark: String, endpoint: ImapEndpoint?
    ) async throws -> Account {
        if let existente = try await database.pool.read({ try AccountRecord.fetchOne($0, key: id) }) {
            let velha = existente.account
            let atualizada = Account(
                id: id, address: address, displayName: displayName,
                provider: provider, host: hostMark,
                tintLightHex: velha.tintLightHex, tintDarkHex: velha.tintDarkHex,
                signature: velha.signature, imap: endpoint,
                state: velha.state, lastSyncedAt: velha.lastSyncedAt
            )
            try await database.pool.write { db in
                try AccountRecord(atualizada, createdAt: existente.createdAt).update(db)
            }
            return atualizada
        }

        let cores = AccountTints.pair(forIndex: try await indiceDeCorLivre())
        let conta = Account(
            id: id, address: address, displayName: displayName,
            provider: provider, host: hostMark,
            tintLightHex: cores.light, tintDarkHex: cores.dark,
            imap: endpoint, state: .carregando
        )
        // O relógio é lido **aqui**, e não dentro da escrita: `now` é estado
        // do ator, e a closure da escrita corre fora da isolação dele.
        let criadaEm = now()
        try await database.pool.write { db in
            try AccountRecord(conta, createdAt: criadaEm).insert(db)
        }
        return conta
    }

    /// O menor índice de cor que **nenhuma** conta está usando.
    ///
    /// Contar quantas contas existem não serve: remover a primeira de duas
    /// devolve a contagem a 1, e a próxima conta nasceria com a cor da que
    /// ficou — duas linhas da mesma cor na lateral, que é exatamente o que a
    /// cor existe para evitar.
    ///
    /// Quando as oito estão ocupadas o laço para no fim e o índice cai fora da
    /// lista, onde `pair` cicla: a nona conta repete uma cor, que é incômodo
    /// visual — e nunca recusa, que seria defeito.
    private func indiceDeCorLivre() async throws -> Int {
        let usadas = try await database.pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT tintLightHex FROM account"))
        }
        var indice = 0
        while indice < AccountTints.count, usadas.contains(AccountTints.pair(forIndex: indice).light) {
            indice += 1
        }
        return indice
    }

    // MARK: Remover

    /// Apaga a conta: banco **e** Keychain, e revoga no Google quando for o caso.
    ///
    /// Os dois, sempre. Deixar o segredo para trás é a definição de "removi e
    /// não removi": a conta some da lista e a senha continua no chaveiro da
    /// pessoa, esperando por um app que já esqueceu dela.
    public func remove(accountID: String) async throws {
        // A carga desta conta morre **antes** da linha ser apagada, e a
        // remoção espera por ela: um carregador ainda vivo escreveria a conta
        // de volta logo depois do `DELETE`, e a pessoa veria reaparecer o que
        // acabou de remover.
        await cancelaCarga(accountID)

        let conta = try await database.pool.read { db in
            try AccountRecord.fetchOne(db, key: accountID)?.account
        }
        if conta?.provider == .gmail, let auth {
            // Falhar aqui (offline, por exemplo) não pode impedir a remoção
            // local — mas o erro fica registrado para a janela mostrar.
            do { try await auth.revoke(accountID: accountID) } catch let erro as SyncError {
                errors[accountID] = erro
                log.error("Revogação de \(accountID, privacy: .public) falhou: \(erro.mensagem)")
            }
        }
        // O segredo sai **antes** da linha, e a ordem é escolhida: as duas
        // escritas não estão na mesma transação (uma é o Keychain, a outra é
        // SQLite), então uma delas vai ser a que falha sozinha. Falhar aqui
        // deixa a conta na lista com o segredo dela — visível, e a pessoa
        // manda remover de novo. Na ordem inversa, o `DELETE` passaria e o
        // Keychain falharia depois: a conta some da tela e a senha fica no
        // chaveiro, sem nada na interface que ainda saiba que ela existe.
        try secrets.remove(for: accountID)
        // A cascata do banco leva pastas, mensagens, corpos, agenda e
        // sync_state junto — está na migração v1, com teste.
        _ = try await database.pool.write { db in
            try AccountRecord.deleteOne(db, key: accountID)
        }
        errors[accountID] = nil
        progresses[accountID] = nil
        generations[accountID] = nil
        await refresh()
    }

    private func cancelaCarga(_ accountID: String) async {
        guard let carga = loads[accountID] else { return }
        loads[accountID] = nil
        carga.cancel()
        // Esperar é o ponto: cancelar sem esperar deixaria a corrida de pé,
        // só mais curta.
        await carga.value
    }

    // MARK: Carregar

    /// A carga inicial da conta, publicando progresso.
    ///
    /// Não lança: quem chama é a UI, e o lugar do erro é o estado publicado —
    /// que é onde a janela mostra a causa e a ação. Engolir seria não
    /// registrar; aqui ele vai para `errors`, para o log e para a tela.
    ///
    /// O trabalho corre numa `Task` própria para que `remove` tenha o que
    /// cancelar. `withTaskCancellationHandler` liga as duas pontas: uma
    /// `Task` sem estrutura **não** herda o cancelamento de quem a criou, e
    /// sem isto cancelar o chamador deixaria a carga rodando sozinha.
    public func loadInitial(accountID: String) async {
        // Uma carga por conta, e a anterior morre **e é esperada** antes de a
        // nova nascer. Sobrescrever `loads` sem isto deixaria a primeira carga
        // rodando sem ninguém que a conheça: um `remove` posterior cancelaria
        // só a segunda, e a órfã seguiria escrevendo depois do `DELETE` — o
        // invariante deste arquivo passaria a depender dos guards de outro.
        await cancelaCarga(accountID)

        let geracao = UUID()
        generations[accountID] = geracao
        let tarefa = Task<Void, Never> { [weak self] in
            await self?.executaCarga(accountID: accountID, geracao: geracao)
        }
        loads[accountID] = tarefa
        await withTaskCancellationHandler {
            await tarefa.value
        } onCancel: {
            tarefa.cancel()
        }
        if loads[accountID] == tarefa { loads[accountID] = nil }
    }

    private func executaCarga(accountID: String, geracao: UUID) async {
        guard let conta = try? await database.pool.read({ db in
            try AccountRecord.fetchOne(db, key: accountID)?.account
        }) else { return }

        let loader = InitialLoader(database: database)
        let publica: @Sendable (LoadProgress) -> Void = { [weak self] progresso in
            Task { await self?.registra(progresso, geracao: geracao) }
        }

        do {
            switch conta.provider {
            case .gmail:
                guard let auth else { throw SyncError.semClientID }
                let cliente = GmailClient(
                    session: session,
                    accessToken: { try await auth.accessToken(for: accountID) },
                    baseURL: gmailBaseURL
                )
                try await loader.loadGmail(
                    account: conta, client: cliente,
                    renewAccessToken: { _ = try await auth.renewedAccessToken(for: accountID) },
                    now: now(), progress: publica
                )
            case .imap, .microsoft:
                guard let endpoint = conta.imap else {
                    throw SyncError.resposta("A conta não tem servidor IMAP configurado.")
                }
                guard case .password(let senha)? = try secrets.secret(for: accountID) else {
                    throw SyncError.autenticacao
                }
                let sessao = try await imapConnect(endpoint, eventLoopGroup)
                defer { Task { await sessao.logout() } }
                try await sessao.login(user: conta.address, password: senha)
                try await loader.loadImap(
                    account: conta, session: sessao, now: now(), progress: publica
                )
            }
            errors[accountID] = nil
        } catch is CancellationError {
            // Cancelamento não é defeito, e é o caminho mais provável dos três:
            // a pessoa fechou a janela, ou removeu a conta no meio. O que não
            // pode sobrar é a conta presa em `carregando` — o carregador já
            // cuida disso quando o cancelamento cai dentro dele, e isto cobre
            // o vão de antes: a conexão que morreu antes da primeira escrita.
            await restaura(accountID)
        } catch let erro as SyncError {
            errors[accountID] = erro
            log.error("Carga de \(accountID, privacy: .public) falhou: \(erro.mensagem)")
        } catch {
            errors[accountID] = .rede(error.localizedDescription)
        }
        // Mesmo cuidado do progresso: uma carga que morreu enquanto a
        // seguinte já rodava não pode apagar a barra da que está viva.
        guard generations[accountID] == geracao else { return }
        progresses[accountID] = nil
        await refresh()
    }

    /// Tira a conta de `carregando` quando a carga morre antes de o carregador
    /// tomar conta dela.
    ///
    /// `Task.detached` porque o GRDB honra o cancelamento: uma escrita chamada
    /// de dentro de uma tarefa já cancelada lança antes de tocar o banco, e a
    /// conta ficaria em `carregando` para sempre — a lição da Task 13, no
    /// mesmo lugar. A conta que já sumiu (removida) simplesmente não é achada.
    private func restaura(_ accountID: String) async {
        let database = self.database
        do {
            try await Task.detached {
                try await database.pool.write { db in
                    guard let registro = try AccountRecord.fetchOne(db, key: accountID) else { return }
                    try AccountRecord(
                        registro.account.withState(.ativa), createdAt: registro.createdAt
                    ).update(db)
                }
            }.value
        } catch {
            log.error("Não foi possível tirar a conta de `carregando`: \(error)")
        }
    }

    private func registra(_ progresso: LoadProgress, geracao: UUID) async {
        // Relato de carga que já não é a corrente não move a barra de ninguém.
        guard generations[progresso.accountID] == geracao else { return }
        progresses[progresso.accountID] = progresso
        await refresh()
    }
}
