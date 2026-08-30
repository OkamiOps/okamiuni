import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("A chave da conversa")
struct ThreadKeyTests {

    // MARK: O assunto normalizado

    @Test("Os prefixos de resposta e de encaminhamento saem — em qualquer idioma da lista")
    func prefixosSaem() {
        for assunto in [
            "Re: Contrato", "RE: Contrato", "Res: Contrato", "Enc: Contrato",
            "Fwd: Contrato", "FW: Contrato", "Rv: Contrato", "AW: Contrato",
        ] {
            #expect(ThreadKey.normalized(subject: assunto) == "contrato", "falhou em \(assunto)")
        }
    }

    /// A prova de que o corte é em **laço**: uma conversa que foi encaminhada e
    /// respondida acumula prefixos, e tirar um só deixaria a resposta da
    /// resposta noutra conversa.
    @Test("Prefixos empilhados saem todos")
    func prefixosEmpilhados() {
        #expect(ThreadKey.normalized(subject: "Re: Enc: Re: Contrato") == "contrato")
        #expect(ThreadKey.normalized(subject: "RE: RE: RE: Contrato") == "contrato")
    }

    @Test("A contagem do Outlook e o espaço antes dos dois pontos contam como prefixo")
    func prefixosTortos() {
        #expect(ThreadKey.normalized(subject: "Re[2]: Contrato") == "contrato")
        #expect(ThreadKey.normalized(subject: "Re : Contrato") == "contrato")
        #expect(ThreadKey.normalized(subject: "Re[2]: Re: Contrato") == "contrato")
    }

