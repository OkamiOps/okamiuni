import Foundation
import GRDB
import Testing
import UNICore

@testable import UNISync

@Suite("A v20: rascunho antecipado e regra de remetente no disco")
struct ReadyDraftStoreTests {

    // MARK: - Migração

    @Test("a v20 sobe de uma v19 com dados, sem perder nada")
    func migratesFromV19WithData() throws {
        let diretorio = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-v19-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: diretorio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: diretorio) }

        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: diretorio.appendingPathComponent("mail.sqlite").path, configuration: config
        )
        try SyncDatabase.migrator.migrate(pool, upTo: "v19")
        try Fixture.escreveMensagem(in: pool, id: "m1")

        let antes = try pool.read { conexao in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(!antes.contains("ready_draft"))
        #expect(!antes.contains("sender_rule"))

        try SyncDatabase.migrator.migrate(pool)

        let depois = try pool.read { conexao in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(depois.contains("ready_draft"))
        #expect(depois.contains("sender_rule"))
        // A mensagem que já estava lá continua lá: migração aditiva não perde
        // linha nenhuma.
        let mensagens = try pool.read { try String.fetchAll($0, sql: "SELECT id FROM message") }
        #expect(mensagens == ["m1"])

        let colunas = try pool.read { Set(try $0.columns(in: "ready_draft").map(\.name)) }
        #expect(colunas == Set([
            "message_id", "text", "content_hash", "model_version", "used_agenda",
            "created_at", "discarded_hash",
        ]))
        let regras = try pool.read { Set(try $0.columns(in: "sender_rule").map(\.name)) }
        #expect(regras == Set(["address", "never_priority", "created_at"]))
    }

    // MARK: - O rascunho

    @Test("grava, lê e some quando a mensagem sai")
    func savesAndReads() throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        let store = ReadyDraftStore(database: banco)

        #expect(try store.drafts(for: ["m1"]).isEmpty)
        try store.save(
            ReadyDraft(
                messageID: "m1", text: "Consigo terça.", contentHash: "abc",
                modelVersion: "fm/v1", usedAgenda: true
            ),
            at: Date(timeIntervalSince1970: 1)
        )
        let lidos = try store.drafts(for: ["m1"])
        #expect(lidos["m1"]?.text == "Consigo terça.")
        #expect(lidos["m1"]?.usedAgenda == true)
        #expect(lidos["m1"]?.contentHash == "abc")

        try banco.pool.write { try $0.execute(sql: "DELETE FROM message WHERE id = 'm1'") }
        #expect(try store.drafts(for: ["m1"]).isEmpty)
    }

    @Test("descartar apaga o texto e trava o mesmo hash")
    func discardBlocksTheSameHash() throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        let store = ReadyDraftStore(database: banco)
        try store.save(
            ReadyDraft(
                messageID: "m1", text: "Consigo terça.", contentHash: "abc",
                modelVersion: "fm/v1"
            ),
            at: Date(timeIntervalSince1970: 1)
        )

        try store.discard(messageID: "m1")
        #expect(try store.drafts(for: ["m1"]).isEmpty)
        #expect(try store.isDiscarded(messageID: "m1", contentHash: "abc"))
        // Outra versão da mensagem é outra pergunta: o descarte não a alcança.
        #expect(try !store.isDiscarded(messageID: "m1", contentHash: "outro"))
    }

    // MARK: - A regra do remetente

    @Test("a regra grava, lê e revoga, sempre normalizada")
    func senderRulesRoundTrip() throws {
        let banco = try SyncDatabase.temporary()
        let store = DatabaseSenderRuleStore(database: banco)

        #expect(try store.senderRules().isEmpty)
        try store.learnSender(
            "  News@Zoho.com ", neverPriority: true, at: Date(timeIntervalSince1970: 10)
        )
        let regras = try store.senderRules()
        #expect(regras.map(\.address) == ["news@zoho.com"])
        #expect(regras[0].neverPriority)
        #expect(regras[0].createdAt == Date(timeIntervalSince1970: 10))

        // Aprender de novo não duplica a linha.
        try store.learnSender(
            "news@zoho.com", neverPriority: true, at: Date(timeIntervalSince1970: 20)
        )
        #expect(try store.senderRules().count == 1)

        try store.learnSender(
            "NEWS@ZOHO.COM", neverPriority: false, at: Date(timeIntervalSince1970: 30)
        )
        #expect(try store.senderRules().isEmpty)
    }
}

/// Uma mensagem mínima no banco, para as chaves estrangeiras das tabelas
/// novas terem em quem se apoiar. Pelos próprios `Record`, e não por SQL à
/// mão: o esquema anda a cada migração, e um `INSERT` escrito aqui envelhece
/// em silêncio.
enum Fixture {

