import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Desligar o grupo de event loops **sem bloquear** a thread do teste.
///
/// `syncShutdownGracefully()` bloqueia até o grupo morrer, e uma função de
/// teste `async` roda no pool cooperativo do Swift, que tem uma thread por
/// núcleo e não cresce. Com poucos testes de IMAP dava para não notar; com
/// mais alguns, todas as threads do pool ficam paradas nesse bloqueio ao mesmo
/// tempo e a suíte inteira trava sem falhar — o pior dos dois mundos.
/// A versão de callback pede o desligamento e volta na hora; num processo de
/// teste que já vai terminar, esperar por ele não prova nada.
private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
    grupo.shutdownGracefully { _ in }
}

/// Um contador que sobrevive a fronteira de isolação — é o que deixa o teste
/// afirmar quantas vezes o closure de montagem foi chamado.
private final class ContadorDeMontagens: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func mais() { lock.lock(); n += 1; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite("IMAP: conectar, autenticar, sair")
struct ImapSessionTests {
    // MARK: A parte pura — os comandos que a gente monta

    @Test("O LOGIN escapa aspas e barra invertida na senha")
    func loginEscapa() {
        // Senha de app com aspas dentro derrubaria o comando e o servidor
        // responderia BAD — que a pessoa leria como "senha errada".
        #expect(ImapWire.login(tag: "A001", user: "eu@x.com", password: "se\"nh\\a")
            == "A001 LOGIN \"eu@x.com\" \"se\\\"nh\\\\a\"")
    }

