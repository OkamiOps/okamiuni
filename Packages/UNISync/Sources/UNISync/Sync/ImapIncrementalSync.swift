import Foundation
import GRDB
import UNICore
import os

/// O delta de uma pasta IMAP: o que chegou, o que mudou de bandeira e o que
/// sumiu, desde o último ciclo.
///
/// ## As três perguntas, e por que são três
///
/// 1. **`UID SEARCH UID n:*`** — o que chegou depois do maior UID conhecido. É
///    a pergunta barata: o servidor devolve só os números, e o `FETCH` de
///    envelope vem em seguida só para eles.
/// 2. **`UID FETCH <recentes> (UID FLAGS)`** — as bandeiras das mensagens que
///    já estão no banco. Sem ela, marcar como lida no telefone nunca chegaria
///    aqui: o UID não muda, então a pergunta 1 nunca a devolveria de novo.
/// 3. **os UIDs que não voltaram na 2** — foram expurgados. O IMAP não tem
///    "liste o que sumiu"; o que existe é perguntar por uma faixa e reparar em
///    quem faltou. É por isso que a pergunta 2 pede a faixa inteira e não só as
///    que mudaram.
///
/// ## Por que a janela de bandeiras é limitada
///
/// Reconferir a caixa inteira a cada ciclo faria uma conta de dez mil mensagens
/// pagar dez mil UIDs de `FETCH` por minuto. A janela são as mais recentes —
/// que é onde a pessoa mexe, no app e no telefone. Uma estrela posta numa
/// mensagem de dois meses atrás noutro cliente só chega na próxima carga
/// completa, e essa é a troca escolhida, dita em voz alta.
public struct ImapIncrementalSync: Sendable {
    /// Quantos UIDs recentes reconferir por pasta a cada ciclo.
    ///
    /// Duzentos é o mesmo `fetchBatchSize` do envelope, e não por acaso: é uma
    /// ida e volta, o tamanho que já se provou caber numa resposta.
    public static let janelaDeBandeiras = 200

    public struct Outcome: Sendable, Equatable {
        /// Mensagens novas gravadas.
        public var novas: Int
        /// Linhas cujas bandeiras mudaram no servidor e foram acertadas aqui.
        public var bandeiras: Int
        /// Linhas apagadas por terem sumido do servidor.
        public var apagadas: Int
        /// A pasta reciclou os UIDs e foi recarregada do zero.
        public var recarregou: Bool

        public init(novas: Int = 0, bandeiras: Int = 0, apagadas: Int = 0, recarregou: Bool = false) {
            self.novas = novas
            self.bandeiras = bandeiras
            self.apagadas = apagadas
            self.recarregou = recarregou
        }

        public static func + (esquerda: Outcome, direita: Outcome) -> Outcome {
            Outcome(
                novas: esquerda.novas + direita.novas,
                bandeiras: esquerda.bandeiras + direita.bandeiras,
                apagadas: esquerda.apagadas + direita.apagadas,
                recarregou: esquerda.recarregou || direita.recarregou
            )
        }
    }

