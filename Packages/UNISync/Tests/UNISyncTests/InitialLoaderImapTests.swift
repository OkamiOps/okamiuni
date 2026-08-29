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

    /// Os comandos que o servidor recebeu, sem a tag na frente.
    private func semTag(_ comandos: [String]) -> [String] {
        comandos.map { linha in
            linha.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        }
    }

    /// Uma carga completa contra um roteiro, do começo ao fim.
    ///
    /// Devolve os relatos de progresso, quantas vezes a sessão precisou ser
    /// refeita — é por este contador que o teto do literal se prova — e o log
    /// de comandos do servidor, que é onde a **ordem** se prova: o servidor
    /// falso responde `UID FETCH` igual em qualquer pasta, então buscar na
    /// pasta errada não aparece em nenhuma asserção sobre o banco.
    @discardableResult
    private func carrega(
        _ db: SyncDatabase, script: FakeImapServer.Script, reconectando: Bool = true
    ) async throws -> (relatos: [LoadProgress], reconexoes: Int, comandos: [String]) {
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
        return (recebidos.todos, contador.total, semTag(servidor.commands))
    }

    // MARK: As pastas

    @Test("Todas as pastas de verdade são carregadas — Enviados com o papel dela, Noselect fora")
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
        // Enviados entra, com o papel dela. Ficava de fora do banco inteiro
        // enquanto não havia caixa Enviadas; agora ela tem a sua, e o que a
        // pessoa mandou de outro cliente aparece aqui também.
        #expect(pastas["Enviados"] == "sent")
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

    /// A ponta a ponta do primeiro teste com conta real: `\Seen` sai do
    /// servidor, atravessa `ImapWire`, `InitialLoader` grava, `SyncDatabase`
    /// guarda, `DatabaseMailSource` lê de volta e `MailStore.unreadCount`
    /// enxerga a diferença entre lida e não lida.
    ///
    /// Esta é a mutação vermelha do item 1: se `TriageProjection.isRead
    /// (imapFlags:)` voltasse a inverter a regra (ou se `InitialLoader`
    /// deixasse de gravar `envelope.isRead`), as duas mensagens nasceriam
    /// com o mesmo `isRead`, `unreadCount` bateria com `count(for:)` e este
    /// teste veria 2 em vez de 1.
    @Test("o contador de não lidas do MailStore reflete o \\Seen que veio do servidor")
    @MainActor
    func naoLidasAtravessamOFioAteOMailStore() async throws {
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())

        let source = DatabaseMailSource(database: db)
        let store = MailStore(source: source)
        await store.load()

        #expect(store.count(for: .today) == 2)
        #expect(store.unreadCount(in: .today) == 1)
    }

    @Test("A segunda passada reseleciona a pasta antes de buscar nela")
    func segundaPassadaReseleciona() async throws {
        // `UID FETCH` age sobre a pasta corrente, e a primeira passada termina
        // com a **última** pasta selecionada. Sem reselecionar, os envelopes da
        // Entrada viriam do Arquivo — e o servidor não avisaria: as mensagens
        // entrariam no banco, com a pasta errada gravada ao lado. É um defeito
        // que nenhuma asserção sobre o banco enxerga, só a ordem do fio.
        let db = try SyncDatabase.temporary()
        let (_, _, comandos) = try await carrega(db, script: roteiro())

        let primeiroEnvelope = try #require(comandos.firstIndex {
            $0.hasPrefix("UID FETCH") && !$0.contains("BODY.PEEK")
        })
        let selectAnterior = try #require(comandos[..<primeiroEnvelope].lastIndex {
            $0.hasPrefix("SELECT ")
        })
        #expect(comandos[selectAnterior] == "SELECT \"INBOX\"")
    }

    @Test("A caixa de arquivo cai em `arquivar`, e não em `hoje`")
    func projecaoPorPasta() async throws {
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())
        let buckets = try await db.pool.read { try String.fetchSet($0, sql: "SELECT DISTINCT bucket FROM message") }
        // Três pastas, três caixas — e Enviados na dela, que não é Arquivado:
        // enfiar o que a pessoa escreveu no arquivo dela era a outra saída, e
        // é a que o `TriageProjection` recusa.
        #expect(buckets == ["hoje", "arquivar", "enviadas"])
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
        // Seis: duas mensagens em cada uma das três pastas (INBOX, Arquivo e
        // Enviados — que passou a entrar quando a caixa Enviadas nasceu).
        #expect(antes == 6)

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
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 6)
    }

    @Test("A geração velha só sai junto com a nova: a pasta nunca fica vazia")
    func apagamentoViajaComOPrimeiroLote() async throws {
        // MENOR M2 DO RELATÓRIO DE BANCO: o `DELETE` da geração velha fechava
        // a transação dele **antes** do download. Entre ele e a primeira
        // gravação havia um SELECT, um UID FETCH de todos os UIDs da janela e o
        // download dos corpos — minutos. App morto (ou rede caída) nessa janela
        // deixava a pasta vazia na tela, com a conta em `.ativa`.
        //
        // A prova é a ORDEM NO FIO: o apagamento tem de acontecer depois do
        // `UID FETCH`, e não antes. Como ele agora viaja dentro da transação do
        // primeiro lote, isso é o mesmo que dizer que ele acontece junto com a
        // primeira gravação.
        //
        // MUTAÇÃO QUE ISTO PEGA: devolver o `DELETE` para a transação de cima
        // (junto com o `save` da pasta).
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: roteiro())
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 6)

        // Segunda carga, com a geração reciclada — e um servidor que **não
        // responde** ao UID FETCH da INBOX: a carga morre no meio, exatamente
        // na janela que o defeito abria.
        var novo = roteiro()
        novo.replies["SELECT"] = [
            "* 2 EXISTS",
            "* OK [UIDVALIDITY 1999999999] UIDs valid",
            "* OK [UIDNEXT 3] Predicted next UID",
            "TAG OK [READ-WRITE] SELECT completed",
        ]
        novo.replies["UID FETCH"] = ["TAG NO Servidor indisponível"]
        _ = try? await carrega(db, script: novo)

        // As seis velhas continuam lá. Antes, o `DELETE` já teria passado e a
        // pessoa veria as pastas vazias — sem nada ter chegado no lugar.
        #expect(
            try await db.pool.read { try MessageRecord.fetchCount($0) } == 6,
            "a pasta ficou vazia entre o apagamento e o download"
        )
        let validades = try await db.pool.read {
            try Int64.fetchSet($0, sql: "SELECT DISTINCT uidValidity FROM message")
        }
        #expect(validades == [1_755_000_000])
    }

    @Test("A pasta que a pessoa criou entra, em Arquivado, com o nome como etiqueta")
    func pastaDoUsuarioEntraComEtiqueta() async throws {
        // A divergência que isto fecha: o IMAP EXCLUÍA explicitamente toda pasta
        // sem papel nosso, e a conta Gmail ao lado incluía todo rótulo do
        // usuário (caindo em Arquivado). A mesma pessoa, com uma pasta "Faturas"
        // nas duas contas, via as faturas do Gmail e nenhuma das do IMAP — duas
        // respostas opostas para a pergunta que o `TriageProjection` existe para
        // responder uma vez só.
        //
        // MUTAÇÃO QUE ISTO PEGA: devolver o `&& pasta.role != .other` ao filtro
        // some com as duas mensagens; trocar `case .other: .archived` por
        // `.trash` em `TriageProjection` muda o bucket gravado; e apagar o
        // `TriageProjection.tag` deixa a linha sem etiqueta nenhuma.
        var script = roteiro()
        script.replies["LIST"] = [
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
            "* LIST (\\HasNoChildren) \"/\" \"Faturas\"",
            "TAG OK LIST completed",
        ]
        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: script)

        let daPasta = try await db.pool.read { conexao in
            try MessageRecord
                .filter(Column("folderID") == "conta-i/Faturas")
                .fetchAll(conexao)
                .map { $0.message(body: []) }
        }
        #expect(daPasta.count == 2)
        #expect(daPasta.allSatisfy { $0.bucket == .archived })
        // A etiqueta é o que salva a informação que a pasta carregava: sem ela,
        // cair em Arquivado apagaria a organização da pessoa.
        #expect(daPasta.allSatisfy { $0.tags.map(\.name) == ["Faturas"] })

        // E a INBOX continua sendo a INBOX: o nome dela é estrutura, não
        // etiqueta. "Entrada" etiquetada como "INBOX" seria ruído.
        let daEntrada = try await db.pool.read { conexao in
            try MessageRecord
                .filter(Column("folderID") == "conta-i/INBOX")
                .fetchAll(conexao)
                .map { $0.message(body: []) }
        }
        #expect(daEntrada.allSatisfy { $0.tags.isEmpty })
        #expect(daEntrada.allSatisfy { $0.bucket == .today })
    }

    @Test("UIDVALIDITY que troca DENTRO da carga aborta a pasta em vez de carimbar errado")
    func uidValidityTrocadaNoMeioDaCarga() async throws {
        // O `uidValidityTrocadaLimpa` acima cobre a troca **entre duas cargas**.
        // Esta é a troca **dentro de uma**: o `select` da segunda passada
        // devolvia um status novo e o `_ =` o jogava fora, então tudo — o id da
        // mensagem, a coluna `uidValidity`, o `sync_state` — continuava vindo do
        // status da primeira passada.
        //
        // A janela não é instantânea: entre as duas leituras cabem a primeira
        // passada inteira e o download completo de todas as pastas anteriores.
        // Minutos, numa conta com várias pastas.
        //
        // Sem conferir, a segunda passada baixa a geração NOVA e a grava com o
        // número da VELHA: o banco fica com o assunto certo sob o UID errado,
        // que é exatamente o defeito que pôr o UIDVALIDITY no `MessageIdentity`
        // existe para impedir.
        //
        // MUTAÇÃO QUE ISTO PEGA: voltar o `_ = try await sessao.select(pasta)`
        // faz a carga terminar sem erro nenhum e gravar quatro mensagens
        // carimbadas com a geração velha.
        var script = roteiro()
        // A ordem dos SELECT é: as três pastas na primeira passada, as três na
        // segunda. O quarto — o reselect da INBOX — recicla.
        let velho = selectOK()
        let reciclado = [
            "* 2 EXISTS",
            "* OK [UIDVALIDITY 1999999999] UIDs valid",
            "* OK [UIDNEXT 9003] Predicted next UID",
            "TAG OK [READ-WRITE] SELECT completed",
        ]
        // Três pastas: a primeira passada gasta três SELECT (INBOX, Arquivo,
        // Enviados), e o **quarto** é o reselect da INBOX — o que recicla.
        script.rounds["SELECT"] = [velho, velho, velho, reciclado, velho]

        let db = try SyncDatabase.temporary()
        _ = try await carrega(db, script: script)

        // A INBOX foi abortada; o Arquivo, cujo reselect devolveu a geração de
        // sempre, entrou inteiro. Nenhuma linha com a geração velha e conteúdo
        // da nova: a INBOX simplesmente não tem linha.
        let porPasta = try await db.pool.read { conexao in
            try Row.fetchAll(conexao, sql: "SELECT folderID, count(*) AS quantas FROM message GROUP BY folderID")
                .map { ($0["folderID"] as String, $0["quantas"] as Int) }
        }
        #expect(porPasta.map(\.0) == ["conta-i/Arquivo", "conta-i/Enviados"])
        #expect(porPasta.first?.1 == 2)

        // E o `sync_state` da INBOX não foi carimbado: é ele que faz a próxima
        // carga detectar a troca, apagar e recomeçar a pasta do zero.
        let daInbox = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(
                conexao, key: ["accountID": "conta-i", "folderID": "conta-i/INBOX"]
            )
        }
        #expect(daInbox == nil)
        // A conta não é derrubada por causa de uma pasta: o Arquivo entrou.
        let estado = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account.state }
        #expect(estado == .ativa)
    }

    // MARK: Os corpos

    @Test("Só os 50 corpos mais recentes da pasta descem — não a pasta inteira")
    func tetoDeCorposNoImap() async throws {
        // LACUNA DA AUDITORIA (G-b): remover o `prefix(Self.fullBodyCount)` de
        // `corposDe` deixava os 206 testes verdes. Numa pasta de 90 dias isso é
        // um `UID FETCH BODY.PEEK` por mensagem, em série, com o corpo inteiro
        // atravessando o fio.
        //
        // A prova é no **fio**: quantos comandos de corpo o servidor recebeu.
        // Contar corpos no banco não bastaria — o roteiro responde o mesmo bloco
        // a todos, e o `bodyText` filtra pelo uid pedido.
        //
        // MUTAÇÃO QUE ISTO PEGA: tirar o `prefix(Self.fullBodyCount)`.
        let quantas = InitialLoader.fullBodyCount + 10
        var script = roteiro()
        // Uma pasta só, para a contagem ser da pasta e não da conta.
        script.replies["LIST"] = [
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
            "TAG OK LIST completed",
        ]
        script.replies["UID SEARCH"] = [
            "* SEARCH " + (1...quantas).map { String(9_000 + $0) }.joined(separator: " "),
            "TAG OK UID SEARCH completed",
        ]
        script.replies["UID FETCH"] = (1...quantas).map { numero in
            fetchLine(
                uid: Int64(9_000 + numero), assunto: "Assunto \(numero)", flags: "",
                // A hora decide quais são "as mais recentes"; o roteiro faz a
                // ordem de data ser o contrário da ordem de UID, para o teste
                // não passar por acidente de ordenação.
                hora: String(format: "%02d", 23 - (numero % 24))
            )
        } + ["TAG OK UID FETCH completed"]
        // A chave de corpo separada: é ela que o `bodyText` aciona.
        script.replies[FakeImapServer.chaveDeCorpo] = [
            "* 1 FETCH (UID 9001 BODY[TEXT] \"Um corpo qualquer.\")",
            "TAG OK UID FETCH completed",
        ]

        let db = try SyncDatabase.temporary()
        let (_, _, comandos) = try await carrega(db, script: script)

        let pedidosDeCorpo = comandos.filter { $0.uppercased().contains("BODY.PEEK") }
        #expect(
            pedidosDeCorpo.count == InitialLoader.fullBodyCount,
            "pediu \(pedidosDeCorpo.count) corpos de \(quantas) mensagens"
        )
        // E todas as mensagens entraram: o teto é dos corpos, não dos envelopes.
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == quantas)
    }


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
        let (relatos, reconexoes, comandos) = try await carrega(db, script: script)

        // A sessão morreu uma vez, e foi refeita uma vez. Sem a reconexão, o
        // comando seguinte cairia em `.rede` e derrubaria a conta inteira.
        #expect(reconexoes == 1)
        #expect(relatos.last?.fraction == 1.0)

        // A conexão nova nasce sem pasta selecionada: entre o segundo LOGIN e
        // o primeiro corpo pedido depois dele tem de haver um SELECT da pasta.
        // Sem ele o resto dos corpos viria da caixa errada, calado — e o banco
        // ficaria idêntico, porque o servidor falso responde igual em qualquer
        // pasta. É por isso que a prova mora na ordem dos comandos.
        let logins = comandos.indices.filter { comandos[$0].hasPrefix("LOGIN ") }
        #expect(logins.count == 2)
        let segundoLogin = try #require(logins.last)
        let corpoDepois = try #require(comandos.indices.first {
            $0 > segundoLogin && comandos[$0].contains("BODY.PEEK")
        })
        #expect(comandos[segundoLogin..<corpoDepois].contains("SELECT \"INBOX\""))

        let devolvida = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account }
        #expect(devolvida?.state == .ativa)

        // Os envelopes das três pastas entraram — inclusive o da mensagem cujo
        // corpo ficou de fora.
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 6)

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
        #expect(pastas == ["Arquivo", "Enviados"])
        let buckets = try await db.pool.read { try String.fetchSet($0, sql: "SELECT DISTINCT bucket FROM message") }
        #expect(buckets == ["arquivar", "enviadas"])

        let devolvida = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account }
        #expect(devolvida?.state == .ativa)
    }

    @Test("Pasta que morre na segunda passada não deixa a barra parada no meio")
    func pastaQueFalhaDepoisDoDenominadorFechado() async throws {
        // O denominador é fechado na primeira passada, com os UIDs de todas as
        // pastas dentro. Uma pasta que morre **depois** disso levaria os UIDs
        // dela para o buraco: a barra pararia em 0,5 com a conta dizendo
        // "pronto", e nada mais chegaria para movê-la.
        var script = roteiro()
        // Passada 1: as três pastas passam. Passada 2: a INBOX morre — é o
        // quarto SELECT, e não o terceiro, desde que Enviados entrou na carga.
        script.rounds["SELECT"] = [
            selectOK(), selectOK(), selectOK(),
            ["TAG NO [NONEXISTENT] Mailbox doesn't exist"],
            selectOK(),
        ]

        let db = try SyncDatabase.temporary()
        let (relatos, _, _) = try await carrega(db, script: script)

        #expect(relatos.last?.fraction == 1.0)
        let devolvida = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account }
        #expect(devolvida?.state == .ativa)
        // A pasta que morreu não gravou mensagem nenhuma — é isso, e não a
        // barra, que conta a história dela.
        let buckets = try await db.pool.read { try String.fetchSet($0, sql: "SELECT DISTINCT bucket FROM message") }
        #expect(buckets == ["arquivar", "enviadas"])
    }

    // MARK: Sem reconexão

    @Test("Sem fecho de reconexão, o corpo é pulado e ninguém tenta entrar de novo")
    func semReconexaoOCorpoEhPuladoEmSilencio() async throws {
        // `reconnect` é opcional, e o que ele faz quando é nulo tem de ser
        // dito: o corpo continua sendo pulado, e a carga **não** abre conexão
        // nenhuma pelas costas de quem não pediu.
        var script = roteiro()
        script.rounds[FakeImapServer.chaveDeCorpo] = [
            ["* 1 FETCH (UID 9002 BODY[TEXT] {9000000}"],
            [
                "* 1 FETCH (UID 9001 BODY[TEXT] {36}\r\nA revisão do contrato ficou pronta.)",
                "TAG OK UID FETCH completed",
            ],
        ]

        let db = try SyncDatabase.temporary()
        let (relatos, reconexoes, comandos) = try await carrega(db, script: script, reconectando: false)

        #expect(reconexoes == 0)
        #expect(comandos.filter { $0.hasPrefix("LOGIN ") }.count == 1)

        // A Entrada gravou os envelopes que já tinha em mãos; o Arquivo veio
        // depois da conexão morta e ficou de fora — e a barra ainda assim
        // fecha, pelo desconto do erro por pasta.
        #expect(relatos.last?.fraction == 1.0)
        let devolvida = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account }
        #expect(devolvida?.state == .ativa)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 2)
        #expect(try await db.pool.read { try MessageBodyRecord.fetchCount($0) } == 0)
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
        let (relatos, _, _) = try await carrega(db, script: roteiro())

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
