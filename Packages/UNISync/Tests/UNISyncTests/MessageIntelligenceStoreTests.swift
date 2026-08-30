import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("A fila local de inteligência")
struct MessageIntelligenceStoreTests {
    private let conta = Account(
        id: "conta-a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )

    private func banco() throws -> SyncDatabase {
        let database = try SyncDatabase.temporary()
        try database.pool.write { db in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(db)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Entrada"
            ).insert(db)
            try self.gravaMensagem(
                id: "m1", corpo: ["Vamos revisar o contrato na sexta às 14h."], in: db
            )
            // Há uma linha de corpo, mas ela não é informação utilizável. Ela
            // não pode acordar o motor só para ele responder "não há texto".
            try self.gravaMensagem(id: "m-vazia", corpo: [" \n\t "], in: db)
        }
        return database
    }

    private func gravaMensagem(
        id: String,
        corpo: [String],
        receivedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        in db: Database
    ) throws {
        let mensagem = Message(
            id: id, accountID: "conta-a",
            from: Contact(name: "Marina", address: "marina@cliente.com"),
            receivedAt: receivedAt,
            subject: "Contrato", snippet: "Vamos revisar", body: corpo,
            tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil
        )
        try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(db)
        var body = MessageBodyRecord(messageID: id, paragraphs: corpo)
        try body.insert(db)
    }