    @Test("A data do UID SEARCH sai no formato do IMAP, em inglês, sempre")
    func dataDoSearch() {
        // `dd-MMM-yyyy` com meses em inglês: o servidor não fala português, e
        // um `DateFormatter` com o locale da máquina mandaria "25-ago-2026",
        // que o servidor recusa. Mesma família do bug de fuso do Marco 1.
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = TimeZone(identifier: "UTC")!
        let data = calendario.date(from: DateComponents(year: 2026, month: 8, day: 25))!
        #expect(ImapWire.imapDate(data, calendar: calendario) == "25-Aug-2026")
        #expect(ImapWire.uidSearchSince(tag: "A004", date: data, calendar: calendario)
            == "A004 UID SEARCH SINCE 25-Aug-2026")
    }

    @Test("As tags são sequenciais e com largura fixa")
    func tags() {
        #expect(ImapWire.tag(1) == "A0001")
        #expect(ImapWire.tag(42) == "A0042")
    }

    @Test("Os comandos que esta tarefa manda saem literais")
    func comandosLiterais() {
        #expect(ImapWire.list(tag: "A002") == "A002 LIST \"\" \"*\"")
        #expect(ImapWire.logout(tag: "A099") == "A099 LOGOUT")
        #expect(ImapWire.startTLS(tag: "A003") == "A003 STARTTLS")
    }

    // MARK: A sessão, contra o servidor falso

    private func endpoint(porta: Int) -> ImapEndpoint {
        // Sem TLS: o servidor falso fala em claro, e é isso que mantém o teste
        // dentro da máquina, sem certificado nenhum. `allowInsecure` na
        // conexão é o que dispensa o `STARTTLS` — e só o teste passa isso.
        ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
    }

    @Test("Login aceito conecta e o LOGOUT fecha limpo")
    func loginOK() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LOGOUT": ["* BYE OkamiUNI falso encerrando", "TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        try await sessao.login(user: "eu@x.com", password: "senha-de-app")
        await sessao.logout()

        #expect(servidor.commands.contains { $0.contains("LOGIN \"eu@x.com\"") })
        #expect(servidor.commands.contains { $0.hasSuffix("LOGOUT") })
    }

    @Test("Login recusado vira `autenticacao`, e não um erro genérico")
    func loginRecusado() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG NO [AUTHENTICATIONFAILED] Invalid credentials"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        await #expect(throws: SyncError.autenticacao) {
            try await sessao.login(user: "eu@x.com", password: "errada")
        }
        await sessao.logout()
    }

    @Test("`BAD` do servidor não é engolido — vira `resposta` com o texto dele")
    func comandoRecusado() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG BAD Missing argument"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        await #expect(throws: SyncError.resposta("O servidor IMAP recusou o comando: Missing argument")) {
            try await sessao.login(user: "eu@x.com", password: "x")
        }
        await sessao.logout()
    }

    @Test("Porta fechada vira erro de rede com o motivo, e não trava")
    func portaFechada() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        // Porta 1 em loopback: recusa imediata, sem esperar tempo nenhum.
        await #expect(throws: (any Error).self) {
            _ = try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: 1, security: .startTLS),
                group: grupo,
                allowInsecure: true,
                teto: .seconds(5)
            )
        }
    }

    @Test("Sair duas vezes não estoura")
    func logoutDuasVezes() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        try await sessao.login(user: "eu@x.com", password: "senha")
        await sessao.logout()
        await sessao.logout()
    }

    @Test("Um servidor que responde `* BYE` na saudação é recusado na hora")
    func saudacaoBye() async throws {
        let servidor = FakeImapServer(script: .init(
            greeting: "* BYE Too many connections from your IP",
            replies: ["LOGOUT": ["TAG OK LOGOUT completed"]]
        ))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        await #expect(throws: SyncError.servidor(codigo: 0, mensagem: "* BYE Too many connections from your IP")) {
            _ = try await ImapSession.connect(
                endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true
            )
        }
    }

    @Test("Sem `allowInsecure`, a sessão exige STARTTLS — e a recusa vira `tls`")
    func startTLSRecusadoNaoDegradaParaClaro() async throws {
        // O caminho de produção: `allowInsecure` é `false` por padrão, então a
        // sessão manda `STARTTLS` antes de qualquer credencial. Um servidor que
        // recusa não vira "conexão em claro que funciona" — vira erro. Sem
        // isto, a senha da pessoa sairia em texto puro no primeiro provedor que
        // resolvesse não anunciar STARTTLS.
        let servidor = FakeImapServer(script: .init(replies: [
            "STARTTLS": ["TAG NO STARTTLS não disponível"],
            "LOGIN": ["TAG OK LOGIN completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        await #expect(throws: SyncError.tls("O servidor recusou STARTTLS: STARTTLS não disponível")) {
            _ = try await ImapSession.connect(endpoint: endpoint(porta: porta), group: grupo)
        }
        #expect(servidor.commands.contains { $0.hasSuffix("STARTTLS") })
        #expect(!servidor.commands.contains { $0.contains("LOGIN") })
    }

    @Test("Dados emendados depois do OK do STARTTLS derrubam a conexão")
    func startTLSComInjecao() async throws {
        // A família do CVE-2011-0411: quem está no meio emenda bytes logo
        // depois do `OK`, e eles seriam lidos como se tivessem vindo de dentro
        // do túnel. Nada pode estar bufferizado quando o TLS sobe.
        let servidor = FakeImapServer(script: .init(replies: [
            "STARTTLS": ["TAG OK Begin TLS negotiation now", "* OK injetado antes do TLS"],
            "LOGIN": ["TAG OK LOGIN completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        await #expect(throws: SyncError.self) {
            _ = try await ImapSession.connect(endpoint: endpoint(porta: porta), group: grupo)
        }
        #expect(!servidor.commands.contains { $0.contains("LOGIN") })
    }

    @Test("Meia linha emendada antes do TLS também derruba a conexão")
    func startTLSComInjecaoSemTerminador() async throws {
        // A injeção do CVE-2011-0411 não precisa ser uma linha inteira: bytes
        // sem CRLF ficam **dentro** do decodificador, onde nenhuma linha
        // coletada os enxerga, e o túnel subiria por cima deles como se
        // tivessem vindo de dentro.
        let servidor = FakeImapServer(script: .init(replies: [
            "STARTTLS": ["TAG OK Begin TLS negotiation now", "CRU:* OK injetado sem terminador"],
            "LOGIN": ["TAG OK LOGIN completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        await #expect(throws: SyncError.self) {
            _ = try await ImapSession.connect(endpoint: endpoint(porta: porta), group: grupo)
        }
        #expect(!servidor.commands.contains { $0.contains("LOGIN") })
    }

    @Test("Handshake TLS falho é erro de TLS, e não de rede")
    func tlsContraServidorEmClaro() async throws {
        // O servidor falso fala IMAP em texto puro. Um cliente em TLS implícito
        // manda o ClientHello e recebe `* OK ...` — handshake quebrado. O erro
        // precisa dizer TLS: `.rede` manda a pessoa conferir a conexão, que
        // está ótima, em vez da porta e da forma de TLS da conta.
        let servidor = FakeImapServer(script: .init(replies: [:]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        do {
            _ = try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .tls),
                group: grupo,
                allowInsecure: false,
                teto: .seconds(5)
            )
            Issue.record("A conexão deveria ter falhado no handshake.")
        } catch let erro as SyncError {
            guard case .tls = erro else {
                Issue.record("Esperava `.tls`, veio \(erro).")
                return
            }
        }
    }

    @Test("O comando é montado uma vez só")
    func comandoMontadoUmaVez() async throws {
        // `run` chamava o closure duas vezes — uma para espiar o comando, outra
        // para mandá-lo. Qualquer construção com efeito colateral (a Task 10
        // monta `UID FETCH` a partir de listas de UID) viraria bug silencioso.
        let servidor = FakeImapServer(script: .init(replies: [
            "NOOP": ["TAG OK NOOP completed"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        let contador = ContadorDeMontagens()
        _ = try await sessao.run { tag in
            contador.mais()
            return "\(tag) NOOP"
        }
        #expect(contador.total == 1)
        await sessao.logout()
    }

    // MARK: Tempo, reentrância e cancelamento

    @Test("Servidor que aceita e emudece não trava a saudação para sempre")
    func saudacaoQueNuncaChega() async throws {
        let servidor = FakeImapServer(script: .init(greeting: "", replies: [:]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        do {
            _ = try await ImapSession.connect(
                endpoint: endpoint(porta: porta), group: grupo,
                allowInsecure: true, teto: .milliseconds(200)
            )
            Issue.record("A conexão deveria ter estourado o teto de tempo.")
        } catch let erro as SyncError {
            guard case .rede(let detalhe) = erro else {
                Issue.record("Esperava `.rede`, veio \(erro).")
                return
            }
            #expect(detalhe.contains("saudação"))
        }
    }

    @Test("Comando sem resposta estoura o teto com motivo, e não fica pendurado")
    func comandoSemResposta() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": [], // recebe e não responde
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo,
            allowInsecure: true, teto: .milliseconds(200)
        )
        do {
            try await sessao.login(user: "eu@x.com", password: "senha")
            Issue.record("O LOGIN deveria ter estourado o teto de tempo.")
        } catch let erro as SyncError {
            guard case .rede(let detalhe) = erro else {
                Issue.record("Esperava `.rede`, veio \(erro).")
                return
            }
            #expect(detalhe.contains("não respondeu"))
        }
        await sessao.logout()
    }

    @Test("Dois comandos concorrentes: um espera o outro, nada vaza, nada trava")
    func comandosConcorrentes() async throws {
        // Um ator não é fila: `await` solta a isolação, e o segundo comando
        // sobrescrevia a continuation do primeiro — que vazava
        // (`SWIFT TASK CONTINUATION MISUSE`) e travava a sessão para sempre.
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": [], // recebe e não responde
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo,
            allowInsecure: true, teto: .milliseconds(200)
        )

        let entrada = Task { try await sessao.login(user: "eu@x.com", password: "senha") }
        let saida = Task { await sessao.logout() }

        // O `logout` termina (não lança) e o `login` termina com erro. O que
        // não pode acontecer é nenhum dos dois terminar — que é o que
        // acontecia quando o segundo comando atropelava a continuation do
        // primeiro.
        await saida.value
        await #expect(throws: SyncError.self) { try await entrada.value }
    }

    @Test("Cancelar a tarefa acorda a espera em vez de deixá-la pendurada")
    func cancelamentoAcordaAEspera() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": [], // recebe e não responde
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: endpoint(porta: porta), group: grupo,
            allowInsecure: true, teto: .seconds(30)
        )

        let tarefa = Task { try await sessao.login(user: "eu@x.com", password: "senha") }
        try await Task.sleep(for: .milliseconds(120))
        tarefa.cancel()

        // Teto de 30s: se o cancelamento não acordasse a espera, isto ficaria
        // pendurado bem além do que o teste tolera.
        await #expect(throws: CancellationError.self) { try await tarefa.value }
        await sessao.logout()
    }
}

@Suite("IMAP: o corte de linhas")
struct CRLFLineDecoderTests {
    private func canal(_ pendencia: PendenciaDeBytes = PendenciaDeBytes()) -> EmbeddedChannel {
        let canal = EmbeddedChannel()
        try! canal.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(CRLFLineDecoder(pendencia: pendencia))
        )
        return canal
    }

    /// As linhas lógicas que saem quando os bytes entram nessas fatias.
    private func linhas(_ escritas: [[UInt8]]) throws -> [String] {
        let canal = canal()
        var saida: [String] = []
        for escrita in escritas {
            var entrada = canal.allocator.buffer(capacity: escrita.count)
            entrada.writeBytes(escrita)
            try canal.writeInbound(entrada)
            while let linha = try canal.readInbound(as: ByteBuffer.self) {
                saida.append(String(buffer: linha))
            }
        }
        _ = try? canal.finish()
        return saida
    }

    @Test("Corta por CRLF e entrega a linha sem o terminador")
    func corta() throws {
        let canal = canal()
        var entrada = canal.allocator.buffer(capacity: 32)
        entrada.writeString("* OK um\r\nA0001 OK dois\r\n")
        try canal.writeInbound(entrada)
        let primeira = try canal.readInbound(as: ByteBuffer.self)
        let segunda = try canal.readInbound(as: ByteBuffer.self)
        #expect(primeira.map { String(buffer: $0) } == "* OK um")
        #expect(segunda.map { String(buffer: $0) } == "A0001 OK dois")
        _ = try canal.finish()
    }

    @Test("Linha sem terminador acima do teto vira erro, e não memória sem fim")
    func tetoDaLinha() throws {
        // Sem teto, quem despeja bytes sem `\n` faz o buffer crescer até a
        // memória acabar — negação de serviço com uma conexão só. A mensagem
        // faz parte do que se promete: é ela que diz o que aconteceu em vez de
        // deixar um erro de biblioteca em inglês vazar para a tela.
        let canal = canal()
        var entrada = canal.allocator.buffer(capacity: CRLFLineDecoder.tetoDaLinha + 64)
        entrada.writeString(String(repeating: "x", count: CRLFLineDecoder.tetoDaLinha + 1))
        #expect(throws: SyncError.resposta(
            "O servidor IMAP mandou uma linha maior que \(CRLFLineDecoder.tetoDaLinha) bytes sem terminador."
        )) { try canal.writeInbound(entrada) }
        _ = try? canal.finish()
    }

    @Test("O teto de linha não conta os bytes do literal")
    func tetoDaLinhaIgnoraOLiteral() throws {
        // 68 KiB de corpo, entregues em duas leituras cortadas **exatamente**
        // no fim do literal. Se a contagem do teto de linha incluir o corpo, a
        // segunda varredura vê 68 KiB "sem terminador" e a conexão morre — uma
        // falha que depende da segmentação TCP, acusa o servidor de algo que
        // ele não fez, e de quebra torna o teto de literal inalcançável.
        let corpo = String(repeating: "x", count: 68 * 1024)
        let cabeca = Array("* 1 FETCH (UID 9001 BODY[TEXT] {\(corpo.utf8.count)}\r\n".utf8)
            + Array(corpo.utf8)
        let saida = try linhas([cabeca, Array(")\r\n".utf8)])
        #expect(saida.count == 1)
        #expect(saida.first?.hasSuffix("xxx)") == true)
        #expect(saida.first?.utf8.count == cabeca.count + 1)
    }

    @Test("Literais colados não crescem sem fim: a linha lógica inteira tem teto")
    func tetoDaLinhaLogica() throws {
        // O teto de linha rearmava depois de **cada** literal, e o de literal
        // media um de cada vez — ninguém olhava a soma. Como a linha lógica só
        // acaba num `\n` que não abre literal, um servidor que encadeia literais
        // faz o buffer crescer sem limite, sem emitir nada, e sem emitir nada
        // nem o teto de tempo dispara. Medido antes do conserto: 40 MiB
        // absorvidos, `readInbound` devolvendo `nil` nos 40 ciclos, zero erros.
        //
        // MUTAÇÃO QUE ISTO PEGA: apagar as chamadas de
        // `confereTetoDaLinhaLogica` (ou trocar o teto por `Int.max`) faz este
        // teste absorver os 40 MiB calado e falhar por "esperava um erro".
        let canal = canal()
        let pedaco = 1024 * 1024
        let corpo = [UInt8](repeating: UInt8(ascii: "x"), count: pedaco)
        var absorvidos = 0
        #expect(throws: SyncError.self) {
            // Um literal por escrita, todos colados na MESMA linha lógica:
            // nenhuma delas termina em `\n` que não abra literal.
            for _ in 0..<40 {
                var entrada = canal.allocator.buffer(capacity: pedaco + 64)
                entrada.writeString("Y {\(pedaco)}\r\n")
                entrada.writeBytes(corpo)
                try canal.writeInbound(entrada)
                absorvidos += 1
            }
        }
        // O teto é de 16 MiB e cada volta traz 1 MiB: a recusa vem bem antes
        // das 40. Sem esta afirmação, um erro na primeira volta passaria.
        #expect(absorvidos > 1)
        #expect(absorvidos < 40)
        _ = try? canal.finish()
    }

    @Test("Um corpo grande, sozinho, continua passando — o teto da soma não o pega")
    func linhaLogicaGrandeMasLegitima() throws {
        // O contrapeso do teste acima: o teto novo não pode estreitar o que já
        // era permitido. Um FETCH com um corpo de 8 MiB — o máximo que o teto
        // de literal deixa passar — atravessa inteiro.
        let corpo = [UInt8](repeating: UInt8(ascii: "x"), count: CRLFLineDecoder.tetoDoLiteral)
        let cabeca = Array("* 1 FETCH (UID 9001 BODY[TEXT] {\(corpo.count)}\r\n".utf8) + corpo
        let saida = try linhas([cabeca, Array(")\r\n".utf8)])
        #expect(saida.count == 1)
        #expect(saida.first?.utf8.count == cabeca.count + 1)
    }

    @Test("Literal anunciado acima do teto é recusado, dizendo o tamanho e o UID")
    func tetoDoLiteral() throws {
        // O tamanho vem declarado pelo servidor. Aceitar `{9999999999}` é
        // entregar a memória do processo a quem estiver do outro lado; o corpo
        // de texto mais gordo que existe cabe em oito mebibytes.
        //
        // A mensagem carrega tamanho e UID porque quem carrega (Task 13) pula
        // o corpo desta mensagem e segue com as outras — e um log sem o UID não
        // diz qual foi pulada.
        let canal = canal()
        var entrada = canal.allocator.buffer(capacity: 64)
        entrada.writeString("* 1 FETCH (UID 9001 BODY[TEXT] {99999999}\r\n")
        do {
            try canal.writeInbound(entrada)
            Issue.record("O literal gigante deveria ter sido recusado.")
        } catch let erro as SyncError {
            guard case .resposta(let detalhe) = erro else {
                Issue.record("Esperava `.resposta`, veio \(erro).")
                return
            }
            #expect(detalhe.contains("99999999"))
            #expect(detalhe.contains("UID 9001"))
        }
        _ = try? canal.finish()
    }

    @Test("Tamanho de literal absurdo derruba a conexão em vez de dessincronizar calado")
    func tamanhoAbsurdo() throws {
        // Treze dígitos não é um corpo, é uma conexão que não dá mais para
        // acompanhar. Seguir lendo a linha como se o literal não existisse faz
        // o conteúdo passar a ser interpretado como protocolo — errado e mudo,
        // que é a pior combinação.
        let canal = canal()
        var entrada = canal.allocator.buffer(capacity: 64)
        entrada.writeString("* 1 FETCH (BODY[TEXT] {12345678901234}\r\n")
        do {
            try canal.writeInbound(entrada)
            Issue.record("O tamanho absurdo deveria ter derrubado a conexão.")
        } catch let erro as SyncError {
            guard case .resposta(let detalhe) = erro else {
                Issue.record("Esperava `.resposta`, veio \(erro).")
                return
            }
            #expect(detalhe.contains("sincronia"))
        }
        _ = try? canal.finish()
    }

    @Test("O literal atravessa duas leituras sem partir um caractere ao meio")
    func literalPartidoEntreLeituras() throws {
        // "ação" tem seis bytes e quatro caracteres. Se cada pedaço que chega
        // da rede for decodificado sozinho, o "ç" cortado entre `0xC3` e `0xA7`
        // vira dois `U+FFFD` — e como `U+FFFD` ocupa três bytes, a contagem do
        // literal escorrega junto e o "o" some.
        let cabeca = Array("* 1 FETCH (UID 9 BODY[TEXT] {6}\r\na".utf8) + [0xC3]
        let rabo: [UInt8] = [0xA7, 0xC3, 0xA3] + Array("o)\r\n".utf8)
        #expect(try linhas([cabeca, rabo]) == ["* 1 FETCH (UID 9 BODY[TEXT] {6}\r\nação)"])
    }

    @Test("Byte a byte dá exatamente a mesma linha lógica")
    func byteAByte() throws {
        let resposta = "* 1 FETCH (UID 9 BODY[TEXT] {6}\r\nação)\r\n"
        let umPorVez = Array(resposta.utf8).map { [$0] }
        #expect(try linhas(umPorVez) == ["* 1 FETCH (UID 9 BODY[TEXT] {6}\r\nação)"])
    }

    @Test("Um literal `{0}` não segura o resto da linha nem a resposta seguinte")
    func literalVazio() throws {
        // Corpo vazio existe: convite de agenda, mensagem só com anexo. Um
        // framer que entra em "modo literal" com tamanho zero fica esperando
        // bytes que já chegaram, e a resposta tagueada morre de teto de tempo
        // culpando o servidor.
        let tudo = Array("* 1 FETCH (UID 9 BODY[TEXT] {0}\r\n)\r\nA0002 OK done\r\n".utf8)
        #expect(try linhas([tudo]) == ["* 1 FETCH (UID 9 BODY[TEXT] {0}\r\n)", "A0002 OK done"])
    }

    @Test("Bytes presos sem terminador ficam contados para quem precisa saber")
    func pendenciaContada() throws {
        // É este número que a fronteira do STARTTLS consulta: meia linha parada
        // dentro do decodificador é conversa em claro que o túnel cobriria.
        let pendencia = PendenciaDeBytes()
        let canal = canal(pendencia)
        var entrada = canal.allocator.buffer(capacity: 32)
        entrada.writeString("* OK inteira\r\n* OK meia")
        try canal.writeInbound(entrada)
        #expect(try canal.readInbound(as: ByteBuffer.self).map { String(buffer: $0) } == "* OK inteira")
        #expect(pendencia.bytes == Array("* OK meia".utf8).count)
        _ = try? canal.finish()
    }

    @Test("O rabo truncado é descartado, e não promovido a resposta")
    func rabosTruncadosSaoDescartados() throws {
        // `A0001 OK` sem `\r\n` é um pedaço do que o servidor ainda ia
        // escrever. Emiti-lo como linha inteira faria um status pela metade
        // virar status válido.
        let canal = canal()
        var entrada = canal.allocator.buffer(capacity: 16)
        entrada.writeString("A0001 OK")
        try canal.writeInbound(entrada)
        #expect(try canal.readInbound(as: ByteBuffer.self) == nil)
        _ = try? canal.finish()
        #expect(try canal.readInbound(as: ByteBuffer.self) == nil)
    }
}
