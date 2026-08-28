import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Desligar o grupo de event loops sem bloquear — a mesma razão de
/// `ImapFetchTests`: o `defer` de um teste `async` roda no pool cooperativo, e
/// um bloqueio ali derruba a suíte inteira em silêncio.
private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
    grupo.shutdownGracefully { _ in }
}

@Suite("Carga inicial: IMAP")
struct InitialLoaderImapTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private let conta = Account(
        id: "conta-i", address: "contato@meusite.com", displayName: "Site",
        provider: .imap, host: "meusite",
        tintLightHex: "#397852", tintDarkHex: "#88D1A2",
        imap: ImapEndpoint(host: "127.0.0.1", port: 0, security: .startTLS),
        state: .carregando
    )

    /// Uma linha de `FETCH` de envelope. A hora varia porque a ordem das
    /// mensagens importa: o corpo desce das mais recentes primeiro.
    private func fetchLine(uid: Int64, assunto: String, flags: String, hora: String = "09") -> String {
        "* \(uid) FETCH (UID \(uid) FLAGS (\(flags)) "
        + "INTERNALDATE \"25-Aug-2026 \(hora):00:00 -0300\" "
        + "ENVELOPE (\"Tue, 25 Aug 2026 \(hora):00:00 -0300\" \"\(assunto)\" "
        + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL "
        + "((\"Ricardo\" NIL \"contato\" \"meusite.com\")) NIL NIL NIL NIL))"
    }

    private func selectOK() -> [String] {
        [
            "* 2 EXISTS",
            "* OK [UIDVALIDITY 1755000000] UIDs valid",
            "* OK [UIDNEXT 9003] Predicted next UID",
            "TAG OK [READ-WRITE] SELECT completed",
        ]
    }

    private func roteiro() -> FakeImapServer.Script {
        .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LIST": [
                "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
                "* LIST (\\Archive \\HasNoChildren) \"/\" \"Arquivo\"",
                "* LIST (\\Sent \\HasNoChildren) \"/\" \"Enviados\"",
                "* LIST (\\Noselect \\HasChildren) \"/\" \"Projetos\"",
                "TAG OK LIST completed",
            ],
            "SELECT": selectOK(),
            "UID SEARCH": ["* SEARCH 9001 9002", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                fetchLine(uid: 9_001, assunto: "Revisao pendente", flags: "\\Seen \\Flagged"),
                fetchLine(uid: 9_002, assunto: "Outro", flags: "", hora: "10"),
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ])
    }

    /// Uma carga completa contra um roteiro, do começo ao fim.
    ///
    /// Devolve os relatos de progresso e quantas vezes a sessão precisou ser
    /// refeita — é por este contador que o teto do literal se prova.
    @discardableResult
    private func carrega(
        _ db: SyncDatabase, script: FakeImapServer.Script, reconectando: Bool = true
    ) async throws -> (relatos: [LoadProgress], reconexoes: Int) {
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        // `save` e não `insert`: o teste do UIDVALIDITY trocado carrega duas
        // vezes a mesma conta. Apagá-la entre as cargas não serviria — a
        // cascata levaria as mensagens junto e a limpeza a provar passaria
        // sozinha, sem nunca ter acontecido.
        try await db.pool.write { try AccountRecord(self.conta, createdAt: self.agora).save($0) }

        // `allowInsecure: true` porque o servidor falso fala em claro: é a
        // versão `internal` do `connect`, a mesma que os testes da Task 10 usam.
        let abre: @Sendable () async throws -> ImapSession = {
            let nova = try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                group: grupo, allowInsecure: true, teto: .seconds(5)
            )
            try await nova.login(user: self.conta.address, password: "senha-de-app")
            return nova
        }
        let sessao = try await abre()

        let contador = Contador()
        let refaz: @Sendable () async throws -> ImapSession = {
            contador.mais()
            return try await abre()
        }
        let recebidos = RecebedorImap()
        try await InitialLoader(database: db).loadImap(
            account: conta, session: sessao, now: agora,
            reconnect: reconectando ? refaz : nil,
            progress: { p in recebidos.registra(p) }
        )
        await sessao.logout()
        return (recebidos.todos, contador.total)
    }

    // MARK: As pastas

    @Test("Só as pastas com papel de triagem são carregadas — Enviados e Noselect ficam de fora")
    func pastasCarregadas() async throws {
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())

        let pastas = try await db.pool.read { conexao -> [String: String] in
            var mapa: [String: String] = [:]
            for registro in try FolderRecord.fetchAll(conexao) { mapa[registro.serverName] = registro.role }
            return mapa
        }
        #expect(pastas["INBOX"] == "inbox")
        #expect(pastas["Arquivo"] == "archive")
        // Enviados existe no servidor e fica fora da triagem — a caixa
        // Enviadas não existe neste marco.
        #expect(pastas["Enviados"] == nil)
        // Noselect é nó da árvore; SELECT nele devolveria NO.
        #expect(pastas["Projetos"] == nil)
    }

    // MARK: As mensagens

    @Test("Os envelopes viram mensagens com o id que carrega pasta e UIDVALIDITY")
    func mensagensGravadas() async throws {
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())

        let ids = try await db.pool.read { try String.fetchSet($0, sql: "SELECT id FROM message") }
        let esperado = MessageIdentity.imap(
            accountID: "conta-i",
            folderID: FolderRecord.id(accountID: "conta-i", serverName: "INBOX"),
            uidValidity: 1_755_000_000, uid: 9_001
        )
        #expect(ids.contains(esperado))

        let registro = try await db.pool.read { try MessageRecord.fetchOne($0, key: esperado) }
        #expect(registro?.uidValidity == 1_755_000_000)
        #expect(registro?.serverID == "9001")
        #expect(registro?.bucket == "hoje")
        #expect(registro?.fromAddress == "marina@clientepremium.com")
    }

    @Test("`\\Seen` e `\\Flagged` viram as mesmas duas bandeiras do Gmail")
    func bandeirasDoImap() async throws {
        // A regra mora em `TriageProjection`, junto da variante do Gmail. Aqui
        // se prova que ela atravessou o fio inteiro: sem isso, a caixa IMAP
        // abriria toda não lida e a bandeira que a pessoa pôs no webmail
        // sumiria na primeira abertura do app.
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())

        let folderID = FolderRecord.id(accountID: "conta-i", serverName: "INBOX")
        let lida = try await db.pool.read {
            try MessageRecord.fetchOne($0, key: MessageIdentity.imap(
                accountID: "conta-i", folderID: folderID, uidValidity: 1_755_000_000, uid: 9_001
            ))
        }
        #expect(lida?.isRead == true)
        #expect(lida?.isFlagged == true)

        let naoLida = try await db.pool.read {
            try MessageRecord.fetchOne($0, key: MessageIdentity.imap(
                accountID: "conta-i", folderID: folderID, uidValidity: 1_755_000_000, uid: 9_002
            ))
        }
        #expect(naoLida?.isRead == false)
        #expect(naoLida?.isFlagged == false)
    }

    @Test("A caixa de arquivo cai em `arquivar`, e não em `hoje`")
    func projecaoPorPasta() async throws {
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())
        let buckets = try await db.pool.read { try String.fetchSet($0, sql: "SELECT DISTINCT bucket FROM message") }
        #expect(buckets == ["hoje", "arquivar"])
    }

    // MARK: O UIDVALIDITY

    @Test("O UIDVALIDITY de cada pasta é guardado para o Marco 3")
    func uidValidityGuardado() async throws {
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())

        let estado = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: [
                "accountID": "conta-i",
                "folderID": FolderRecord.id(accountID: "conta-i", serverName: "INBOX"),
            ])
        }
        #expect(estado?.uidValidity == 1_755_000_000)
        #expect(estado?.highestUID == 9_002)
    }

    @Test("UIDVALIDITY trocada apaga as mensagens velhas daquela pasta antes de gravar as novas")
    func uidValidityTrocadaLimpa() async throws {
        // Sem isto, a pasta ficaria com duas gerações de UID convivendo: a
        // lista mostraria cada mensagem duas vezes, com assuntos diferentes
        // sob o mesmo UID.
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())
        let antes = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(antes == 4)

        var novo = roteiro()
        novo.replies["SELECT"] = [
            "* 2 EXISTS",
            "* OK [UIDVALIDITY 1999999999] UIDs valid",
            "* OK [UIDNEXT 3] Predicted next UID",
            "TAG OK [READ-WRITE] SELECT completed",
        ]
        _ = try await carrega(db, script: novo)

        let validades = try await db.pool.read { try Int64.fetchSet($0, sql: "SELECT DISTINCT uidValidity FROM message") }
        #expect(validades == [1_999_999_999])
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 4)
    }

    // MARK: Os corpos

    @Test("Os corpos das mais recentes descem, e a busca acha por dentro deles")
    func corposDescem() async throws {
        var script = roteiro()
        // O `UID FETCH` de corpo usa o mesmo verbo; o roteiro devolve o mesmo
        // bloco, e o `bodyText` filtra pelo uid pedido. O que importa aqui é
        // que a linha de corpo chega e é indexada.
        script.replies["UID FETCH"] = [
            fetchLine(uid: 9_001, assunto: "Revisao pendente", flags: "\\Seen"),
            fetchLine(uid: 9_002, assunto: "Outro", flags: "", hora: "10"),
            "* 1 FETCH (UID 9001 BODY[TEXT] \"A revisão do contrato ficou pronta.\")",
            "TAG OK UID FETCH completed",
        ]
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: script)

        try await db.pool.read { conexao in
            let achados = try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: nil)
            #expect(!achados.isEmpty)
        }
    }

    @Test("Um corpo acima do teto do literal custa aquele corpo — a carga reconecta e segue")
    func corpoAcimaDoTetoNaoDerrubaACarga() async throws {
        // O teto de 8 MiB é fatal para a **sessão** por construção: depois de
        // recusar o literal ninguém sabe mais onde a resposta acaba e o
        // protocolo começa, e o canal cai. Fatal para a sessão não pode ser
        // fatal para a carga — uma mensagem gigante numa caixa de noventa dias
        // deixaria a pessoa sem caixa nenhuma.
        var script = roteiro()
        script.rounds[FakeImapServer.chaveDeCorpo] = [
            // O tamanho vem no cabeçalho: o decodificador recusa antes de
            // reservar um byte, e a mensagem de erro leva o tamanho e o UID.
            ["* 1 FETCH (UID 9002 BODY[TEXT] {9000000}"],
            [
                // Literal contado em bytes, como um servidor de verdade manda:
                // "revisão" tem um `ã`, e 35 caracteres são 36 bytes.
                "* 1 FETCH (UID 9001 BODY[TEXT] {36}\r\nA revisão do contrato ficou pronta.)",
                "TAG OK UID FETCH completed",
            ],
        ]

        let db = try SyncDatabase.temporary()
        let (relatos, reconexoes) = try await carrega(db, script: script)

        // A sessão morreu uma vez, e foi refeita uma vez. Sem a reconexão, o
        // comando seguinte cairia em `.rede` e derrubaria a conta inteira.
        #expect(reconexoes == 1)
        #expect(relatos.last?.fraction == 1.0)

        let devolvida = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account }
        #expect(devolvida?.state == .ativa)

        // Os quatro envelopes entraram — inclusive o da mensagem cujo corpo
        // ficou de fora.
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 4)

        let folderID = FolderRecord.id(accountID: "conta-i", serverName: "INBOX")
        func corpo(uid: Int64) async throws -> [String] {
            let id = MessageIdentity.imap(
                accountID: "conta-i", folderID: folderID, uidValidity: 1_755_000_000, uid: uid
            )
            return try await db.pool.read {
                try MessageBodyRecord.filter(Column("messageID") == id).fetchOne($0)?.body ?? []
            }
        }
        // O corpo que estourou o teto ficou de fora; o da mensagem seguinte,
        // pedido já na sessão nova, desceu inteiro.
        #expect(try await corpo(uid: 9_002).isEmpty)
        #expect(try await corpo(uid: 9_001) == ["A revisão do contrato ficou pronta."])
    }

    // MARK: Erro por pasta

    @Test("Uma pasta que o servidor recusa não leva as outras junto")
    func pastaQueFalhaNaoDerrubaAsOutras() async throws {
        var script = roteiro()
        // O primeiro SELECT (INBOX) falha; os seguintes, não.
        script.rounds["SELECT"] = [["TAG NO [NONEXISTENT] Mailbox doesn't exist"], selectOK()]

        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: script)

        let pastas = try await db.pool.read { try String.fetchSet($0, sql: "SELECT serverName FROM folder") }
        #expect(pastas == ["Arquivo"])
        let buckets = try await db.pool.read { try String.fetchSet($0, sql: "SELECT DISTINCT bucket FROM message") }
        #expect(buckets == ["arquivar"])

        let devolvida = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account }
        #expect(devolvida?.state == .ativa)
    }

    @Test("Todas as pastas recusadas é carga falhada — não uma conta ativa com a caixa vazia")
    func todasAsPastasFalhando() async throws {
        var script = roteiro()
        script.replies["SELECT"] = ["TAG NO [NONEXISTENT] Mailbox doesn't exist"]
        let db = try SyncDatabase.temporary()

        await #expect(throws: (any Error).self) { _ = try await self.carrega(db, script: script) }
        // `.ativa`, e não `erroDeAutenticacao`: a credencial não tem nada com
        // isso, e oferecer "Reconectar" seria a ação errada com convicção.
        let estado = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account.state }
        #expect(estado == .ativa)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
    }

    // MARK: O fim

    @Test("A conta termina `ativa`, com carimbo, e o progresso chega ao fim")
    func terminaAtiva() async throws {
        let db = try SyncDatabase.temporary()
        let (relatos, _) = try await carrega(db, script: roteiro())

        let devolvida = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account }
        #expect(devolvida?.state == .ativa)
        #expect(devolvida?.lastSyncedAt == agora)
        #expect(relatos.last?.fraction == 1.0)
    }

    @Test("Senha recusada deixa a conta em `erroDeAutenticacao`")
    func senhaRecusada() async throws {
        var script = roteiro()
        script.replies["LIST"] = ["TAG NO [AUTHENTICATIONFAILED] Invalid credentials"]
        let db = try SyncDatabase.temporary()

        await #expect(throws: (any Error).self) { _ = try await self.carrega(db, script: script) }
        let estado = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account.state }
        #expect(estado == .erroDeAutenticacao)
    }
}

private final class RecebedorImap: @unchecked Sendable {
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

/// Quantas vezes a carga pediu uma sessão nova.
private final class Contador: @unchecked Sendable {
    private let lock = NSLock()
    private var quantas = 0

    func mais() {
        lock.lock()
        quantas += 1
        lock.unlock()
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return quantas
    }
}
