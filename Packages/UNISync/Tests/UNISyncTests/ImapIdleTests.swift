import Foundation
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// O `IDLE` do RFC 2177 — o que faz uma mensagem nova aparecer em segundos em
/// vez de esperar o próximo minuto do relógio.
///
/// **Nada aqui toca rede externa**: o `FakeImapServer` roda em `127.0.0.1`,
/// dentro do processo do teste.
@Suite("IMAP: IDLE")
struct ImapIdleTests {
    private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
        grupo.shutdownGracefully { _ in }
    }

    private func roteiro(
        idle: [String], atrasoDoIdle: TimeInterval = 0
    ) -> FakeImapServer.Script {
        .init(
            replies: [
                "LOGIN": ["TAG OK LOGIN completed"],
                "CAPABILITY": [
                    "* CAPABILITY IMAP4rev1 IDLE STARTTLS",
                    "TAG OK CAPABILITY completed",
                ],
                "IDLE": idle,
                "DONE": ["TAG OK IDLE terminated"],
                "NOOP": ["TAG OK NOOP completed"],
                "LOGOUT": ["* BYE tchau", "TAG OK LOGOUT completed"],
            ],
            atrasos: atrasoDoIdle > 0 ? ["IDLE": atrasoDoIdle] : [:]
        )
    }

    /// Sobe o servidor, conecta e autentica.
    private func sessao(
        _ script: FakeImapServer.Script, grupo: MultiThreadedEventLoopGroup, porta: Int
    ) async throws -> ImapSession {
        let sessao = try await ImapSession.connectForRehearsal(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo
        )
        try await sessao.login(user: "eu@x.com", password: "senha")
        return sessao
    }

    // MARK: A parte pura

    @Test("O IDLE e o DONE saem como o protocolo os escreve")
    func comandos() {
        #expect(ImapWire.idle(tag: "A007") == "A007 IDLE")
        // `DONE` é a única linha do protocolo **sem tag**: dar-lhe uma faria o
        // servidor não reconhecer o fim do IDLE.
        #expect(ImapWire.done() == "DONE")
    }

    @Test("Só EXISTS, EXPUNGE e FETCH acordam quem está em IDLE")
    func avisosDeMudanca() {
        // Acordar por `RECENT` ou por um `OK` de manutenção gastaria um ciclo
        // de rede por notícia que não muda nada no banco.
        #expect(ImapChannelHandler.ehAvisoDeMudanca(.exists(2)))
        #expect(ImapChannelHandler.ehAvisoDeMudanca(.expunge(3)))
        #expect(ImapChannelHandler.ehAvisoDeMudanca(.fetch(
            ImapWire.FetchLine(
                uid: 9, flags: ["\\Seen"], internalDate: nil,
                from: nil, to: nil, cc: nil, subject: nil, text: nil
            )
        )))
        #expect(!ImapChannelHandler.ehAvisoDeMudanca(.outra("+ idling")))
        #expect(!ImapChannelHandler.ehAvisoDeMudanca(.ok(code: "CAPABILITY", value: "IMAP4rev1")))
    }

    @Test("O aviso que chega ANTES de a espera se registrar acorda NA HORA")
    func avisoAntesDaEsperaNaoSePerde() async throws {
        // A janela é real e é de um `await`: entre armar a escuta e registrar a
        // espera, o servidor pode já ter mandado o `* 2 EXISTS`. Contra o
        // servidor falso em loopback esse lado da corrida quase nunca cai, e um
        // teste que só quase prova não prova — por isso a corrida é encenada
        // aqui, no handler, sem rede nenhuma.
        //
        // **A afirmação é sobre o instante, e não sobre o valor.** Um aviso
        // anotado e não respondido na hora ainda sairia `true` — só que 25
        // minutos depois, com a mensagem nova esperando esse tempo todo para
        // aparecer. É exatamente a queixa que esta tarefa existe para consertar,
        // de volta por outra porta.
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let handler = ImapChannelHandler()

        handler.armaIdle()
        handler.acordaIdle(true)
        let acordou = await comTeto {
            await handler.esperaIdle(limite: .seconds(30), on: grupo.next())
        }

        #expect(acordou == true)
    }

    @Test("Sem escuta armada, a espera devolve na hora em vez de prender para sempre")
    func semEscutaArmadaNaoPrende() async throws {
        // `esperaIdle` sobre uma escuta que não foi armada devolve na hora, sem
        // prender continuation nenhuma. Prendê-la seria pior do que devolver
        // errado: o teto do IDLE só acorda quem está **armado**, então a
        // continuation ficaria pendurada para sempre e a conta pararia de
        // sincronizar em silêncio.
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }
        let handler = ImapChannelHandler()

        let acordou = await comTeto {
            await handler.esperaIdle(limite: .seconds(30), on: grupo.next())
        }

        #expect(acordou == false)
    }

    /// A espera, com **teto de teste**: `nil` quando ela não voltou a tempo.
    ///
    /// Existe porque as duas afirmações acima são sobre o **instante**, e não
    /// sobre o valor: sem teto, uma espera que devolvesse a resposta certa
    /// tarde demais passaria, e uma que não devolvesse nunca travaria a suíte
    /// sem falhar — o pior dos dois mundos.
    private func comTeto(
        _ segundos: TimeInterval = 2, _ espera: @escaping @Sendable () async -> Bool
    ) async -> Bool? {
        // A espera corre numa `Task` **solta**, e não num grupo estruturado: o
        // defeito que este teto existe para pegar é justamente uma continuation
        // que nunca é retomada, e um grupo estruturado esperaria por ela para
        // sempre — a suíte travaria em vez de falhar, que é o pior dos dois
        // mundos. Solta, o teste desiste no prazo e diz o que viu.
        let caixa = CaixaDeResposta()
        let tarefa = Task { caixa.guarda(await espera()) }
        let limite = Date().addingTimeInterval(segundos)
        while caixa.valor == nil, Date() < limite {
            try? await Task.sleep(for: .milliseconds(10))
        }
        tarefa.cancel()
        return caixa.valor
    }

    /// Um lugar para a resposta da espera atravessar a fronteira de isolação.
    private final class CaixaDeResposta: @unchecked Sendable {
        private let lock = NSLock()
        private var resposta: Bool?
        func guarda(_ valor: Bool) { lock.lock(); resposta = valor; lock.unlock() }
        var valor: Bool? { lock.lock(); defer { lock.unlock() }; return resposta }
    }

    // MARK: Contra o servidor falso

    @Test("As capacidades são lidas DEPOIS do login")
    func capacidadesDepoisDoLogin() async throws {
        let servidor = FakeImapServer(script: roteiro(idle: ["+ idling"]))
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await sessao(roteiro(idle: ["+ idling"]), grupo: grupo, porta: porta)
        let capacidades = try await sessao.capabilities()
        await sessao.logout()

        #expect(capacidades.contains("IDLE"))
        // A ordem importa: a lista muda com a autenticação, e servidor que só
        // oferece `IDLE` a sessão autenticada existe.
        let comandos = servidor.commands
        let login = try #require(comandos.firstIndex { $0.contains("LOGIN") })
        let capability = try #require(comandos.firstIndex { $0.hasSuffix("CAPABILITY") })
        #expect(login < capability)
    }

    @Test("O `* EXISTS` acorda o IDLE, e o DONE fecha o comando")
    func existsAcorda() async throws {
        // O caminho inteiro, de ponta a ponta: o servidor responde `+ idling`,
        // despeja o aviso, e o cliente acorda, escreve o `DONE` e fecha o
        // comando. Qual dos dois lados da corrida cai aqui é do agendador — os
        // dois têm prova própria acima e abaixo.
        let script = roteiro(idle: ["+ idling", "* 2 EXISTS"])
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await sessao(script, grupo: grupo, porta: porta)
        let acordou = try await sessao.idle(limite: .seconds(5))
        await sessao.logout()

        #expect(acordou)
        // O `DONE` sai sempre: sem ele a conexão fica num estado em que nenhum
        // comando seguinte é aceito, e o delta morreria de teto culpando o
        // servidor.
        #expect(servidor.commands.contains("DONE"))
    }

    @Test("O aviso que chega DEPOIS de a espera começar também acorda")
    func existsAtrasadoAcorda() async throws {
        // O outro lado da corrida: aqui a espera já está registrada quando o
        // aviso chega. Os dois caminhos existem no código, e um teste só
        // deixaria metade sem prova.
        let script = roteiro(idle: ["+ idling", "* 2 EXISTS"], atrasoDoIdle: 0.15)
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await sessao(script, grupo: grupo, porta: porta)
        let acordou = try await sessao.idle(limite: .seconds(5))
        await sessao.logout()

        #expect(acordou)
    }

    @Test("Sem aviso nenhum, o IDLE volta no teto — e a sessão continua servindo")
    func tetoDevolveSemAtividade() async throws {
        let script = roteiro(idle: ["+ idling"])
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await sessao(script, grupo: grupo, porta: porta)
        let acordou = try await sessao.idle(limite: .milliseconds(150))
        // A prova de que o `DONE` fechou o comando de verdade: um comando
        // seguinte na MESMA conexão responde. Sem o `DONE`, o servidor
        // continuaria em IDLE e este `NOOP` morreria de teto de tempo.
        _ = try await sessao.run { "\($0) NOOP" }
        await sessao.logout()

        #expect(acordou == false)
        #expect(servidor.commands.contains("DONE"))
    }

    @Test("Cancelar durante o IDLE escreve o DONE antes de morrer")
    func cancelamentoFechaOIdle() async throws {
        let script = roteiro(idle: ["+ idling"])
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await sessao(script, grupo: grupo, porta: porta)
        let tarefa = Task { try await sessao.idle(limite: .seconds(30)) }
        // Tempo de o `IDLE` chegar ao servidor antes de o cancelamento entrar.
        try await Task.sleep(for: .milliseconds(150))
        tarefa.cancel()
        await #expect(throws: CancellationError.self) { _ = try await tarefa.value }
        await sessao.logout()

        // Cancelar não é motivo para deixar a conexão presa: o `DONE` sai, e só
        // então o laço de fora tem o direito de morrer.
        #expect(servidor.commands.contains("DONE"))
    }
}
