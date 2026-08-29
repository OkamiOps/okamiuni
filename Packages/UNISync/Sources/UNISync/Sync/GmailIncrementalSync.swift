import Foundation
import GRDB
import UNICore
import os

/// A carga **contínua** de uma conta Gmail: `users.history.list` a partir do
/// `historyId` que a carga inicial carimbou.
///
/// É a resposta direta à queixa do dono — "as contas não estão sincronizando".
/// A carga inicial trazia noventa dias e parava ali: nada do que chegasse
/// depois entrava, e nenhuma estrela posta no navegador aparecia no app.
///
/// ## O que ele grava, e o que ele não busca
///
/// Ele grava a **mensagem**: remetente, assunto, data, caixa da triagem e as
/// duas bandeiras. Ele **não** busca o corpo, e isso é escolha: o acesso por
/// demanda (`DatabaseBodyFetcher`) já cobre a mensagem que a pessoa abre, e
/// baixar o corpo de tudo o que chega enquanto o app está aberto pagaria a
/// mensagem inteira de cada newsletter para nada. O formato pedido é
/// `.metadata`, e é a mesma projeção da carga inicial —
/// `InitialLoader.gravaMensagensDoGmail`, uma função, dois chamadores.
///
/// ## A idempotência
///
/// O id de cada linha é determinístico (`MessageIdentity.gmail`) e a escrita é
/// upsert. Isso é o que faz o caminho do 404 ser seguro: recarregar a janela
/// inteira por cima do que já está no banco **atualiza** as linhas existentes
/// em vez de duplicar a caixa.
public struct GmailIncrementalSync: Sendable {
    /// O teto de páginas de histórico num ciclo. Não é um número de conforto:
    /// um servidor que devolvesse sempre o mesmo `nextPageToken` faria o ciclo
    /// girar para sempre sem gravar nada, exatamente como a listagem da carga
    /// inicial já se protege de girar.
    public static let maxPages = 100

    /// O que um ciclo fez. É o que o teste afirma e o que o coordenador
    /// registra.
    public struct Outcome: Sendable, Equatable {
        /// Quantas linhas de `message` foram escritas (novas ou atualizadas).
        public var gravadas: Int
        /// Quantas linhas saíram do banco por apagamento no servidor.
        public var apagadas: Int
        /// O ciclo teve de recarregar a janela porque o `historyId` expirou.
        public var recarregou: Bool

        public init(gravadas: Int = 0, apagadas: Int = 0, recarregou: Bool = false) {
            self.gravadas = gravadas
            self.apagadas = apagadas
            self.recarregou = recarregou
        }
    }

