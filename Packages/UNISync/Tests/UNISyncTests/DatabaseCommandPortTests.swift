import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// A porta de escrita real, e a v2 do banco por trás dela.
///
/// O defeito visto pelo dono: com conta real, arquivar/apagar não
/// funcionava porque a mutação só mexia na memória do `MailStore`, e o
/// retrato seguinte — lido do banco, que nunca soubera da mudança — a
/// desfazia. Estes testes provam o conserto: a projeção e o enfileiramento
/// acontecem na mesma transação, então o retrato seguinte já nasce certo.
@Suite("A v2 do banco e a porta de escrita")
struct DatabaseCommandPortTests {
    private func banco() throws -> SyncDatabase { try SyncDatabase.temporary() }

    private let conta = Account(
        id: "conta-a", address: "eu@meudominio.com.br", displayName: "Meu",
        provider: .imap, host: "meudominio",
        tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
        imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
        state: .ativa
    )

    private func mensagem(
        _ id: String, bucket: TriageBucket = .today
    ) -> Message {
        Message(
            id: id, accountID: "conta-a",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Assunto", snippet: "Trecho", body: ["Corpo"],
            tags: [], bucket: bucket, isRead: false,
            summary: nil, detectedEvent: nil,
            serverID: "9001", uidValidity: 42
        )
    }

