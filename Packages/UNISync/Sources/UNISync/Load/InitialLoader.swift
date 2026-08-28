import Foundation
import GRDB
import UNICore
import os

public struct LoadProgress: Sendable, Hashable {
    public let accountID: String
    public let done: Int
    public let total: Int

    public init(accountID: String, done: Int, total: Int) {
        self.accountID = accountID
        self.done = done
        self.total = total
    }

    /// Entre 0 e 1. Total zero é 1: uma conta vazia terminou de carregar.
    public var fraction: Double {
        guard total > 0 else { return 1 }
        return min(1, Double(done) / Double(total))
    }
}

/// A carga inicial de leitura: 90 dias, por conta, para o banco.
///
/// **Interrompível e retomável, por construção.** As transações são por lote,
/// os ids são determinísticos e a escrita é upsert: parar no meio deixa o que
/// entrou, e reabrir passa por cima sem duplicar. Não há "recomeçar do zero"
/// nem estado parcial em memória que se perca.
public struct InitialLoader: Sendable {
    /// Noventa dias. É a janela do marco: o suficiente para o app ser útil
    /// offline sem baixar dez anos de caixa numa primeira abertura.
    public static let windowDays = 90

    /// Quantas mensagens ganham o corpo cheio na carga inicial. O resto desce
    /// por demanda — baixar o corpo de milhares de mensagens que ninguém vai
    /// abrir custa tempo e disco para nada.
    public static let fullBodyCount = 50

    /// O teto de páginas da listagem. A `messages.list` pede 500 ids por
    /// página, então 500 páginas são 250 mil mensagens — quarenta e cinco dias
    /// de folga sobre a caixa mais movimentada que uma janela de 90 dias
    /// produz. Quem passar disso não é uma caixa grande: é um laço.
    public static let maxPages = 500

    /// Quantas mensagens por transação. Lote pequeno demais paga o preço da
    /// transação a toda hora; grande demais deixa o progresso mentindo parado
    /// e o cancelamento demorado.
    public static let defaultBatchSize = 50

