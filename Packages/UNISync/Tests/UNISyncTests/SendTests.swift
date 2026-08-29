import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// O caminho inteiro do "Enviar": da porta que enfileira até o servidor.
///
/// Nada aqui toca rede externa — Gmail contra o `StubURLProtocol`, IMAP contra
/// o `FakeImapServer`, SMTP contra o `FakeSmtpServer`, todos em memória ou em
/// loopback.
@Suite("O envio")
struct SendTests {
    private let base = "/gmail/v1/users/me"

    private func mensagem(
        messageID: String = "novo-1@meudominio.com.br",
        to: [OutgoingAddress] = [OutgoingAddress(name: "Marina", address: "marina@clientepremium.com")],
        bcc: [OutgoingAddress] = [],
        html: String? = nil
    ) -> OutgoingMessage {
        OutgoingMessage(
            messageID: messageID,
            accountID: "conta-a",
            from: OutgoingAddress(name: "Eu", address: "eu@meudominio.com.br"),
            to: to, bcc: bcc,
            subject: "Contrato",
            // Com acento de propósito: é o que faz o literal do APPEND ter
            // mais bytes que letras, e é onde um `count` no lugar de
            // `utf8.count` quebraria em silêncio.
            plainText: "Segue a versão final.",
            html: html
        )
    }

    // MARK: O Gmail

