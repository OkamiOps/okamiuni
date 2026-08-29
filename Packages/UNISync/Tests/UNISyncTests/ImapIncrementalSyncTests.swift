import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// O delta de uma pasta IMAP — o que chegou, o que mudou de bandeira e o que
/// sumiu desde o último ciclo.
///
/// **Nada aqui toca rede externa**: o `FakeImapServer` sobe em `127.0.0.1`,
/// dentro do processo do teste, e é o `connectForRehearsal` (que só fala com a
/// própria máquina) que chega até ele.
@Suite("Sincronização contínua: IMAP")
struct ImapIncrementalSyncTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private let conta = Account(
        id: "conta-i", address: "ricardo@angulos.com", displayName: "Trabalho",
        provider: .imap, host: "angulos",
        tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4",
        imap: ImapEndpoint(host: "127.0.0.1", port: 1, security: .startTLS),
        state: .ativa
    )

    private let entrada = ImapFolder(name: "INBOX", specialUse: "\\Inbox")
    private var folderID: String { FolderRecord.id(accountID: "conta-i", serverName: "INBOX") }

    private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
        grupo.shutdownGracefully { _ in }
    }

    /// Uma mensagem já no banco, com o UID e as bandeiras que o teste pedir —
    /// o estado que a carga inicial (ou um ciclo anterior) deixou.
    private func banco(
        uidValidity: Int64? = 55, maiorUID: Int64? = nil,
        mensagens: [(uid: Int64, lida: Bool, sinalizada: Bool)] = []
    ) async throws -> SyncDatabase {
        let db = try SyncDatabase.temporary()
        let conta = conta
        let folderID = folderID
        let agora = agora
        try await db.pool.write { conexao in
            try AccountRecord(conta, createdAt: agora).insert(conexao)
            try FolderRecord(
                id: folderID, accountID: conta.id, serverName: "INBOX",
                role: .inbox, displayName: "INBOX"
            ).insert(conexao)
            if let uidValidity {
                try SyncStateRecord(
                    accountID: conta.id, folderID: folderID,
                    uidValidity: uidValidity, highestUID: maiorUID, syncedAt: agora
                ).insert(conexao)
            }
            for (uid, lida, sinalizada) in mensagens {
                let mensagem = Message(
                    id: MessageIdentity.imap(
                        accountID: conta.id, folderID: folderID,
                        uidValidity: uidValidity ?? 0, uid: uid
                    ),
                    accountID: conta.id,
                    from: Contact(name: "Marina", address: "marina@clientepremium.com"),
                    receivedAt: agora.addingTimeInterval(Double(uid)),
                    subject: "UID \(uid)", snippet: "UID \(uid)",
                    body: [], tags: [], bucket: .today,
                    isRead: lida, summary: nil, detectedEvent: nil,
                    isFlagged: sinalizada,
                    serverID: String(uid), uidValidity: uidValidity ?? 0
                )
                try MessageRecord(mensagem, folderID: folderID).insert(conexao)
            }
        }
        return db
    }

    /// Sobe o servidor falso, conecta, autentica e roda o delta de uma pasta.
    private func delta(
        _ db: SyncDatabase, script: FakeImapServer.Script
    ) async throws -> (ImapIncrementalSync.Outcome, [String]) {
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connectForRehearsal(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo
        )
        try await sessao.login(user: conta.address, password: "senha-de-app")
        let saida = try await ImapIncrementalSync(database: db).run(
            account: conta, session: sessao, folder: entrada, bucket: .today, now: agora
        )
        await sessao.logout()
        return (saida, servidor.commands)
    }

    private func linhas(_ db: SyncDatabase) async throws -> [MessageRecord] {
        try await db.pool.read { try MessageRecord.order(Column("serverID")).fetchAll($0) }
    }

    private func estado(_ db: SyncDatabase) async throws -> SyncStateRecord? {
        let chave = folderID
        return try await db.pool.read {
            try SyncStateRecord.fetchOne($0, key: ["accountID": "conta-i", "folderID": chave])
        }
    }

    private func roteiro(
        select: [String] = [
            "* 3 EXISTS",
            "* OK [UIDVALIDITY 55] UIDs valid",
            "* OK [UIDNEXT 40] proximo",
            "TAG OK [READ-WRITE] SELECT completed",
        ],
        busca: [String],
        envelopes: [String] = ["TAG OK UID FETCH completed"],
        bandeiras: [String] = ["TAG OK UID FETCH completed"]
    ) -> FakeImapServer.Script {
        .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "SELECT": select,
            "UID SEARCH": busca,
            "UID FETCH": envelopes,
            FakeImapServer.chaveDeBandeiras: bandeiras,
            "LOGOUT": ["* BYE tchau", "TAG OK LOGOUT completed"],
        ])
    }

    private func envelope(uid: Int64, assunto: String, flags: String = "") -> String {
        """
        * 1 FETCH (UID \(uid) FLAGS (\(flags)) INTERNALDATE "25-Aug-2026 09:00:00 -0300" \
        ENVELOPE ("Mon, 25 Aug 2026 09:00:00 -0300" "\(assunto)" \
        (("Marina" NIL "marina" "clientepremium.com")) NIL NIL \
        (("Ricardo" NIL "ricardo" "angulos.com")) NIL NIL NIL NIL))
        """
    }

    // MARK: A parte pura

    @Test("O `n:*` parte do UID pedido, e nunca de zero")
    func comandoDoIntervaloAberto() {
        #expect(ImapWire.uidSearchFrom(tag: "A005", uid: 31) == "A005 UID SEARCH UID 31:*")
        // `0:*` não é intervalo legal de UID (eles começam em 1), e servidor
        // que responde `BAD` a isso pararia o ciclo de toda conta nova.
        #expect(ImapWire.uidSearchFrom(tag: "A005", uid: 0) == "A005 UID SEARCH UID 1:*")
    }

    @Test("O FETCH de bandeiras pede só o par que interessa")
    func comandoDeBandeiras() {
        // Reler o envelope de duzentas mensagens para descobrir que uma virou
        // lida custaria o que a carga inicial custa, a cada ciclo.
        #expect(ImapWire.uidFetchFlags(tag: "A006", uids: [1, 2, 5]) == "A006 UID FETCH 1,2,5 (UID FLAGS)")
    }

    @Test("As capacidades saem em maiúsculas, e o rótulo da linha fica de fora")
    func capacidades() throws {
        let resposta = try ImapResponseAdapter.untagged(
            fromLogicalLine: "* CAPABILITY IMAP4rev1 Idle STARTTLS"
        )
        let lista = ImapWire.capabilities(from: [resposta])
        // A dobra é o ponto: o RFC não obriga caixa nenhuma, e um servidor que
        // responde `Idle` ficaria de fora do caminho vivo por causa disso.
        #expect(lista.contains("IDLE"))
        #expect(lista.contains("IMAP4REV1"))
        // `CAPABILITY` é o rótulo da linha, não uma capacidade: deixá-lo dentro
        // faria um `contains` responder sim a qualquer pergunta.
        #expect(!lista.contains("CAPABILITY"))
    }

    @Test("O EXPUNGE untagged é lido como sinal, e não confundido com EXISTS")
    func expungeEhLido() throws {
        #expect(try ImapResponseAdapter.untagged(fromLogicalLine: "* 3 EXPUNGE") == .expunge(3))
        #expect(try ImapResponseAdapter.untagged(fromLogicalLine: "* 2 EXISTS") == .exists(2))
    }

    // MARK: O que chegou

    @Test("O delta parte do maior UID conhecido MAIS UM")
    func partiDoMaiorMaisUm() async throws {
        let db = try await banco(maiorUID: 30, mensagens: [(30, true, false)])
        let (_, comandos) = try await delta(db, script: roteiro(
            busca: ["* SEARCH", "TAG OK UID SEARCH completed"],
            bandeiras: [envelopeFlags(uid: 30, flags: "\\Seen"), "TAG OK UID FETCH completed"]
        ))

        // `30:*` traria de volta a mensagem que já está no banco, e ela seria
        // regravada em todo ciclo, para sempre.
        #expect(comandos.contains { $0.hasSuffix("UID SEARCH UID 31:*") })
    }

    @Test("Mensagem nova entra no banco e o piso do próximo ciclo anda")
    func mensagemNovaEntra() async throws {
        let db = try await banco(maiorUID: 30)
        let (saida, _) = try await delta(db, script: roteiro(
            busca: ["* SEARCH 31", "TAG OK UID SEARCH completed"],
            envelopes: [envelope(uid: 31, assunto: "Chegou"), "TAG OK UID FETCH completed"],
            bandeiras: [envelopeFlags(uid: 31, flags: ""), "TAG OK UID FETCH completed"]
        ))

        #expect(saida.novas == 1)
        let todas = try await linhas(db)
        #expect(todas.count == 1)
        #expect(todas.first?.subject == "Chegou")
        #expect(todas.first?.bucket == TriageBucket.today.rawValue)
        // Sem o piso novo, o ciclo seguinte pediria `31:*` de novo e regravaria
        // a mesma mensagem.
        #expect(try await estado(db)?.highestUID == 31)
    }

    @Test("UID abaixo do piso não é mensagem nova — o `n:*` do RFC devolve o maior mesmo assim")
    func uidAbaixoDoPisoNaoEhNova() async throws {
        // O RFC 3501 manda o servidor tratar `*` como o maior UID existente:
        // `31:*` numa caixa cujo maior é 30 devolve **30**. Sem o filtro, uma
        // caixa parada anunciaria a mesma mensagem como nova a cada ciclo.
        let db = try await banco(maiorUID: 30)
        let (saida, comandos) = try await delta(db, script: roteiro(
            busca: ["* SEARCH 30", "TAG OK UID SEARCH completed"]
        ))

        #expect(saida.novas == 0)
        #expect(try await linhas(db).isEmpty)
        // E nem chegou a pedir envelope: o roteiro responde `OK` sem nenhum
        // FETCH, e a contagem prova que a pergunta não foi feita.
        #expect(!comandos.contains { $0.contains("ENVELOPE") })
    }

    // MARK: O que mudou de bandeira

    @Test("Lida no telefone chega ao banco pelo FETCH de bandeiras")
    func bandeiraMudaDosDoisLados() async throws {
        // O UID não muda quando a bandeira muda, então a busca por UID novo
        // nunca a devolveria: sem esta pergunta, marcar como lida noutro
        // cliente jamais chegaria aqui.
        let db = try await banco(maiorUID: 30, mensagens: [(30, false, false)])
        let (saida, _) = try await delta(db, script: roteiro(
            busca: ["* SEARCH", "TAG OK UID SEARCH completed"],
            bandeiras: [
                envelopeFlags(uid: 30, flags: "\\Seen \\Flagged"),
                "TAG OK UID FETCH completed",
            ]
        ))

        #expect(saida.bandeiras == 1)
        let linha = try #require(try await linhas(db).first)
        #expect(linha.isRead)
        #expect(linha.isFlagged)
    }

    @Test("Bandeira que não mudou não gasta escrita")
    func bandeiraIgualNaoEscreve() async throws {
        let db = try await banco(maiorUID: 30, mensagens: [(30, true, true)])
        let (saida, _) = try await delta(db, script: roteiro(
            busca: ["* SEARCH", "TAG OK UID SEARCH completed"],
            bandeiras: [
                envelopeFlags(uid: 30, flags: "\\Seen \\Flagged"),
                "TAG OK UID FETCH completed",
            ]
        ))
        #expect(saida.bandeiras == 0)
    }

    // MARK: O que sumiu

    @Test("UID que não volta no FETCH sumiu do servidor, e sai do banco")
    func expurgoTiraDoBanco() async throws {
        // O IMAP não tem "liste o que sumiu": o que existe é perguntar por uma
        // faixa e reparar em quem faltou.
        let db = try await banco(maiorUID: 31, mensagens: [(30, true, false), (31, true, false)])
        let (saida, _) = try await delta(db, script: roteiro(
            busca: ["* SEARCH", "TAG OK UID SEARCH completed"],
            bandeiras: [envelopeFlags(uid: 31, flags: "\\Seen"), "TAG OK UID FETCH completed"]
        ))

        #expect(saida.apagadas == 1)
        #expect(try await linhas(db).compactMap(\.serverID) == ["31"])
    }

    // MARK: A geração de UIDs

    @Test("UIDVALIDITY reciclado apaga a geração velha e relê a janela inteira")
    func reciclagemRecarrega() async throws {
        // A geração velha não casa com nada: deixá-la ali faria a lista mostrar
        // cada mensagem duas vezes, com assuntos diferentes sob o mesmo UID.
        let db = try await banco(uidValidity: 55, maiorUID: 30, mensagens: [(30, true, false)])
        let (saida, comandos) = try await delta(db, script: roteiro(
            select: [
                "* 1 EXISTS",
                "* OK [UIDVALIDITY 77] UIDs valid",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            busca: ["* SEARCH 1", "TAG OK UID SEARCH completed"],
            envelopes: [envelope(uid: 1, assunto: "Geração nova"), "TAG OK UID FETCH completed"],
            bandeiras: [envelopeFlags(uid: 1, flags: ""), "TAG OK UID FETCH completed"]
        ))

        #expect(saida.recarregou)
        // A janela de 90 dias, e não o intervalo aberto: o piso da geração
        // velha não significa nada na nova.
        #expect(comandos.contains { $0.contains("UID SEARCH SINCE") })
        let todas = try await linhas(db)
        #expect(todas.count == 1)
        #expect(todas.first?.subject == "Geração nova")
        let marcador = try #require(try await estado(db))
        #expect(marcador.uidValidity == 77)
        // O piso volta a ser o da geração nova: guardar o 30 da velha faria o
        // ciclo seguinte pular tudo o que a nova trouxe.
        #expect(marcador.highestUID == 1)
    }

    @Test("Pasta nunca vista lê a janela inteira, e isso NÃO é reciclagem")
    func primeiraVezNaoEhReciclagem() async throws {
        let db = try await banco(uidValidity: nil)
        let (saida, comandos) = try await delta(db, script: roteiro(
            busca: ["* SEARCH 7", "TAG OK UID SEARCH completed"],
            envelopes: [envelope(uid: 7, assunto: "Primeira"), "TAG OK UID FETCH completed"],
            bandeiras: [envelopeFlags(uid: 7, flags: ""), "TAG OK UID FETCH completed"]
        ))

        #expect(comandos.contains { $0.contains("UID SEARCH SINCE") })
        // "Nunca vi esta pasta" não é "os UIDs foram reciclados": relatar
        // reciclagem aqui contaria uma história que não aconteceu.
        #expect(saida.recarregou == false)
        #expect(saida.novas == 1)
    }

    /// Uma linha de `FETCH` só com UID e bandeiras — o que o delta pede.
    private func envelopeFlags(uid: Int64, flags: String) -> String {
        "* 1 FETCH (UID \(uid) FLAGS (\(flags)))"
    }
}