    private let database: SyncDatabase
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "GmailIncremental")

    public init(database: SyncDatabase) {
        self.database = database
    }

    /// Um ciclo: lê o marcador, pede o histórico, aplica, recarimba.
    ///
    /// - Parameter renewAccessToken: a segunda chance do 401, a mesma da carga
    ///   inicial (`GmailAuthReplay`).
    public func run(
        account: Account,
        client: GmailClient,
        renewAccessToken: (@Sendable () async throws -> Void)? = nil,
        now: Date
    ) async throws -> Outcome {
        let gmail = GmailAuthReplay(client: client, renew: renewAccessToken)

        // Sem marcador não há de onde partir: a conta nunca completou a carga
        // inicial (ou o banco foi apagado por baixo). Recarregar é a única
        // resposta honesta — inventar um `historyId` faria o incremental partir
        // de um ponto que nunca existiu e nunca reconsiderar o que ficou atrás.
        guard let marcador = try await historyIDGravado(account.id), !marcador.isEmpty else {
            try await recarrega(account: account, client: client, renew: renewAccessToken, now: now)
            return Outcome(recarregou: true)
        }

        let mudancas: Mudancas
        do {
            mudancas = try await coleta(desde: marcador, com: gmail)
        } catch SyncError.servidor(let codigo, _) where codigo == 404 {
            // O Gmail guarda o histórico por tempo limitado. App fechado por
            // uma semana volta com um marcador que o servidor já esqueceu, e a
            // resposta é 404 — não é defeito, é o contrato. Recarregar a janela
            // recente é o que reconstrói o que se perdeu, e recarimbar é o que
            // faz o próximo ciclo voltar a ser barato.
            log.notice("""
                O histórico do Gmail de \(account.address, privacy: .private) expirou; \
                recarregando a janela recente.
                """)
            try await recarrega(account: account, client: client, renew: renewAccessToken, now: now)
            return Outcome(recarregou: true)
        }

        var resultado = Outcome()
        // Nada mudou: nem os rótulos são lidos. É o ciclo ocioso, e ele custa
        // uma ida e volta — que é o mínimo que "continuar sincronizando" pode
        // custar.
        if !mudancas.paraBuscar.isEmpty {
            let idDoDepois = TriageProjection.laterLabelID(in: try await gmail.labels())
            resultado.gravadas = try await aplica(
                mudancas.paraBuscar, account: account, laterLabelID: idDoDepois, gmail: gmail
            )
        }
        // Os apagamentos por último: uma mensagem que chegou e foi apagada
        // dentro do mesmo intervalo termina apagada, que é o estado do servidor.
        resultado.apagadas = try await apaga(mudancas.apagadas, account: account)

        // O carimbo **só depois** de aplicar. Carimbar antes faria uma falha no
        // meio da aplicação enterrar as mensagens daquele intervalo para
        // sempre: o próximo ciclo partiria do marcador novo e nunca voltaria.
        if let novo = mudancas.historyID {
            try await carimba(novo, account: account.id, em: now)
        }
        return resultado
    }

    // MARK: A coleta

    private struct Mudancas {
        /// Adicionadas e mudadas, na ordem, sem repetição e **sem** as que
        /// foram apagadas: buscar uma mensagem que já não existe é uma viagem
        /// para receber 404.
        var paraBuscar: [String] = []
        var apagadas: [String] = []
        var historyID: String?
    }

    private func coleta(desde marcador: String, com gmail: GmailAuthReplay) async throws -> Mudancas {
        var adicionadasEmudadas: [String] = []
        var vistas: Set<String> = []
        var apagadas: Set<String> = []
        var ultimoHistoryID: String?
        var token: String?
        var tokensVistos: Set<String> = []
        var paginas = 0

        repeat {
            try Task.checkCancellation()
            let pagina = try await gmail.history(startHistoryID: marcador, pageToken: token)
            for id in pagina.added + pagina.changed where vistas.insert(id).inserted {
                adicionadasEmudadas.append(id)
            }
            apagadas.formUnion(pagina.deleted)
            // O `historyId` da última página é o marcador do fim do intervalo.
            if let id = pagina.historyID { ultimoHistoryID = id }
            paginas += 1

            if let proximo = pagina.nextPageToken {
                guard tokensVistos.insert(proximo).inserted else {
                    throw SyncError.resposta(
                        "O histórico do Gmail devolveu a mesma página de novo (token repetido) — a paginação não avança."
                    )
                }
                guard paginas < Self.maxPages else {
                    throw SyncError.resposta(
                        "O histórico do Gmail passou de \(Self.maxPages) páginas sem terminar."
                    )
                }
            }
            token = pagina.nextPageToken
        } while token != nil

        var mudancas = Mudancas()
        mudancas.paraBuscar = adicionadasEmudadas.filter { !apagadas.contains($0) }
        mudancas.apagadas = Array(apagadas)
        mudancas.historyID = ultimoHistoryID
        return mudancas
    }

    // MARK: A aplicação

    private func aplica(
        _ ids: [String], account: Account, laterLabelID: String?, gmail: GmailAuthReplay
    ) async throws -> Int {
        let folderID = FolderRecord.id(accountID: account.id, serverName: "GMAIL")
        var gravadas = 0
        for lote in stride(from: 0, to: ids.count, by: InitialLoader.defaultBatchSize) {
            try Task.checkCancellation()
            let fatia = ids[lote..<min(lote + InitialLoader.defaultBatchSize, ids.count)]
            var mensagens: [(GmailMessage, Bool)] = []
            for id in fatia {
                do {
                    // `false` no segundo campo: **sem corpo**, sempre. O corpo
                    // desce por demanda, e é `.metadata` que está sendo pedido.
                    mensagens.append((try await gmail.message(id: id, format: .metadata), false))
                } catch let erro as SyncError where !InitialLoader.derrubaACarga(erro) {
                    // Mensagem que sumiu entre o histórico e a leitura, ou que
                    // veio num formato que não conhecemos: ela fica de fora, e
                    // as outras do lote não pagam por ela — a mesma regra da
                    // carga inicial.
                    log.error("A mensagem \(id, privacy: .public) ficou de fora do ciclo: \(erro.mensagem)")
                }
            }
            guard !mensagens.isEmpty else { continue }
            let lote = mensagens
            gravadas += try await database.pool.write { db in
                // A pseudo-pasta existe desde a carga inicial, mas o ciclo não
                // pode contar com isso: a chave estrangeira de `message` aponta
                // para ela, e um banco recarregado sem ela derrubaria a
                // transação inteira. `save` é upsert — reescrevê-la não custa
                // nada e fecha o caso.
                try FolderRecord(
                    id: folderID, accountID: account.id, serverName: "GMAIL",
                    role: .other, displayName: "Gmail"
                ).save(db)
                return try InitialLoader.gravaMensagensDoGmail(
                    db, lote, account: account, folderID: folderID, laterLabelID: laterLabelID
                )
            }
        }
        return gravadas
    }

    private func apaga(_ ids: [String], account: Account) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let nossos = ids.map { MessageIdentity.gmail(accountID: account.id, serverID: $0) }
        return try await database.pool.write { db -> Int in
            let marcadores = nossos.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM message WHERE id IN (\(marcadores))",
                arguments: StatementArguments(nossos)
            )
            return db.changesCount
        }
    }

    // MARK: O marcador

    private func historyIDGravado(_ accountID: String) async throws -> String? {
        try await database.pool.read { db in
            try SyncStateRecord.fetchOne(
                db, key: ["accountID": accountID, "folderID": ""]
            )?.historyID
        }
    }

    private func carimba(_ historyID: String, account accountID: String, em data: Date) async throws {
        try await database.pool.write { db in
            try SyncStateRecord(
                accountID: accountID, folderID: "", historyID: historyID, syncedAt: data
            ).save(db)
        }
    }

    /// A recarga da janela — o caminho do 404 e o da conta sem marcador.
    ///
    /// **É a carga inicial, e não uma segunda implementação dela.** Ela é
    /// idempotente por construção (id determinístico + upsert), relê o
    /// `historyId` do perfil e o recarimba no fim: exatamente o que "recarrega
    /// e re-estampa, sem duplicar" pede. Reescrevê-la aqui seria a terceira
    /// cópia da mesma projeção.
    private func recarrega(
        account: Account, client: GmailClient,
        renew: (@Sendable () async throws -> Void)?, now: Date
    ) async throws {
        try await InitialLoader(database: database).loadGmail(
            account: account, client: client, renewAccessToken: renew,
            now: now, progress: { _ in }
        )
    }
}