    /// Grava a conta e uma mensagem, direto pelos registros — o mesmo atalho
    /// que `SyncDatabaseTests` usa.
    private func semear(_ db: SyncDatabase, mensagens: [Message]) throws {
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            for mensagem in mensagens {
                try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(conexao)
            }
        }
    }

    // MARK: - A migração

    @Test("A migração v2 cria o outbox, com o índice do executor")
    func migracaoV2() throws {
        let db = try banco()
        let tabelas = try db.pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tabelas.contains("outbox"))

        let indices = try db.pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indices.contains("outbox_on_account_state_next"))

        let versoes = try db.pool.read { try SyncDatabase.migrator.appliedIdentifiers($0) }
        #expect(versoes == ["v1", "v2", "v3", "v4", "v5", "v6", "v7"])
    }

    @Test("As colunas do outbox são as da spec, e o estado nasce pendente")
    func colunasDoOutbox() throws {
        let db = try banco()
        try semear(db, mensagens: [mensagem("m1")])
        let porta = DatabaseCommandPort(database: db)
        try porta.move(to: .archived, accountID: "conta-a", messageIDs: ["m1"])

        let linha = try db.pool.read { conexao in
            try #require(try OutboxRecord.fetchOne(conexao))
        }
        #expect(linha.accountID == "conta-a")
        #expect(linha.state == OutboxState.pendente.rawValue)
        #expect(linha.attempts == 0)
        #expect(linha.operation == .move(bucket: "arquivar", messageIDs: ["m1"]))
    }

    // MARK: - O defeito do dono

    @Test("Arquivar com conta real persiste no banco e cria a operação")
    func arquivarPersisteEEnfileira() throws {
        let db = try banco()
        try semear(db, mensagens: [mensagem("m1", bucket: .today)])
        let porta = DatabaseCommandPort(database: db)

        try porta.move(to: .archived, accountID: "conta-a", messageIDs: ["m1"])

        let bucket = try db.pool.read { conexao in
            try #require(try MessageRecord.fetchOne(conexao, key: "m1")).bucket
        }
        #expect(bucket == TriageBucket.archived.rawValue)

        let pendentes = try db.pool.read { try OutboxRecord.fetchCount($0) }
        #expect(pendentes == 1)
    }

    @Test("O retrato pós-mutação reflete a ação — o teste do defeito do dono")
    func retratoPosMutacaoReflete() async throws {
        let db = try banco()
        try semear(db, mensagens: [mensagem("m1", bucket: .today)])
        let porta = DatabaseCommandPort(database: db)
        let fonte = DatabaseMailSource(database: db)

        // Antes: a mensagem está em "hoje".
        let antes = try #require(try await fonte.snapshot().messages.first { $0.id == "m1" })
        #expect(antes.bucket == .today)

        // A mutação que o dono viu falhar: arquivar.
        try porta.move(to: .archived, accountID: "conta-a", messageIDs: ["m1"])

        // O retrato **seguinte**, lido de novo do banco — exatamente o que
        // `DatabaseMailSource.snapshots()` entregaria à próxima observação —
        // já mostra o arquivamento. Antes do conserto, este retrato lia
        // `message` sem a escrita (que só existia em memória no
        // `MailStore`) e devolvia "hoje" de novo, desfazendo a ação na tela.
        let depois = try #require(try await fonte.snapshot().messages.first { $0.id == "m1" })
        #expect(depois.bucket == .archived)
    }

    @Test("Apagar (mover para a Lixeira) também persiste e enfileira")
    func apagarPersisteEEnfileira() throws {
        let db = try banco()
        try semear(db, mensagens: [mensagem("m1", bucket: .archived)])
        let porta = DatabaseCommandPort(database: db)

        try porta.delete(accountID: "conta-a", messageIDs: ["m1"])

        let bucket = try db.pool.read { conexao in
            try #require(try MessageRecord.fetchOne(conexao, key: "m1")).bucket
        }
        #expect(bucket == TriageBucket.trash.rawValue)

        let operacao = try db.pool.read { conexao in
            try #require(try OutboxRecord.fetchOne(conexao)).operation
        }
        #expect(operacao == .delete(messageIDs: ["m1"]))
    }

    @Test("Apagar definitivamente remove a linha, sem deixá-la para trás")
    func apagarDefinitivamenteRemoveALinha() throws {
        let db = try banco()
        try semear(db, mensagens: [mensagem("m1", bucket: .trash)])
        let porta = DatabaseCommandPort(database: db)

        try porta.deletePermanently(accountID: "conta-a", messageIDs: ["m1"])

        let restante = try db.pool.read { try MessageRecord.fetchOne($0, key: "m1") }
        #expect(restante == nil)
    }

    @Test("Esvaziar a lixeira remove só as mensagens da Lixeira, da conta pedida")
    func esvaziarLixeira() throws {
        let db = try banco()
        try semear(db, mensagens: [
            mensagem("m1", bucket: .trash), mensagem("m2", bucket: .archived),
        ])
        let porta = DatabaseCommandPort(database: db)

        try porta.emptyTrash(accountID: "conta-a")

        let restantes = try db.pool.read { try MessageRecord.fetchAll($0).map(\.id) }
        #expect(restantes == ["m2"])
    }

    // MARK: - Idempotência

    /// **Esta afirmação foi invertida, e a inversão é o conserto.**
    ///
    /// A versão anterior provava que a mesma intenção chamada duas vezes
    /// **não** duplicava a fila, por uma chave de idempotência derivada do
    /// conteúdo da operação. A regra estava resolvendo um problema que ninguém
    /// tinha — a reexecução segura já é garantida por linha (a reivindicação
    /// atômica do executor) e por operação (o espelho põe ou tira, nunca
    /// inverte) — e criava dois que existiam:
    ///
    /// - ler → não-ler → ler perdia o terceiro passo, e o servidor terminava
    ///   não-lido enquanto a tela mostrava lido;
    /// - `emptyTrash`, que não tem ids, colidia consigo mesma **para sempre**.
    ///
    /// Descartar no enfileirar é a única perda que nenhum retry conserta: a
    /// operação nunca chegou a existir. Então toda ação entra, e quem tira
    /// redundância é a coalescência do executor — depois, e sabendo o que está
    /// junto de quê.
    @Test("Toda ação entra na fila: enfileirar nunca descarta em silêncio")
    func toda_acao_entra() throws {
        let db = try banco()
        try semear(db, mensagens: [mensagem("m1", bucket: .today)])
        let porta = DatabaseCommandPort(database: db)

        try porta.setFlagged(true, accountID: "conta-a", messageIDs: ["m1"])
        try porta.setFlagged(true, accountID: "conta-a", messageIDs: ["m1"])
        #expect(try db.pool.read { try OutboxRecord.fetchCount($0) } == 2)

        try porta.setFlagged(false, accountID: "conta-a", messageIDs: ["m1"])
        #expect(try db.pool.read { try OutboxRecord.fetchCount($0) } == 3)

        // E `emptyTrash`, que não tem alvo nenhum, entra tantas vezes quantas
        // for pedida — antes, a segunda de toda a vida da instalação sumia.
        try porta.emptyTrash(accountID: "conta-a")
        try porta.emptyTrash(accountID: "conta-a")
        #expect(try db.pool.read { try OutboxRecord.fetchCount($0) } == 5)

        // As chaves continuam únicas: elas identificam a **linha**, que é o que
        // um `UNIQUE` deve garantir — e não a intenção, que se repete de
        // propósito.
        let chaves = try db.pool.read {
            try String.fetchAll($0, sql: "SELECT idempotencyKey FROM outbox")
        }
        #expect(Set(chaves).count == 5)
    }

    // MARK: - MailStore, com a porta

    @Test("MailStore.move chama a porta e persiste")
    @MainActor
    func mailStoreChamaAPorta() async throws {
        let db = try banco()
        try semear(db, mensagens: [mensagem("m1", bucket: .today)])
        let porta = DatabaseCommandPort(database: db)
        let fonte = DatabaseMailSource(database: db)
        let snapshot = try await fonte.snapshot()
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: snapshot.accounts, messages: snapshot.messages, agenda: []
            ),
            commandPort: porta
        )
        await store.load()
        let mensagem = try #require(store.messages.first { $0.id == "m1" })
        store.move(mensagem, to: .archived)

        let bucket = try await db.pool.read { conexao in
            try #require(try MessageRecord.fetchOne(conexao, key: "m1")).bucket
        }
        #expect(bucket == TriageBucket.archived.rawValue)
    }
}
