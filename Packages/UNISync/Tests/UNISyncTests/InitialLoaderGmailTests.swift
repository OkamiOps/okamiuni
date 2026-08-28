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
        try await carrega(db)

        let estado = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: ["accountID": "conta-g", "folderID": ""])
        }
        #expect(estado?.historyID == "9928471")
        #expect(estado?.syncedAt != nil)
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
        let estado = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account.state
        }
        // Cancelar não é defeito de credencial.
        #expect(estado != .erroDeAutenticacao)
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
