import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("O banco da v1")
struct SyncDatabaseTests {
    private func banco() throws -> SyncDatabase { try SyncDatabase.inMemory() }

    private let conta = Account(
        id: "conta-a", address: "eu@meudominio.com.br", displayName: "Meu",
        provider: .imap, host: "meudominio",
        tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
        imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
        state: .carregando
    )

    private func mensagem(
        _ id: String, assunto: String = "Assunto", corpo: [String] = ["Corpo"],
        bucket: TriageBucket = .today
    ) -> Message {
        Message(
            id: id, accountID: "conta-a",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: assunto, snippet: "Trecho", body: corpo,
            tags: [], bucket: bucket, isRead: false,
            summary: nil, detectedEvent: nil,
            to: [Contact(name: "Eu", address: "eu@meudominio.com.br")],
            serverID: "9001", uidValidity: 42
        )
    }

    @Test("A migração v1 cria as seis tabelas e o índice de busca")
    func migracaoV1() throws {
        let db = try banco()
        let tabelas = try db.pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for esperada in ["account", "folder", "message", "message_body", "agenda_item", "sync_state", "message_fts"] {
            #expect(tabelas.contains(esperada), "faltou a tabela \(esperada)")
        }
        let versoes = try db.pool.read { try SyncDatabase.migrator.appliedIdentifiers($0) }
        #expect(versoes == ["v1"])
    }

    @Test("Migrar duas vezes não faz nada na segunda")
    func migracaoIdempotente() throws {
        let db = try banco()
        try SyncDatabase.migrator.migrate(db.pool)
        let versoes = try db.pool.read { try SyncDatabase.migrator.appliedIdentifiers($0) }
        #expect(versoes == ["v1"])
    }

    @Test("A conta vai e volta inteira — inclusive o endpoint e o estado")
    func contaVaiEVolta() throws {
        let db = try banco()
        try db.pool.write { try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert($0) }
        let devolvida = try db.pool.read { conexao -> Account in
            try #require(try AccountRecord.fetchOne(conexao, key: "conta-a")).account
        }
        #expect(devolvida == conta)
    }

    @Test("Nenhuma coluna do banco guarda segredo")
    func nenhumaColunaDeSegredo() throws {
        let db = try banco()
        let colunas = try db.pool.read { conexao -> [String] in
            try conexao.columns(in: "account").map(\.name)
        }
        let proibidas = ["password", "senha", "token", "accessToken", "refreshToken", "secret"]
        for coluna in colunas {
            let dobrada = coluna.lowercased()
            #expect(!proibidas.contains { dobrada.contains($0.lowercased()) }, "coluna suspeita: \(coluna)")
        }
    }

    @Test("A mensagem vai e volta inteira, corpo incluído")
    func mensagemVaiEVolta() throws {
        let db = try banco()
        let original = mensagem("m1", corpo: ["Primeiro parágrafo.", "Segundo."])
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(original, folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(messageID: "m1", paragraphs: original.body).insert(conexao)
        }
        let devolvida = try db.pool.read { conexao -> Message in
            let registro = try #require(try MessageRecord.fetchOne(conexao, key: "m1"))
            let corpo = try MessageBodyRecord.fetchOne(conexao, key: "m1")
            return registro.message(body: corpo?.body ?? [])
        }
        #expect(devolvida == original)
    }

    @Test("Apagar a conta leva junto pastas, mensagens, corpos, agenda e estado de sync")
    func cascataAoRemoverConta() throws {
        let db = try banco()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(mensagem("m1"), folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(messageID: "m1", paragraphs: ["Corpo"]).insert(conexao)
            try AgendaItemRecord(
                AgendaItem(id: "a1", title: "Reunião", startMinute: 570, endMinute: 600, accountID: "conta-a")
            ).insert(conexao)
            try SyncStateRecord(
                accountID: "conta-a", folderID: "conta-a/INBOX",
                historyID: "77", uidValidity: 42, highestUID: 9001,
                syncedAt: Date(timeIntervalSince1970: 2)
            ).insert(conexao)
            _ = try AccountRecord.deleteOne(conexao, key: "conta-a")
        }
        try db.pool.read { conexao in
            // A extração em `let` (em vez de `try` direto dentro de `#expect`)
            // não é estilo: sem ela, o compilador não enxerga o `throws` desta
            // clausura quando ela só contém chamadas de `#expect`, e a
            // compilação cai com "errors thrown from here are not handled".
            let pastas = try FolderRecord.fetchCount(conexao)
            let mensagens = try MessageRecord.fetchCount(conexao)
            let corpos = try MessageBodyRecord.fetchCount(conexao)
            let itens = try AgendaItemRecord.fetchCount(conexao)
            let estados = try SyncStateRecord.fetchCount(conexao)
            // O gatilho do FTS tem de ter desfeito o índice junto com o corpo.
            let noIndice = try Int.fetchOne(conexao, sql: "SELECT count(*) FROM message_fts")
            #expect(pastas == 0)
            #expect(mensagens == 0)
            #expect(corpos == 0)
            #expect(itens == 0)
            #expect(estados == 0)
            #expect(noIndice == 0)
        }
    }