    private func trocaCorpo(_ paragraphs: [String], database: SyncDatabase) throws {
        try database.pool.write { db in
            var atual = try #require(
                try MessageBodyRecord.filter(Column("messageID") == "m1").fetchOne(db)
            )
            let novo = MessageBodyRecord(messageID: "m1", paragraphs: paragraphs)
            atual.paragraphs = novo.paragraphs
            atual.plain = novo.plain
            try atual.update(db)
        }
    }

    @Test("Mensagens antigas e novas entram pela mesma fila, com corpo e âncoras")
    func pendentesTemCorpoEAncoras() throws {
        let database = try banco()
        let pendentes = try MessageIntelligenceStore(database: database).pendingWork()

        #expect(pendentes.count == 1)
        let work = try #require(pendentes.first)
        #expect(work.messageID == "m1")
        #expect(work.accountID == "conta-a")
        #expect(work.fromName == "Marina")
        #expect(work.fromAddress == "marina@cliente.com")
        #expect(work.receivedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(work.plainBody == "Vamos revisar o contrato na sexta às 14h.")
        #expect(work.contentHash == MessageIntelligenceWork.contentHash(for: work.plainBody))
        #expect(work.contentHash.count == 64)
    }

    @Test("A mensagem aberta fura a ordem cronológica da fila")
    func prioridadeDaMensagemAberta() throws {
        let database = try banco()
        try database.pool.write { db in
            try self.gravaMensagem(
                id: "m-antiga",
                corpo: ["Este é o conteúdo que a pessoa abriu."],
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                in: db
            )
        }

        let pendentes = try MessageIntelligenceStore(database: database).pendingWork(
            limit: 2,
            modelVersion: "analysis-v2-tldr",
            priorityMessageID: "m-antiga"
        )

        #expect(pendentes.map(\.messageID) == ["m-antiga", "m1"])
    }

    @Test("Uma mensagem gravada em v10 entra como pendente implícita após a v11")
    func mensagemLegadaEntraSemBackfill() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-intelligence-v10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let path = directory.appendingPathComponent("mail.sqlite").path
        let legacyPool = try DatabasePool(path: path, configuration: configuration)
        try SyncDatabase.migrator.migrate(legacyPool, upTo: "v10")
        try legacyPool.write { db in
            // Escreve no esquema **da v10**. `AccountRecord` acompanha a
            // versão atual e já contém `signatureJSON` (v12), portanto usá-lo
            // aqui deixaria de testar um banco legado e tentaria inserir uma
            // coluna que ainda não existe.
            try db.execute(
                sql: """
                    INSERT INTO account (
                      id, address, displayName, provider, host,
                      tintLightHex, tintDarkHex, signature,
                      imapHost, imapPort, imapSecurity, state,
                      lastSyncedAt, createdAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    self.conta.id, self.conta.address, self.conta.displayName,
                    self.conta.provider.rawValue, self.conta.host,
                    self.conta.tintLightHex, self.conta.tintDarkHex,
                    self.conta.signature, nil, nil, nil,
                    self.conta.state.rawValue, nil, 1.0,
                ]
            )
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Entrada"
            ).insert(db)
            // Mesma razão da conta acima: `MessageRecord` atual já conhece a
            // coluna `category` da v13. A linha abaixo é deliberadamente a
            // forma que uma instalação v10 tinha no disco.
            try db.execute(
                sql: """
                    INSERT INTO message (
                      id, accountID, folderID, serverID, uidValidity,
                      fromName, fromAddress, toJSON, ccJSON,
                      subject, snippet, receivedAt, dayOffset,
                      isRead, isFlagged, bucket, tagsJSON,
                      summary, detectedEventJSON, replyHintsJSON,
                      rfcMessageID, referencesJSON, threadKey, folderMembershipJSON
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "m1", "conta-a", "conta-a/INBOX", nil, nil,
                    "Marina", "marina@cliente.com", "[]", "[]",
                    "Contrato", "Corpo que já existia.", 1_800_000_000.0, 0,
                    false, false, TriageBucket.today.rawValue, "[]",
                    nil, nil, "[]", nil, "[]", "m1", "[]",
                ]
            )
            var body = MessageBodyRecord(
                messageID: "m1", paragraphs: ["Corpo que já existia."]
            )
            try body.insert(db)
        }

        let upgraded = try SyncDatabase(path: path)
        let store = MessageIntelligenceStore(database: upgraded)
        let work = try #require(try store.pendingWork().first)
        #expect(work.messageID == "m1")
        #expect(work.plainBody == "Corpo que já existia.")
        let linhasAntesDeAssumir = try upgraded.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message_intelligence")
        }
        #expect(linhasAntesDeAssumir == 0)
        #expect(try store.markProcessing(work, modelVersion: "m5.1", at: Date(timeIntervalSince1970: 2)))
    }

    @Test("Falha e incompatibilidade não entram em loop; corpo novo reabre uma vez")
    func transicoesEReprocessamentoPorHash() throws {
        let database = try banco()
        let store = MessageIntelligenceStore(database: database)
        let t1 = Date(timeIntervalSince1970: 10)
        let primeiro = try #require(try store.pendingWork().first)

        #expect(try store.markProcessing(primeiro, modelVersion: "m5.1", at: t1))
        // `processing` é retomável na próxima abertura: a queda entre assumir
        // e concluir não deixa uma linha presa para sempre.
        let retomado = try #require(try store.pendingWork().first)
        #expect(retomado == primeiro)
        #expect(try store.markProcessing(retomado, modelVersion: "m5.1", at: t1.addingTimeInterval(1)))
        #expect(try store.markFailed(
            retomado, error: "modelo indisponível", at: t1.addingTimeInterval(2)
        ))
        #expect(try store.pendingWork().isEmpty)

        try trocaCorpo(["A revisão mudou para segunda às 09h."], database: database)
        let segundo = try #require(try store.pendingWork().first)
        #expect(segundo.contentHash != primeiro.contentHash)
        #expect(try store.markProcessing(segundo, modelVersion: "m5.2", at: t1.addingTimeInterval(3)))
        #expect(try store.markUnsupported(
            segundo, error: "idioma sem suporte", at: t1.addingTimeInterval(4)
        ))
        #expect(try store.pendingWork().isEmpty)

        try trocaCorpo(["A revisão mudou para terça às 10h."], database: database)
        let terceiro = try #require(try store.pendingWork().first)
        let eventJSON = "{\"label\":\"Revisão · ter 10:00\",\"start\":1800000000,\"duration\":3600}"
        #expect(try store.markProcessing(terceiro, modelVersion: "m5.3", at: t1.addingTimeInterval(5)))
        #expect(try store.markCompleted(
            terceiro, modelVersion: "m5.3", summary: "Revisão confirmada.",
            detectedEventJSON: eventJSON, category: .transactions,
            at: t1.addingTimeInterval(6)
        ))
        #expect(try store.pendingWork().isEmpty)

        try database.pool.read { db in
            let state = try #require(try MessageIntelligenceRecord.fetchOne(db, key: "m1"))
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT summary, detectedEventJSON, category FROM message WHERE id = 'm1'"
            ))
            let summary: String? = row["summary"]
            let detectedEventJSON: String? = row["detectedEventJSON"]
            #expect(state.state == MessageIntelligenceState.completed.rawValue)
            #expect(state.contentHash == terceiro.contentHash)
            #expect(state.modelVersion == "m5.3")
            #expect(state.lastError == nil)
            #expect(state.updatedAt == t1.addingTimeInterval(6))
            #expect(summary == "Revisão confirmada.")
            #expect(detectedEventJSON == eventJSON)
            let category: String? = row["category"]
            #expect(category == MailCategory.transactions.rawValue)
        }
    }

    @Test("Conclusão estale não grava resumo nem evento pela metade")
    func conclusaoEstaleEhAtomica() throws {
        let database = try banco()
        let store = MessageIntelligenceStore(database: database)
        let antigo = try #require(try store.pendingWork().first)
        #expect(try store.markProcessing(antigo, modelVersion: "m5.1", at: Date(timeIntervalSince1970: 10)))

        try trocaCorpo(["O compromisso mudou depois do pedido ao modelo."], database: database)
        let concluiu = try store.markCompleted(
            antigo, modelVersion: "m5.1", summary: "Resumo velho",
            detectedEventJSON: "{\"old\":true}", at: Date(timeIntervalSince1970: 11)
        )
        #expect(!concluiu)

        try database.pool.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT summary, detectedEventJSON, category FROM message WHERE id = 'm1'"
            ))
            let summary: String? = row["summary"]
            let detectedEventJSON: String? = row["detectedEventJSON"]
            let category: String? = row["category"]
            #expect(summary == nil)
            #expect(detectedEventJSON == nil)
            #expect(category == nil)
        }
        let novo = try #require(try store.pendingWork().first)
        #expect(novo.contentHash != antigo.contentHash)
    }

    @Test("Uma política nova reprocessa o mesmo corpo uma vez e limpa o resumo antigo")
    func modelVersionReopensCompletedWork() throws {
        let database = try banco()
        let store = MessageIntelligenceStore(database: database)
        let workV1 = try #require(try store.pendingWork(modelVersion: "analysis-v1").first)

        #expect(try store.markProcessing(workV1, modelVersion: "analysis-v1"))
        #expect(try store.markCompleted(
            workV1,
            modelVersion: "analysis-v1",
            summary: "Mensagem de e-mail recebida hoje.",
            detectedEventJSON: nil,
            category: .updates
        ))
        #expect(try store.pendingWork(modelVersion: "analysis-v1").isEmpty)

        let workV2 = try #require(try store.pendingWork(modelVersion: "analysis-v2-tldr").first)
        #expect(workV2.contentHash == workV1.contentHash)
        #expect(try store.markProcessing(workV2, modelVersion: "analysis-v2-tldr"))
        try database.pool.read { db in
            let row = try #require(try Row.fetchOne(
                db,
                sql: "SELECT summary, category FROM message WHERE id = 'm1'"
            ))
            let summary: String? = row["summary"]
            let category: String? = row["category"]
            #expect(summary == nil)
            #expect(category == nil)
        }

        #expect(try store.markCompleted(
            workV2,
            modelVersion: "analysis-v2-tldr",
            summary: "Marina pede a revisão do contrato na sexta às 14h.",
            detectedEventJSON: nil
        ))
        #expect(try store.pendingWork(modelVersion: "analysis-v2-tldr").isEmpty)
    }

    @Test("O upsert de sync não apaga a projeção de inteligência")
    func syncPreservaResumoEEvento() throws {
        let database = try banco()
        let store = MessageIntelligenceStore(database: database)
        let work = try #require(try store.pendingWork().first)
        #expect(try store.markProcessing(work, modelVersion: "m5.1", at: Date(timeIntervalSince1970: 10)))
        #expect(try store.markCompleted(
            work, modelVersion: "m5.1", summary: "Resumo local",
            detectedEventJSON: "{\"event\":true}", category: .promotions,
            at: Date(timeIntervalSince1970: 11)
        ))

        try database.pool.write { db in
            var doServidor = try #require(try MessageRecord.fetchOne(db, key: "m1"))
            doServidor.subject = "Contrato atualizado no servidor"
            doServidor.summary = nil
            doServidor.detectedEventJSON = nil
            doServidor.category = nil
            try doServidor.savePreservingIntelligenceProjection(db)
        }
        try database.pool.read { db in
            let record = try #require(try MessageRecord.fetchOne(db, key: "m1"))
            #expect(record.subject == "Contrato atualizado no servidor")
            #expect(record.summary == "Resumo local")
            #expect(record.detectedEventJSON == "{\"event\":true}")
            #expect(record.category == MailCategory.promotions.rawValue)
        }
    }
}
