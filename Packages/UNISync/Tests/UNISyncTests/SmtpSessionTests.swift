import Foundation
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

@Suite("A sessão SMTP")
struct SmtpSessionTests {
    /// Um grupo por teste, desligado sem bloquear a thread de quem chama — a
    /// mesma razão registrada em `FakeImapServer.stop`.
    private func grupo() -> MultiThreadedEventLoopGroup {
        MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Conecta ao servidor falso em claro. `allowInsecure` é a alavanca de
    /// teste do `ImapSession`, aqui pela mesma razão: o servidor falso roda no
    /// loopback sem certificado, e exigir TLS ali seria gerar um certificado
    /// para provar coisas que não são sobre TLS.
    private func conecta(
        porta: Int, grupo: any EventLoopGroup, teto: TimeAmount = .seconds(5)
    ) async throws -> SmtpSession {
        try await SmtpSession.connect(
            endpoint: SmtpEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo, allowInsecure: true, teto: teto
        )
    }

    // MARK: O caminho inteiro

    @Test("O envio percorre EHLO, AUTH, MAIL, RCPT, DATA e QUIT, nessa ordem")
    func caminhoCompleto() async throws {
        let servidor = FakeSmtpServer(script: .aceitaTudo())
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        let sessao = try await conecta(porta: porta, grupo: grupo)
        try await sessao.login(user: "eu@meudominio.com.br", password: "senha-de-app")
        try await sessao.send(
            from: "eu@meudominio.com.br",
            recipients: ["marina@clientepremium.com", "socio@meudominio.com.br"],
            raw: "Subject: oi\r\n\r\ncorpo"
        )
        await sessao.quit()

        let verbos = servidor.comandos.map { String($0.split(separator: " ").first ?? "") }
        #expect(verbos == ["EHLO", "AUTH", "MAIL", "RCPT", "RCPT", "DATA", "QUIT"])
        // Um `RCPT TO` por destinatário: mandar dois numa linha só é o erro
        // que faz o segundo nunca receber, sem nada acusando.
        #expect(servidor.comandos.contains("RCPT TO:<marina@clientepremium.com>"))
        #expect(servidor.comandos.contains("RCPT TO:<socio@meudominio.com.br>"))
        #expect(servidor.comandos.contains("MAIL FROM:<eu@meudominio.com.br>"))
        #expect(servidor.corpos == ["Subject: oi\r\n\r\ncorpo"])
    }

    @Test("A linha que começa com ponto chega inteira do outro lado")
    func dotStuffingNoFio() async throws {
        let servidor = FakeSmtpServer(script: .aceitaTudo())
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        let sessao = try await conecta(porta: porta, grupo: grupo)
        try await sessao.login(user: "eu@x.com", password: "s")
        try await sessao.send(
            from: "eu@x.com", recipients: ["ela@y.com"],
            raw: "Subject: oi\r\n\r\n.tudo o que vier depois"
        )
        await sessao.quit()

        // Sem o ponto duplicado, o servidor teria fechado o `DATA` na linha do
        // ponto e o resto do corpo viraria comando: a mensagem chega cortada e
        // ninguém relaciona o `500` com o texto.
        #expect(servidor.corpos == ["Subject: oi\r\n\r\n..tudo o que vier depois"])
    }

    // MARK: A senha e o túnel

    @Test("Servidor sem STARTTLS não recebe credencial nenhuma")
    func semStartTLS() async throws {
        // Um atacante no meio consegue **tirar** a linha `250-STARTTLS` do
        // EHLO em claro — é o ataque de stripping, e é a razão de a submissão
        // exigir TLS. Seguir sem túnel "porque o servidor não ofereceu" seria
        // mandar a senha exatamente para quem tirou a linha.
        let servidor = FakeSmtpServer(script: FakeSmtpServer.Script(replies: [
            "EHLO": ["250-okamiuni.falso", "250 AUTH PLAIN"],
            "QUIT": ["221 tchau"],
        ]))
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        await #expect(throws: SyncError.self) {
            // Sem `allowInsecure`: é o caminho de produção, e ele tem de
            // recusar.
            _ = try await SmtpSession.connect(
                endpoint: SmtpEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                group: grupo, allowInsecure: false, teto: .seconds(5)
            )
        }
        // Nenhum `AUTH` saiu — a promessa não é só falhar, é falhar **antes**
        // de a senha existir no fio.
        #expect(!servidor.comandos.contains { $0.hasPrefix("AUTH") })
    }

    @Test("STARTTLS recusado é erro de TLS, nunca de rede")
    func startTLSRecusado() async throws {
        // `.rede` manda a pessoa conferir a conexão; `.tls` manda conferir a
        // porta e a forma de TLS da conta — que é o que de fato resolve.
        let servidor = FakeSmtpServer(script: FakeSmtpServer.Script(replies: [
            "EHLO": ["250-okamiuni.falso", "250 STARTTLS"],
            "STARTTLS": ["454 4.7.0 TLS indisponível agora"],
            "QUIT": ["221 tchau"],
        ]))
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        do {
            _ = try await SmtpSession.connect(
                endpoint: SmtpEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
                group: grupo, allowInsecure: false, teto: .seconds(5)
            )
            Issue.record("A conexão deveria ter falhado.")
        } catch let erro as SyncError {
            guard case .tls = erro else {
                Issue.record("Esperava `.tls`, veio \(erro).")
                return
            }
        }
    }

