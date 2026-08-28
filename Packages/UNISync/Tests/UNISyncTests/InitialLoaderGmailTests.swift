import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("Carga inicial: Gmail")
struct InitialLoaderGmailTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private let conta = Account(
        id: "conta-g", address: "ricardo@gmail.com", displayName: "Pessoal",
        provider: .gmail, host: "gmail",
        tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4", state: .carregando
    )

    // MARK: O roteiro

    private func mensagemJSON(id: String, rotulos: [String], assunto: String, corpo: String) -> String {
        let base64 = Data(corpo.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let lista = rotulos.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(id)","labelIds":[\(lista)],
         "snippet":"prévia de \(id)","internalDate":"1799000000000",
         "payload":{"mimeType":"text/plain",
           "headers":[
             {"name":"From","value":"Marina <marina@clientepremium.com>"},
             {"name":"To","value":"ricardo@gmail.com"},
             {"name":"Subject","value":"\(assunto)"}
           ],
           "body":{"data":"\(base64)"}}}
        """
    }

    /// Quatro mensagens, duas páginas, e uma de cada caixa. `m1` chega não
    /// lida e com estrela — é ela que prova a projeção de bandeiras.
    private func roteiroPadrao() -> [String: [StubURLProtocol.Reply]] {
        [
            "/gmail/v1/users/me/profile": [.json(
                "{\"emailAddress\":\"ricardo@gmail.com\",\"historyId\":\"9928471\"}"
            )],
            "/gmail/v1/users/me/labels": [.json("""
                {"labels":[{"id":"INBOX","name":"INBOX"},{"id":"Label_7","name":"OkamiUNI/Depois"}]}
                """)],
            "/gmail/v1/users/me/messages": [
                .json("{\"messages\":[{\"id\":\"m1\"},{\"id\":\"m2\"}],\"nextPageToken\":\"p2\"}"),
                .json("{\"messages\":[{\"id\":\"m3\"},{\"id\":\"m4\"}]}"),
            ],
            "/gmail/v1/users/me/messages/m1": [
                .json(mensagemJSON(
                    id: "m1", rotulos: ["INBOX", "UNREAD", "STARRED"],
                    assunto: "Um", corpo: "A revisão saiu."
                ))
            ],
            "/gmail/v1/users/me/messages/m2": [
                .json(mensagemJSON(id: "m2", rotulos: ["INBOX", "TRASH"], assunto: "Dois", corpo: "Lixo."))
            ],
            "/gmail/v1/users/me/messages/m3": [
                .json(mensagemJSON(id: "m3", rotulos: ["SENT"], assunto: "Três", corpo: "Escrevi."))
            ],
            "/gmail/v1/users/me/messages/m4": [
                .json(mensagemJSON(id: "m4", rotulos: ["Label_7"], assunto: "Quatro", corpo: "Depois."))
            ],
        ]
    }

    /// Seis mensagens de entrada numa página só — o roteiro do teste de
    /// retomada de verdade. `falhandoEm` troca a resposta de uma delas por um
    /// 401, que é erro **da sessão**: a carga para ali.
    private func roteiroDeSeis(falhandoEm falha: String? = nil) -> [String: [StubURLProtocol.Reply]] {
        var roteiro: [String: [StubURLProtocol.Reply]] = [
            "/gmail/v1/users/me/profile": [.json(
                "{\"emailAddress\":\"ricardo@gmail.com\",\"historyId\":\"9928471\"}"
            )],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[{\"id\":\"INBOX\",\"name\":\"INBOX\"}]}")],
            "/gmail/v1/users/me/messages": [.json(
                "{\"messages\":[" + (1...6).map { "{\"id\":\"m\($0)\"}" }.joined(separator: ",") + "]}"
            )],
        ]
        for numero in 1...6 {
            let id = "m\(numero)"
            roteiro["/gmail/v1/users/me/messages/\(id)"] = id == falha
                ? [.json("{\"error\":{\"code\":401}}", status: 401)]
                : [.json(mensagemJSON(
                    id: id, rotulos: ["INBOX"], assunto: "Assunto \(numero)", corpo: "Corpo de \(id)."
                ))]
        }
        return roteiro
    }

    private func servidorIDs(_ db: SyncDatabase) async throws -> Set<String> {
        try await db.pool.read { conexao in
            Set(try MessageRecord.fetchAll(conexao).compactMap(\.serverID))
        }
    }

    private func estado(_ db: SyncDatabase) async throws -> Account.State? {
        try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account.state
        }
    }

    private func cliente(_ session: URLSession, token: @Sendable @escaping () -> String = { "at" }) -> GmailClient {
        GmailClient(
            session: session,
            accessToken: { token() },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
    }

    private func contaNoBanco(_ db: SyncDatabase) async throws {
        try await db.pool.write { try AccountRecord(self.conta, createdAt: self.agora).insert($0) }
    }

    /// Uma carga completa contra um roteiro, do zero.
    @discardableResult
    private func carrega(
        _ db: SyncDatabase,
        roteiro: [String: [StubURLProtocol.Reply]]? = nil,
        batchSize: Int = InitialLoader.defaultBatchSize,
        inserindoConta: Bool = true
    ) async throws -> (relatos: [LoadProgress], session: URLSession) {
        if inserindoConta { try await contaNoBanco(db) }
        let session = StubURLProtocol.session(routes: roteiro ?? roteiroPadrao())
        let recebidos = Recebedor()
        try await InitialLoader(database: db, batchSize: batchSize).loadGmail(
            account: conta, client: cliente(session), now: agora,
            progress: { p in recebidos.registra(p) }
        )
        return (recebidos.todos, session)
    }

    // MARK: A janela

    @Test("A janela é de 90 dias, e quem filtra é o servidor")
    func janelaDe90Dias() async throws {
        let db = try SyncDatabase.temporary()
        let (_, session) = try await carrega(db)

        #expect(InitialLoader.windowDays == 90)
        #expect(InitialLoader.gmailQuery == "newer_than:90d")
        // A prova de que o filtro viajou: `q=newer_than:90d` na query da
        // listagem. Sem ele o Gmail devolveria a caixa inteira para nós
        // filtrarmos — numa conta de dez anos, a carga inicial nunca acabaria.
        let listagens = StubURLProtocol.requests(for: session)
            .filter { $0.path.hasSuffix("/messages") }
        #expect(listagens.count == 2)
        #expect(listagens.allSatisfy {
            ($0.query.removingPercentEncoding ?? $0.query).contains("q=newer_than:90d")
        })
        // E a janela em data, que é o que a carga IMAP consome. São 90 dias de
        // **calendário**, não 90 × 86.400 segundos: atravessando o horário de
        // verão as duas contas divergem em uma hora, e é por isso que `since`
        // recebe um `Calendar` em vez de subtrair segundos.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let inicio = InitialLoader(database: db, calendar: utc).since(now: agora)
        #expect(utc.dateComponents([.day], from: inicio, to: agora).day == 90)
        #expect(agora.timeIntervalSince(inicio) == 90 * 24 * 60 * 60)
    }

    // MARK: A projeção

    @Test("As quatro mensagens caem nas caixas certas — e a enviada não entra")
    func projecaoNaEntrada() async throws {
        let db = try SyncDatabase.temporary()
        try await carrega(db)

        let porBucket = try await db.pool.read { conexao -> [String: String] in
            var mapa: [String: String] = [:]
            for registro in try MessageRecord.fetchAll(conexao) {
                mapa[registro.serverID ?? ""] = registro.bucket
            }
            return mapa
        }
        #expect(porBucket["m1"] == "hoje")
        #expect(porBucket["m2"] == "lixeira")
        #expect(porBucket["m4"] == "depois")
        // A enviada não entra: a caixa Enviadas não existe neste marco.
        #expect(porBucket["m3"] == nil)
        #expect(porBucket.count == 3)
    }

    @Test("`UNREAD` e `STARRED` viram não lida e sinalizada na linha gravada")
    func bandeirasProjetadas() async throws {
        // A regra não existia em lugar nenhum antes desta carga: sem ela a
        // caixa inteira abriria lida, contrariando o número que a pessoa vê no
        // navegador, e a estrela que ela pôs lá sumiria ao abrir o app.
        let db = try SyncDatabase.temporary()
        try await carrega(db)

        let porID = try await db.pool.read { conexao -> [String: MessageRecord] in
            var mapa: [String: MessageRecord] = [:]
            for registro in try MessageRecord.fetchAll(conexao) { mapa[registro.serverID ?? ""] = registro }
            return mapa
        }
        #expect(porID["m1"]?.isRead == false)
        #expect(porID["m1"]?.isFlagged == true)
        // `m2` não traz `UNREAD`: ausência é lida, porque o Gmail não tem
        // rótulo `READ`.
        #expect(porID["m2"]?.isRead == true)
        #expect(porID["m2"]?.isFlagged == false)
    }

    @Test("O id da linha é o determinístico, não um UUID")
    func idDeterministico() async throws {
        let db = try SyncDatabase.temporary()
        try await carrega(db)

        let ids = try await db.pool.read { try String.fetchSet($0, sql: "SELECT id FROM message") }
        #expect(ids.contains(MessageIdentity.gmail(accountID: "conta-g", serverID: "m1")))
    }

    // MARK: Retomável

    @Test("Carregar duas vezes não duplica nada")
    func retomavelSemDuplicar() async throws {
        // É o teste do "parar no meio e reabrir". Sem upsert com id
        // determinístico, a segunda carga dobraria a caixa.
        let db = try SyncDatabase.temporary()
        try await carrega(db)
        let depoisDaPrimeira = try await db.pool.read { try MessageRecord.fetchCount($0) }

        let session = StubURLProtocol.session(routes: roteiroPadrao())
        try await InitialLoader(database: db).loadGmail(
            account: conta, client: cliente(session), now: agora, progress: { _ in }
        )
        let depoisDaSegunda = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(depoisDaPrimeira == depoisDaSegunda)
        #expect(depoisDaPrimeira == 3)
        // O corpo também é um por mensagem: `messageID` é UNIQUE, e uma
        // segunda inserção derrubaria a transação do lote inteiro.
        let corpos = try await db.pool.read { try MessageBodyRecord.fetchCount($0) }
        #expect(corpos == 3)
    }

    @Test("Interromper no meio commita os lotes fechados e retomar completa a caixa")
    func retomaDepoisDeInterromper() async throws {
        // O teste de retomada de verdade — duas cargas completas provam
        // idempotência, não interrupção. Aqui a primeira passada morre no meio
        // de um lote: os três primeiros já estão commitados, e a quarta
        // mensagem, que estava no lote aberto, vai embora com ele.
        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let primeira = StubURLProtocol.session(routes: roteiroDeSeis(falhandoEm: "m5"))

        await #expect(throws: SyncError.autenticacao) {
            try await InitialLoader(database: db, batchSize: 3).loadGmail(
                account: self.conta, client: self.cliente(primeira), now: self.agora, progress: { _ in }
            )
        }
        // O lote fechado ficou; o lote aberto não — ou entra tudo, ou nada.
        #expect(try await servidorIDs(db) == ["m1", "m2", "m3"])
        #expect(try await estado(db) == .erroDeAutenticacao)

        // Reabrir continua de onde parou: nada duplicado, nada faltando.
        let segunda = StubURLProtocol.session(routes: roteiroDeSeis())
        try await InitialLoader(database: db, batchSize: 3).loadGmail(
            account: conta, client: cliente(segunda), now: agora, progress: { _ in }
        )
        #expect(try await servidorIDs(db) == ["m1", "m2", "m3", "m4", "m5", "m6"])
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 6)
        #expect(try await db.pool.read { try MessageBodyRecord.fetchCount($0) } == 6)
        #expect(try await estado(db) == .ativa)
    }

    @Test("Uma mensagem apagada entre a listagem e a leitura (404) não custa as outras")
    func quatrocentosEQuatroNoMeio() async throws {
        // O 404 é real e comum: a listagem devolveu o id, a pessoa apagou a
        // mensagem no navegador, e o `get` chega tarde. É erro **daquela**
        // mensagem — a carga segue e termina bem.
        var roteiro = roteiroPadrao()
        roteiro["/gmail/v1/users/me/messages/m2"] = [
            .json("{\"error\":{\"code\":404,\"message\":\"Requested entity was not found.\"}}", status: 404)
        ]

        let db = try SyncDatabase.temporary()
        try await carrega(db, roteiro: roteiro)

        // `m3` é Enviada e nunca vira linha; sobram `m1` e `m4`.
        #expect(try await servidorIDs(db) == ["m1", "m4"])
        #expect(try await estado(db) == .ativa)
        let sync = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: ["accountID": "conta-g", "folderID": ""])
        }
        #expect(sync?.historyID == "9928471")
    }

    @Test("Um 403 no meio é da sessão: aborta e a conta pede reconexão")
    func quatrocentosETresAborta() async throws {
        // O espelho do 404. Autorização retirada não melhora na próxima
        // mensagem: insistir gastaria oitenta e nove requisições para chegar
        // ao mesmo lugar, mais tarde.
        //
        // Quarenta ids e uma janela de quatro: a falha cai na primeira, e o que
        // se afirma é que o laço **para** — a carga não gasta as outras trinta e
        // nove requisições para chegar ao mesmo lugar. Afirmar "a segunda nunca
        // foi pedida" seria afirmar que a busca é sequencial, que é justamente o
        // que ela deixou de ser: as quatro da janela partem juntas, de propósito,
        // e cada resposta consumida solta mais uma até o erro chegar.
        let quantas = 40
        var roteiro: [String: [StubURLProtocol.Reply]] = [
            "/gmail/v1/users/me/profile": [.json(
                "{\"emailAddress\":\"ricardo@gmail.com\",\"historyId\":\"9928471\"}"
            )],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[{\"id\":\"INBOX\",\"name\":\"INBOX\"}]}")],
            "/gmail/v1/users/me/messages": [.json(
                "{\"messages\":[" + (1...quantas).map { "{\"id\":\"m\($0)\"}" }.joined(separator: ",") + "]}"
            )],
        ]
        for numero in 1...quantas {
            roteiro["/gmail/v1/users/me/messages/m\(numero)"] = [.json(mensagemJSON(
                id: "m\(numero)", rotulos: ["INBOX"], assunto: "Assunto \(numero)", corpo: "Corpo."
            ))]
        }
        roteiro["/gmail/v1/users/me/messages/m1"] = [
            .json("{\"error\":{\"code\":403,\"message\":\"Insufficient Permission\"}}", status: 403)
        ]

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let session = StubURLProtocol.session(routes: roteiro)

        await #expect(throws: SyncError.autorizacaoRevogada) {
            try await InitialLoader(database: db).loadGmail(
                account: self.conta, client: self.cliente(session), now: self.agora, progress: { _ in }
            )
        }
        #expect(try await estado(db) == .erroDeAutenticacao)
        // Abortou de verdade: a carga parou logo, em vez de gastar as quarenta.
        let deMensagem = StubURLProtocol.requests(for: session)
            .map(\.path)
            .filter { $0.contains("/messages/m") }
        #expect(deMensagem.count < quantas / 2, "pediu \(deMensagem.count) de \(quantas)")
        // E nada de `historyId`: a carga não terminou, e o Marco 3 não pode
        // partir de um ponto que nunca foi alcançado.
        let sync = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: ["accountID": "conta-g", "folderID": ""])
        }
        #expect(sync == nil)
    }

    @Test("O corpo desce e a busca acha por dentro dele, com acento dobrado")
    func corpoIndexado() async throws {
        let db = try SyncDatabase.temporary()
        try await carrega(db)

        try await db.pool.read { conexao in
            let achados = try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: nil)
            #expect(achados == [MessageIdentity.gmail(accountID: "conta-g", serverID: "m1")])
        }
    }

    @Test("O historyId do profile é guardado para o Marco 3 começar incremental")
    func historyIDGuardado() async throws {
        let db = try SyncDatabase.temporary()
        let (_, session) = try await carrega(db)

        let sync = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: ["accountID": "conta-g", "folderID": ""])
        }
        #expect(sync?.historyID == "9928471")
        #expect(sync?.syncedAt != nil)

        // **Lido antes, guardado depois.** É a ordem que importa, e ela não
        // aparece em nenhum dado do banco: mover o `profile()` para depois da
        // paginação deixaria tudo acima verde e abriria o vão em que uma
        // mensagem chegada durante a carga nunca apareceria — nem aqui (a
        // listagem já passou) nem no incremental do Marco 3 (o `historyId`
        // já a inclui). A prova é a ordem no log de requisições.
        let caminhos = StubURLProtocol.requests(for: session).map(\.path)
        let perfil = try #require(caminhos.firstIndex { $0.hasSuffix("/profile") })
        let listagem = try #require(caminhos.firstIndex { $0.hasSuffix("/messages") })
        #expect(perfil < listagem)
    }

    @Test("A conta termina `ativa` e com carimbo de sincronização")
    func contaTerminaAtiva() async throws {
        let db = try SyncDatabase.temporary()
        try await carrega(db)

        let devolvida = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account
        }
        #expect(devolvida?.state == .ativa)
        #expect(devolvida?.lastSyncedAt == agora)
    }

    @Test("O progresso é relatado, cresce e termina completo")
    func progresso() async throws {
        let db = try SyncDatabase.temporary()
        let (relatos, _) = try await carrega(db, batchSize: 2)

        #expect(!relatos.isEmpty)
        #expect(relatos.allSatisfy { $0.accountID == "conta-g" })
        #expect(relatos.map(\.done) == relatos.map(\.done).sorted())
        #expect(relatos.last?.done == relatos.last?.total)
        #expect(relatos.last?.fraction == 1.0)
        // Conta vazia terminou de carregar — não ficou a 0%.
        #expect(LoadProgress(accountID: "x", done: 0, total: 0).fraction == 1)
    }

    // MARK: A janela de concorrência

    @Test("A busca não é mais em série — e não passa da janela de quatro")
    func buscaConcorrenteComTeto() async throws {
        // Era uma requisição de cada vez: a 50 mil mensagens e um ida-e-volta
        // otimista de 50 ms são 42 minutos de latência de rede quase toda
        // ociosa, e o teto de páginas planeja para 250 mil, onde seriam 3,5 h.
        //
        // As duas metades da afirmação, e a segunda importa tanto quanto a
        // primeira: soltar o lote inteiro de uma vez seriam 50 requisições
        // simultâneas — o caminho mais curto para o 429 que o `GmailClient`
        // traduz como `.quota`.
        //
        // O atraso no roteiro é o que torna a observação possível: com resposta
        // instantânea, uma busca sequencial e uma concorrente registram os
        // mesmos pedidos na mesma ordem, e nada distingue as duas.
        //
        // MUTAÇÃO QUE ISTO PEGA: `janelaDoGmail = 1` derruba o piso (pico == 1,
        // que é a definição de sequencial); `janelaDoGmail = 50` derruba o teto.
        let quantas = 12
        var roteiro: [String: [StubURLProtocol.Reply]] = [
            "/gmail/v1/users/me/profile": [.json(
                "{\"emailAddress\":\"ricardo@gmail.com\",\"historyId\":\"9928471\"}"
            )],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[{\"id\":\"INBOX\",\"name\":\"INBOX\"}]}")],
            "/gmail/v1/users/me/messages": [.json(
                "{\"messages\":[" + (1...quantas).map { "{\"id\":\"m\($0)\"}" }.joined(separator: ",") + "]}"
            )],
        ]
        for numero in 1...quantas {
            roteiro["/gmail/v1/users/me/messages/m\(numero)"] = [.json(
                mensagemJSON(
                    id: "m\(numero)", rotulos: ["INBOX"],
                    assunto: "Assunto \(numero)", corpo: "Corpo de m\(numero)."
                ),
                delay: 0.05
            )]
        }

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let session = StubURLProtocol.session(routes: roteiro)
        try await InitialLoader(database: db).loadGmail(
            account: conta, client: cliente(session), now: agora, progress: { _ in }
        )

        let pico = StubURLProtocol.maxConcurrent(for: session)
        #expect(pico > 1, "pico de \(pico): a busca continua sequencial")
        // O teto é afirmado contra o número **literal**, e não contra
        // `InitialLoader.janelaDoGmail`: comparar a constante com ela mesma
        // moveria o alvo junto com a mutação, e a metade do teto passaria a
        // ser verdadeira por construção — que é a definição do teste inútil
        // que a auditoria deste marco encontrou três vezes.
        #expect(pico <= 4, "pico de \(pico)")
        #expect(InitialLoader.janelaDoGmail == 4)
        // E as doze entraram: concorrência que perde mensagem não é ganho.
        #expect(try await servidorIDs(db).count == quantas)
    }

    @Test("A ordem de gravação do lote é a da listagem, mesmo com as respostas fora de ordem")
    func ordemDeGravacaoPreservada() async throws {
        // As tarefas voltam na ordem em que **respondem**, e não na ordem em que
        // partiram. Gravar nessa ordem faria a ordem das linhas no banco depender
        // da latência de cada requisição — e o `rowid` é o que a busca FTS
        // percorre. Os resultados são recolocados por índice antes de a
        // transação abrir.
        //
        // O roteiro inverte a latência: a primeira da listagem é a que demora
        // mais. Em série isso não muda nada; em paralelo, a última a responder é
        // a que tem de ser gravada primeiro.
        //
        // MUTAÇÃO QUE ISTO PEGA: gravar na ordem de chegada (usar o array
        // acumulado pelo `grupo.next()` em vez do `compactMap` por índice)
        // inverte as linhas.
        let quantas = 8
        var roteiro: [String: [StubURLProtocol.Reply]] = [
            "/gmail/v1/users/me/profile": [.json(
                "{\"emailAddress\":\"ricardo@gmail.com\",\"historyId\":\"9928471\"}"
            )],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[{\"id\":\"INBOX\",\"name\":\"INBOX\"}]}")],
            "/gmail/v1/users/me/messages": [.json(
                "{\"messages\":[" + (1...quantas).map { "{\"id\":\"m\($0)\"}" }.joined(separator: ",") + "]}"
            )],
        ]
        for numero in 1...quantas {
            roteiro["/gmail/v1/users/me/messages/m\(numero)"] = [.json(
                mensagemJSON(
                    id: "m\(numero)", rotulos: ["INBOX"],
                    assunto: "Assunto \(numero)", corpo: "Corpo de m\(numero)."
                ),
                delay: 0.02 * Double(quantas - numero + 1)
            )]
        }

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let session = StubURLProtocol.session(routes: roteiro)
        try await InitialLoader(database: db, batchSize: 4).loadGmail(
            account: conta, client: cliente(session), now: agora, progress: { _ in }
        )

        // `rowid` é a ordem física de inserção — a mesma que o índice FTS
        // percorre quando ninguém manda ordenar.
        let naOrdemGravada = try await db.pool.read { conexao in
            try String.fetchAll(conexao, sql: "SELECT serverID FROM message ORDER BY rowid")
        }
        #expect(naOrdemGravada == (1...quantas).map { "m\($0)" })
    }

    // MARK: A carga que não carregou nada

    @Test("Todas as mensagens falhando é carga FALHA: sem `ativa`, sem historyId")
    func todasAsMensagensFalhandoNaoConclui() async throws {
        // O simétrico do guarda da carga IMAP (`pastasQueFalharam ==
        // comPapel.count`). Sem ele, o laço engolia todo erro "da mensagem" —
        // que inclui `.resposta` e todo 4xx —, e depois gravava o `sync_state`
        // com o `historyId` do perfil e punha a conta em `.ativa`, sem nenhuma
        // condição.
        //
        // O que faz disto perda de dados: o `historyId` é o ponto de partida do
        // Marco 3. Carimbado sobre uma caixa vazia, o incremental parte dali e
        // as mensagens que falharam ficam permanentemente fora do banco.
        var roteiro = roteiroDeSeis()
        for numero in 1...6 {
            roteiro["/gmail/v1/users/me/messages/m\(numero)"] = [
                .json("{\"error\":{\"code\":404,\"message\":\"Requested entity was not found.\"}}", status: 404)
            ]
        }

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let session = StubURLProtocol.session(routes: roteiro)
        await #expect(throws: SyncError.self) {
            try await InitialLoader(database: db).loadGmail(
                account: conta, client: cliente(session), now: agora, progress: { _ in }
            )
        }

        // Nada gravado, e nada carimbado: nem o estado, nem o carimbo de
        // sincronização, nem o ponto de partida do Marco 3.
        #expect(try await servidorIDs(db).isEmpty)
        let devolvida = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account
        }
        // `.ativa`, e não `erroDeAutenticacao` — a mesma resposta que o irmão
        // IMAP dá em `todasAsPastasFalhando`: a credencial não tem nada com
        // isso, e oferecer "Reconectar" seria a ação errada com convicção. O
        // que diz que a carga falhou é o erro que sobe até quem chamou, e a
        // ausência dos dois carimbos abaixo.
        #expect(devolvida?.state == .ativa)
        #expect(devolvida?.lastSyncedAt == nil)
        let sync = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: ["accountID": "conta-g", "folderID": ""])
        }
        #expect(sync == nil)
    }

    @Test("Uma que entra basta: com cinco falhas e uma boa, a carga conclui")
    func umaMensagemBoaBastaParaConcluir() async throws {
        // O contrapeso. O guarda é sobre "nenhuma entrou", e não sobre "alguma
        // falhou" — senão ele engoliria o caso que o `quatrocentosEQuatroNoMeio`
        // já protege, e uma mensagem apagada no navegador passaria a derrubar a
        // carga inteira.
        var roteiro = roteiroDeSeis()
        for numero in 1...5 {
            roteiro["/gmail/v1/users/me/messages/m\(numero)"] = [
                .json("{\"error\":{\"code\":404}}", status: 404)
            ]
        }

        let db = try SyncDatabase.temporary()
        try await carrega(db, roteiro: roteiro)

        #expect(try await servidorIDs(db) == ["m6"])
        #expect(try await estado(db) == .ativa)
        let sync = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: ["accountID": "conta-g", "folderID": ""])
        }
        #expect(sync?.historyID == "9928471")
    }

    // MARK: Falha, cancelamento e o que sobrevive

    @Test("Falha no meio deixa `erroDeAutenticacao` e o que já baixou fica")
    func falhaNoMeio() async throws {
        // Interrompível sem corromper: as transações são por lote, então o que
        // entrou fica, e o estado da conta diz o que houve — em vez de a lista
        // ficar vazia sem explicação.
        var roteiro = roteiroPadrao()
        roteiro["/gmail/v1/users/me/messages/m4"] = [.json("{\"error\":{\"code\":401}}", status: 401)]

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let session = StubURLProtocol.session(routes: roteiro)

        await #expect(throws: SyncError.autenticacao) {
            // Lote de 2 é o que faz a primeira transação fechar antes da
            // falha: com o lote de 50, nada teria sido gravado e a promessa
            // "o que já entrou fica" passaria sem prova nenhuma.
            try await InitialLoader(database: db, batchSize: 2).loadGmail(
                account: self.conta, client: self.cliente(session), now: self.agora, progress: { _ in }
            )
        }
        let estado = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account.state
        }
        #expect(estado == .erroDeAutenticacao)
        let quantas = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(quantas > 0)
    }

    @Test("Rede caída **não** vira `erroDeAutenticacao`")
    func redeNaoDerrubaACredencial() async throws {
        // Sem rota para o profile, o stub dispara `URLError` — falha de
        // transporte. Oferecer "Reconectar" a quem só perdeu o wi-fi é a ação
        // errada com convicção.
        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let session = StubURLProtocol.session(routes: [:])

        await #expect(throws: SyncError.self) {
            try await InitialLoader(database: db).loadGmail(
                account: self.conta, client: self.cliente(session), now: self.agora, progress: { _ in }
            )
        }
        let estado = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account.state
        }
        #expect(estado == .ativa)
    }

    @Test("Uma mensagem defeituosa fica de fora; as outras entram")
    func mensagemDefeituosaNaoDerrubaACarga() async throws {
        // O mesmo princípio do teto da carga IMAP: o que é da mensagem morre
        // na mensagem. Derrubar noventa dias por causa de um JSON torto
        // entregaria uma caixa vazia por causa de um item.
        var roteiro = roteiroPadrao()
        roteiro["/gmail/v1/users/me/messages/m4"] = [.json("{\"id\":\"m4\",\"labelIds\":[\"INBOX\"]}")]

        let db = try SyncDatabase.temporary()
        let (relatos, _) = try await carrega(db, roteiro: roteiro)

        let servidorIDs = try await db.pool.read { conexao in
            Set(try MessageRecord.fetchAll(conexao).compactMap(\.serverID))
        }
        #expect(servidorIDs == ["m1", "m2"])
        let estado = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account.state
        }
        #expect(estado == .ativa)
        // A barra chega ao fim mesmo com a pulada: ela conta o percorrido, não
        // o gravado.
        #expect(relatos.last?.done == 4)
    }

    @Test("O que é da sessão e o que é da mensagem")
    func classificacaoDeErros() {
        #expect(InitialLoader.derrubaACarga(.autenticacao))
        #expect(InitialLoader.derrubaACarga(.quota))
        #expect(InitialLoader.derrubaACarga(.rede("sem rota")))
        #expect(InitialLoader.derrubaACarga(.servidor(codigo: 503, mensagem: "indisponível")))
        #expect(!InitialLoader.derrubaACarga(.resposta("sem payload")))
        // Apagada entre a listagem e a leitura: é dela, e de mais nenhuma.
        #expect(!InitialLoader.derrubaACarga(.servidor(codigo: 404, mensagem: "not found")))
    }

    @Test("Cancelar para em segundos e não corrompe")
    func cancelavel() async throws {
        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let session = StubURLProtocol.session(routes: roteiroPadrao())

        let tarefa = Task {
            try await InitialLoader(database: db).loadGmail(
                account: self.conta, client: self.cliente(session), now: self.agora, progress: { _ in }
            )
        }
        tarefa.cancel()
        _ = try? await tarefa.value
        // O que importa é não travar nem deixar o banco inconsistente: a
        // migração continua íntegra e a contagem é legível.
        let quantas = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(quantas >= 0)
        // E a conta **volta de `carregando`**. Afirmar só
        // `!= .erroDeAutenticacao` passava com o defeito: a escrita de
        // recuperação rodava dentro da tarefa já cancelada, o GRDB lançava
        // `CancellationError` antes de tocar o banco, o `try?` engolia, e a
        // conta ficava presa girando a roda para sempre.
        #expect(try await estado(db) == .ativa)
    }

    // MARK: O replay pós-401

    @Test("Um 401 no meio renova o token e repete a chamada — a carga segue")
    func replayApos401() async throws {
        // Sem isto, um relógio adiantado ou uma revogação no meio matava a
        // carga de noventa dias: o `GoogleAuth` só renova por expiração
        // **local**, e para ele o token ainda estava bom.
        var roteiro = roteiroPadrao()
        roteiro["/gmail/v1/users/me/messages/m4"] = [
            .json("{\"error\":{\"code\":401}}", status: 401),
            .json(mensagemJSON(id: "m4", rotulos: ["Label_7"], assunto: "Quatro", corpo: "Depois.")),
        ]

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let cofre = Cofre("at-velho")
        let session = StubURLProtocol.session(routes: roteiro)

        try await InitialLoader(database: db).loadGmail(
            account: conta,
            client: cliente(session, token: { cofre.token }),
            renewAccessToken: { cofre.renova(para: "at-novo") },
            now: agora, progress: { _ in }
        )

        // A carga terminou inteira, com a mensagem que tinha tomado o 401.
        let servidorIDs = try await db.pool.read { conexao in
            Set(try MessageRecord.fetchAll(conexao).compactMap(\.serverID))
        }
        #expect(servidorIDs == ["m1", "m2", "m4"])
        let estado = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account.state
        }
        #expect(estado == .ativa)

        // Uma renovação, e o replay levou o token **novo** — reenviar o mesmo
        // token vencido tomaria o mesmo 401 e não seria replay nenhum.
        #expect(cofre.renovacoes == 1)
        let tentativas = StubURLProtocol.requests(for: session)
            .filter { $0.path.hasSuffix("/messages/m4") }
        #expect(tentativas.count == 2)
        #expect(tentativas.first?.authorization == "Bearer at-velho")
        #expect(tentativas.last?.authorization == "Bearer at-novo")
    }

    @Test("Dois 401 seguidos são revogação: a conta cai em erro, e sem terceira tentativa")
    func doisQuatrocentoseUmRevogam() async throws {
        var roteiro = roteiroPadrao()
        roteiro["/gmail/v1/users/me/messages/m4"] = [
            .json("{\"error\":{\"code\":401}}", status: 401),
            .json("{\"error\":{\"code\":401}}", status: 401),
        ]

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let cofre = Cofre("at-velho")
        let session = StubURLProtocol.session(routes: roteiro)

        await #expect(throws: SyncError.autorizacaoRevogada) {
            try await InitialLoader(database: db, batchSize: 2).loadGmail(
                account: self.conta,
                client: self.cliente(session, token: { cofre.token }),
                renewAccessToken: { cofre.renova(para: "at-novo") },
                now: self.agora, progress: { _ in }
            )
        }

        let estado = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account.state
        }
        #expect(estado == .erroDeAutenticacao)
        // Uma tentativa, nunca duas: insistir num token de fato revogado é um
        // laço de renovações que o Google trata como abuso.
        #expect(cofre.renovacoes == 1)
        #expect(StubURLProtocol.requests(for: session).filter { $0.path.hasSuffix("/messages/m4") }.count == 2)
        // E o que já tinha entrado continua lá.
        let quantas = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(quantas > 0)
    }

    @Test("O 401 na SEGUNDA página repete a página certa, não a primeira")
    func replayNaPaginacao() async throws {
        // O replay tem de repetir a chamada **como ela era** — com o
        // `pageToken`. Repetida sem ele, a listagem devolveria a primeira
        // página de novo: metade da caixa some, e nada no relato diz por quê.
        var roteiro = roteiroPadrao()
        roteiro["/gmail/v1/users/me/messages"] = [
            .json("{\"messages\":[{\"id\":\"m1\"},{\"id\":\"m2\"}],\"nextPageToken\":\"p2\"}"),
            .json("{\"error\":{\"code\":401}}", status: 401),
            .json("{\"messages\":[{\"id\":\"m3\"},{\"id\":\"m4\"}]}"),
        ]

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let cofre = Cofre("at-velho")
        let session = StubURLProtocol.session(routes: roteiro)

        try await InitialLoader(database: db).loadGmail(
            account: conta,
            client: cliente(session, token: { cofre.token }),
            renewAccessToken: { cofre.renova(para: "at-novo") },
            now: agora, progress: { _ in }
        )

        // As duas páginas entraram inteiras.
        #expect(try await servidorIDs(db) == ["m1", "m2", "m4"])
        #expect(try await estado(db) == .ativa)

        let listagens = StubURLProtocol.requests(for: session).filter { $0.path.hasSuffix("/messages") }
        #expect(listagens.count == 3)
        // Byte a byte a mesma query — só o Bearer muda.
        #expect(listagens[1].query == listagens[2].query)
        #expect((listagens[1].query.removingPercentEncoding ?? "").contains("pageToken=p2"))
        #expect(listagens[1].authorization == "Bearer at-velho")
        #expect(listagens[2].authorization == "Bearer at-novo")
        #expect(cofre.renovacoes == 1)
    }

    @Test("Token de página repetido aborta com explicação, em vez de girar para sempre")
    func paginacaoQueNaoAvanca() async throws {
        // Um servidor (ou um proxy no meio) que devolve sempre o mesmo
        // `nextPageToken` prenderia a carga num laço: `ids` enchendo de
        // repetidos, a segunda etapa nunca começando, a roda girando sem nada
        // no relato. A guarda transforma isso num erro que se lê.
        var roteiro = roteiroPadrao()
        roteiro["/gmail/v1/users/me/messages"] = Array(repeating: .json(
            "{\"messages\":[{\"id\":\"m1\"}],\"nextPageToken\":\"sempre-o-mesmo\"}"
        ), count: 4)

        let db = try SyncDatabase.temporary()
        try await contaNoBanco(db)
        let session = StubURLProtocol.session(routes: roteiro)

        await #expect(throws: SyncError.self) {
            try await InitialLoader(database: db).loadGmail(
                account: self.conta, client: self.cliente(session), now: self.agora, progress: { _ in }
            )
        }
        // Parou na segunda: o token repetido é detectado assim que reaparece.
        #expect(StubURLProtocol.requests(for: session).filter { $0.path.hasSuffix("/messages") }.count == 2)
        // Não é erro de credencial — a conta não pode oferecer "Reconectar"
        // para um defeito de paginação do servidor.
        #expect(try await estado(db) == .ativa)
        #expect(InitialLoader.maxPages == 500)
    }

    @Test("Sem quem renove, o primeiro 401 continua terminal")
    func semRenovadorOQuatrocentoseUmEhTerminal() async throws {
        // O envoltório não inventa uma segunda chance onde não há credencial
        // para renovar: aí o 401 é o que sempre foi.
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/profile": [.json("{\"error\":{\"code\":401}}", status: 401)],
        ])
        let replay = GmailAuthReplay(client: cliente(session))
        await #expect(throws: SyncError.autenticacao) { _ = try await replay.profile() }
        #expect(StubURLProtocol.requests(for: session).count == 1)
    }

    @Test("Falha da própria renovação vale mais que o 401 que a pediu")
    func erroDaRenovacaoPrevalece() async throws {
        // `.rede` no meio do refresh não pode virar "reconecte a conta": a
        // pessoa perderia a conta por causa de wi-fi instável.
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/profile": [.json("{\"error\":{\"code\":401}}", status: 401)],
        ])
        let replay = GmailAuthReplay(client: cliente(session), renew: { throw SyncError.rede("sem rota") })
        await #expect(throws: SyncError.rede("sem rota")) { _ = try await replay.profile() }
    }
}

/// Junta os relatos de progresso vindos da closure `@Sendable`.
private final class Recebedor: @unchecked Sendable {
    private let lock = NSLock()
    private var lista: [LoadProgress] = []

    func registra(_ p: LoadProgress) {
        lock.lock()
        lista.append(p)
        lock.unlock()
    }

    var todos: [LoadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return lista
    }
}

/// O token corrente do teste, e quantas vezes ele foi renovado. É o que
/// permite afirmar que o replay levou o token **novo**, e não o mesmo.
private final class Cofre: @unchecked Sendable {
    private let lock = NSLock()
    private var valor: String
    private var contagem = 0

    init(_ inicial: String) { valor = inicial }

    var token: String {
        lock.lock()
        defer { lock.unlock() }
        return valor
    }

    var renovacoes: Int {
        lock.lock()
        defer { lock.unlock() }
        return contagem
    }

    func renova(para novo: String) {
        lock.lock()
        valor = novo
        contagem += 1
        lock.unlock()
    }
}
