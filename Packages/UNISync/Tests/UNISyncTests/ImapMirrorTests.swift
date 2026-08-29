import Foundation
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// O espelho da triagem no IMAP, contra o servidor falso do pacote. Nenhuma
/// destas afirmações toca rede externa: o servidor roda em `127.0.0.1`, dentro
/// do processo do teste.
@Suite("O espelho da triagem no IMAP")
struct ImapMirrorTests {
    private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
        grupo.shutdownGracefully { _ in }
    }

    /// A lista de pastas que quase todos estes roteiros devolvem.
    private static let pastas = [
        #"* LIST (\HasNoChildren \Inbox) "/" "INBOX""#,
        #"* LIST (\HasNoChildren \Archive) "/" "Arquivo""#,
        #"* LIST (\HasNoChildren \Trash) "/" "Lixeira""#,
        "TAG OK LIST completo",
    ]

    private static let selecionada = [
        "* 3 EXISTS",
        "* OK [UIDVALIDITY 42] UIDs valid",
        "* OK [UIDNEXT 9010] Próximo",
        "TAG OK [READ-WRITE] SELECT completo",
    ]

    private func conecta(
        porta: Int, grupo: MultiThreadedEventLoopGroup, teto: TimeAmount = .seconds(5)
    ) async throws -> ImapSession {
        // `allowInsecure: true` porque o servidor falso fala em claro — a mesma
        // porta `internal` que os testes de IMAP já usam.
        try await ImapSession.connect(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo, allowInsecure: true, teto: teto
        )
    }

    private func alvo(_ uid: Int64, pasta: String = "INBOX") -> MessageCoordinate {
        .imap(folderName: pasta, uidValidity: 42, uid: uid)
    }

    // MARK: - As bandeiras

    @Test("Marcar como lida vira um UID STORE com \\Seen")
    func lida() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "SELECT": Self.selecionada,
            "UID STORE": ["TAG OK STORE completo"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let espelho = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await espelho.apply(
            .setRead(isRead: true, messageIDs: ["a", "b"]),
            targets: [alvo(9001), alvo(9002)]
        )

        // Um `STORE` só para as duas: o agrupamento por pasta é o que faz N
        // mensagens virarem uma ida e volta.
        let stores = servidor.commands.filter { $0.contains("UID STORE") }
        #expect(stores.count == 1)
        #expect(stores[0].hasSuffix(#"UID STORE 9001,9002 +FLAGS.SILENT (\Seen)"#))
    }

    @Test("Desmarcar sinalizada tira \\Flagged")
    func desinaliza() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "SELECT": Self.selecionada,
            "UID STORE": ["TAG OK STORE completo"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let espelho = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await espelho.apply(
            .setFlagged(isFlagged: false, messageIDs: ["a"]), targets: [alvo(9001)]
        )
        #expect(servidor.commands.contains { $0.hasSuffix(#"UID STORE 9001 -FLAGS.SILENT (\Flagged)"#) })
    }

    // MARK: - As caixas

    @Test("Arquivar copia para a pasta de arquivo e expurga a origem")
    func arquiva() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LIST": Self.pastas,
            "SELECT": Self.selecionada,
            "UID SEARCH": ["* SEARCH 9001", "TAG OK SEARCH completo"],
            FakeImapServer.chaveDeCabecalho: [
                "* 1 FETCH (UID 9001 BODY[HEADER.FIELDS (MESSAGE-ID)] {40}",
                "Message-ID: <abc@clientepremium.com>",
                "",
                ")",
                "TAG OK FETCH completo",
            ],
            FakeImapServer.chaveDeBuscaPorHeader: ["* SEARCH", "TAG OK SEARCH completo"],
            "UID COPY": ["TAG OK COPY completo"],
            "UID STORE": ["TAG OK STORE completo"],
            "EXPUNGE": ["TAG OK EXPUNGE completo"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let espelho = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await espelho.apply(
            .move(bucket: TriageBucket.archived.rawValue, messageIDs: ["a"]), targets: [alvo(9001)]
        )

        // O papel `\Archive` é quem escolhe a pasta — não o nome dela, que aqui
        // é "Arquivo" e noutro provedor é "All Mail".
        #expect(servidor.commands.contains { $0.hasSuffix(#"UID COPY 9001 "Arquivo""#) })
        #expect(servidor.commands.contains { $0.hasSuffix(#"UID STORE 9001 +FLAGS.SILENT (\Deleted)"#) })
        #expect(servidor.commands.contains { $0.hasSuffix("EXPUNGE") })
    }

    @Test("Depois cria a pasta no primeiro uso — e só no primeiro")
    func depoisCriaUmaVezSo() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            // A conta não tem `OkamiUNI/Depois`: nem na primeira listagem, nem
            // na releitura depois do CREATE — é o servidor falso, e o que
            // importa é quantos CREATE saem daqui.
            "LIST": Self.pastas,
            "CREATE": ["TAG OK CREATE completo"],
            "SELECT": Self.selecionada,
            "UID SEARCH": ["* SEARCH 9001", "TAG OK SEARCH completo"],
            FakeImapServer.chaveDeCabecalho: [
                "* 1 FETCH (UID 9001 BODY[HEADER.FIELDS (MESSAGE-ID)] {40}",
                "Message-ID: <abc@clientepremium.com>",
                "",
                ")",
                "TAG OK FETCH completo",
            ],
            FakeImapServer.chaveDeBuscaPorHeader: ["* SEARCH", "TAG OK SEARCH completo"],
            "UID COPY": ["TAG OK COPY completo"],
            "UID STORE": ["TAG OK STORE completo"],
            "EXPUNGE": ["TAG OK EXPUNGE completo"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let espelho = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await espelho.apply(
            .move(bucket: TriageBucket.later.rawValue, messageIDs: ["a"]), targets: [alvo(9001)]
        )
        try await espelho.apply(
            .move(bucket: TriageBucket.later.rawValue, messageIDs: ["b"]), targets: [alvo(9002)]
        )

        let criacoes = servidor.commands.filter { $0.contains("CREATE") }
        #expect(criacoes.count == 1)
        #expect(criacoes[0].hasSuffix(#"CREATE "OkamiUNI/Depois""#))
        // E as duas foram copiadas para lá.
        #expect(servidor.commands.filter { $0.contains("UID COPY") }.count == 2)
    }

    @Test("Esvaziar a lixeira marca a caixa inteira e expurga")
    func esvazia() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LIST": Self.pastas,
            "SELECT": Self.selecionada,
            "STORE": ["TAG OK STORE completo"],
            "EXPUNGE": ["TAG OK EXPUNGE completo"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let espelho = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await espelho.apply(.emptyTrash, targets: [])

        #expect(servidor.commands.contains { $0.hasSuffix(#"SELECT "Lixeira""#) })
        #expect(servidor.commands.contains { $0.hasSuffix(#"STORE 1:* +FLAGS.SILENT (\Deleted)"#) })
        #expect(servidor.commands.contains { $0.hasSuffix("EXPUNGE") })
    }

    // MARK: - O invariante

    @Test("O retry depois de um timeout ambíguo não copia a mensagem duas vezes")
    func moverEhIdempotente() async throws {
        // O roteiro encena o pior ponto de queda do mover: o `COPY` passou, o
        // servidor aplicou, e a conexão morreu **antes** do `STORE \Deleted`.
        // Do nosso lado isso é um timeout — não dá para saber se a cópia
        // aconteceu. A fila tenta de novo, e a mensagem não pode aparecer duas
        // vezes na pasta de destino.
        let servidor = FakeImapServer(script: .init(
            replies: [
                "LIST": Self.pastas,
                "SELECT": Self.selecionada,
                // O UID continua na origem nas duas tentativas: o `EXPUNGE`
                // nunca chegou a rodar.
                "UID SEARCH": ["* SEARCH 9001", "TAG OK SEARCH completo"],
                FakeImapServer.chaveDeCabecalho: [
                    "* 1 FETCH (UID 9001 BODY[HEADER.FIELDS (MESSAGE-ID)] {40}",
                    "Message-ID: <abc@clientepremium.com>",
                    "",
                    ")",
                    "TAG OK FETCH completo",
                ],
                "UID COPY": ["TAG OK COPY completo"],
                "EXPUNGE": ["TAG OK EXPUNGE completo"],
            ],
            rounds: [
                // Primeira pergunta ao destino: não está lá. Segunda (o retry):
                // **está** — a cópia da primeira tentativa passou.
                FakeImapServer.chaveDeBuscaPorHeader: [
                    ["* SEARCH", "TAG OK SEARCH completo"],
                    ["* SEARCH 5", "TAG OK SEARCH completo"],
                ],
                // O `STORE \Deleted` da primeira tentativa **não responde**: é
                // o timeout ambíguo. O da segunda responde normalmente.
                "UID STORE": [[], ["TAG OK STORE completo"]],
            ]
        ))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        // Teto curto: o teste que prova o timeout não pode levar quinze
        // segundos.
        let primeira = ImapMirror(
            session: try await conecta(porta: porta, grupo: grupo, teto: .milliseconds(300))
        )
        await #expect(throws: SyncError.self) {
            try await primeira.apply(
                .move(bucket: TriageBucket.archived.rawValue, messageIDs: ["a"]),
                targets: [alvo(9001)]
            )
        }

        // A fila tenta de novo, numa conexão nova — como o executor faria
        // depois do recuo.
        let segunda = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await segunda.apply(
            .move(bucket: TriageBucket.archived.rawValue, messageIDs: ["a"]), targets: [alvo(9001)]
        )

        // **A mutação:** apagar a pergunta ao destino em `ImapMirror.moveUm`
        // (o `precisaCopiar`, que fica sempre `true`) faz sair um segundo
        // `UID COPY` — a mensagem duplicada na pasta de destino, no webmail da
        // pessoa. Esta afirmação é a que morre.
        let copias = servidor.commands.filter { $0.contains("UID COPY") }
        #expect(copias.count == 1)
        // E a limpeza da segunda tentativa aconteceu: a origem foi marcada e
        // expurgada, então a operação está de fato terminada.
        #expect(servidor.commands.filter { $0.hasSuffix("EXPUNGE") }.count == 1)
    }

    @Test("Mover uma mensagem que já saiu da origem não faz nada")
    func origemJaVazia() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LIST": Self.pastas,
            "SELECT": Self.selecionada,
            // O UID não está mais na origem: `COPY`, `STORE` e `EXPUNGE` já
            // aconteceram numa tentativa anterior.
            "UID SEARCH": ["* SEARCH", "TAG OK SEARCH completo"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let espelho = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await espelho.apply(
            .move(bucket: TriageBucket.archived.rawValue, messageIDs: ["a"]), targets: [alvo(9001)]
        )

        #expect(!servidor.commands.contains { $0.contains("UID COPY") })
        #expect(!servidor.commands.contains { $0.contains("EXPUNGE") })
    }

    // MARK: A pasta que falta

    /// O roteiro completo de um mover, sem a lista de pastas — quem a fornece é
    /// cada teste, porque é justamente ela que muda aqui.
    private static func roteiroDeMover(_ pastas: [String]) -> [String: [String]] {
        [
            "LIST": pastas,
            "SELECT": Self.selecionada,
            "UID SEARCH": ["* SEARCH 9001", "TAG OK SEARCH completo"],
            FakeImapServer.chaveDeCabecalho: [
                "* 1 FETCH (UID 9001 BODY[HEADER.FIELDS (MESSAGE-ID)] {40}",
                "Message-ID: <abc@clientepremium.com>",
                "",
                ")",
                "TAG OK FETCH completo",
            ],
            FakeImapServer.chaveDeBuscaPorHeader: ["* SEARCH", "TAG OK SEARCH completo"],
            "UID COPY": ["TAG OK COPY completo"],
            "UID STORE": ["TAG OK STORE completo"],
            "EXPUNGE": ["TAG OK EXPUNGE completo"],
        ]
    }

    /// O defeito do dono, encenado: `marcos@okamiops.com` tinha cinco operações
    /// paradas na fila atrás de "A conta não tem pasta de arquivo no servidor, e
    /// arquivar precisa de uma". O servidor dela não tem `\Archive` nem nada que
    /// a heurística de nome reconheça, e o espelho desistia.
    ///
    /// **A mutação:** trocar o `try await cria(MirrorNames.archive)` de
    /// `destino(de: .archived)` de volta pelo `throw SyncError.resposta(…)` faz
    /// esta chamada lançar, e nenhum `CREATE` nem `UID COPY` sai — a fila da
    /// conta volta a parar.
    @Test("Arquivar numa conta sem pasta de arquivo cria a pasta e move")
    func arquivaCriandoAPasta() async throws {
        let servidor = FakeImapServer(script: .init(
            // Um servidor que só tem a caixa de entrada: nem `\Archive`, nem
            // "Arquivo", nem "Archive".
            replies: Self.roteiroDeMover([
                #"* LIST (\HasNoChildren \Inbox) "/" "INBOX""#,
                "TAG OK LIST completo",
            ]),
            mailboxes: ["INBOX"]
        ))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let espelho = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await espelho.apply(
            .move(bucket: TriageBucket.archived.rawValue, messageIDs: ["a"]), targets: [alvo(9001)]
        )

        #expect(servidor.commands.contains { $0.hasSuffix(#"CREATE "Archive""#) })
        #expect(servidor.commands.contains { $0.hasSuffix(#"UID COPY 9001 "Archive""#) })
        #expect(servidor.mailboxes.contains("Archive"))
        // O nome criado é um que a leitura reconhece de volta: sem isso, o
        // `LIST` seguinte não acharia a pasta e o espelho criaria uma segunda ao
        // lado, com as mensagens arquivadas partidas em duas.
        #expect(FolderRoles.role(specialUse: nil, name: MirrorNames.archive) == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: MirrorNames.trash) == .trash)
    }

    /// A outra metade: a pasta **está** no `LIST`, e mesmo assim o servidor
    /// recusa o destino — a caixa foi apagada entre a listagem e o move, ou o
    /// `LIST` mentiu. O protocolo tem código próprio para isto
    /// (`NO [NONEXISTENT]` no `SELECT`, `NO [TRYCREATE]` no `COPY`), e ele quer
    /// dizer literalmente "crie e tente de novo".
    ///
    /// **A mutação:** apagar o `catch … where ImapWire.pedeCriacaoDaCaixa` de
    /// `moveUm` faz o `NO` subir como `SyncError.servidor`, a operação falha
    /// permanentemente e nenhum `CREATE` sai.
    @Test("O NO [TRYCREATE] do destino é atendido: cria a caixa e repete o move")
    func atendeOTryCreate() async throws {
        let servidor = FakeImapServer(script: .init(
            // O `LIST` anuncia "Arquivo" como pasta de arquivo…
            replies: Self.roteiroDeMover([
                #"* LIST (\HasNoChildren \Inbox) "/" "INBOX""#,
                #"* LIST (\HasNoChildren \Archive) "/" "Arquivo""#,
                "TAG OK LIST completo",
            ]),
            // …e o servidor não a tem.
            mailboxes: ["INBOX"]
        ))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let espelho = ImapMirror(session: try await conecta(porta: porta, grupo: grupo))
        try await espelho.apply(
            .move(bucket: TriageBucket.archived.rawValue, messageIDs: ["a"]), targets: [alvo(9001)]
        )

        #expect(servidor.commands.contains { $0.hasSuffix(#"CREATE "Arquivo""#) })
        #expect(servidor.commands.contains { $0.hasSuffix(#"UID COPY 9001 "Arquivo""#) })
        // Uma cópia, e não duas: a retentativa refaz o mover do começo, e a
        // pergunta de idempotência ao destino recém-criado responde "copie" uma
        // vez só.
        #expect(servidor.commands.filter { $0.contains("UID COPY") }.count == 1)
    }

    /// A recusa que **não** é sobre a caixa faltar continua sendo falha. Criar
    /// uma pasta em cima de um `NO` de permissão esconderia o problema real
    /// atrás de uma pasta nova e vazia.
    @Test("Um NO que não pede criação continua falhando")
    func recusaQueNaoPedeCriacao() {
        #expect(ImapWire.pedeCriacaoDaCaixa("[TRYCREATE] Mailbox does not exist"))
        #expect(ImapWire.pedeCriacaoDaCaixa("[NONEXISTENT] Unknown Mailbox"))
        #expect(ImapWire.pedeCriacaoDaCaixa("Mailbox does not exist"))
        #expect(ImapWire.pedeCriacaoDaCaixa("NO SUCH MAILBOX"))
        #expect(!ImapWire.pedeCriacaoDaCaixa("[NOPERM] Permission denied"))
        #expect(!ImapWire.pedeCriacaoDaCaixa("[OVERQUOTA] Quota exceeded"))
        #expect(!ImapWire.pedeCriacaoDaCaixa("[READ-ONLY] Mailbox is read-only"))
    }

    // MARK: O ciclo fecha

    @Test("Pasta criada, papel lido de volta: o bucket que sai é o que entrou")
    func cicloFecha() {
        // O nome que a escrita cria é o mesmo que a leitura procura, e o papel
        // que ele produz projeta de volta na mesma caixa. É a metade "de graça"
        // do espelho bidirecional — uma constante só, uma tabela só.
        let papel = FolderRoles.role(specialUse: nil, name: MirrorNames.later)
        #expect(papel == .later)
        #expect(TriageProjection.bucket(role: papel) == .later)
    }
}