    @Test("O acento cai, a caixa cai, e o espaço a mais colapsa")
    func dobra() {
        #expect(
            ThreadKey.normalized(subject: "Revisão do CONTRATO")
                == ThreadKey.normalized(subject: "revisao do contrato")
        )
        // "ã" composto de dois pontos de código — o que um cliente manda e o
        // outro não. Sem a dobra, dois assuntos iguais dariam duas conversas.
        #expect(ThreadKey.normalized(subject: "Revisa\u{0303}o") == "revisao")
        #expect(ThreadKey.normalized(subject: "  Nossa   call  amanha ") == "nossa call amanha")
    }

    /// A palavra que **começa** com um prefixo não é um prefixo: sem os dois
    /// pontos, nada é cortado.
    @Test("Sem os dois pontos não há prefixo")
    func semDoisPontos() {
        #expect(ThreadKey.normalized(subject: "Reunião de hoje") == "reuniao de hoje")
        #expect(ThreadKey.normalized(subject: "Encerramento") == "encerramento")
    }

    // MARK: A ordem das regras

    @Test("A raiz das References vence o In-Reply-To e o Message-ID próprio")
    func raizVence() {
        let chave = ThreadKey.derive(
            accountID: "c", messageID: "c3@x", inReplyTo: "c2@x",
            references: ["c1@x", "c2@x"], subject: "Re: Call", fallback: "id"
        )
        #expect(chave == "c:m:c1@x")
    }

    @Test("Sem References, o In-Reply-To; sem ele, o próprio Message-ID")
    func degrausSeguintes() {
        #expect(
            ThreadKey.derive(
                accountID: "c", messageID: "c2@x", inReplyTo: "c1@x",
                references: [], subject: "Re: Call", fallback: "id"
            ) == "c:m:c1@x"
        )
        #expect(
            ThreadKey.derive(
                accountID: "c", messageID: "c1@x", inReplyTo: nil,
                references: [], subject: "Call", fallback: "id"
            ) == "c:m:c1@x"
        )
    }

    /// A mensagem antiga, sem cabeçalho nenhum: a chave é o assunto
    /// normalizado, por conta. É o que faz as 83 mensagens que já estão no
    /// banco do dono se agruparem sem uma sincronização nova.
    @Test("Sem cabeçalho nenhum, o assunto normalizado — e por conta")
    func fallbackDoAssunto() {
        let original = ThreadKey.derive(
            accountID: "c", messageID: nil, inReplyTo: nil, references: [],
            subject: "Lembrete rápido: nossa call amanhã", fallback: "id1"
        )
        let resposta = ThreadKey.derive(
            accountID: "c", messageID: nil, inReplyTo: nil, references: [],
            subject: "Re: Lembrete rápido: nossa call amanhã", fallback: "id2"
        )
        #expect(original == resposta)
        // Outra conta, mesma conversa aparente: chaves diferentes. O filtro de
        // conta da lista promete que uma caixa nunca mistura a outra.
        let outraConta = ThreadKey.derive(
            accountID: "d", messageID: nil, inReplyTo: nil, references: [],
            subject: "Lembrete rápido: nossa call amanhã", fallback: "id3"
        )
        #expect(outraConta != original)
    }

    @Test("Sem cabeçalho e sem assunto, a mensagem é uma conversa dela mesma")
    func fallbackFinal() {
        let chave = ThreadKey.derive(
            accountID: "c", messageID: nil, inReplyTo: nil, references: [],
            subject: "   ", fallback: "conta:i:pasta:1:9"
        )
        #expect(chave == "conta:i:pasta:1:9")
    }

    /// Os três espaços de chave não se cruzam: um assunto que por acaso fosse
    /// igual a um `Message-ID` juntaria duas conversas sem relação.
    @Test("Assunto, Message-ID e threadId vivem em espaços separados")
    func espacosSeparados() {
        #expect(ThreadKey.subject(accountID: "c", subject: "a@x") != ThreadKey.rfc(accountID: "c", messageID: "a@x"))
        #expect(ThreadKey.gmail(accountID: "c", threadID: "a@x") != ThreadKey.rfc(accountID: "c", messageID: "a@x"))
    }

    // MARK: Os cabeçalhos crus

    @Test("O Message-ID vai e volta pelado")
    func pelado() {
        #expect(ThreadKey.bare("<abc@x.com>") == "abc@x.com")
        #expect(ThreadKey.bare("  abc@x.com ") == "abc@x.com")
    }

    @Test("A lista de References é lida pelo que está entre < e >")
    func listaDeReferences() {
        #expect(ThreadKey.ids(inHeader: "<a@x> <b@x>") == ["a@x", "b@x"])
        // Comentário entre parênteses, vírgula no lugar do espaço e quebra de
        // linha: as três formas são legais e as três chegam de verdade.
        #expect(ThreadKey.ids(inHeader: "<a@x>, (comentário) <b@x>\r\n <c@x>") == ["a@x", "b@x", "c@x"])
        #expect(ThreadKey.ids(inHeader: "").isEmpty)
    }

    @Test("Um bloco de cabeçalho entrega o campo pedido, com a continuação junto")
    func blocoDeCabecalho() {
        let bloco = "References: <a@x>\r\n <b@x>\r\nMessage-ID: <c@x>\r\n\r\n"
        #expect(ThreadKey.headerValue(bloco, campo: "References") == "<a@x> <b@x>")
        #expect(ThreadKey.headerValue(bloco, campo: "message-id") == "<c@x>")
        #expect(ThreadKey.headerValue(bloco, campo: "In-Reply-To") == nil)
    }
}

@Suite("A conversa gravada no banco")
struct ThreadKeyPersistenceTests {

    private let conta = Account(
        id: "c1", address: "eu@meusite.com", displayName: "Eu",
        provider: .imap, host: "meusite",
        tintLightHex: "#397852", tintDarkHex: "#88D1A2"
    )

