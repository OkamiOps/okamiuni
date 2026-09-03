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
    /// O erro da fila de saída, **em prateleira própria** — ver `reportQueue`.
    private var queueErrors: [String: SyncError] = [:]
    private var progresses: [String: LoadProgress] = [:]
    /// Contas com um ciclo incremental em curso. Separado de `progresses`
    /// porque o delta não tem numerador/denominador honesto — só "está no ar".
    private var cycling: Set<String> = []
    /// Total da Entrada no Gmail, por conta. Vive aqui porque o ciclo o lê
    /// e a janela o mostra; o banco guarda a caixa local, não o retrato do
    /// provedor.
    private var remoteInboxCounts: [String: Int] = [:]
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
    /// A observação da fila de saída. Uma só, viva enquanto houver quem desenhe
    /// a lista — ver `observaAFila()`.
    private var fila: Task<Void, Never>?

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
            self.observaAFila()
            continuation.onTermination = { _ in
                Task { await self.desassina(chave) }
            }
            // O primeiro valor sai sozinho: quem assina não deve ter de esperar
            // a próxima mudança para desenhar a lista que já existe.
            Task { await self.refresh() }
        }
    }

    private func desassina(_ chave: UUID) {
        subscribers[chave] = nil
        // Sem ninguém olhando, a observação do banco desliga: ela existe para
        // acordar a janela, e continuar acordando ninguém pelo resto da vida do
        // app é o mesmo desperdício que a `snapshots()` do `DatabaseMailSource`
        // desfaz no `onTermination` dela.
        if subscribers.isEmpty {
            fila?.cancel()
            fila = nil
        }
    }

    /// O selo "n aguardando" muda quando a **tabela** muda, e não quando alguém
    /// se lembra de perguntar.
    ///
    /// `ValueObservation` sobre a `outbox`, como o resto do app: enfileirar,
    /// executar e concluir são escritas nela, e cada uma acorda esta observação
    /// — que só chama `refresh()`. Sem isto o número só se moveria nas ações
    /// que já publicam (adicionar, remover, um erro reportado), e a fila
    /// esvaziando sozinha em segundo plano deixaria "3 aguardando" na tela para
    /// sempre.
    ///
    /// Uma só para todos os assinantes, e ela não lê o número: o valor
    /// observado é a contagem da tabela inteira, barato, e serve de gatilho —
    /// `montaStatuses` faz a leitura de verdade, por conta.
    private func observaAFila() {
        guard fila == nil else { return }
        let pool = database.pool
        fila = Task { [weak self] in
            do {
                let gatilho = ValueObservation.tracking { db in
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM outbox") ?? 0
                }
                for try await _ in gatilho.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                    await self?.refresh()
                }
            } catch {
                // Observação que morre não pode derrubar a janela: o resto dos
                // caminhos que publicam continua valendo.
                await self?.registraQuedaDaFila(error)
            }
        }
    }

    private func registraQuedaDaFila(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        log.error("A observação da fila de saída parou: \(error)")
    }

    /// O erro do **ciclo** de uma conta: a carga inicial e o coordenador de
    /// sincronização (`SyncRunner`).
    ///
    /// `nil` limpa — é o ciclo que passou, e a pessoa precisa ver isso tanto
    /// quanto viu a falha. A publicação só acontece quando o valor de fato
    /// muda: um ciclo bem sucedido por minuto redesenharia a lista inteira à
    /// toa, para sempre.
    ///
    /// **Não toca no erro da fila.** As duas prateleiras foram uma só, e o
    /// preço apareceu no banco do dono: a fila parava às 09:21 e relatava a
    /// falha, o ciclo seguinte passava bem e relatava `nil` — e o `nil` do
    /// ciclo apagava o erro da fila. A conta aparecia "Sincronizada às 00:59 ·
    /// 48 mensagens · 5 aguardando", saudável, com cinco operações travadas e
    /// nenhuma saída oferecida. Numa prateleira só a fila perde sempre: o
    /// ciclo passa a cada minuto e ela não.
    public func report(accountID: String, error: SyncError?) async {
        guard errors[accountID] != error else { return }
        errors[accountID] = error
        await refresh()
    }

    /// O erro da **fila de saída** de uma conta (`OutboxExecutor`, pelo
    /// `OutboxRunner`). A outra prateleira.
    ///
    /// Ela só é limpa por quem tratou a fila: `retryAfterPermanentFailure`
    /// relata `nil` ao religá-la. Um ciclo de sincronização bem sucedido não
    /// diz nada sobre uma operação de saída que o servidor recusou.
    public func reportQueue(accountID: String, error: SyncError?) async {
        guard queueErrors[accountID] != error else { return }
        queueErrors[accountID] = error
        await refresh()
    }

    /// Liga ou desliga o selo "sincronizando" de uma conta.
    ///
    /// Publica só quando o valor muda: um ciclo que relata `true` duas vezes
    /// (o `defer` de um `syncOnce` cancelado no mesmo instante do seguinte)
    /// não pode redesenhar a barra à toa.
    public func reportSyncing(accountID: String, active: Bool) async {
        let estava = cycling.contains(accountID)
        if active {
            cycling.insert(accountID)
        } else {
            cycling.remove(accountID)
        }
        guard cycling.contains(accountID) != estava else { return }
        await refresh()
    }

    /// O total da Entrada no Gmail. Publica só quando o número muda.
    public func reportRemoteInbox(accountID: String, count: Int) async {
        guard remoteInboxCounts[accountID] != count else { return }
        remoteInboxCounts[accountID] = count
        await refresh()
    }

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
                // A fila de saída desta conta. O mesmo `state <> feita` do
                // executor, e pela mesma razão: a linha concluída sai da
                // tabela, então o que resta é o que ainda não aconteceu —
                // pendente, esperando o recuo, ou parada por uma falha.
                let aguardando = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM outbox WHERE accountID = ? AND state <> ?",
                    arguments: [registro.id, OutboxState.feita.rawValue]
                ) ?? 0
                return Linha(conta: registro.account, mensagens: quantas, aguardando: aguardando)
            }
        }
        return contas.map { linha in
            AccountStatus(
                accountID: linha.conta.id, address: linha.conta.address,
                hostMark: linha.conta.host, state: linha.conta.state,
                messageCount: linha.mensagens, lastSyncedAt: linha.conta.lastSyncedAt,
                error: errors[linha.conta.id], progress: progresses[linha.conta.id],
                pendingOperations: linha.aguardando,
                queueError: queueErrors[linha.conta.id],
                signature: linha.conta.signature,
                emailSignature: linha.conta.emailSignature,
                isSyncing: cycling.contains(linha.conta.id),
                remoteInboxCount: remoteInboxCounts[linha.conta.id],
                sendAliases: linha.conta.sendAliases,
                provider: linha.conta.provider,
                imap: linha.conta.imap
            )
        }
    }

    /// O par conta+contagem que atravessa a fronteira da leitura do banco.
    private struct Linha: Sendable {
        let conta: Account
        let mensagens: Int
        let aguardando: Int
    }

    // MARK: Assinatura

    /// Atualiza só a assinatura rica da conta e publica o novo retrato.
    ///
    /// A leitura e a escrita acontecem na mesma transação. Alterar uma
    /// `Account` reconstruindo-a fora do banco seria perigoso: estado, carimbo
    /// de sincronização, cores e endpoint IMAP são história da conta e não
    /// fazem parte desta edição. Mutar o `AccountRecord` já lido torna esse
    /// contrato explícito e preserva todos os demais campos.
    @discardableResult
    public func updateEmailSignature(
        accountID: String, signature: EmailSignature
    ) async throws -> Account {
        do {
            let atualizada = try await database.pool.write { db -> Account in
                guard var registro = try AccountRecord.fetchOne(db, key: accountID) else {
                    throw SyncError.resposta("A conta não existe.")
                }
                registro.emailSignature = signature
                try registro.update(db)
                return registro.account
            }
            await refresh()
            return atualizada
        } catch let erro as SyncError {
            throw erro
        } catch {
            throw SyncError.banco("Não foi possível gravar a assinatura: \(error)")
        }
    }

    /// API temporária de compatibilidade para quem ainda edita somente texto.
    /// A gravação passa pelo mesmo caminho rico, com HTML e recursos vazios,
    /// para as duas colunas nunca divergirem.
    @discardableResult
    public func updateSignature(accountID: String, signature: String) async throws -> Account {
        try await updateEmailSignature(
            accountID: accountID, signature: EmailSignature(legacyText: signature)
        )
    }

    /// Grava a lista de aliases desta conta. O endereço principal não entra.
    @discardableResult
    public func updateSendAliases(
        accountID: String, aliases: [SendAlias]
    ) async throws -> Account {
        do {
            let atualizada = try await database.pool.write { db -> Account in
                guard var registro = try AccountRecord.fetchOne(db, key: accountID) else {
                    throw SyncError.resposta("A conta não existe.")
                }
                registro.sendAliases = SendAlias.normalized(
                    aliases, excluding: registro.address
                )
                try registro.update(db)
                return registro.account
            }
            await refresh()
            return atualizada
        } catch let erro as SyncError {
            throw erro
        } catch {
            throw SyncError.banco("Não foi possível gravar os remetentes: \(error)")
        }
    }

    /// Lê "Enviar como" no Gmail e funde com os aliases manuais.
    @discardableResult
    public func refreshGmailSendAliases(accountID: String) async throws -> Account {
        guard let auth else { throw SyncError.semClientID }
        let registro = try await database.pool.read { db in
            try AccountRecord.fetchOne(db, key: accountID)
        }
        guard let registro else { throw SyncError.resposta("A conta não existe.") }
        guard registro.account.provider == .gmail else {
            throw SyncError.resposta("Só contas Google trazem aliases do Gmail.")
        }
        let cliente = GmailClient(
            session: session,
            accessToken: { try await auth.accessToken(for: accountID) },
            baseURL: gmailBaseURL
        )
        let remotos = try await cliente.sendAsAliases()
        let fundidos = SendAlias.merging(
            gmail: remotos.map {
                ($0.email, $0.displayName, $0.isPrimary, $0.isDefault)
            },
            existing: registro.sendAliases,
            primary: registro.address
        )
        let atuais = SendAlias.normalized(registro.sendAliases, excluding: registro.address)
        if fundidos == atuais { return registro.account }
        return try await updateSendAliases(accountID: accountID, aliases: fundidos)
    }

    /// A carga e o ciclo chamam isto. Falha aqui não pode derrubar o sync:
    /// a caixa continua, os aliases tentam de novo na próxima volta.
    func refreshGmailSendAliasesIfPossible(accountID: String) async {
        do {
            _ = try await refreshGmailSendAliases(accountID: accountID)
        } catch {
            log.debug("Aliases Gmail de \(accountID, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
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
    /// Quando todas as do catálogo estão ocupadas o laço para no fim e o
    /// índice cai fora da lista, onde `pair` cicla: a conta seguinte
    /// repete uma cor, que é incômodo visual — e nunca recusa, que seria
    /// defeito.
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

    // MARK: Reconectar

    /// Reautentica a conta Google **que já existe**, no lugar.
    ///
    /// Preserva id, banco, fila de saída e preferências — porque não mexe em
    /// nenhum deles: o que troca é o token no Keychain, e mais nada. Era a
    /// saída que faltava, e a sua falta era grave: a única ação que a faixa de
    /// atenção oferecia era "Remover conta…", que apagava 1.446 mensagens
    /// locais e uma fila de saída com item pendente para resolver uma
    /// credencial vencida.
    ///
    /// ## Por que o consentimento vai para um rascunho
    ///
    /// `GoogleAuth.connect` **guarda o token** no fim do fluxo, e o endereço só
    /// pode ser conferido depois — com um token na mão é que se pergunta ao
    /// Gmail de quem ele é. Conectar direto no id da conta gravaria por cima
    /// antes da conferência: quem entrasse com a conta errada acabaria com a
    /// credencial de uma pessoa pendurada na caixa de outra, e o token bom da
    /// conta original já teria sido substituído. O rascunho desfaz isso: o
    /// consentimento vai para um id descartável, a conferência acontece com ele,
    /// e só uma reconexão **confirmada** escreve no id de verdade.
    ///
    /// Nada é apagado antes de a substituta existir. Toda falha — consentimento
    /// negado, rede caída, endereço diferente — sai daqui com o token velho
    /// intacto no lugar dele.
    @discardableResult
    public func reconnectGoogle(accountID: String) async throws -> Account {
        let conta = try await contaExistente(accountID)
        guard let auth else {
            // Sem Client ID não há o que reconectar: falta configurar o
            // **aplicativo**, e a janela mostra o roteiro em vez de um botão
            // que abriria um consentimento sem identidade.
            errors[accountID] = .semClientID
            await refresh()
            throw SyncError.semClientID
        }

        let rascunho = "reconectar:\(UUID().uuidString)"
        do {
            _ = try await auth.connect(accountID: rascunho, loginHint: conta.address)
            let cliente = GmailClient(
                session: session,
                accessToken: { try await auth.accessToken(for: rascunho) },
                baseURL: gmailBaseURL
            )
            let perfil = try await cliente.profile()
            try confereEndereco(esperado: conta.address, recebido: perfil.emailAddress)

            // A troca: o segredo do rascunho passa a ser o segredo da conta.
            // Só aqui, e só depois da conferência.
            guard let novo = try secrets.secret(for: rascunho) else {
                throw SyncError.autenticacao
            }
            try secrets.store(novo, for: accountID)
            try? secrets.remove(for: rascunho)

            let religada = try await religa(conta)
            errors[accountID] = nil
            queueErrors[accountID] = nil
            await refresh()
            return religada
        } catch {
            // O rascunho nunca sobrevive à falha: é credencial de verdade, e
            // credencial órfã no chaveiro é vazamento — um refresh token sem
            // dono, que nenhuma tela lista e ninguém consegue revogar.
            //
            // **Pega tudo, e não só `SyncError`** — mesmo hoje, quando todo
            // caminho entre guardar o rascunho e trocá-lo pelo definitivo já
            // traduz o que lança (`GmailClient.get` embrulha até erro de
            // decodificação). Filtrar por tipo aqui faria a limpeza da
            // credencial depender dessa disciplina continuar valendo em cada
            // callee, para sempre; e a falha silenciosa dessa aposta é um
            // refresh token órfão no chaveiro, que nenhuma tela lista e
            // ninguém revoga. Não há teste para este `catch` porque não há
            // como alcançá-lo por aqui — ele é o que impede o próximo caminho
            // de virar vazamento, não o conserto de um vazamento de hoje.
            // O que muda com o tipo é só a faixa da janela, que continua
            // falando a língua de `SyncError`.
            try? secrets.remove(for: rascunho)
            if let erro = error as? SyncError { errors[accountID] = erro }
            await refresh()
            throw error
        }
    }

    /// Reautentica a conta IMAP que já existe: testa a senha nova e grava por
    /// cima. O endereço vem do formulário porque ele é editável na tela — e é
    /// justamente por isso que ele é conferido.
    ///
    /// O teste vem **antes** da gravação, como em `addImapAccount`: uma senha
    /// que não serve não pode substituir uma que servia.
    @discardableResult
    public func reconnectImap(
        accountID: String, address: String, password: String, endpoint: ImapEndpoint
    ) async throws -> Account {
        let conta = try await contaExistente(accountID)
        do {
            try confereEndereco(esperado: conta.address, recebido: address)
            try await testImap(address: address, password: password, endpoint: endpoint)
            try secrets.store(.password(password), for: accountID)
            let religada = try await religa(conta, endpoint: endpoint)
            errors[accountID] = nil
            queueErrors[accountID] = nil
            await refresh()
            return religada
        } catch let erro as SyncError {
            errors[accountID] = erro
            await refresh()
            throw erro
        }
    }

    /// A conta do banco, ou o erro que diz que ela não está lá.
    ///
    /// Reconectar age sobre o que existe: uma conta que sumiu do banco não pode
    /// ser "reconectada" para dentro dele — isso seria adicionar, com outro
    /// nome.
    private func contaExistente(_ accountID: String) async throws -> Account {
        guard let conta = try await database.pool.read({ db in
            try AccountRecord.fetchOne(db, key: accountID)?.account
        }) else {
            throw SyncError.banco("A conta não está mais na lista.")
        }
        return conta
    }

    /// Reconectar não pode trocar de identidade em silêncio.
    ///
    /// Comparação sem caixa e sem espaço em volta: `Marcos@OkamiOps.com` e
    /// `marcos@okamiops.com` são a mesma caixa, e recusá-las como diferentes
    /// travaria quem só digitou com maiúscula.
    private func confereEndereco(esperado: String, recebido: String) throws {
        let a = esperado.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = recebido.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard a != b else { return }
        throw SyncError.contaDiferente(esperado: esperado, recebido: recebido)
    }

    /// A conta volta a ser uma conta viva: estado `.ativa` e mais nada tocado.
    ///
    /// **Não** é `grava(id:…)`: aquela é a porta de quem está adicionando, e
    /// atualiza nome e marca do host a partir de um formulário. Aqui não houve
    /// formulário nenhum de identidade — só uma credencial nova —, e o que a
    /// conta é continua sendo o que ela era. O carimbo de sync, a cor, a
    /// assinatura e as mensagens seguem intocados, que é o ponto inteiro
    /// desta operação.
    ///
    /// `.ativa`, e não `.carregando`: reconectar não pediu para baixar noventa
    /// dias de novo. O ciclo incremental acorda sozinho e traz o que faltou.
    private func religa(_ conta: Account, endpoint: ImapEndpoint? = nil) async throws -> Account {
        let religada = Account(
            id: conta.id, address: conta.address, displayName: conta.displayName,
            provider: conta.provider, host: conta.host,
            tintLightHex: conta.tintLightHex, tintDarkHex: conta.tintDarkHex,
            signature: conta.signature,
            imap: endpoint ?? conta.imap,
            state: .ativa, lastSyncedAt: conta.lastSyncedAt
        )
        try await database.pool.write { db in
            guard let existente = try AccountRecord.fetchOne(db, key: religada.id) else { return }
            try AccountRecord(religada, createdAt: existente.createdAt).update(db)
        }
        return religada
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
                // `.private`, e não `.public`: `accountID(for:)` só passa o
                // endereço para caixa baixa e troca o que não for
                // alfanumérico/`@.-_` por `-` — para `marina@clientepremium.com`
                // o id **é** o endereço. `.public` o gravava em claro no log
                // unificado do sistema, visível em `log show` e recolhido em
                // qualquer sysdiagnose. O `InitialLoader` já respondia
                // `.private` para o mesmo dado; as duas respostas conviviam.
                log.error("Revogação de \(accountID, privacy: .private) falhou: \(erro.mensagem)")
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
        queueErrors[accountID] = nil
        progresses[accountID] = nil
        cycling.remove(accountID)
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
                    now: now(), progress: publica,
                    remoteInbox: { [weak self] total in
                        Task { await self?.reportRemoteInbox(accountID: accountID, count: total) }
                    }
                )
                await refreshGmailSendAliasesIfPossible(accountID: accountID)
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
            log.error("Carga de \(accountID, privacy: .private) falhou: \(erro.mensagem)")
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

    /// `internal`, e não `private`: é a porta mínima que deixa o teste provar o
    /// token de geração.
    ///
    /// A Task 15 evitou esta porta e declarou o token **sem teste**; a auditoria
    /// por mutação deste marco mediu o preço — apagar o `guard` abaixo deixava
    /// os 206 testes verdes. O relato de progresso viaja num `Task` próprio,
    /// disparado de fora do ator, e não há como fazer um relato de carga morta
    /// chegar atrasado a partir da API pública sem depender de tempo: o único
    /// jeito honesto de provar a regra é chamar isto com uma geração que não é
    /// a corrente. A porta não abre nada que já não estivesse aberto ao
    /// `@testable` — ela só dá nome ao que provar.
    func registra(_ progresso: LoadProgress, geracao: UUID) async {
        // Relato de carga que já não é a corrente não move a barra de ninguém.
        guard generations[progresso.accountID] == geracao else { return }
        progresses[progresso.accountID] = progresso
        await refresh()
    }

    /// A geração corrente de uma conta. A outra metade da porta acima: sem ela
    /// o teste não teria como distinguir "a geração certa" de "uma qualquer".
    func geracaoCorrente(de accountID: String) -> UUID? { generations[accountID] }

    /// O progresso que a janela veria agora. Sem isto, provar que o relato
    /// velho **não** moveu a barra dependeria de reconstruir o `AccountStatus`
    /// inteiro pelo fluxo de assinatura, e o teste passaria a medir o fluxo em
    /// vez da regra.
    func progressoCorrente(de accountID: String) -> LoadProgress? { progresses[accountID] }
}
