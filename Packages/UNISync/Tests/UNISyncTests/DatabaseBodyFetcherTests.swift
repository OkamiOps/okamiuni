import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Desligar o grupo sem bloquear — a mesma razão dos outros testes de IMAP: o
/// `defer` de um teste `async` roda no pool cooperativo, e um bloqueio ali
/// derruba a suíte inteira em silêncio.
private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
    grupo.shutdownGracefully { _ in }
}

@Suite("O corpo por demanda, contra o servidor falso")
struct DatabaseBodyFetcherTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)
    private static let uidValidity: Int64 = 1_755_000_000

    private let conta = Account(
        id: "conta-i", address: "contato@meusite.com", displayName: "Site",
        provider: .imap, host: "meusite",
        tintLightHex: "#397852", tintDarkHex: "#88D1A2",
        imap: ImapEndpoint(host: "127.0.0.1", port: 0, security: .startTLS),
        state: .ativa
    )

    private var messageID: String {
        MessageIdentity.imap(
            accountID: "conta-i", folderID: "conta-i/INBOX",
            uidValidity: Self.uidValidity, uid: 9_001
        )
    }

    /// A fonte que um servidor de verdade devolve: multipart, com a parte de
    /// texto em quoted-printable.
    private static let corpoCru = "--xyz\r\n"
        + "Content-Type: text/plain; charset=\"utf-8\"\r\n"
        + "Content-Transfer-Encoding: quoted-printable\r\n"
        + "\r\n"
        + "A revis=C3=A3o do or=C3=A7amento ficou pronta.\r\n"
        + "--xyz\r\n"
        + "Content-Type: text/html; charset=\"utf-8\"\r\n"
        + "\r\n"
        + "<p>tags</p>\r\n"
        + "--xyz--\r\n"

    private static let cabecalhoCru = "Content-Type: multipart/alternative; boundary=\"xyz\"\r\n"
        + "Content-Transfer-Encoding: 7bit\r\n\r\n"

    private func selectOK(uidValidity: Int64 = DatabaseBodyFetcherTests.uidValidity) -> [String] {
        [
            "* 1 EXISTS",
            "* OK [UIDVALIDITY \(uidValidity)] UIDs valid",
            "* OK [UIDNEXT 9002] Predicted next UID",
            "TAG OK [READ-WRITE] SELECT completed",
        ]
    }

    private func roteiro(
        uidValidity: Int64 = DatabaseBodyFetcherTests.uidValidity
    ) -> FakeImapServer.Script {
        .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "SELECT": selectOK(uidValidity: uidValidity),
            FakeImapServer.chaveDeCorpo: [
                "* 1 FETCH (UID 9001 "
                + "BODY[HEADER.FIELDS (CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] "
                + "{\(Self.cabecalhoCru.utf8.count)}\r\n\(Self.cabecalhoCru)"
                + "BODY[TEXT] {\(Self.corpoCru.utf8.count)}\r\n\(Self.corpoCru))",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ])
    }

    /// A mensagem que a carga inicial deixou **sem corpo** — o estado de 39 das
    /// 83 mensagens do dono: envelope no banco, `message_body` sem linha
    /// nenhuma, e a prévia da lista sendo o próprio assunto.
    private func semeia(_ db: SyncDatabase) async throws {
        try await db.pool.write { conexao in
            try AccountRecord(self.conta, createdAt: self.agora).save(conexao)
            try FolderRecord(
                id: "conta-i/INBOX", accountID: "conta-i",
                serverName: "INBOX", role: .inbox, displayName: "INBOX"
            ).save(conexao)
            let mensagem = Message(
                id: self.messageID, accountID: "conta-i",
                from: Contact(name: "Marina", address: "marina@clientepremium.com"),
                receivedAt: self.agora,
                subject: "Revisao pendente", snippet: "Revisao pendente", body: [],
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil,
                serverID: "9001", uidValidity: Self.uidValidity
            )
            try MessageRecord(mensagem, folderID: "conta-i/INBOX").save(conexao)
        }
    }

    /// Sobe o servidor falso, monta o buscador apontado para ele, e roda o
    /// bloco.
    private func comBuscador(
        _ db: SyncDatabase, script: FakeImapServer.Script,
        _ corpo: (DatabaseBodyFetcher, FakeImapServer) async throws -> Void
    ) async throws {
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let cofre = InMemorySecretStore()
        try cofre.store(.password("senha-de-app"), for: "conta-i")

        let buscador = DatabaseBodyFetcher(
            database: db, secrets: cofre, auth: nil, session: .shared,
            eventLoopGroup: grupo,
            // `allowInsecure: true` porque o servidor falso fala em claro — a
            // mesma versão `internal` do `connect` que os testes da carga usam.
            imapConnect: { _, grupoDoNIO in
                try await ImapSession.connect(
                    endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                    group: grupoDoNIO, allowInsecure: true, teto: .seconds(5)
                )
            }
        )
        try await corpo(buscador, servidor)
        await buscador.close()
    }

    // MARK: Ponta a ponta

    @Test("Mensagem sem corpo: pedir o corpo o traz decodificado e o GRAVA no banco")
    func pontaAPonta() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)

        // Antes: a linha existe, o corpo não.
        #expect(try await db.pool.read { try MessageBodyRecord.fetchCount($0) } == 0)

        try await comBuscador(db, script: roteiro()) { buscador, _ in
            let paragrafos = try await buscador.fetchBody(
                accountID: "conta-i", messageID: self.messageID
            )
            // Decodificado: nem fronteira, nem sub-cabeçalho, nem `=C3`.
            #expect(paragrafos == ["A revisão do orçamento ficou pronta."])
        }

        // **Prova por mutação do "grava".** Um `fetchBody` que devolvesse os
        // parágrafos sem os escrever passaria pela asserção acima e por
        // qualquer teste de tela: o texto apareceria, e sumiria ao trocar de
        // mensagem e voltar. A viagem seria paga de novo a cada abertura, e a
        // busca continuaria sem achar o que a pessoa acabou de ler.
        let gravado = try await db.pool.read { conexao in
            try MessageBodyRecord.filter(Column("messageID") == self.messageID).fetchOne(conexao)
        }
        #expect(gravado?.body == ["A revisão do orçamento ficou pronta."])
    }

    @Test("O retrato seguinte entrega o corpo à tela, e a busca passa a achá-lo")
    func oRetratoSeguinte() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let fonte = DatabaseMailSource(database: db)
        #expect(try await fonte.bodyMatches("orcamento", accountID: nil) == [])

        try await comBuscador(db, script: roteiro()) { buscador, _ in
            _ = try await buscador.fetchBody(accountID: "conta-i", messageID: self.messageID)
        }

        // É por aqui que o corpo chega à tela: a `ValueObservation` acorda na
        // escrita de `message_body`, e o retrato seguinte traz a mensagem com
        // corpo. Nada na UI precisou saber que houve rede.
        let retrato = try await fonte.snapshot()
        #expect(retrato.messages.first?.body == ["A revisão do orçamento ficou pronta."])
        // E o índice FTS foi mantido pelo gatilho de INSERT da v1.
        #expect(try await fonte.bodyMatches("orcamento", accountID: nil) == [messageID])
    }

    @Test("A prévia da lista deixa de repetir o assunto")
    func aPreviaDeixaDeRepetir() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        try await comBuscador(db, script: roteiro()) { buscador, _ in
            _ = try await buscador.fetchBody(accountID: "conta-i", messageID: self.messageID)
        }
        let snippet = try await db.pool.read { conexao in
            try String.fetchOne(
                conexao, sql: "SELECT snippet FROM message WHERE id = ?", arguments: [self.messageID]
            )
        }
        // Sem corpo, a prévia era o assunto — a linha da lista mostrava a mesma
        // frase duas vezes, uma em cima da outra.
        #expect(snippet == "A revisão do orçamento ficou pronta.")
    }

    @Test("A conexão é reaproveitada: dois corpos, um LOGIN")
    func sessaoReaproveitada() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        try await comBuscador(db, script: roteiro()) { buscador, servidor in
            _ = try await buscador.fetchBody(accountID: "conta-i", messageID: self.messageID)
            _ = try await buscador.fetchBody(accountID: "conta-i", messageID: self.messageID)
            let logins = servidor.commands.filter { $0.uppercased().contains(" LOGIN ") }
            // Abrir TCP, TLS e `LOGIN` por mensagem somaria meio segundo a cada
            // clique de quem está passando pela caixa.
            #expect(logins.count == 1)
        }
    }

    @Test("UIDVALIDITY trocada no servidor recusa em voz alta, em vez de gravar outra mensagem")
    func uidValidityTrocada() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        // O servidor reciclou os UIDs: o 9001 de hoje não é o 9001 do banco.
        // Baixar assim mesmo gravaria o corpo de **outra** mensagem sob este
        // id — trocar de conteúdo em silêncio é pior do que falhar em voz alta.
        try await comBuscador(db, script: roteiro(uidValidity: 1_999_000_000)) { buscador, _ in
            await #expect(throws: SyncError.self) {
                _ = try await buscador.fetchBody(accountID: "conta-i", messageID: self.messageID)
            }
        }
        #expect(try await db.pool.read { try MessageBodyRecord.fetchCount($0) } == 0)
    }

    @Test("Id que não é desta conta não vira viagem nenhuma")
    func idDeOutraConta() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        try await comBuscador(db, script: roteiro()) { buscador, servidor in
            await #expect(throws: SyncError.self) {
                _ = try await buscador.fetchBody(accountID: "conta-i", messageID: "conta-z:g:abc")
            }
            #expect(servidor.commands.isEmpty)
        }
    }
}
