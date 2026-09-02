import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// A triagem gravada e lida de volta: a coluna JSON e as duas
/// desnormalizadas, que existem para ordenar sem abrir o JSON de cada linha.
@Suite("A triagem guardada")
struct MessageTriagePersistenceTests {
    private let conta = Account(
        id: "conta-a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )

    private let prazo = Date(timeIntervalSince1970: 1_800_100_000)

    private func banco() throws -> SyncDatabase {
        let database = try SyncDatabase.temporary()
        try database.pool.write { db in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(db)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Entrada"
            ).insert(db)
            let mensagem = Message(
                id: "m1", accountID: "conta-a",
                from: Contact(name: "Marina", address: "marina@cliente.com"),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                subject: "Contrato", snippet: "Vamos revisar",
                body: ["Precisamos fechar até sexta, 15h."],
                tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil
            )
            try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(db)
            var corpo = MessageBodyRecord(
                messageID: "m1", paragraphs: ["Precisamos fechar até sexta, 15h."]
            )
            try corpo.insert(db)
        }
        return database
    }

    private var triagem: MessageTriage {
        MessageTriage(
            needsReply: true,
            intent: .lead,
            urgency: .high,
            deadline: DetectedDeadline(date: prazo, evidence: "até sexta, 15h")
        )
    }

    @Test("a v17 grava JSON, needsReply e o instante do prazo, e devolve o mesmo objeto")
    func idaEVolta() throws {
        let database = try banco()
        let store = MessageIntelligenceStore(database: database)
        let work = try #require(try store.pendingWork().first)
        #expect(try store.markProcessing(work, modelVersion: "v-teste"))
        #expect(try store.markCompleted(
            work,
            modelVersion: "v-teste",
            summary: "Marina quer fechar o contrato.",
            detectedEventJSON: nil,
            category: .primary,
            triage: triagem
        ))

        let linha = try #require(try database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT triage, triage_needs_reply, triage_deadline_at
                    FROM message_intelligence WHERE messageID = ?
                    """,
                arguments: ["m1"]
            )
        })
        #expect(MessageTriage.decoded(linha["triage"]) == triagem)
        #expect(linha["triage_needs_reply"] as Int? == 1)
        #expect(linha["triage_deadline_at"] as Double? == prazo.timeIntervalSince1970)
    }

    @Test("a mensagem hidratada do banco chega com a triagem")
    func hidratacao() throws {
        let database = try banco()
        let store = MessageIntelligenceStore(database: database)
        let work = try #require(try store.pendingWork().first)
        _ = try store.markProcessing(work, modelVersion: "v-teste")
        _ = try store.markCompleted(
            work, modelVersion: "v-teste", summary: "Resumo.",
            detectedEventJSON: nil, category: nil, triage: triagem
        )

        let mensagens = try database.pool.read { db in
            try DatabaseMailSource.mensagensParaTeste(in: db)
        }
        #expect(mensagens.first?.triage == triagem)
    }

    @Test("corpo trocado apaga a triagem junto com o resumo")
    func corpoNovoLimpaTriagem() throws {
        let database = try banco()
        let store = MessageIntelligenceStore(database: database)
        let work = try #require(try store.pendingWork().first)
        _ = try store.markProcessing(work, modelVersion: "v-teste")
        _ = try store.markCompleted(
            work, modelVersion: "v-teste", summary: "Resumo.",
            detectedEventJSON: nil, category: nil, triage: triagem
        )

        try database.pool.write { db in
            var atual = try #require(
                try MessageBodyRecord.filter(Column("messageID") == "m1").fetchOne(db)
            )
            let novo = MessageBodyRecord(messageID: "m1", paragraphs: ["Outro texto."])
            atual.paragraphs = novo.paragraphs
            atual.plain = novo.plain
            try atual.update(db)
        }

        let novo = try #require(try store.pendingWork().first)
        #expect(try store.markProcessing(novo, modelVersion: "v-teste"))
        let triagemGuardada = try database.pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT triage FROM message_intelligence WHERE messageID = ?",
                arguments: ["m1"]
            )
        }
        #expect(triagemGuardada == nil)
    }
}
