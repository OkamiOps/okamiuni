import Foundation
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Desligar o grupo de event loops fora do contexto assíncrono.
///
/// `syncShutdownGracefully()` é indisponível de dentro de uma função `async`
/// nesta versão do NIO — ela bloqueia a thread —, e `defer` não pode `await`.
/// A função síncrona é o desvio mínimo que mantém o desligamento no `defer`,
/// que é onde ele precisa estar para valer também no caminho de erro.
private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
    try? grupo.syncShutdownGracefully()
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
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true
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
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true
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
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true
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
                allowInsecure: true
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
            endpoint: endpoint(porta: porta), group: grupo, allowInsecure: true
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
}