    private func banco() throws -> SyncDatabase {
        let db = try SyncDatabase.temporary()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "c1/INBOX", accountID: "c1", serverName: "INBOX",
                role: .inbox, displayName: "INBOX"
            ).insert(conexao)
        }
        return db
    }

    private func grava(_ db: SyncDatabase, _ message: Message) throws {
        try db.pool.write { try MessageRecord(message, folderID: "c1/INBOX").save($0) }
    }

    private func mensagem(
        id: String, subject: String, rfcMessageID: String?,
        references: [String] = [], threadKey: String?
    ) -> Message {
        Message(
            id: id, accountID: "c1", from: Contact(name: "Marina", address: "marina@x.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: subject, snippet: "", body: [], tags: [], bucket: .today,
            isRead: false, summary: nil, detectedEvent: nil,
            rfcMessageID: rfcMessageID, references: references, threadKey: threadKey
        )
    }

    // MARK: A v4

    @Test("A v4 acrescenta as três colunas e os dois índices, sem tocar nas anteriores")
    func colunasEIndices() throws {
        let db = try banco()
        let colunas = try db.pool.read { conexao in
            try conexao.columns(in: "message").map(\.name)
        }
        for esperada in ["rfcMessageID", "referencesJSON", "threadKey"] {
            #expect(colunas.contains(esperada), "faltou a coluna \(esperada)")
        }
        let indices = try db.pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indices.contains("message_on_thread"))
        #expect(indices.contains("message_on_rfc_message_id"))
        // As da v1 continuam lá: acrescentar não é reescrever.
        #expect(indices.contains("message_on_received"))
    }

    /// A prova de que as linhas antigas — as que já estão no banco do dono, sem
    /// cabeçalho nenhum — se agrupam pelo assunto depois da migração.
    @Test("A migração preenche a chave das linhas antigas pelo assunto normalizado")
    func migracaoPreencheAsAntigas() throws {
        // Um banco na v3: as três primeiras migrações, e só elas.
        let diretorio = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-v3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: diretorio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: diretorio) }
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: diretorio.appendingPathComponent("mail.sqlite").path, configuration: config
        )
        try SyncDatabase.migrator.migrate(pool, upTo: "v3")

        try pool.write { db in
            // O banco está deliberadamente parado na v3. Inserir o record
            // atual tentaria escrever colunas acrescentadas por migrações
            // posteriores (como `signatureJSON`) e deixaria de testar a
            // atualização de um esquema antigo real.
            try db.execute(
                sql: """
                    INSERT INTO account
                      (id, address, displayName, provider, host, tintLightHex,
                       tintDarkHex, signature, imapHost, imapPort, imapSecurity,
                       state, lastSyncedAt, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    conta.id, conta.address, conta.displayName, conta.provider.rawValue,
                    conta.host, conta.tintLightHex, conta.tintDarkHex, conta.signature,
                    conta.imap?.host, conta.imap?.port, conta.imap?.security.rawValue,
                    conta.state.rawValue, conta.lastSyncedAt, 1.0,
                ]
            )
            try FolderRecord(
                id: "c1/INBOX", accountID: "c1", serverName: "INBOX",
                role: .inbox, displayName: "INBOX"
            ).insert(db)
            for (id, assunto) in [
                ("m1", "Lembrete rápido: nossa call amanhã"),
                ("m2", "Re: Lembrete rápido: nossa call amanhã"),
                ("m3", "Outro assunto"),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO message
                          (id, accountID, folderID, fromName, fromAddress, subject,
                           snippet, receivedAt, bucket)
                        VALUES (?, 'c1', 'c1/INBOX', 'Marina', 'marina@x.com', ?, '', 1, 'hoje')
                        """,
                    arguments: [id, assunto]
                )
            }
        }

        try SyncDatabase.migrator.migrate(pool)

        let chaves = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, threadKey FROM message ORDER BY id")
        }
        let porID = Dictionary(uniqueKeysWithValues: chaves.map { ($0["id"] as String, $0["threadKey"] as String?) })
        #expect(porID["m1"] == porID["m2"])
        #expect(porID["m1"] != porID["m3"])
        #expect(porID["m1"] == ThreadKey.subject(accountID: "c1", subject: "Lembrete rápido: nossa call amanhã"))
    }

    // MARK: A herança

    /// O caso da queixa: a terceira mensagem responde à segunda. Sem herança
    /// ela abriria uma conversa nova com a chave da segunda, e a tela mostraria
    /// duas linhas onde o webmail mostra uma.
    @Test("A filha herda a chave da mãe, e a neta herda a mesma")
    func heranca() throws {
        let db = try banco()
        let raiz = ThreadKey.rfc(accountID: "c1", messageID: "a@x")
        try grava(db, mensagem(id: "m1", subject: "Call", rfcMessageID: "a@x", threadKey: raiz))

        let daFilha = try db.pool.write { conexao in
            try ThreadKeyResolver.resolve(
                conexao, accountID: "c1", messageID: "b@x", inReplyTo: "a@x",
                references: [], subject: "Re: Call", fallback: "m2"
            )
        }
        #expect(daFilha == raiz)
        try grava(db, mensagem(id: "m2", subject: "Re: Call", rfcMessageID: "b@x", threadKey: daFilha))

        let daNeta = try db.pool.write { conexao in
            try ThreadKeyResolver.resolve(
                conexao, accountID: "c1", messageID: "c@x", inReplyTo: "b@x",
                references: [], subject: "Re: Call", fallback: "m3"
            )
        }
        #expect(daNeta == raiz)
    }

    @Test("Sem mãe no banco, a resolução cai nas regras puras")
    func semMae() throws {
        let db = try banco()
        let chave = try db.pool.write { conexao in
            try ThreadKeyResolver.resolve(
                conexao, accountID: "c1", messageID: "b@x", inReplyTo: "a@x",
                references: [], subject: "Re: Call", fallback: "m2"
            )
        }
        #expect(chave == ThreadKey.rfc(accountID: "c1", messageID: "a@x"))
    }

    /// A mãe de **outra conta** não empresta chave nenhuma: as duas caixas são
    /// mundos separados, como o filtro de conta promete.
    @Test("A herança não atravessa contas")
    func herancaNaoAtravessaContas() throws {
        let db = try banco()
        try grava(db, mensagem(id: "m1", subject: "Call", rfcMessageID: "a@x", threadKey: "c1:m:a@x"))
        let chave = try db.pool.write { conexao in
            try ThreadKeyResolver.resolve(
                conexao, accountID: "outra", messageID: "b@x", inReplyTo: "a@x",
                references: [], subject: "Re: Call", fallback: "m2"
            )
        }
        #expect(chave == "outra:m:a@x")
    }

    // MARK: O que o Gmail grava

    @Test("O Gmail grava o threadId como chave, e guarda os cabeçalhos da resposta")
    func gmailGravaOThreadID() throws {
        let db = try banco()
        try db.pool.write { conexao in
            try FolderRecord.gmail(accountID: "c1").save(conexao)
        }
        let original = GmailMessage(
            id: "g1", threadID: "t9", labelIDs: ["INBOX"],
            internalDate: Date(timeIntervalSince1970: 1_800_000_000),
            from: Contact(name: "Marina", address: "marina@x.com"), to: [], cc: [],
            subject: "Lembrete rápido: nossa call amanhã", snippet: "", body: [],
            html: nil, calendarICS: nil, rfcMessageID: "a@x", references: []
        )
        let resposta = GmailMessage(
            id: "g2", threadID: "t9", labelIDs: ["INBOX"],
            internalDate: Date(timeIntervalSince1970: 1_800_003_600),
            from: Contact(name: "Eu", address: "eu@meusite.com"), to: [], cc: [],
            subject: "Re: Lembrete rápido: nossa call amanhã", snippet: "", body: [],
            html: nil, calendarICS: nil, rfcMessageID: "b@x", references: ["a@x"]
        )
        try db.pool.write { conexao in
            _ = try InitialLoader.gravaMensagensDoGmail(
                conexao, [(original, false), (resposta, false)],
                account: conta, folderID: FolderRecord.gmail(accountID: "c1").id,
                laterLabelID: nil
            )
        }
        let linhas = try db.pool.read { conexao in
            try MessageRecord.order(Column("id")).fetchAll(conexao)
        }
        #expect(linhas.count == 2)
        #expect(linhas.allSatisfy { $0.threadKey == ThreadKey.gmail(accountID: "c1", threadID: "t9") })
        #expect(linhas.first?.rfcMessageID == "a@x")
        #expect(linhas.last?.message(body: []).references == ["a@x"])
    }

    // MARK: A mensagem enviada

    @Test("A resposta enviada entra na conversa da mensagem respondida")
    func enviadaEntraNaConversa() throws {
        let db = try banco()
        let raiz = ThreadKey.gmail(accountID: "c1", threadID: "t9")
        try grava(db, mensagem(id: "m1", subject: "Call", rfcMessageID: "a@x", threadKey: raiz))

        let saindo = OutgoingMessage(
            messageID: "b@x", accountID: "c1",
            from: OutgoingAddress(name: "Eu", address: "eu@meusite.com"),
            to: [OutgoingAddress(name: "Marina", address: "marina@x.com")],
            subject: "Re: Call", plainText: "combinado",
            inReplyTo: "a@x", references: ["a@x"]
        )
        let chave = try db.pool.write { conexao in
            try ThreadKeyResolver.resolve(
                conexao, accountID: "c1", messageID: saindo.messageID,
                inReplyTo: saindo.inReplyTo, references: saindo.references,
                subject: saindo.subject,
                fallback: ThreadKey.rfc(accountID: "c1", messageID: saindo.messageID)
            )
        }
        // A chave do Gmail — que a `messages.send` não devolve — chega pela
        // herança. Sem ela, a resposta ficaria numa linha separada da conversa
        // que ela responde.
        #expect(chave == raiz)

        let linhas = SentCopy.linhas(
            saindo, gravadaEm: .gmail(serverID: "g2"), accountID: "c1",
            now: Date(timeIntervalSince1970: 1_800_003_600), threadKey: chave
        )
        #expect(linhas.message.threadKey == raiz)
        #expect(linhas.message.rfcMessageID == "b@x")
        #expect(linhas.message.references == ["a@x"])
    }
}

