import Foundation
import GRDB
import UNICore

/// `MailSource` lendo do banco. **A fonte de verdade da UI quando há conta.**
///
/// Nada aqui espera rede: o pior caso é uma leitura de SQLite local. É o que
/// faz o app abrir offline mostrando os 90 dias, e é por isso que a rede
/// escreve no banco em vez de falar com a tela.
public struct DatabaseMailSource: MailSource, Sendable {
    private let database: SyncDatabase
    /// O que entregar enquanto o banco não tiver **conta nenhuma**.
    ///
    /// Nulo nos testes que querem o banco cru. O app passa
    /// `InMemoryMailSource.fixtures`, e isso é o critério de aceite do Marco 2
    /// virado código: sem conta conectada, o app é o do Marco 1.
    ///
    /// A substituição mora **aqui**, e não na composição, por uma razão de
    /// tempo: escolher a fonte uma vez, na abertura, deixaria a troca
    /// dependendo de reiniciar o app — a primeira conta entraria e a tela
    /// continuaria nas fixtures até o próximo lançamento. A única coisa que
    /// acompanha o banco continuamente é a observação, então a decisão tem de
    /// ser tomada por retrato, dentro dela. Com isto, a primeira conta a entrar
    /// e a última a sair trocam a lista na hora, pelo mesmo `observe()`.
    private let fallback: InMemoryMailSource?

    public init(database: SyncDatabase, emptyFallback: InMemoryMailSource? = nil) {
        self.database = database
        self.fallback = emptyFallback
    }

    public func accounts() async throws -> [Account] {
        try await database.pool.read { db in
            try AccountRecord.order(Column("createdAt")).fetchAll(db).map(\.account)
        }
    }

    public func messages() async throws -> [Message] {
        try await database.pool.read { try Self.messages(in: $0) }
    }

    public func agenda() async throws -> [AgendaItem] {
        try await database.pool.read { db in
            try AgendaItemRecord.fetchAll(db).map(\.item)
        }
    }

    public func folders() async throws -> [MailFolder] {
        try await database.pool.read { try Self.folders(in: $0) }
    }

    /// Sem tabela: `PendingItem` é a seção "Vindo do email" do Marco 1, que
    /// nasce da detecção no dispositivo e não do servidor. Lista vazia é a
    /// resposta honesta — inventar uma tabela vazia seria pior.
    public func pendingItems() async throws -> [PendingItem] { [] }

    /// O retrato inteiro numa leitura só, e não quatro.
    ///
    /// Quatro `read` seriam quatro instantâneos diferentes do banco: a carga
    /// inicial grava mensagem e corpo em lotes, e um retrato montado de quatro
    /// leituras pode ter a mensagem de um lote sem o corpo dele. Uma
    /// transação de leitura vê um estado consistente e pronto.
    public func snapshot() async throws -> MailSnapshot {
        try await resolvido(database.pool.read { db in try Self.snapshot(in: db) })
    }

    /// O retrato que a UI recebe: o do banco, ou o das fixtures enquanto não
    /// houver conta nenhuma.
    ///
    /// A pergunta é `accounts.isEmpty` e não "quantas mensagens": uma conta
    /// recém-adicionada, ainda carregando, tem zero mensagem — e mostrar as
    /// fixtures por cima dela seria dizer que a conta não entrou.
    private func resolvido(_ retrato: MailSnapshot) async throws -> MailSnapshot {
        guard retrato.accounts.isEmpty, let fallback else { return retrato }
        return try await fallback.snapshot()
    }