    private func gmail(
        routes: [String: [StubURLProtocol.Reply]]
    ) -> (GmailMirror, URLSession) {
        let sessao = StubURLProtocol.session(routes: routes)
        let cliente = GmailClient(
            session: sessao, accessToken: { "token" },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
        return (GmailMirror(client: cliente, now: { Date(timeIntervalSince1970: 1_787_407_391) }), sessao)
    }

    /// O `raw` que foi para `messages/send`, já decodificado de base64url.
    private func rawEnviado(_ sessao: URLSession) throws -> String {
        let pedidos = StubURLProtocol.requests(for: sessao).filter { $0.path == "\(base)/messages/send" }
        let corpo = try #require(pedidos.first?.body.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: corpo) as? [String: Any])
        let bruto = try #require(json["raw"] as? String)
        let devolta = bruto
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let preenchido = devolta + String(repeating: "=", count: (4 - devolta.count % 4) % 4)
        let dados = try #require(Data(base64Encoded: preenchido))
        return try #require(String(data: dados, encoding: .utf8))
    }

    @Test("O Gmail recebe a mensagem inteira em base64url, com a cópia oculta no cabeçalho")
    func gmailEnvia() async throws {
        let (espelho, sessao) = gmail(routes: [
            // A busca da idempotência: nada encontrado, então pode mandar.
            "\(base)/messages": [.json(#"{"messages": []}"#)],
            "\(base)/messages/send": [.json(#"{"id": "1a2b3c"}"#)],
        ])

        let onde = try await espelho.apply(
            .send(message: mensagem(bcc: [OutgoingAddress(name: "", address: "socio@meudominio.com.br")])),
            targets: []
        )
        // O id que a `messages.send` devolveu é onde a cópia ficou em SENT — e
        // é ele que faz a linha de Enviadas gravada agora ser a **mesma linha**
        // que a sincronização traria depois.
        #expect(onde == .gmail(serverID: "1a2b3c"))

        let raw = try rawEnviado(sessao)
        #expect(raw.contains("From: Eu <eu@meudominio.com.br>"))
        #expect(raw.contains("To: Marina <marina@clientepremium.com>"))
        #expect(raw.contains("Message-ID: <novo-1@meudominio.com.br>"))
        // No Gmail a cópia oculta **tem** de estar no texto: a API monta os
        // destinatários a partir dele e tira o cabeçalho antes de entregar.
        #expect(raw.contains("Bcc: socio@meudominio.com.br"))
        #expect(raw.contains("Segue a vers=C3=A3o final."))
    }

    @Test("A mensagem que já está na conta não é enviada de novo")
    func gmailIdempotente() async throws {
        // O caso é o tempo esgotado ambíguo: o Gmail aceitou e a resposta não
        // voltou. Sem a pergunta pelo `Message-ID`, a segunda tentativa entrega
        // a mesma mensagem outra vez — e não há como desfazer.
        let (espelho, sessao) = gmail(routes: [
            "\(base)/messages": [.json(#"{"messages": [{"id": "ja-esta-la"}]}"#)],
            "\(base)/messages/send": [.json(#"{"id": "nao-devia-acontecer"}"#)],
        ])

        try await espelho.apply(.send(message: mensagem()), targets: [])

        let enviados = StubURLProtocol.requests(for: sessao).filter { $0.path == "\(base)/messages/send" }
        #expect(enviados.isEmpty)
        // E a pergunta foi pelo operador certo: `rfc822msgid:` é o que enxerga
        // o cabeçalho `Message-ID`, inclusive em Enviadas.
        let buscas = StubURLProtocol.requests(for: sessao).filter { $0.path == "\(base)/messages" }
        #expect(buscas.first?.query.contains("rfc822msgid") == true)
    }

    // MARK: O IMAP e o SMTP

    /// Um par IMAP+SMTP falso, e o espelho que fala com os dois.
    private func imap(
        imapScript: FakeImapServer.Script,
        smtpScript: FakeSmtpServer.Script = .aceitaTudo()
    ) throws -> (ImapMirror, FakeImapServer, FakeSmtpServer, MultiThreadedEventLoopGroup) {
        let servidorImap = FakeImapServer(script: imapScript)
        let portaImap = try servidorImap.start()
        let servidorSmtp = FakeSmtpServer(script: smtpScript)
        let portaSmtp = try servidorSmtp.start()
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let sessaoImap = ImapSession.self
        let espelho = ImapMirror(
            connect: {
                try await sessaoImap.connect(
                    endpoint: ImapEndpoint(host: "127.0.0.1", port: portaImap, security: .startTLS),
                    group: grupo, allowInsecure: true, teto: .seconds(5)
                )
            },
            smtp: {
                try await SmtpSession.connect(
                    endpoint: SmtpEndpoint(host: "127.0.0.1", port: portaSmtp, security: .startTLS),
                    group: grupo, allowInsecure: true, teto: .seconds(5)
                )
            },
            now: { Date(timeIntervalSince1970: 1_787_407_391) }
        )
        return (espelho, servidorImap, servidorSmtp, grupo)
    }

    /// O roteiro de um servidor IMAP com pasta de Enviadas e `LITERAL+`.
    private func roteiroImap(
        buscaPorHeader: [String] = ["* SEARCH", "TAG OK busca feita"],
        capacidades: String = "* CAPABILITY IMAP4rev1 LITERAL+"
    ) -> FakeImapServer.Script {
        FakeImapServer.Script(replies: [
            "LIST": [
                "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
                "* LIST (\\Sent \\HasNoChildren) \"/\" \"Enviados\"",
                "TAG OK lista feita",
            ],
            "SELECT": [
                "* 3 EXISTS",
                "* OK [UIDVALIDITY 42] ok",
                "* OK [UIDNEXT 9] ok",
                "TAG OK [READ-WRITE] selecionada",
            ],
            FakeImapServer.chaveDeBuscaPorHeader: buscaPorHeader,
            "CAPABILITY": [capacidades, "TAG OK capacidades"],
            "APPEND": ["TAG OK [APPENDUID 42 9] gravada"],
            "LOGOUT": ["* BYE tchau", "TAG OK saiu"],
        ])
    }

    @Test("A conta IMAP entrega por SMTP e guarda a cópia em Enviadas")
    func imapEnvia() async throws {
        let (espelho, servidorImap, servidorSmtp, grupo) = try imap(imapScript: roteiroImap())
        defer {
            servidorImap.stop()
            servidorSmtp.stop()
            grupo.shutdownGracefully { _ in }
        }

        let onde = try await espelho.apply(
            .send(message: mensagem(bcc: [OutgoingAddress(name: "", address: "socio@meudominio.com.br")])),
            targets: []
        )
        // O `APPENDUID` do roteiro (`[APPENDUID 42 9]`) volta como coordenada:
        // é o endereço da cópia, e é o que dá à linha de Enviadas o mesmo id
        // que a leitura seguinte da pasta daria.
        #expect(onde == .imap(folderName: "Enviados", uidValidity: 42, uid: 9))

        // Entregue: envelope com os três destinatários e o corpo no `DATA`.
        #expect(servidorSmtp.comandos.contains("MAIL FROM:<eu@meudominio.com.br>"))
        #expect(servidorSmtp.comandos.contains("RCPT TO:<marina@clientepremium.com>"))
        // A cópia oculta viaja **aqui**, e não em cabeçalho nenhum.
        #expect(servidorSmtp.comandos.contains("RCPT TO:<socio@meudominio.com.br>"))
        let corpo = try #require(servidorSmtp.corpos.first)
        #expect(!corpo.contains("Bcc:"))
        #expect(corpo.contains("Message-ID: <novo-1@meudominio.com.br>"))

        // E guardada: o `APPEND` foi para a pasta com atributo `\Sent`, com a
        // mensagem marcada como lida — uma cópia do que a própria pessoa
        // escreveu chegando "não lida" faria um contador subir à toa.
        let append = try #require(servidorImap.commands.first { $0.contains("APPEND") })
        #expect(append.contains("\"Enviados\""))
        #expect(append.contains("(\\Seen)"))
        // O tamanho do literal é em **bytes**: um assunto com acento tem mais
        // bytes que letras, e um número curto faria o servidor ler o resto da
        // mensagem como comandos.
        #expect(append.contains("{\(corpo.utf8.count)+}"))
    }

    @Test("A mensagem que já está em Enviadas não sai de novo")
    func imapIdempotente() async throws {
        // A `SEARCH` acha o `Message-ID` na pasta de Enviadas: a tentativa
        // anterior chegou até o fim, e reenviar entregaria a mesma mensagem
        // duas vezes.
        let (espelho, servidorImap, servidorSmtp, grupo) = try imap(
            imapScript: roteiroImap(buscaPorHeader: ["* SEARCH 7", "TAG OK achei"])
        )
        defer {
            servidorImap.stop()
            servidorSmtp.stop()
            grupo.shutdownGracefully { _ in }
        }

        try await espelho.apply(.send(message: mensagem()), targets: [])

        #expect(servidorSmtp.corpos.isEmpty)
        #expect(!servidorSmtp.comandos.contains { $0.hasPrefix("MAIL") })
        // A pergunta foi feita pelo `Message-ID` inteiro, entre `<>` — é assim
        // que o cabeçalho está gravado na pasta.
        let busca = try #require(servidorImap.commands.first { $0.contains("SEARCH HEADER") })
        #expect(busca.contains("<novo-1@meudominio.com.br>"))
    }

    @Test("Servidor sem LITERAL+ não impede o envio: a cópia é que não é gravada")
    func imapSemLiteral() async throws {
        // A mensagem **já saiu** quando o `APPEND` entra em cena. Transformar
        // a falta de uma capacidade em erro faria a fila tentar de novo um
        // envio que já aconteceu.
        let (espelho, servidorImap, servidorSmtp, grupo) = try imap(
            imapScript: roteiroImap(capacidades: "* CAPABILITY IMAP4rev1")
        )
        defer {
            servidorImap.stop()
            servidorSmtp.stop()
            grupo.shutdownGracefully { _ in }
        }

        let onde = try await espelho.apply(.send(message: mensagem()), targets: [])

        #expect(servidorSmtp.corpos.count == 1)
        #expect(!servidorImap.commands.contains { $0.contains("APPEND") })
        // Sem cópia gravada não há coordenada honesta a devolver — e é isso
        // que impede o executor de inventar uma linha de Enviadas para uma
        // mensagem que só existe na caixa de quem recebeu.
        #expect(onde == nil)
    }

    @Test("Conta sem servidor de envio diz isso, em vez de fingir que enviou")
    func imapSemSmtp() async throws {
        let servidorImap = FakeImapServer(script: roteiroImap())
        let porta = try servidorImap.start()
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            servidorImap.stop()
            grupo.shutdownGracefully { _ in }
        }
        let espelho = ImapMirror(connect: {
            try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                group: grupo, allowInsecure: true, teto: .seconds(5)
            )
        })

        await #expect(throws: SyncError.self) {
            try await espelho.apply(.send(message: self.mensagem()), targets: [])
        }
    }

    // MARK: A fila

    private let conta = Account(
        id: "conta-a", address: "eu@meudominio.com.br", displayName: "Eu",
        provider: .imap, host: "meudominio",
        tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
        imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
        state: .ativa
    )

    private func banco() throws -> SyncDatabase {
        let db = try SyncDatabase.temporary()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
        }
        return db
    }

    @Test("Enviar enfileira a mensagem inteira, e a fila a leva ao espelho")
    func filaLevaAoEspelho() async throws {
        let db = try banco()
        let porta = DatabaseCommandPort(database: db)
        let original = mensagem(html: "<p>Segue.</p>")

        try porta.send(original)

        // Uma linha na fila, com a mensagem inteira dentro — inclusive o
        // `Message-ID`, que é a identidade que faz o reenvio ser seguro.
        let linhas = try await db.pool.read { try OutboxRecord.fetchAll($0) }
        #expect(linhas.count == 1)
        guard case .send(let guardada)? = linhas.first?.operation else {
            Issue.record("A fila não guardou um envio.")
            return
        }
        #expect(guardada == original)
        #expect(guardada.messageID == "novo-1@meudominio.com.br")
        #expect(guardada.html == "<p>Segue.</p>")

        // E o executor a entrega ao espelho, saindo da tabela depois.
        let espelho = EspelhoFalso()
        let executor = OutboxExecutor(
            accountID: "conta-a", database: db, mirror: espelho,
            // Depois do carimbo que a porta pôs (ela usa o relógio de
            // verdade): um "agora" no passado deixaria a linha eternamente
            // no futuro, e o `drain` não veria nada.
            now: { Date(timeIntervalSince1970: 4_000_000_000) },
            sleeper: { _ in }, jitter: { 0 }
        )
        let resultado = await executor.drain()
        #expect(resultado.executadas == 1)
        let feitas = await espelho.operacoes
        #expect(feitas == [.send(message: original)])
        // Operação feita **sai da tabela** — o invariante do M3-2, que o envio
        // herda sem mudar nada.
        let restantes = try await db.pool.read { try OutboxRecord.fetchCount($0) }
        #expect(restantes == 0)
    }

    /// O executor com o relógio adiantado que estes testes usam — a porta
    /// carimba com o relógio de verdade, e um "agora" no passado deixaria a
    /// linha eternamente no futuro para o `drain`.
    private func executor(
        _ db: SyncDatabase, espelho: any MailMirror
    ) -> OutboxExecutor {
        OutboxExecutor(
            accountID: "conta-a", database: db, mirror: espelho,
            now: { Date(timeIntervalSince1970: 4_000_000_000) },
            sleeper: { _ in }, jitter: { 0 }
        )
    }

    /// **Este teste foi invertido, e o relatório da M3-7 registra por quê.**
    ///
    /// Ele se chamava "Enviar não grava mensagem nenhuma na triagem" e travava
    /// a não-gravação: sem caixa Enviadas no shell, gravar a linha seria
    /// escrever no banco para nenhuma visão ler — e ela apareceria em
    /// Arquivado. A caixa existe agora, e o sentido mudou **de propósito**.
    ///
    /// O que sobrevive da versão anterior, e é a primeira metade deste teste:
    /// **enfileirar continua não gravando nada**. Quem grava é a confirmação do
    /// servidor. Gravar no "Enviar" mostraria como enviado o que ainda está na
    /// fila — e o que a fila recusasse (um endereço que não existe) ficaria lá
    /// para sempre dizendo que saiu.
    @Test("Enviar não grava nada; quem grava em Enviadas é a confirmação do servidor")
    func oEnvioConfirmadoViraLinhaDeEnviadas() async throws {
        let db = try banco()
        try DatabaseCommandPort(database: db).send(mensagem())
        // Enfileirado, e mais nada: a mensagem ainda não saiu.
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)

        let onde = MessageCoordinate.imap(folderName: "Enviados", uidValidity: 42, uid: 9)
        let resultado = await executor(db, espelho: EspelhoFalso(gravouEm: onde)).drain()
        #expect(resultado.executadas == 1)

        let linha = try await db.pool.read { try MessageRecord.fetchAll($0) }.first
        let gravada = try #require(linha)
        // Na caixa dela, lida, e com o id que o **servidor** deu: é o mesmo que
        // `MessageIdentity` daria à mesma mensagem lida da pasta de Enviados.
        #expect(gravada.bucket == "enviadas")
        #expect(gravada.isRead)
        #expect(gravada.id == MessageIdentity.imap(
            accountID: "conta-a",
            folderID: FolderRecord.id(accountID: "conta-a", serverName: "Enviados"),
            uidValidity: 42, uid: 9
        ))
        #expect(gravada.subject == "Contrato")
        #expect(gravada.fromAddress == "eu@meudominio.com.br")
        // O destinatário viaja junto: é ele que a linha da lista escreve em
        // Enviadas (`Message.listHeadline`).
        #expect(gravada.toJSON.contains("marina@clientepremium.com"))
        // E o corpo, para a mensagem enviada abrir no leitor como qualquer
        // outra em vez de aparecer vazia.
        let corpo = try await db.pool.read {
            try MessageBodyRecord.filter(Column("messageID") == gravada.id).fetchOne($0)?.body
        }
        #expect(corpo == ["Segue a versão final."])

        // A pasta veio junto — `message` tem chave estrangeira para ela, e no
        // primeiro envio de uma conta nova ela pode não estar no banco.
        let pasta = try await db.pool.read {
            try FolderRecord.fetchOne($0, key: FolderRecord.id(accountID: "conta-a", serverName: "Enviados"))
        }
        #expect(pasta?.role == "sent")
    }

    @Test("A mesma mensagem gravada duas vezes continua sendo uma linha só")
    func aEnviadaNaoDuplica() async throws {
        // O caso real: o servidor já pôs a cópia em Enviadas, e a próxima
        // sincronização vai trazê-la. Ela chega com o id que `MessageIdentity`
        // monta a partir da coordenada do servidor — o **mesmo** que a linha
        // gravada no envio. Mesmo id, `save` é upsert, uma linha.
        //
        // MUTAÇÃO QUE ISTO PEGA: dar à linha do envio um id nosso (um
        // `conta:enviada:message-id`, por exemplo). A mensagem que a pessoa
        // mandou apareceria duas vezes na caixa dela, e não haveria como
        // desfazer sem apagar a certa junto.
        let db = try banco()
        let onde = MessageCoordinate.imap(folderName: "Enviados", uidValidity: 42, uid: 9)

        try DatabaseCommandPort(database: db).send(mensagem())
        _ = await executor(db, espelho: EspelhoFalso(gravouEm: onde)).drain()
        try DatabaseCommandPort(database: db).send(mensagem())
        _ = await executor(db, espelho: EspelhoFalso(gravouEm: onde)).drain()

        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 1)
        #expect(try await db.pool.read { try MessageBodyRecord.fetchCount($0) } == 1)
    }

    @Test("Envio sem cópia gravada no servidor não inventa linha nenhuma")
    func semCoordenadaNaoGravaNada() async throws {
        // Servidor sem `LITERAL+`, conta sem pasta de Enviadas, ou a
        // reexecução que descobriu que a mensagem já estava lá: o espelho
        // devolve `nil`, e `nil` quer dizer "não sei onde ela está". Inventar
        // um lugar aqui seria pôr na caixa da pessoa uma linha que o servidor
        // não tem — e que a sincronização seguinte duplicaria.
        let db = try banco()
        try DatabaseCommandPort(database: db).send(mensagem())
        let resultado = await executor(db, espelho: EspelhoFalso()).drain()
        #expect(resultado.executadas == 1)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
    }

    @Test("A operação que não é envio nunca grava mensagem nenhuma")
    func soOEnvioGrava() async throws {
        // O espelho falso devolve a coordenada só no `.send` — mas o executor
        // não pode depender disso: é ele que confere a operação antes de
        // gravar. Aqui a fila leva um `move`, e o banco continua sem linha.
        let db = try banco()
        try DatabaseCommandPort(database: db).move(
            to: .archived, accountID: "conta-a", messageIDs: ["conta-a:i:conta-a/INBOX:42:7"]
        )
        let onde = MessageCoordinate.imap(folderName: "Enviados", uidValidity: 42, uid: 9)
        _ = await executor(db, espelho: EspelhoFalso(gravouEm: onde)).drain()
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
    }

    @Test("Uma recusa definitiva do envio para a fila, com a frase do servidor")
    func recusaParaAFila() async throws {
        let db = try banco()
        try DatabaseCommandPort(database: db).send(mensagem())

        let espelho = EspelhoFalso(roteiro: [.recusado("marina@x.com: 550 usuário desconhecido")])
        let executor = OutboxExecutor(
            accountID: "conta-a", database: db, mirror: espelho,
            // Depois do carimbo que a porta pôs (ela usa o relógio de
            // verdade): um "agora" no passado deixaria a linha eternamente
            // no futuro, e o `drain` não veria nada.
            now: { Date(timeIntervalSince1970: 4_000_000_000) },
            sleeper: { _ in }, jitter: { 0 }
        )
        let resultado = await executor.drain()
        // Parada, e não repetição para sempre: um endereço digitado errado
        // pede que a pessoa faça alguma coisa, e insistir esconde isso dela.
        #expect(resultado.executadas == 0)
        let frase = resultado.falhaPermanente?.mensagem ?? ""
        #expect(frase.contains("550"))
        #expect(resultado.pendentes == 1)
    }

    @Test("Uma recusa temporária adia o envio, sem parar a fila")
    func adiaSemParar() async throws {
        let db = try banco()
        try DatabaseCommandPort(database: db).send(mensagem())

        let espelho = EspelhoFalso(roteiro: [.transitorio("451 greylisted")])
        let executor = OutboxExecutor(
            accountID: "conta-a", database: db, mirror: espelho,
            // Depois do carimbo que a porta pôs (ela usa o relógio de
            // verdade): um "agora" no passado deixaria a linha eternamente
            // no futuro, e o `drain` não veria nada.
            now: { Date(timeIntervalSince1970: 4_000_000_000) },
            sleeper: { _ in }, jitter: { 0 }
        )
        let resultado = await executor.drain()
        // A mensagem continua na fila, marcada para depois — greylisting é o
        // caso mais comum de primeira entrega a um domínio novo, e a única
        // forma de passar por ele é esperar.
        #expect(resultado.falhaPermanente == nil)
        #expect(resultado.pendentes == 1)
        #expect(resultado.proximaTentativa != nil)
    }
}
