import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// A sincronização contínua do Gmail — a peça que faz a conta continuar
/// recebendo depois da carga inicial.
///
/// **Nada aqui toca rede externa**: o `StubURLProtocol` responde do roteiro em
/// memória, e uma URL fora dele derruba o teste em vez de sair pela placa.
@Suite("Sincronização contínua: Gmail")
struct GmailIncrementalSyncTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private let conta = Account(
        id: "conta-g", address: "ricardo@gmail.com", displayName: "Pessoal",
        provider: .gmail, host: "gmail",
        tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4", state: .ativa
    )

    private var folderID: String { FolderRecord.id(accountID: "conta-g", serverName: "GMAIL") }

    // MARK: O roteiro

    private func mensagemJSON(id: String, rotulos: [String], assunto: String) -> String {
        let lista = rotulos.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(id)","labelIds":[\(lista)],
         "snippet":"prévia de \(id)","internalDate":"1799000000000",
         "payload":{"mimeType":"text/plain",
           "headers":[
             {"name":"From","value":"Marina <marina@clientepremium.com>"},
             {"name":"Subject","value":"\(assunto)"}
           ],
           "body":{}}}
        """
    }

    private func cliente(_ session: URLSession) -> GmailClient {
        GmailClient(
            session: session,
            accessToken: { "at" },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
    }

    /// A conta, a pseudo-pasta e o marcador de histórico — o estado que a carga
    /// inicial deixa para trás.
    private func bancoCarregado(
        historyID: String? = "100", comMensagem serverID: String? = nil,
        lida: Bool = false, sinalizada: Bool = false
    ) async throws -> SyncDatabase {
        let db = try SyncDatabase.temporary()
        let conta = conta
        let folderID = folderID
        let agora = agora
        try await db.pool.write { conexao in
            try AccountRecord(conta, createdAt: agora).insert(conexao)
            try FolderRecord(
                id: folderID, accountID: conta.id, serverName: "GMAIL",
                role: .other, displayName: "Gmail"
            ).insert(conexao)
            if let historyID {
                try SyncStateRecord(
                    accountID: conta.id, folderID: "", historyID: historyID, syncedAt: agora
                ).insert(conexao)
            }
            if let serverID {
                let mensagem = Message(
                    id: MessageIdentity.gmail(accountID: conta.id, serverID: serverID),
                    accountID: conta.id,
                    from: Contact(name: "Marina", address: "marina@clientepremium.com"),
                    receivedAt: agora, subject: "Velha", snippet: "velha",
                    body: [], tags: [], bucket: .today,
                    isRead: lida, summary: nil, detectedEvent: nil,
                    isFlagged: sinalizada, serverID: serverID
                )
                try MessageRecord(mensagem, folderID: folderID).insert(conexao)
            }
        }
        return db
    }

    private func mensagens(_ db: SyncDatabase) async throws -> [MessageRecord] {
        try await db.pool.read { try MessageRecord.order(Column("id")).fetchAll($0) }
    }

    private func marcador(_ db: SyncDatabase) async throws -> String? {
        try await db.pool.read {
            try SyncStateRecord.fetchOne($0, key: ["accountID": "conta-g", "folderID": ""])?.historyID
        }
    }

    // MARK: O parser, puro

    @Test("As três listas do histórico saem separadas, e sem repetidos")
    func parserSeparaAsTresListas() throws {
        // Um saco único de ids obrigaria quem aplica a adivinhar qual das três
        // ações tomar — e a adivinhação erraria no caso mais caro: apagar uma
        // mensagem que só mudou de rótulo.
        let pagina = try GmailHistoryParser.parse(Data("""
        {"history":[
          {"messagesAdded":[{"message":{"id":"m1"}}]},
          {"labelsAdded":[{"message":{"id":"m2"}}]},
          {"labelsRemoved":[{"message":{"id":"m2"}}]},
          {"messagesDeleted":[{"message":{"id":"m3"}}]}
        ],"historyId":"321"}
        """.utf8))

        #expect(pagina.added == ["m1"])
        #expect(pagina.deleted == ["m3"])
        // `m2` apareceu em dois eventos e sai **uma** vez: buscá-la duas vezes
        // é pagar duas viagens pelo mesmo resultado.
        #expect(pagina.changed == ["m2"])
        #expect(pagina.historyID == "321")
        #expect(pagina.nextPageToken == nil)
    }

    @Test("Histórico vazio é página vazia, e não erro")
    func parserAceitaHistoricoVazio() throws {
        // Conta parada não está quebrada: o Gmail simplesmente omite `history`.
        let pagina = try GmailHistoryParser.parse(Data("{\"historyId\":\"100\"}".utf8))
        #expect(pagina.added.isEmpty)
        #expect(pagina.changed.isEmpty)
        #expect(pagina.deleted.isEmpty)
    }

    @Test("O pedido leva o marcador e os quatro tipos de evento")
    func pedidoLevaMarcadorETipos() async throws {
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/history": [.json("{\"historyId\":\"101\"}")],
        ])
        _ = try await cliente(session).history(startHistoryID: "100", pageToken: nil)

        let pedido = try #require(StubURLProtocol.requests(for: session).first)
        let query = pedido.query.removingPercentEncoding ?? pedido.query
        #expect(query.contains("startHistoryId=100"))
        // Sem `historyTypes` o Gmail devolve todos os tipos, e os que sobram
        // viram viagens de rede para mensagens que nunca entram na triagem.
        for tipo in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] {
            #expect(query.contains("historyTypes=\(tipo)"))
        }
    }

    // MARK: Mensagem nova

    @Test("Mensagem nova no histórico vira linha no banco, e o marcador anda")
    func mensagemNovaEntra() async throws {
        let db = try await bancoCarregado()
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/history": [.json("""
                {"history":[{"messagesAdded":[{"message":{"id":"nova"}}]}],"historyId":"777"}
                """)],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[]}")],
            "/gmail/v1/users/me/messages/nova": [.json(
                mensagemJSON(id: "nova", rotulos: ["INBOX", "UNREAD"], assunto: "Chegou")
            )],
        ])

        let saida = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        #expect(saida.gravadas == 1)
        #expect(saida.recarregou == false)
        let linhas = try await mensagens(db)
        #expect(linhas.count == 1)
        #expect(linhas.first?.subject == "Chegou")
        #expect(linhas.first?.bucket == TriageBucket.today.rawValue)
        #expect(linhas.first?.isRead == false)
        // O marcador anda: sem isso, o ciclo seguinte reprocessaria o mesmo
        // intervalo para sempre.
        #expect(try await marcador(db) == "777")
    }

    @Test("Nada mudou: um ciclo ocioso não busca mensagem nenhuma")
    func cicloOciosoCustaUmaViagem() async throws {
        let db = try await bancoCarregado()
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/labels/INBOX": [.json(
                #"{"id":"INBOX","name":"INBOX","type":"system","messagesTotal":165}"#
            )],
            "/gmail/v1/users/me/history": [.json("{\"historyId\":\"100\"}")],
        ])

        let saida = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        #expect(saida.gravadas == 0)
        #expect(saida.remoteInboxCount == 165)
        // Duas idas e voltas, e só: o total da Entrada e o histórico vazio.
        // Sem isto o retrato da caixa mente; sem o teto, o ciclo ocioso
        // voltaria a listar rótulos e mensagens a cada minuto.
        let caminhos = StubURLProtocol.requests(for: session).map(\.path)
        #expect(caminhos == [
            "/gmail/v1/users/me/labels/INBOX",
            "/gmail/v1/users/me/history",
        ])
    }

    // MARK: Bandeiras

    @Test("Estrela posta no navegador chega ao banco pelo histórico")
    func bandeiraMudaDosDoisLados() async throws {
        // A mensagem já está no banco, não lida e sem estrela. No servidor ela
        // ganhou `STARRED` e perdeu `UNREAD` — é exatamente o que a pessoa faz
        // no webmail enquanto o app está aberto.
        let db = try await bancoCarregado(comMensagem: "velha", lida: false, sinalizada: false)
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/history": [.json("""
                {"history":[{"labelsAdded":[{"message":{"id":"velha"}}]}],"historyId":"888"}
                """)],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[]}")],
            "/gmail/v1/users/me/messages/velha": [.json(
                mensagemJSON(id: "velha", rotulos: ["INBOX", "STARRED"], assunto: "Velha")
            )],
        ])

        _ = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        let linhas = try await mensagens(db)
        // **Uma** linha, e não duas: o id é determinístico e a escrita é
        // upsert. Sem isso, cada mudança de rótulo duplicaria a mensagem.
        #expect(linhas.count == 1)
        #expect(linhas.first?.isFlagged == true)
        #expect(linhas.first?.isRead == true)
    }

    @Test("Ir para a lixeira é mudança de rótulo, e a caixa da triagem acompanha")
    func lixeiraVemPorRotulo() async throws {
        let db = try await bancoCarregado(comMensagem: "velha")
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/history": [.json("""
                {"history":[{"labelsAdded":[{"message":{"id":"velha"}}]}],"historyId":"889"}
                """)],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[]}")],
            "/gmail/v1/users/me/messages/velha": [.json(
                mensagemJSON(id: "velha", rotulos: ["INBOX", "TRASH"], assunto: "Velha")
            )],
        ])

        _ = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        // `TRASH` ganha de `INBOX` — apagar tem de parecer apagar.
        #expect(try await mensagens(db).first?.bucket == TriageBucket.trash.rawValue)
    }

    // MARK: Apagamento

    @Test("Mensagem apagada de vez sai do banco")
    func apagadaSaiDoBanco() async throws {
        let db = try await bancoCarregado(comMensagem: "velha")
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/history": [.json("""
                {"history":[{"messagesDeleted":[{"message":{"id":"velha"}}]}],"historyId":"900"}
                """)],
        ])

        let saida = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        #expect(saida.apagadas == 1)
        #expect(try await mensagens(db).isEmpty)
    }

    @Test("Chegou e foi apagada no mesmo intervalo: termina apagada, e sem viagem à toa")
    func adicionadaEapagadaTerminaApagada() async throws {
        let db = try await bancoCarregado()
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/history": [.json("""
                {"history":[
                  {"messagesAdded":[{"message":{"id":"efemera"}}]},
                  {"messagesDeleted":[{"message":{"id":"efemera"}}]}
                ],"historyId":"901"}
                """)],
        ])

        _ = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        #expect(try await mensagens(db).isEmpty)
        // E nem foi buscada: pedir uma mensagem que já não existe é uma viagem
        // para receber 404. O roteiro não tem rota para ela — se tivesse sido
        // pedida, o stub derrubaria o teste.
        #expect(!StubURLProtocol.requests(for: session).contains { $0.path.hasSuffix("/efemera") })
    }

    // MARK: O marcador expirado

    @Test("404 no histórico recarrega a janela, re-estampa e NÃO duplica")
    func historyExpiradoRecarrega() async throws {
        // O Gmail guarda o histórico por tempo limitado: app fechado por uma
        // semana volta com um marcador que o servidor já esqueceu.
        let db = try await bancoCarregado(historyID: "1", comMensagem: "m1")
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/history": [.json("{\"error\":{\"code\":404}}", status: 404)],
            "/gmail/v1/users/me/profile": [.json(
                "{\"emailAddress\":\"ricardo@gmail.com\",\"historyId\":\"5000\"}"
            )],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[]}")],
            "/gmail/v1/users/me/messages": [.json(
                "{\"messages\":[{\"id\":\"m1\"},{\"id\":\"m2\"}]}"
            )],
            "/gmail/v1/users/me/messages/m1": [.json(
                mensagemJSON(id: "m1", rotulos: ["INBOX"], assunto: "Um")
            )],
            "/gmail/v1/users/me/messages/m2": [.json(
                mensagemJSON(id: "m2", rotulos: ["INBOX"], assunto: "Dois")
            )],
        ])

        let saida = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        #expect(saida.recarregou)
        let linhas = try await mensagens(db)
        // Duas, e não três: `m1` já estava no banco e foi **atualizada** pelo
        // id determinístico + upsert, não duplicada.
        #expect(linhas.count == 2)
        #expect(linhas.map(\.subject) == ["Um", "Dois"])
        // E o marcador foi re-estampado com o do perfil: sem isso, o ciclo
        // seguinte tomaria 404 de novo, para sempre.
        #expect(try await marcador(db) == "5000")
    }

    @Test("Conta sem marcador nenhum recarrega em vez de partir do nada")
    func semMarcadorRecarrega() async throws {
        let db = try await bancoCarregado(historyID: nil)
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/profile": [.json(
                "{\"emailAddress\":\"ricardo@gmail.com\",\"historyId\":\"4242\"}"
            )],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[]}")],
            "/gmail/v1/users/me/messages": [.json("{\"messages\":[{\"id\":\"m1\"}]}")],
            "/gmail/v1/users/me/messages/m1": [.json(
                mensagemJSON(id: "m1", rotulos: ["INBOX"], assunto: "Um")
            )],
        ])

        let saida = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        #expect(saida.recarregou)
        // Nem chegou a pedir histórico: sem ponto de partida, pedir seria
        // inventar um marcador que nunca existiu.
        #expect(!StubURLProtocol.requests(for: session).contains { $0.path.hasSuffix("/history") })
        #expect(try await marcador(db) == "4242")
    }

    // MARK: A paginação

    @Test("Duas páginas de histórico: o marcador gravado é o da ÚLTIMA")
    func marcadorEhODaUltimaPagina() async throws {
        let db = try await bancoCarregado()
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/history": [
                .json("""
                    {"history":[{"messagesAdded":[{"message":{"id":"a"}}]}],
                     "nextPageToken":"p2","historyId":"200"}
                    """),
                .json("""
                    {"history":[{"messagesAdded":[{"message":{"id":"b"}}]}],"historyId":"300"}
                    """),
            ],
            "/gmail/v1/users/me/labels": [.json("{\"labels\":[]}")],
            "/gmail/v1/users/me/messages/a": [.json(
                mensagemJSON(id: "a", rotulos: ["INBOX"], assunto: "A")
            )],
            "/gmail/v1/users/me/messages/b": [.json(
                mensagemJSON(id: "b", rotulos: ["INBOX"], assunto: "B")
            )],
        ])

        let saida = try await GmailIncrementalSync(database: db).run(
            account: conta, client: cliente(session), now: agora
        )

        #expect(saida.gravadas == 2)
        // Carimbar o da primeira página faria o ciclo seguinte reprocessar a
        // segunda — trabalho de rede pago para sempre.
        #expect(try await marcador(db) == "300")
    }

    @Test("Token repetido não faz a paginação girar para sempre")
    func tokenRepetidoParaOCiclo() async throws {
        let db = try await bancoCarregado()
        let pagina = StubURLProtocol.Reply.json(
            "{\"history\":[],\"nextPageToken\":\"sempre-o-mesmo\",\"historyId\":\"200\"}"
        )
        let session = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/labels/INBOX": [.json(
                #"{"id":"INBOX","name":"INBOX","type":"system","messagesTotal":0}"#
            )],
            "/gmail/v1/users/me/history": [pagina, pagina, pagina],
        ])

        await #expect(throws: SyncError.self) {
            _ = try await GmailIncrementalSync(database: db).run(
                account: self.conta, client: self.cliente(session), now: self.agora
            )
        }
        // Três viagens e para: Entrada, a primeira página, e a que reconhece
        // o token repetido.
        #expect(StubURLProtocol.requests(for: session).count == 3)
    }
}
