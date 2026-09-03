import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("O banco da v1")
struct SyncDatabaseTests {
    private func banco() throws -> SyncDatabase { try SyncDatabase.temporary() }

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
            serverID: "9001", uidValidity: 42,
            // A pasta em que ela mora — a mesma que o `folderID` da gravação
            // diz. A coluna `folderMembershipJSON` da v8 grava `[]` justamente
            // quando as duas coincidem, e a leitura a resolve de volta para
            // aqui: é a ida e volta que este teste afirma.
            folderIDs: ["conta-a/INBOX"]
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
        #expect(versoes == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20"])
        let colunas = try db.pool.read { conexao in
            Set(try conexao.columns(in: "message").map(\.name))
        }
        #expect(colunas.contains("category"))
    }

    @Test("Migrar duas vezes não faz nada na segunda")
    func migracaoIdempotente() throws {
        let db = try banco()
        try SyncDatabase.migrator.migrate(db.pool)
        let versoes = try db.pool.read { try SyncDatabase.migrator.appliedIdentifiers($0) }
        #expect(versoes == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20"])
    }

    @Test("Um banco já em v10 recebe a fila de inteligência na v11")
    func migracaoIncrementalV11() throws {
        let diretorio = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-v10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: diretorio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: diretorio) }

        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: diretorio.appendingPathComponent("mail.sqlite").path, configuration: config
        )
        try SyncDatabase.migrator.migrate(pool, upTo: "v10")

        let antes = try pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(antes.contains("message_attachment"))
        #expect(!antes.contains("message_intelligence"))

        try SyncDatabase.migrator.migrate(pool)
        let depois = try pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(depois.contains("message_attachment"))
        #expect(depois.contains("message_intelligence"))
        let colunas = try pool.read { conexao in
            Set(try conexao.columns(in: "message_intelligence").map(\.name))
        }
        // A v17 acrescenta a triagem à mesma tabela: o JSON e as duas
        // projeções que ordenam sem abrir o JSON de cada linha.
        #expect(colunas == Set([
            "messageID", "contentHash", "state", "modelVersion", "lastError", "updatedAt",
            "triage", "triage_needs_reply", "triage_deadline_at",
        ]))
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

    @Test("As colunas de data são REAL de verdade, não texto")
    func datasSaoNumericas() throws {
        // `.deferredToDate` (o padrão do GRDB) grava "AAAA-MM-DD HH:MM:SS.SSS"
        // — texto que cabe numa coluna DOUBLE sem erro nenhum, e que
        // continuaria voltando igual num teste de ida-e-volta (o mesmo
        // `.deferredToDate` decodifica de volta), escondendo o problema até
        // alguém tentar `ORDER BY` numa coluna que hoje é ordenada como
        // string.
        let db = try banco()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(mensagem("m1"), folderID: "conta-a/INBOX").insert(conexao)
        }
        try db.pool.read { conexao in
            let tipoDaConta = try String.fetchOne(conexao, sql: "SELECT typeof(createdAt) FROM account WHERE id = 'conta-a'")
            let tipoDaMensagem = try String.fetchOne(conexao, sql: "SELECT typeof(receivedAt) FROM message WHERE id = 'm1'")
            #expect(tipoDaConta == "real")
            #expect(tipoDaMensagem == "real")
        }
    }

    @Test("Os índices de mensagem são usados pelas consultas que as Tasks 13/14 fazem")
    func indicesDeMensagemSaoUsados() throws {
        let db = try banco()
        try db.pool.read { conexao in
            // A asserção é o plano usar o índice — não que a consulta devolva
            // linha nenhuma. Um banco vazio ainda assim compila um plano, e é
            // o plano que prova o índice existe e é o escolhido.
            let planoPorData = try Row.fetchAll(
                conexao, sql: "EXPLAIN QUERY PLAN SELECT * FROM message ORDER BY receivedAt DESC"
            ).map { $0["detail"] as String }.joined(separator: " | ")
            let planoPorPasta = try Row.fetchAll(
                conexao, sql: "EXPLAIN QUERY PLAN SELECT * FROM message WHERE folderID = 'conta-a/INBOX'"
            ).map { $0["detail"] as String }.joined(separator: " | ")
            #expect(planoPorData.contains("message_on_received"), "plano: \(planoPorData)")
            #expect(planoPorPasta.contains("message_on_folder"), "plano: \(planoPorPasta)")
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
            var corpo = MessageBodyRecord(messageID: "m1", paragraphs: original.body)
            try corpo.insert(conexao)
        }
        let devolvida = try db.pool.read { conexao -> Message in
            let registro = try #require(try MessageRecord.fetchOne(conexao, key: "m1"))
            // A chave física de `message_body` é o `rowid` desde a rodada de
            // conserto 1 — `messageID` continua única, mas a busca por ela
            // passa pela forma de dicionário (qualquer chave com índice
            // único, não só a primária).
            let corpo = try MessageBodyRecord.fetchOne(conexao, key: ["messageID": "m1"])
            return registro.message(body: corpo?.body ?? [])
        }
        // A volta traz `folderIDs` preenchido com a pasta em que a linha mora,
        // e a ida gravou `[]`: **é a mesma informação, dita de duas formas**.
        // Uma mensagem IMAP está numa pasta e ponto, e repetir o `folderID` em
        // toda linha do banco seria a segunda fonte da verdade que um dia
        // diverge — ver a v8. `[]` na entrada quer dizer "onde `folderID` diz",
        // e é isso que sai.
        #expect(devolvida.folderIDs == ["conta-a/INBOX"])
        #expect(devolvida == original)
    }

    @Test("Tags, resumo, evento detectado e sugestões de resposta também vão e voltam")
    func mensagemComExtrasVaiEVolta() throws {
        // A fixture `mensagem(_:)` traz os quatro campos vazios — é assim que
        // o teste original não expunha o buraco: `[]`/`nil` cravados em
        // `message(body:)` batiam com `[]`/`nil` vindos da fixture por
        // coincidência. Este teste usa valores de verdade nos quatro.
        let db = try banco()
        let original = Message(
            id: "m1", accountID: "conta-a",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Assunto", snippet: "Trecho", body: ["Corpo"],
            tags: [Tag(name: "Precisa resposta", tintHex: "#FF6B6B"), Tag(name: "Lead")],
            bucket: .today, isRead: false,
            summary: "Resumo gerado no dispositivo.",
            detectedEvent: DetectedEvent(
                label: "Call de contrato · qui 27, 15:00",
                start: Date(timeIntervalSince1970: 1_800_100_000),
                duration: 1_800
            ),
            category: .transactions,
            replyHints: ["Confirmar quinta 15h", "Pedir mais um dia"],
            serverID: "9001", uidValidity: 42,
            folderIDs: ["conta-a/INBOX"]
        )
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(original, folderID: "conta-a/INBOX").insert(conexao)
        }
        let devolvida = try db.pool.read { conexao -> Message in
            let registro = try #require(try MessageRecord.fetchOne(conexao, key: "m1"))
            return registro.message(body: original.body)
        }
        #expect(devolvida.category == .transactions)
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
            var corpo = MessageBodyRecord(messageID: "m1", paragraphs: ["Corpo"])
            try corpo.insert(conexao)
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
            // O gatilho de DELETE tem de ter desfeito o índice junto com o
            // corpo. Nem `SELECT count(*) FROM message_fts` nem
            // `MessageSearch.matchingBodyIDs` provam isso: os dois fazem
            // — direta ou indiretamente (via JOIN com `message_body`) —
            // uma consulta que só enxerga linhas que ainda têm conteúdo
            // vivo, e a linha de conteúdo já foi embora na cascata. Um
            // índice sujo (gatilho de DELETE ausente) fica invisível para
            // as duas, e a rodada de conserto 1 provou isso na prática:
            // removendo só esse gatilho, as duas continuavam devolvendo 0.
            // A prova honesta é MATCH direto contra `message_fts`, sem
            // JOIN nenhum — é o que realmente pergunta "o índice ainda tem
            // esta linha?".
            let consulta = try #require(MessageSearch.ftsQuery("corpo"))
            let indexado = try Int.fetchOne(
                conexao,
                sql: "SELECT count(*) FROM (SELECT rowid FROM message_fts WHERE message_fts MATCH ?)",
                arguments: [consulta]
            )
            #expect(pastas == 0)
            #expect(mensagens == 0)
            #expect(corpos == 0)
            #expect(itens == 0)
            #expect(estados == 0)
            #expect(indexado == 0)
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
            var corpo = MessageBodyRecord(
                messageID: "m1",
                paragraphs: ["A revisão do contrato ficou pronta.", "Abraço."]
            )
            try corpo.insert(conexao)
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

    @Test("O teto da busca devolve os 200 MAIS RECENTES, e não os 200 mais antigos")
    func buscaDevolveOsMaisRecentes() throws {
        // Sem `ORDER BY`, a ordem é a do percurso do índice FTS — ordem de
        // `rowid`, isto é, ordem de inserção. O teto de 200 devolvia então os
        // 200 **mais antigos**: medido num banco de 50 mil, de 1 000 corpos que
        // casavam, os 200 devolvidos cobriam os primeiros 20 % da faixa de datas
        // e toda a metade recente ficava invisível. E como o resultado é um
        // `Set` que a UI interseca, o corte é mudo: não há "mostrando 200 de
        // 1 000", só ausência.
        //
        // MUTAÇÃO QUE ISTO PEGA: tirar o `ORDER BY m.receivedAt DESC` de
        // `MessageSearch.matchingBodyIDs` inverte o conjunto devolvido — a mais
        // nova some e a mais velha aparece.
        let db = try banco()
        let quantas = 250
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            // Inseridas em ordem crescente de data: a ordem de `rowid` e a
            // ordem de data coincidem, que é o caso em que a falta de `ORDER BY`
            // erra de forma mais limpa.
            for numero in 1...quantas {
                var registro = MessageRecord(mensagem("m\(numero)"), folderID: "conta-a/INBOX")
                registro.receivedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(numero))
                try registro.insert(conexao)
                var corpo = MessageBodyRecord(
                    messageID: "m\(numero)", paragraphs: ["O relatorio numero \(numero)."]
                )
                try corpo.insert(conexao)
            }
        }
        try db.pool.read { conexao in
            let achados = try MessageSearch.matchingBodyIDs(conexao, term: "relatorio", accountID: nil)
            #expect(achados.count == 200)
            // As cinquenta mais antigas ficam de fora, as duzentas mais novas
            // entram. As pontas são o que separa "cortou" de "cortou o lado
            // certo".
            #expect(achados.contains("m\(quantas)"))
            #expect(achados.contains("m\(quantas - 199)"))
            #expect(!achados.contains("m1"))
            #expect(!achados.contains("m\(quantas - 200)"))
        }
    }

    @Test("A busca por corpo chega em `message` pela via indexada, e não varrendo a tabela")
    func planoDaBusca() throws {
        let db = try banco()
        try db.pool.read { conexao in
            // O `ORDER BY` novo custa uma ordenação das linhas que casam (mil,
            // no banco medido; 2 ms para a consulta inteira). O que ele **não**
            // pode custar é uma varredura de `message`: a junção continua
            // entrando pela chave primária.
            let consulta = try #require(MessageSearch.ftsQuery("relatorio"))
            let plano = try Row.fetchAll(conexao, sql: """
                EXPLAIN QUERY PLAN
                SELECT b.messageID
                FROM message_fts f
                JOIN message_body b ON b.rowid = f.rowid
                JOIN message m ON m.id = b.messageID
                WHERE message_fts MATCH ?
                ORDER BY m.receivedAt DESC LIMIT 200
                """, arguments: [consulta]
            ).map { $0["detail"] as String }.joined(separator: " | ")
            #expect(plano.contains("VIRTUAL TABLE INDEX"), "plano: \(plano)")
            #expect(plano.contains("SEARCH m"), "plano: \(plano)")
            #expect(!plano.contains("SCAN m"), "plano: \(plano)")
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
                var corpo = MessageBodyRecord(messageID: id, paragraphs: ["A revisão saiu."])
                try corpo.insert(conexao)
            }
        }
        try db.pool.read { conexao in
            let todas = try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: nil)
            let soContaB = try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: "conta-b")
            #expect(todas == ["m1", "m2"])
            #expect(soContaB == ["m2"])
        }
    }

    @Test("Termo curto demais, ou que só tem pontuação, não vira consulta — MATCH com sintaxe inválida derruba o SQLite")
    func termoVazioNaoConsulta() throws {
        #expect(MessageSearch.ftsQuery("   ") == nil)
        #expect(MessageSearch.ftsQuery("\"") == nil)
        // Piso de dois caracteres na última palavra: é ela quem ganha `*` de
        // prefixo, e uma letra só casaria com uma fração enorme do índice a
        // cada primeira tecla digitada.
        #expect(MessageSearch.ftsQuery("r") == nil)
        #expect(MessageSearch.ftsQuery("revisão do contrato") == "\"revisão\" \"do\" \"contrato\"*")
        let db = try banco()
        try db.pool.read { conexao in
            let vazio = try MessageSearch.matchingBodyIDs(conexao, term: "  ", accountID: nil)
            let curto = try MessageSearch.matchingBodyIDs(conexao, term: "r", accountID: nil)
            #expect(vazio.isEmpty)
            #expect(curto.isEmpty)
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
            var corpo = MessageBodyRecord(messageID: "m1", paragraphs: ["Prévia curta."])
            try corpo.insert(conexao)
            // A carga inicial baixa a prévia primeiro e o corpo cheio depois:
            // é exatamente este UPDATE que roda no meio da Task 12. A busca
            // é por `messageID` (a chave única de aplicação); a chave física
            // agora é o `rowid`, por isso o fetch antes de mutar, em vez de
            // um `update` cego num registro novo em folha sem `rowid` nenhum.
            var existente = try #require(try MessageBodyRecord.fetchOne(conexao, key: ["messageID": "m1"]))
            let atualizado = MessageBodyRecord(messageID: "m1", paragraphs: ["Corpo inteiro com orçamento."])
            existente.paragraphs = atualizado.paragraphs
            existente.plain = atualizado.plain
            try existente.update(conexao)
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