    @Test("A busca no corpo dobra acento nos dois sentidos")
    func buscaDobraAcento() throws {
        let db = try banco()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(mensagem("m1"), folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(
                messageID: "m1",
                paragraphs: ["A revisão do contrato ficou pronta.", "Abraço."]
            ).insert(conexao)
        }
        try db.pool.read { conexao in
            let semAcento = try MessageSearch.matchingBodyIDs(conexao, term: "Revisao", accountID: nil)
            let comAcento = try MessageSearch.matchingBodyIDs(conexao, term: "revisão", accountID: nil)
            let prefixo = try MessageSearch.matchingBodyIDs(conexao, term: "contra", accountID: nil)
            let ausente = try MessageSearch.matchingBodyIDs(conexao, term: "orçamento", accountID: nil)
            // Sem acento acha com acento — é o caso que o README promete.
            #expect(semAcento == ["m1"])
            // E com acento acha o mesmo, para a busca não punir quem digita certo.
            #expect(comAcento == ["m1"])
            // Prefixo funciona: quem digitou meia palavra ainda acha.
            #expect(prefixo == ["m1"])
            // E o que não está no corpo não aparece.
            #expect(ausente.isEmpty)
        }
    }

    @Test("A busca respeita o filtro de conta")
    func buscaFiltraPorConta() throws {
        let db = try banco()
        let outra = Account(
            id: "conta-b", address: "outro@x.com", displayName: "Outro",
            provider: .imap, host: "x", tintLightHex: "#397852", tintDarkHex: "#88D1A2"
        )
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try AccountRecord(outra, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            for (id, accountID) in [("m1", "conta-a"), ("m2", "conta-b")] {
                try FolderRecord(
                    id: "\(accountID)/INBOX", accountID: accountID,
                    serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
                ).insert(conexao)
                var registro = MessageRecord(mensagem(id), folderID: "\(accountID)/INBOX")
                registro.accountID = accountID
                try registro.insert(conexao)
                try MessageBodyRecord(messageID: id, paragraphs: ["A revisão saiu."]).insert(conexao)
            }
        }
        try db.pool.read { conexao in
            let todas = try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: nil)
            let soContaB = try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: "conta-b")
            #expect(todas == ["m1", "m2"])
            #expect(soContaB == ["m2"])
        }
    }

    @Test("Termo que só tem pontuação não vira consulta — MATCH com sintaxe inválida derruba o SQLite")
    func termoVazioNaoConsulta() throws {
        #expect(MessageSearch.ftsQuery("   ") == nil)
        #expect(MessageSearch.ftsQuery("\"") == nil)
        #expect(MessageSearch.ftsQuery("revisão do contrato") == "\"revisão\" \"do\" \"contrato\"*")
        let db = try banco()
        try db.pool.read { conexao in
            let vazio = try MessageSearch.matchingBodyIDs(conexao, term: "  ", accountID: nil)
            #expect(vazio.isEmpty)
        }
    }

    @Test("Trocar o corpo reindexa: o texto velho deixa de achar, o novo passa a achar")
    func atualizarCorpoReindexa() throws {
        let db = try banco()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(mensagem("m1"), folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(messageID: "m1", paragraphs: ["Prévia curta."]).insert(conexao)
            // A carga inicial baixa a prévia primeiro e o corpo cheio depois:
            // é exatamente este UPDATE que roda no meio da Task 12.
            try MessageBodyRecord(messageID: "m1", paragraphs: ["Corpo inteiro com orçamento."]).update(conexao)
        }
        try db.pool.read { conexao in
            let previa = try MessageSearch.matchingBodyIDs(conexao, term: "previa", accountID: nil)
            let orcamento = try MessageSearch.matchingBodyIDs(conexao, term: "orcamento", accountID: nil)
            #expect(previa.isEmpty)
            #expect(orcamento == ["m1"])
        }
    }

    @Test("A observação acorda quando alguém escreve")
    func observacaoAcorda() async throws {
        let db = try banco()
        try await db.pool.write { conexao in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
        }
        let observacao = ValueObservation.tracking { conexao in
            try AccountRecord.fetchCount(conexao)
        }
        var vistos: [Int] = []
        for try await contagem in observacao.values(in: db.pool) {
            vistos.append(contagem)
            if vistos.count == 1 {
                let outra = Account(
                    id: "conta-b", address: "outro@x.com", displayName: "Outro",
                    provider: .imap, host: "x", tintLightHex: "#397852", tintDarkHex: "#88D1A2"
                )
                try await db.pool.write { try AccountRecord(outra, createdAt: Date(timeIntervalSince1970: 1)).insert($0) }
            }
            if vistos.count == 2 { break }
        }
        #expect(vistos == [1, 2])
    }
}