    /// A observação: um retrato agora, e outro a cada escrita que mexa no que
    /// a UI mostra — mas **coalescida**.
    ///
    /// `ValueObservation` observa as tabelas que a consulta toca, então uma
    /// escrita em `sync_state` não acorda a lista à toa, e um lote da carga
    /// inicial acorda.
    ///
    /// **Por que a observação é partida em duas.** O retrato inteiro custa caro
    /// — 0,585 s medidos sobre 50 mil mensagens, quase tudo em decodificar cinco
    /// JSONs por linha. Enquanto o retrato caro era o *corpo* da
    /// `ValueObservation`, o GRDB o refazia uma vez por transação, e a carga
    /// inicial fecha uma transação por lote: 20 lotes davam 21 retratos, cada um
    /// sobre uma tabela maior que a do anterior. Extrapolando para a carga real
    /// de 50 mil com lotes de 50 — mil lotes —, a soma das linhas materializadas
    /// passa de 25 milhões, uns 290 s de CPU só reconstruindo retratos.
    ///
    /// Agora quem observa é um gatilho **barato** (`marcaDeMudanca`), e o
    /// retrato caro é feito por quem consome. Com `bufferingNewest(1)`, os
    /// gatilhos que chegam enquanto um retrato está sendo montado colapsam num
    /// só: os lotes do meio da carga deixam de virar retratos. A leitura sai
    /// numa transação sua, depois do gatilho — então ela é sempre **igual ou
    /// mais nova** que a mudança que a acordou, e o último gatilho sempre tem um
    /// retrato depois dele. Nada se perde, só a repetição.
    public func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        let pool = database.pool
        return AsyncThrowingStream { continuation in
            let tarefa = Task {
                do {
                    let gatilho = ValueObservation.tracking { db in
                        try Self.marcaDeMudanca(in: db)
                    }
                    for try await _ in gatilho.values(
                        in: pool, bufferingPolicy: .bufferingNewest(1)
                    ) {
                        let retrato = try await pool.read { db in try Self.snapshot(in: db) }
                        continuation.yield(try await resolvido(retrato))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Quem para de consumir (a janela fechou, o `for` deu `break`)
            // desliga a observação junto — senão ela continua acordando a cada
            // escrita, para ninguém, enquanto o app viver.
            continuation.onTermination = { _ in tarefa.cancel() }
        }
    }

    public func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? {
        let fallback = self.fallback
        return try await database.pool.read { db in
            // Sem conta e com fixtures no lugar, quem responde é a fonte em
            // memória — e ela devolve `nil`, "não sei procurar no corpo". Um
            // conjunto vazio diria "procurei e não achei" sobre um índice que
            // não indexa nenhuma das mensagens que estão na tela.
            if fallback != nil, try AccountRecord.fetchCount(db) == 0 { return nil }
            return try MessageSearch.matchingBodyIDs(db, term: term, accountID: accountID)
        }
    }

    // MARK: A leitura, num lugar só

    /// O gatilho barato: só `count(*)` das quatro tabelas que o retrato lê.
    ///
    /// O **valor** não interessa e nunca é olhado — uma mensagem marcada como
    /// lida não muda contagem nenhuma. O que interessa é a *região* observada:
    /// ler estas quatro tabelas faz a `ValueObservation` acordar exatamente nas
    /// escritas em que o retrato mudaria, e em nenhuma outra. É a mesma região
    /// de antes, pelo preço de quatro contagens em vez de cinquenta mil
    /// decodificações de JSON.
    ///
    /// Sem `removeDuplicates()`, de propósito: o `ValueObservation.tracking`
    /// avisa a cada mudança da região, e é disso que precisamos — filtrar por
    /// igualdade de contagem perderia a mensagem que virou lida.
    private static func marcaDeMudanca(in db: Database) throws -> Int {
        try AccountRecord.fetchCount(db)
            &+ MessageRecord.fetchCount(db)
            &+ MessageBodyRecord.fetchCount(db)
            &+ AgendaItemRecord.fetchCount(db)
            // `folder` entrou na M3-17, e não é decorativa: o retrato passou a
            // levar as pastas, e sem esta contagem a `ValueObservation` não
            // observa a tabela — a pasta criada no webmail só apareceria na
            // barra quando alguma **mensagem** mudasse alguma coisa.
            &+ FolderRecord.fetchCount(db)
    }

    private static func snapshot(in db: Database) throws -> MailSnapshot {
        MailSnapshot(
            accounts: try AccountRecord.order(Column("createdAt")).fetchAll(db).map(\.account),
            messages: try messages(in: db),
            agenda: try AgendaItemRecord.fetchAll(db).map(\.item),
            pendingItems: [],
            folders: try folders(in: db)
        )
    }

    /// As pastas do provedor, sem as linhas que não são pastas de verdade —
    /// `FolderRecord.folder` devolve `nil` para a pseudo-pasta do Gmail, e é
    /// por isso que o `compactMap` está aqui e não um `map`.
    private static func folders(in db: Database) throws -> [MailFolder] {
        try FolderRecord.fetchAll(db).compactMap(\.folder)
    }

    private static func messages(in db: Database) throws -> [Message] {
        // `ORDER BY receivedAt DESC` desce pelo índice `message_on_received`,
        // cujo plano a Task 5 provou por `EXPLAIN QUERY PLAN` — nenhuma
        // consulta nova entra aqui.
        let registros = try MessageRecord
            .order(Column("receivedAt").desc)
            .fetchAll(db)
        // Os corpos numa consulta só: um `fetchOne` por mensagem seria uma
        // consulta por linha da lista, e a lista tem milhares.
        let corpos = try MessageBodyRecord.fetchAll(db)
        // `uniquingKeysWith` e não `uniqueKeysWithValues`: `messageID` é UNIQUE
        // no esquema, mas um `init(uniqueKeysWithValues:)` responde a uma
        // violação disso com `fatalError` — o app inteiro caindo por causa de
        // uma linha duplicada num banco de disco. Ficar com uma delas é pior
        // do que nada e melhor do que morrer.
        let porID = Dictionary(
            corpos.map { ($0.messageID, $0) }, uniquingKeysWith: { primeiro, _ in primeiro }
        )
        return registros.map { registro in
            let corpo = porID[registro.id]
            return registro.message(
                body: corpo?.body ?? [],
                // A mensagem **sem linha nenhuma** em `message_body` continua
                // com `nil` aqui — e é assim que o leitor sabe que ainda há o
                // que buscar. Trocar por `""` a daria por decodificada.
                bodyHTML: corpo?.html, calendarICS: corpo?.calendarICS
            )
        }
    }
}