    private let database: SyncDatabase
    private let calendar: Calendar
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "ImapIncremental")

    public init(database: SyncDatabase, calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.database = database
        self.calendar = calendar
    }

    /// O delta de **todas** as pastas que a triagem conhece.
    ///
    /// Uma pasta que falha não derruba as outras — a mesma regra da carga
    /// inicial, e pela mesma razão: uma pasta de arquivo que o servidor recusa
    /// não pode custar a caixa de entrada.
    public func run(account: Account, session: ImapSession, now: Date) async throws -> Outcome {
        let doServidor = try await session.folders()
        let comPapel = doServidor.map { pasta in
            (pasta, TriageProjection.bucket(role: pasta.role))
        }
        // A descoberta acontece **a cada ciclo**, e não só na carga inicial: a
        // pasta criada no webmail hoje de manhã aparece na barra sem reiniciar o
        // app, e a que foi apagada some. O `LIST` já estava sendo feito aqui —
        // o que faltava era gravar o resultado dele.
        try await database.pool.write { db in
            try FolderSync.reconcile(
                db, accountID: account.id,
                discovered: InitialLoader.registros(doServidor, accountID: account.id)
            )
        }
        var total = Outcome()
        for (pasta, bucket) in comPapel {
            try Task.checkCancellation()
            do {
                total = total + (try await run(
                    account: account, session: session, folder: pasta, bucket: bucket, now: now
                ))
            } catch let erro as SyncError where !InitialLoader.derrubaAConta(erro) {
                log.error("A pasta \(pasta.name, privacy: .private) ficou de fora do ciclo: \(erro.mensagem)")
            }
        }
        return total
    }

    /// O delta de **uma** pasta. A sessão sai com ela selecionada.
    public func run(
        account: Account, session: ImapSession,
        folder: ImapFolder, bucket: TriageBucket, now: Date
    ) async throws -> Outcome {
        let folderID = FolderRecord.id(accountID: account.id, serverName: folder.name)
        let status = try await session.select(folder)
        let anterior = try await database.pool.read { db in
            try SyncStateRecord.fetchOne(db, key: ["accountID": account.id, "folderID": folderID])
        }

        // A pasta que nunca vimos, e a que reciclou os UIDs, pedem a mesma
        // coisa: reler a janela inteira. `changed` responde `false` para a
        // primeira vez de propósito (ver `ImapUidValidity`), então as duas
        // condições são conferidas separadamente.
        let nunca = anterior?.uidValidity == nil
        let reciclou = ImapUidValidity.changed(
            previous: anterior?.uidValidity, current: status.uidValidity
        )
        var resultado = Outcome(recarregou: reciclou)

        let novos: [Int64]
        if nunca || reciclou {
            novos = try await session.uids(since: desde(now), calendar: calendar)
        } else {
            // `+ 1`: o maior UID conhecido já está no banco, e repeti-lo em todo
            // ciclo faria a mensagem mais recente ser regravada para sempre.
            novos = try await session.uids(from: (anterior?.highestUID ?? 0) + 1)
        }

        // A pasta e as mensagens novas na mesma transação do apagamento da
        // geração velha: as duas gerações trocam de lugar de uma vez, e não há
        // instante em que a pasta esteja vazia — a mesma regra da carga
        // inicial.
        try await database.pool.write { db in
            try FolderRecord(
                id: folderID, accountID: account.id, serverName: folder.name,
                role: folder.role, displayName: folder.name
            ).save(db)
        }

        if !novos.isEmpty || reciclou {
            let envelopes = try await session.envelopes(uids: novos)
            resultado.novas = try await grava(
                envelopes, account: account, folderID: folderID,
                uidValidity: status.uidValidity, bucket: bucket,
                etiqueta: TriageProjection.tag(folderRole: folder.role, folderName: folder.name),
                apagandoAGeracaoVelha: reciclou
            )
        }

        // As bandeiras e o expurgo, sobre a janela recente do que está no banco
        // **agora** — inclusive as que acabaram de entrar acima.
        let conferidas = try await uidsRecentes(folderID: folderID, uidValidity: status.uidValidity)
        if !conferidas.isEmpty {
            let noServidor = try await session.flags(uids: conferidas.map(\.uid))
            resultado.bandeiras = try await acertaBandeiras(conferidas, servidor: noServidor)
            let sumiram = conferidas.filter { noServidor[$0.uid] == nil }.map(\.id)
            resultado.apagadas = try await apaga(sumiram)
        }

        let maior = max(novos.max() ?? 0, anterior?.highestUID ?? 0)
        try await database.pool.write { db in
            try SyncStateRecord(
                accountID: account.id, folderID: folderID,
                uidValidity: status.uidValidity,
                // Reciclagem zera o piso junto com a geração: guardar o maior
                // UID da geração velha faria o `n:*` do ciclo seguinte pular
                // tudo o que a geração nova trouxe.
                highestUID: reciclou ? (novos.max() ?? 0) : maior,
                syncedAt: now
            ).save(db)
        }
        return resultado
    }

    // MARK: As bandeiras e o expurgo

    /// Uma linha do banco, na parte que o delta compara.
    struct Conferida: Sendable, Hashable, FetchableRecord, Decodable {
        var id: String
        var uid: Int64
        var isRead: Bool
        var isFlagged: Bool
    }

    /// Os UIDs mais recentes desta pasta que estão no banco, **nesta** geração.
    ///
    /// Por `receivedAt`, e não por UID: é a ordem que a pessoa vê na lista, e é
    /// onde ela mexe. Ordenar por UID daria quase sempre o mesmo conjunto, mas
    /// erraria justamente na caixa que recebeu mensagens antigas por
    /// importação.
    private func uidsRecentes(folderID: String, uidValidity: Int64) async throws -> [Conferida] {
        let limite = Self.janelaDeBandeiras
        return try await database.pool.read { db in
            try Conferida.fetchAll(
                db,
                sql: """
                    SELECT id, CAST(serverID AS INTEGER) AS uid, isRead, isFlagged
                    FROM message
                    WHERE folderID = ? AND uidValidity IS ? AND serverID IS NOT NULL
                    ORDER BY receivedAt DESC
                    LIMIT ?
                    """,
                arguments: [folderID, uidValidity, limite]
            )
        }
    }

    private func acertaBandeiras(
        _ conferidas: [Conferida], servidor: [Int64: [String]]
    ) async throws -> Int {
        var mudadas: [(String, Bool, Bool)] = []
        for linha in conferidas {
            guard let flags = servidor[linha.uid] else { continue }
            let lida = TriageProjection.isRead(imapFlags: flags)
            let sinalizada = TriageProjection.isFlagged(imapFlags: flags)
            guard lida != linha.isRead || sinalizada != linha.isFlagged else { continue }
            mudadas.append((linha.id, lida, sinalizada))
        }
        guard !mudadas.isEmpty else { return 0 }
        let acertos = mudadas
        // Um `UPDATE` por coluna, e não a linha inteira reescrita: reescrever a
        // linha exigiria reler o envelope do servidor, e o que mudou foram duas
        // colunas cujo valor já está na mão.
        try await database.pool.write { db in
            for (id, lida, sinalizada) in acertos {
                try db.execute(
                    sql: "UPDATE message SET isRead = ?, isFlagged = ? WHERE id = ?",
                    arguments: [lida, sinalizada, id]
                )
            }
        }
        return mudadas.count
    }

    private func apaga(_ ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try await database.pool.write { db -> Int in
            let marcadores = ids.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM message WHERE id IN (\(marcadores))",
                arguments: StatementArguments(ids)
            )
            return db.changesCount
        }
    }

    // MARK: A escrita das novas

    private func grava(
        _ envelopes: [ImapEnvelope], account: Account, folderID: String,
        uidValidity: Int64, bucket: TriageBucket, etiqueta: Tag?,
        apagandoAGeracaoVelha apagar: Bool
    ) async throws -> Int {
        try await database.pool.write { db in
            if apagar {
                try InitialLoader.apagaGeracaoVelha(db, folderID: folderID, uidValidity: uidValidity)
            }
            for envelope in envelopes {
                let id = MessageIdentity.imap(
                    accountID: account.id, folderID: folderID,
                    uidValidity: uidValidity, uid: envelope.uid
                )
                // A mesma resolução da carga inicial, e pela mesma razão: a
                // resposta que chega agora tem de cair na conversa que já está
                // no banco, não abrir uma linha nova ao lado dela.
                let chave = try ThreadKeyResolver.resolve(
                    db, accountID: account.id, messageID: envelope.messageID,
                    inReplyTo: envelope.inReplyTo, references: [],
                    subject: envelope.subject, fallback: id
                )
                let nossa = Message(
                    id: id, accountID: account.id, from: envelope.from,
                    receivedAt: envelope.date, subject: envelope.subject,
                    // Sem corpo baixado, a prévia é o assunto — a mesma regra da
                    // carga inicial, e o mesmo `UPDATE … WHERE snippet = subject`
                    // do `DatabaseBodyFetcher` a substitui quando o corpo chega.
                    snippet: envelope.subject,
                    body: [], tags: etiqueta.map { [$0] } ?? [], bucket: bucket,
                    isRead: envelope.isRead, summary: nil, detectedEvent: nil,
                    to: envelope.to, cc: envelope.cc, isFlagged: envelope.isFlagged,
                    serverID: String(envelope.uid), uidValidity: uidValidity,
                    rfcMessageID: envelope.messageID,
                    references: [envelope.inReplyTo].compactMap { $0 },
                    threadKey: chave
                )
                try MessageRecord(nossa, folderID: folderID).savePreservingIntelligenceProjection(db)
            }
            return envelopes.count
        }
    }

    private func desde(_ now: Date) -> Date {
        calendar.date(byAdding: .day, value: -InitialLoader.windowDays, to: now) ?? now
    }
}