    // MARK: As credenciais

    @Test("Sem PLAIN anunciado, a sessão cai no AUTH LOGIN")
    func authLogin() async throws {
        var roteiro = FakeSmtpServer.Script.aceitaTudo(
            capacidades: ["250-okamiuni.falso", "250 AUTH LOGIN"]
        )
        // As três respostas do `AUTH LOGIN`, na ordem: pede usuário, pede
        // senha, aceita.
        roteiro.rounds["AUTH"] = [
            ["334 VXNlcm5hbWU6"], ["334 UGFzc3dvcmQ6"], ["235 2.7.0 autenticado"],
        ]
        let servidor = FakeSmtpServer(script: roteiro)
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        let sessao = try await conecta(porta: porta, grupo: grupo)
        try await sessao.login(user: "eu@x.com", password: "senha")
        await sessao.quit()

        // Cada metade em base64 sozinha, na ordem. Provedores antigos são os
        // únicos a oferecer só isto, e sem a reserva a conta não enviaria nada.
        #expect(servidor.comandos.contains("AUTH LOGIN"))
        #expect(servidor.comandos.contains(SmtpWire.base64("eu@x.com")))
        #expect(servidor.comandos.contains(SmtpWire.base64("senha")))
        // A senha nunca aparece em claro no fio.
        #expect(!servidor.comandos.contains { $0.contains("senha") })
    }

    @Test("Senha recusada vira erro de autenticação, e não uma falha de rede")
    func senhaRecusada() async throws {
        var roteiro = FakeSmtpServer.Script.aceitaTudo()
        roteiro.replies["AUTH"] = ["535 5.7.8 usuário ou senha inválidos"]
        let servidor = FakeSmtpServer(script: roteiro)
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        let sessao = try await conecta(porta: porta, grupo: grupo)
        await #expect(throws: SyncError.autenticacao) {
            try await sessao.login(user: "eu@x.com", password: "errada")
        }
        await sessao.quit()
    }

    // MARK: As recusas do envelope

    @Test("Destinatário recusado derruba o envio inteiro, dizendo qual foi")
    func destinatarioRecusado() async throws {
        var roteiro = FakeSmtpServer.Script.aceitaTudo()
        roteiro.rounds["RCPT"] = [
            ["250 2.1.5 ok"], ["550 5.1.1 usuário desconhecido"],
        ]
        let servidor = FakeSmtpServer(script: roteiro)
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        let sessao = try await conecta(porta: porta, grupo: grupo)
        try await sessao.login(user: "eu@x.com", password: "s")
        do {
            try await sessao.send(
                from: "eu@x.com", recipients: ["boa@y.com", "torta@y.com"], raw: "corpo"
            )
            Issue.record("O envio deveria ter falhado.")
        } catch let erro as SyncError {
            // Seguir com os que sobraram entregaria a mensagem pela metade sem
            // ninguém saber quem ficou de fora. E o endereço entra na frase:
            // é o que a pessoa precisa para corrigir.
            #expect(erro.mensagem.contains("torta@y.com"))
        }
        await sessao.quit()
        // Nada foi entregue: o `DATA` nem chegou a abrir.
        #expect(servidor.corpos.isEmpty)
    }

    @Test("Recusa temporária do corpo é transitória, e a fila tenta de novo")
    func corpoAdiado() async throws {
        var roteiro = FakeSmtpServer.Script.aceitaTudo()
        roteiro.replies[FakeSmtpServer.chaveDoCorpo] = ["451 4.7.1 tente de novo em 5 minutos"]
        let servidor = FakeSmtpServer(script: roteiro)
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        let sessao = try await conecta(porta: porta, grupo: grupo)
        try await sessao.login(user: "eu@x.com", password: "s")
        do {
            try await sessao.send(from: "eu@x.com", recipients: ["ela@y.com"], raw: "corpo")
            Issue.record("O envio deveria ter falhado.")
        } catch let erro as SyncError {
            guard case .transitorio = erro else {
                Issue.record("Esperava `.transitorio`, veio \(erro).")
                return
            }
            #expect(!OutboxExecutor.ehPermanente(erro))
        }
        await sessao.quit()
    }

    @Test("Mensagem sem destinatário não abre conexão de envelope nenhuma")
    func semDestinatario() async throws {
        let servidor = FakeSmtpServer(script: .aceitaTudo())
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        let sessao = try await conecta(porta: porta, grupo: grupo)
        await #expect(throws: SyncError.self) {
            try await sessao.send(from: "eu@x.com", recipients: [], raw: "corpo")
        }
        await sessao.quit()
        #expect(!servidor.comandos.contains { $0.hasPrefix("MAIL") })
    }

    // MARK: O teto

    @Test("Servidor que emudece não prende o envio para sempre")
    func tetoDeTempo() async throws {
        // Servidor que aceita a conexão e não fala é caso comum (balanceador
        // que aceita e não repassa). Sem teto, o envio some numa espera eterna
        // e o app parece só estar devagar.
        let servidor = FakeSmtpServer(script: FakeSmtpServer.Script(greeting: "", replies: [:]))
        let porta = try servidor.start()
        let grupo = grupo()
        defer {
            servidor.stop()
            grupo.shutdownGracefully { _ in }
        }

        await #expect(throws: SyncError.self) {
            _ = try await self.conecta(porta: porta, grupo: grupo, teto: .milliseconds(200))
        }
    }
}