    @discardableResult
    static func escreveMensagem(
        in pool: DatabasePool,
        id: String,
        accountID: String = "conta-a",
        assunto: String = "Assunto",
        trecho: String = "Trecho",
        corpo: [String] = ["Corpo da mensagem."],
        nome: String = "Jack Whitmore",
        endereco: String = "jack@whitmore.dev",
        recebidaEm: Date = Date(timeIntervalSince1970: 1_800_000_000),
        vistaEm: Date? = nil,
        marks: BulkMailMarks = []
    ) throws -> Message {
        let mensagem = Message(
            id: id, accountID: accountID,
            from: Contact(name: nome, address: endereco),
            receivedAt: recebidaEm,
            subject: assunto, snippet: trecho, body: corpo,
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil,
            bulkMarks: marks
        )
        try pool.write { db in
            if try AccountRecord.fetchOne(db, key: accountID) == nil {
                try AccountRecord(
                    Account(
                        id: accountID, address: "eu@exemplo.com", displayName: "Conta",
                        provider: .imap, host: "imap.exemplo.com",
                        tintLightHex: "#000000", tintDarkHex: "#FFFFFF",
                        state: .ativa
                    ),
                    createdAt: Date(timeIntervalSince1970: 0)
                ).insert(db)
                try FolderRecord(
                    id: "f1-\(accountID)", accountID: accountID, serverName: "INBOX",
                    role: .inbox, displayName: "Caixa"
                ).insert(db)
            }
            try MessageRecord(
                mensagem, folderID: "f1-\(accountID)", firstSeenAt: vistaEm ?? recebidaEm
            ).insert(db)
            var corpoRegistro = MessageBodyRecord(messageID: id, paragraphs: corpo)
            try corpoRegistro.insert(db)
        }
        return mensagem
    }

    /// A triagem persistida da mensagem — o que a fila do rascunho lê para
    /// saber se alguém espera resposta. Passa pelo mesmo par de colunas que a
    /// análise grava: o JSON e a projeção que ordena.
    static func escreveTriagem(
        in pool: DatabasePool, id: String, triage: MessageTriage,
        modelVersion: String = "analise/v1"
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message_intelligence
                      (messageID, contentHash, state, modelVersion, updatedAt,
                       triage, triage_needs_reply, triage_deadline_at)
                    VALUES (?, ?, 'completed', ?, 0, ?, ?, ?)
                    ON CONFLICT(messageID) DO UPDATE SET
                      triage = excluded.triage,
                      triage_needs_reply = excluded.triage_needs_reply,
                      triage_deadline_at = excluded.triage_deadline_at
                    """,
                arguments: [
                    id, "hash-\(id)", modelVersion,
                    MessageTriage.encodedJSON(triage),
                    triage.needsReply ? 1 : 0,
                    triage.deadline?.date.timeIntervalSince1970,
                ]
            )
        }
    }
}

@Suite("O que a tela vê dos rascunhos")
@MainActor
struct ReadyDraftsModelTests {

    @Test("o modelo entrega só os rascunhos pedidos")
    func returnsOnlyWhatWasAsked() throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveMensagem(in: banco.pool, id: "m2")
        let loja = ReadyDraftStore(database: banco)
        try loja.save(
            ReadyDraft(messageID: "m1", text: "Um.", contentHash: "a", modelVersion: "v")
        )
        try loja.save(
            ReadyDraft(messageID: "m2", text: "Dois.", contentHash: "b", modelVersion: "v")
        )

        let modelo = ReadyDraftsModel(database: banco)
        #expect(modelo.readyDrafts(for: ["m1"]).keys.sorted() == ["m1"])
        #expect(modelo.readyDrafts(for: ["m1", "m2"]).count == 2)
        #expect(modelo.readyDrafts(for: []).isEmpty)
    }

    @Test("descartar some da tela e trava o hash no disco")
    func discardRemovesAndPersists() throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        let loja = ReadyDraftStore(database: banco)
        try loja.save(
            ReadyDraft(messageID: "m1", text: "Um.", contentHash: "a", modelVersion: "v")
        )

        let modelo = ReadyDraftsModel(database: banco)
        #expect(modelo.readyDrafts(for: ["m1"]).count == 1)
        modelo.discardReadyDraft(messageID: "m1")
        #expect(modelo.readyDrafts(for: ["m1"]).isEmpty)
        #expect(try loja.isDiscarded(messageID: "m1", contentHash: "a"))
        #expect(try loja.drafts(for: ["m1"]).isEmpty)
    }
}