    private let database: SyncDatabase
    private let calendar: Calendar
    /// Configurável **para poder ser testado**: a promessa "parar no meio
    /// deixa o que já entrou" só é verificável quando o teste consegue fazer
    /// a falha cair depois de um lote e antes do próximo. Com o lote fixo em
    /// 50 e quatro mensagens no roteiro, nenhuma transação fecharia antes da
    /// falha e a garantia passaria sem prova.
    private let batchSize: Int
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "InitialLoader")

    public init(
        database: SyncDatabase,
        calendar: Calendar = Calendar(identifier: .gregorian),
        batchSize: Int = InitialLoader.defaultBatchSize
    ) {
        self.database = database
        self.calendar = calendar
        self.batchSize = max(1, batchSize)
    }

    /// O começo da janela. Recebe `now` em vez de ler o relógio: teste com
    /// relógio de verdade é teste que passa hoje e falha em novembro.
    public func since(now: Date) -> Date {
        calendar.date(byAdding: .day, value: -Self.windowDays, to: now) ?? now
    }

    /// A consulta que o **servidor** executa.
    ///
    /// `newer_than:90d` é o que faz o Gmail devolver só a janela. Trazer a
    /// caixa inteira para filtrar aqui gastaria uma listagem de anos de
    /// mensagens para jogar quase tudo fora — e numa conta grande a carga
    /// inicial nunca terminaria.
    public static var gmailQuery: String { "newer_than:\(windowDays)d" }

    // MARK: Gmail

    /// - Parameter renewAccessToken: buscar um token **forçando** a renovação.
    ///   É o que dá ao 401 uma segunda chance — ver `GmailAuthReplay`. Nulo
    ///   mantém o comportamento antigo: o primeiro 401 é terminal.
    public func loadGmail(
        account: Account,
        client: GmailClient,
        renewAccessToken: (@Sendable () async throws -> Void)? = nil,
        now: Date,
        progress: @Sendable (LoadProgress) -> Void
    ) async throws {
        let gmail = GmailAuthReplay(client: client, renew: renewAccessToken)
        do {
            try await marca(account.id, estado: .carregando)

            // O `historyId` é lido **antes** da carga e guardado **depois**
            // dela: o que chegar no meio entra pelo incremental do Marco 3,
            // em vez de cair no vão entre as duas leituras.
            let perfil = try await gmail.profile()
            let rotulos = try await gmail.labels()
            let idDoDepois = TriageProjection.laterLabelID(in: rotulos)

            // Uma "pasta" só para o Gmail: os rótulos fazem o papel das pastas,
            // e a tabela `folder` guarda a chave estrangeira que a cascata usa.
            let folderID = FolderRecord.id(accountID: account.id, serverName: "GMAIL")
            try await database.pool.write { db in
                try FolderRecord(
                    id: folderID, accountID: account.id, serverName: "GMAIL",
                    role: .inbox, displayName: "Gmail"
                ).save(db)
            }

            // 1. Os ids, paginados.
            //
            // O laço tem duas guardas, e nenhuma delas é decorativa: um
            // servidor que devolve sempre o mesmo `nextPageToken` (por defeito
            // dele ou por um proxy no meio) faria a carga girar para sempre,
            // enchendo `ids` de repetidos e sem nunca chegar à segunda etapa —
            // uma roda de progresso que nunca anda, sem nada no relato.
            var ids: [String] = []
            var token: String?
            var tokensVistos: Set<String> = []
            var paginas = 0
            repeat {
                try Task.checkCancellation()
                let pagina = try await gmail.messageIDs(query: Self.gmailQuery, pageToken: token)
                ids.append(contentsOf: pagina.ids)
                paginas += 1

                if let proximo = pagina.nextPageToken {
                    guard tokensVistos.insert(proximo).inserted else {
                        throw SyncError.resposta(
                            "A listagem do Gmail devolveu a mesma página de novo (token repetido) — a paginação não avança."
                        )
                    }
                    guard paginas < Self.maxPages else {
                        throw SyncError.resposta(
                            "A listagem do Gmail passou de \(Self.maxPages) páginas sem terminar."
                        )
                    }
                }
                token = pagina.nextPageToken
            } while token != nil

            progress(LoadProgress(accountID: account.id, done: 0, total: ids.count))

            // 2. As mensagens, em lotes, com corpo cheio só nas primeiras.
            var lote: [(GmailMessage, Bool)] = []
            for (indice, id) in ids.enumerated() {
                try Task.checkCancellation()
                let comCorpo = indice < Self.fullBodyCount
                do {
                    lote.append((try await gmail.message(id: id, format: comCorpo ? .full : .metadata), comCorpo))
                } catch let erro as SyncError where !Self.derrubaACarga(erro) {
                    // Uma mensagem defeituosa não pode custar as outras
                    // oitenta e nove. Ela fica de fora, com o id no relato —
                    // o mesmo princípio do teto da carga IMAP: o que é da
                    // mensagem morre na mensagem, o que é da sessão morre na
                    // sessão.
                    log.error("A mensagem \(id, privacy: .public) ficou de fora da carga: \(erro.mensagem)")
                }

                if lote.count >= batchSize || indice == ids.count - 1 {
                    if !lote.isEmpty {
                        try await grava(lote, account: account, folderID: folderID, laterLabelID: idDoDepois)
                        lote = []
                    }
                    // O progresso conta o que foi **percorrido**, não o que foi
                    // gravado: uma mensagem pulada não pode deixar a barra
                    // parada a 3/4 para sempre, e uma Enviada — que nunca vira
                    // linha — muito menos.
                    progress(LoadProgress(accountID: account.id, done: indice + 1, total: ids.count))
                }
            }

            // 3. O ponto de partida do Marco 3, guardado agora.
            try await database.pool.write { db in
                try SyncStateRecord(
                    accountID: account.id, folderID: "",
                    historyID: perfil.historyID, syncedAt: now
                ).save(db)
            }
            try await conclui(account.id, em: now)
            log.info("Carga inicial de \(account.address, privacy: .private) terminou: \(ids.count) mensagens.")
        } catch is CancellationError {
            // Cancelamento não é defeito: a conta volta a `ativa` com o que
            // baixou, e a próxima abertura continua de onde parou.
            await recupera(account.id, estado: .ativa)
            throw CancellationError()
        } catch let erro as SyncError {
            await recupera(account.id, estado: Self.estadoPara(erro))
            log.error("Carga inicial de \(account.address, privacy: .private) falhou: \(erro.mensagem)")
            throw erro
        } catch {
            // Banco, GRDB, o que for: o que não pode acontecer é a conta ficar
            // presa em `carregando` para sempre, girando uma roda que nunca
            // mais vai parar.
            await recupera(account.id, estado: .ativa)
            log.error("Carga inicial de \(account.address, privacy: .private) falhou: \(error)")
            throw error
        }
    }

    /// A escrita de recuperação — a que tira a conta de `carregando` quando a
    /// carga termina mal.
    ///
    /// **Fora da tarefa cancelada, sempre.** O GRDB honra o cancelamento: uma
    /// `pool.write` chamada de dentro de um `Task` já cancelado lança
    /// `CancellationError` antes de tocar o banco. Escrita direta aqui, com o
    /// erro engolido por um `try?`, deixava a conta presa em `carregando` para
    /// sempre — girando a roda que o comentário acima jura que para. É o
    /// caminho **exato** do cancelamento, o mais provável dos três.
    ///
    /// `Task.detached` porque ele não herda o cancelamento do chamador; e
    /// `try?` continua ali porque, se nem esta escrita passar, o que resta é
    /// registrar — lançar daqui trocaria o erro real da carga por um erro de
    /// banco na limpeza.
    private func recupera(_ accountID: String, estado: Account.State) async {
        do {
            try await Task.detached { [self] in
                try await marca(accountID, estado: estado)
            }.value
        } catch {
            log.error("Não foi possível tirar a conta de `carregando`: \(error)")
        }
    }

    /// Um lote inteiro numa transação: ou entra tudo, ou nada.
    private func grava(
        _ lote: [(GmailMessage, Bool)], account: Account, folderID: String, laterLabelID: String?
    ) async throws {
        try await database.pool.write { db in
            for (mensagem, temCorpo) in lote {
                guard let bucket = TriageProjection.bucket(
                    gmailLabelIDs: mensagem.labelIDs, laterLabelID: laterLabelID
                ) else { continue }   // Enviadas ficam fora da triagem.

                let id = MessageIdentity.gmail(accountID: account.id, serverID: mensagem.id)
                let nossa = Message(
                    id: id, accountID: account.id, from: mensagem.from,
                    receivedAt: mensagem.internalDate,
                    subject: mensagem.subject, snippet: mensagem.snippet,
                    body: mensagem.body, tags: [], bucket: bucket,
                    // As bandeiras também são projeção, e a regra mora junto
                    // das outras em `TriageProjection` — não escrita à mão
                    // aqui dentro, onde a carga do Marco 3 teria de a copiar.
                    isRead: TriageProjection.isRead(gmailLabelIDs: mensagem.labelIDs),
                    summary: nil, detectedEvent: nil,
                    to: mensagem.to, cc: mensagem.cc,
                    isFlagged: TriageProjection.isFlagged(gmailLabelIDs: mensagem.labelIDs),
                    serverID: mensagem.id
                )
                // `save` é upsert: id determinístico + upsert = recarga
                // idempotente, que é o que faz "parar no meio" ser seguro.
                try MessageRecord(nossa, folderID: folderID).save(db)
                if temCorpo, !mensagem.body.isEmpty {
                    try Self.gravaCorpo(db, id: id, paragrafos: mensagem.body)
                }
            }
        }
    }

    /// O corpo, gravado de forma idempotente.
    ///
    /// O corpo tem chave própria (`messageID` é UNIQUE, não a chave física):
    /// recarregar tem de **atualizar** a linha que já existe, senão a segunda
    /// carga esbarra no índice único e derruba a transação inteira do lote.
    ///
    /// Uma função só para os dois provedores: `save` num `MutablePersistableRecord`
    /// com o `rowid` nulo é sempre um `insert`, e a armadilha é a mesma no
    /// Gmail e no IMAP — escrita duas vezes, seria consertada uma vez.
    static func gravaCorpo(_ db: Database, id: String, paragrafos: [String]) throws {
        if var existente = try MessageBodyRecord.filter(Column("messageID") == id).fetchOne(db) {
            let novo = MessageBodyRecord(messageID: id, paragraphs: paragrafos)
            existente.paragraphs = novo.paragraphs
            existente.plain = novo.plain
            try existente.update(db)
        } else {
            var corpo = MessageBodyRecord(messageID: id, paragraphs: paragrafos)
            try corpo.insert(db)
        }
    }

    // MARK: IMAP

    /// A carga inicial de uma conta IMAP: as pastas com papel de triagem, os
    /// envelopes dos últimos 90 dias em lote, e o corpo das mais recentes de
    /// cada pasta.
    ///
    /// - Parameter reconnect: como abrir **outra** sessão, já autenticada,
    ///   contra o mesmo servidor. É o que permite sobreviver a um corpo que
    ///   derruba a conexão — ver `corposDe(_:)`. Nulo é aceito e degrada com
    ///   honestidade: o corpo continua sendo pulado, e se a conexão de fato
    ///   tiver morrido o comando seguinte diz isso em voz alta, em vez de a
    ///   carga fingir que terminou.
    public func loadImap(
        account: Account,
        session: ImapSession,
        now: Date,
        reconnect: (@Sendable () async throws -> ImapSession)? = nil,
        progress: @Sendable (LoadProgress) -> Void
    ) async throws {
        // `var` porque a sessão é substituível: um corpo acima do teto do
        // literal mata a conexão, e a carga continua na próxima.
        var sessao = session
        do {
            try await marca(account.id, estado: .carregando)

            // Só as pastas com papel de triagem. Enviados fica de fora (a
            // caixa não existe neste marco) e `other` também: carregar toda
            // pasta que a pessoa criou baixaria a caixa inteira sob o nome de
            // "90 dias".
            let comPapel = try await sessao.folders().filter { pasta in
                TriageProjection.bucket(role: pasta.role) != nil && pasta.role != .other
            }

            let desde = since(now: now)
            var totalEstimado = 0
            var feitas = 0
            var porPasta: [(ImapFolder, ImapMailboxStatus, [Int64])] = []
            /// O primeiro erro de pasta. Guardado porque uma pasta que falha
            /// não derruba as outras — mas **todas** falharem não é uma carga
            /// bem-sucedida de caixa nenhuma, e terminar `ativa` ali diria à
            /// pessoa que está tudo certo com a caixa vazia na tela.
            var primeiroErroDePasta: SyncError?
            var pastasQueFalharam = 0

            // 1. Selecionar cada pasta e descobrir o que existe na janela.
            //    Duas passadas — descobrir tudo, depois baixar — para o
            //    progresso ter denominador de verdade desde o primeiro relato,
            //    em vez de uma barra que anda para trás quando a pasta seguinte
            //    aparece.
            for pasta in comPapel {
                try Task.checkCancellation()
                do {
                    let status = try await sessao.select(pasta)
                    let uids = try await sessao.uids(since: desde, calendar: calendar)
                    totalEstimado += uids.count
                    porPasta.append((pasta, status, uids))
                } catch let erro as SyncError where !Self.derrubaAConta(erro) {
                    // Uma pasta que sumiu entre o `LIST` e o `SELECT`, ou que
                    // o servidor recusa por qualquer motivo local, não pode
                    // custar a caixa de entrada.
                    anota(erro, pasta: pasta.name, em: &primeiroErroDePasta, contando: &pastasQueFalharam)
                }
            }
            progress(LoadProgress(accountID: account.id, done: 0, total: totalEstimado))

            // 2. Baixar, pasta a pasta.
            for (pasta, status, uids) in porPasta {
                try Task.checkCancellation()
                let folderID = FolderRecord.id(accountID: account.id, serverName: pasta.name)
                let bucket = TriageProjection.bucket(role: pasta.role) ?? .archived

                do {
                    let anterior = try await database.pool.read { db in
                        try SyncStateRecord.fetchOne(
                            db, key: ["accountID": account.id, "folderID": folderID]
                        )
                    }
                    let trocou = ImapUidValidity.changed(
                        previous: anterior?.uidValidity, current: status.uidValidity
                    )

                    try await database.pool.write { db in
                        try FolderRecord(
                            id: folderID, accountID: account.id, serverName: pasta.name,
                            role: pasta.role, displayName: pasta.name
                        ).save(db)
                        if trocou {
                            // Os UIDs foram reciclados: a geração velha não
                            // casa com nada. Deixá-la ali faria a lista mostrar
                            // cada mensagem duas vezes, com assuntos diferentes
                            // sob o mesmo UID.
                            try db.execute(
                                sql: "DELETE FROM message WHERE folderID = ? AND uidValidity IS NOT ?",
                                arguments: [folderID, status.uidValidity]
                            )
                        }
                    }

                    // Reselecionar: a primeira passada deixou outra pasta
                    // selecionada, e `UID FETCH` age sobre a pasta corrente.
                    _ = try await sessao.select(pasta)
                    let envelopes = try await sessao.envelopes(uids: uids)

                    // Os corpos das mais recentes desta pasta.
                    let corpos = try await corposDe(
                        envelopes, pasta: pasta, sessao: &sessao, reconnect: reconnect
                    )

                    for lote in stride(from: 0, to: envelopes.count, by: batchSize) {
                        try Task.checkCancellation()
                        let fatia = Array(envelopes[lote..<min(lote + batchSize, envelopes.count)])
                        try await gravaImap(
                            fatia, account: account, folderID: folderID,
                            uidValidity: status.uidValidity, bucket: bucket, corpos: corpos
                        )
                        feitas += fatia.count
                        progress(LoadProgress(accountID: account.id, done: feitas, total: totalEstimado))
                    }

                    // O ponto de partida do Marco 3 para esta pasta.
                    try await database.pool.write { db in
                        try SyncStateRecord(
                            accountID: account.id, folderID: folderID,
                            uidValidity: status.uidValidity,
                            highestUID: uids.max(), syncedAt: now
                        ).save(db)
                    }
                } catch let erro as SyncError where !Self.derrubaAConta(erro) {
                    anota(erro, pasta: pasta.name, em: &primeiroErroDePasta, contando: &pastasQueFalharam)
                }
            }

            // Todas as pastas falharam: não há carga nenhuma para chamar de
            // concluída.
            if let primeiroErroDePasta, pastasQueFalharam == comPapel.count, !comPapel.isEmpty {
                throw primeiroErroDePasta
            }

            try await conclui(account.id, em: now)
            log.info("Carga IMAP de \(account.address, privacy: .private) terminou: \(feitas) mensagens.")
        } catch is CancellationError {
            await recupera(account.id, estado: .ativa)
            throw CancellationError()
        } catch let erro as SyncError {
            await recupera(account.id, estado: Self.estadoPara(erro))
            log.error("Carga IMAP de \(account.address, privacy: .private) falhou: \(erro.mensagem)")
            throw erro
        } catch {
            await recupera(account.id, estado: .ativa)
            log.error("Carga IMAP de \(account.address, privacy: .private) falhou: \(error)")
            throw error
        }
    }

    private func anota(
        _ erro: SyncError, pasta: String,
        em primeiro: inout SyncError?, contando quantas: inout Int
    ) {
        if primeiro == nil { primeiro = erro }
        quantas += 1
        log.error("A pasta \(pasta, privacy: .public) ficou de fora da carga: \(erro.mensagem)")
    }

    /// Os corpos das `fullBodyCount` mensagens mais recentes da pasta.
    ///
    /// **Um corpo que falha custa aquele corpo, e nada mais.** O caso que dá
    /// nome a este método é o teto de 8 MiB do literal (`CRLFLineDecoder`):
    /// ele estoura dentro do decodificador, e por construção é fatal para a
    /// **sessão** — depois de recusar o literal ninguém sabe mais onde a
    /// resposta acaba e o protocolo começa, então a conexão cai em vez de
    /// seguir dessincronizada. Fatal para a sessão não é fatal para a carga: o
    /// envelope daquela mensagem já está gravado, o corpo dela fica para o
    /// acesso por demanda, o tamanho e o UID vão para o log (é para isso que o
    /// decodificador os escreve na mensagem de erro), e a sessão é **refeita**
    /// para as mensagens seguintes.
    ///
    /// A pasta é reselecionada logo depois de reconectar: `UID FETCH` age
    /// sobre a pasta corrente, e a conexão nova nasce sem nenhuma selecionada
    /// — sem isto o resto dos corpos viria da caixa errada, calado.
    private func corposDe(
        _ envelopes: [ImapEnvelope],
        pasta: ImapFolder,
        sessao: inout ImapSession,
        reconnect: (@Sendable () async throws -> ImapSession)?
    ) async throws -> [Int64: [String]] {
        let maisRecentes = envelopes.sorted { $0.date > $1.date }.prefix(Self.fullBodyCount)
        var corpos: [Int64: [String]] = [:]
        for envelope in maisRecentes {
            try Task.checkCancellation()
            do {
                corpos[envelope.uid] = try await sessao.bodyText(uid: envelope.uid)
            } catch let erro as SyncError where !Self.derrubaACarga(erro) {
                log.error(
                    "O corpo do UID \(envelope.uid, privacy: .public) ficou de fora da carga: \(erro.mensagem)"
                )
                guard let reconnect else { continue }
                sessao = try await reconnect()
                _ = try await sessao.select(pasta)
            }
        }
        return corpos
    }

    private func gravaImap(
        _ envelopes: [ImapEnvelope], account: Account, folderID: String,
        uidValidity: Int64, bucket: TriageBucket, corpos: [Int64: [String]]
    ) async throws {
        try await database.pool.write { db in
            for envelope in envelopes {
                let id = MessageIdentity.imap(
                    accountID: account.id, folderID: folderID,
                    uidValidity: uidValidity, uid: envelope.uid
                )
                let corpo = corpos[envelope.uid] ?? []
                let nossa = Message(
                    id: id, accountID: account.id, from: envelope.from,
                    receivedAt: envelope.date,
                    subject: envelope.subject,
                    // Sem corpo baixado, a prévia é o assunto: melhor do que
                    // uma linha vazia onde o design desenha o trecho.
                    snippet: corpo.first ?? envelope.subject,
                    body: corpo, tags: [], bucket: bucket,
                    isRead: envelope.isRead, summary: nil, detectedEvent: nil,
                    to: envelope.to, cc: envelope.cc, isFlagged: envelope.isFlagged,
                    serverID: String(envelope.uid), uidValidity: uidValidity
                )
                try MessageRecord(nossa, folderID: folderID).save(db)
                if !corpo.isEmpty {
                    try Self.gravaCorpo(db, id: id, paragrafos: corpo)
                }
            }
        }
    }

    /// O erro de **uma pasta** derruba a conta inteira?
    ///
    /// Credencial recusada e TLS quebrado valem para todas as pastas: insistir
    /// nas outras gasta viagens para chegar ao mesmo lugar. O resto — pasta que
    /// sumiu, `NO` de uma caixa só — é daquela pasta, e derrubar a carga por
    /// causa dela entregaria uma caixa de entrada vazia por causa de uma pasta
    /// de arquivo.
    static func derrubaAConta(_ erro: SyncError) -> Bool {
        switch erro {
        case .autenticacao, .autorizacaoRevogada, .semClientID, .tls: true
        default: false
        }
    }

    // MARK: Estado da conta

    func marca(_ accountID: String, estado: Account.State) async throws {
        try await database.pool.write { db in
            guard let registro = try AccountRecord.fetchOne(db, key: accountID) else { return }
            try AccountRecord(registro.account.withState(estado), createdAt: registro.createdAt).update(db)
        }
    }

    func conclui(_ accountID: String, em data: Date) async throws {
        try await database.pool.write { db in
            guard let registro = try AccountRecord.fetchOne(db, key: accountID) else { return }
            let atualizada = registro.account.withState(.ativa).withLastSynced(data)
            try AccountRecord(atualizada, createdAt: registro.createdAt).update(db)
        }
    }

    /// Nem todo erro derruba a conta para `erroDeAutenticacao`.
    ///
    /// Rede caída e quota não são culpa da credencial, e marcar a conta como
    /// autenticação quebrada faria a janela oferecer "Reconectar" para quem só
    /// precisa esperar o wi-fi voltar — a ação errada, com convicção.
    static func estadoPara(_ erro: SyncError) -> Account.State {
        switch erro {
        case .autenticacao, .autorizacaoRevogada, .semClientID: .erroDeAutenticacao
        default: .ativa
        }
    }

    /// O erro é da **sessão** ou da **mensagem**?
    ///
    /// Um 401 vai reprovar as noventa mensagens seguintes do mesmo jeito:
    /// insistir é gastar noventa requisições para chegar ao mesmo lugar, mais
    /// tarde e mais confuso. Já um JSON que não casa com o contrato, ou um 404
    /// numa mensagem apagada entre a listagem e a leitura, é daquela mensagem
    /// e de mais nenhuma — derrubar a carga inteira por causa dela entregaria
    /// uma caixa vazia por causa de um item.
    static func derrubaACarga(_ erro: SyncError) -> Bool {
        switch erro {
        case .autenticacao, .autorizacaoRevogada, .semClientID, .quota,
             .rede, .tls, .keychain, .banco:
            true
        case .resposta:
            false
        // 4xx é sobre **este** recurso; 5xx é o servidor passando mal, e o
        // próximo pedido vai encontrar o mesmo servidor doente.
        case .servidor(let codigo, _):
            !(400..<500).contains(codigo)
        }
    }
}