@Suite("O ENVELOPE do IMAP traz a conversa")
struct ImapEnvelopeThreadTests {

    private func fetchLine(uid: Int64, inReplyTo: String, messageID: String) -> String {
        "* \(uid) FETCH (UID \(uid) FLAGS () "
        + "INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" "
        + "ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"Re: Call\" "
        + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL "
        + "((\"Ricardo\" NIL \"contato\" \"meusite.com\")) NIL NIL "
        + "\(inReplyTo) \(messageID)))"
    }

    /// Os dois últimos campos do `ENVELOPE` já vinham na resposta e eram
    /// jogados fora. Nenhum comando mudou para lê-los.
    @Test("O nono e o décimo campos do ENVELOPE viram In-Reply-To e Message-ID")
    func envelopeTrazOsDois() throws {
        let linha = try ImapResponseAdapter.untagged(
            fromLogicalLine: fetchLine(uid: 9_001, inReplyTo: "\"<a@x>\"", messageID: "\"<b@x>\"")
        )
        let envelopes = ImapWire.envelopes(from: [linha])
        #expect(envelopes.count == 1)
        #expect(envelopes.first?.inReplyTo == "a@x")
        #expect(envelopes.first?.messageID == "b@x")
    }

    @Test("NIL nos dois campos é ausência, não texto")
    func envelopeSemOsDois() throws {
        let linha = try ImapResponseAdapter.untagged(
            fromLogicalLine: fetchLine(uid: 9_001, inReplyTo: "NIL", messageID: "NIL")
        )
        let envelopes = ImapWire.envelopes(from: [linha])
        #expect(envelopes.first?.inReplyTo == nil)
        #expect(envelopes.first?.messageID == nil)
    }

    /// O comando de envelope **não** mudou — e isso é uma decisão, não um
    /// esquecimento: ele é o do laço de lotes, o mais caro da carga, e pedir
    /// `References` nele custaria um literal a mais por mensagem. A corrente é
    /// reconstruída pela herança. Ver `ImapEnvelope.inReplyTo`.
    @Test("O FETCH de envelope continua sendo o mesmo comando")
    func comandoIntacto() {
        #expect(
            ImapWire.uidFetchEnvelopes(tag: "A0001", uids: [1, 2])
                == "A0001 UID FETCH 1,2 (UID FLAGS INTERNALDATE ENVELOPE)"
        )
    }
}
