import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("O protocolo SMTP, em texto puro")
struct SmtpWireTests {
    // MARK: A leitura das respostas

    @Test("O hífen na quarta coluna diz que a resposta continua")
    func continuacao() {
        // Ler isto ao contrário é a diferença entre esperar para sempre (a
        // última linha tomada por continuação) e mandar o próximo comando no
        // meio do EHLO (uma continuação tomada por fim).
        #expect(!SmtpWire.ehFinal("250-STARTTLS"))
        #expect(SmtpWire.ehFinal("250 OK"))
        #expect(SmtpWire.ehFinal("250"))
    }

    @Test("O código sai dos três primeiros dígitos, e linha sem código não vira zero")
    func codigo() {
        #expect(SmtpWire.codigo("250 OK") == 250)
        #expect(SmtpWire.codigo("535-5.7.8 credencial") == 535)
        // Servidor falando fora do protocolo (um portal cativo devolvendo
        // HTML, por exemplo) não pode virar "código zero" em silêncio: quem
        // chama precisa saber que não entendeu nada.
        #expect(SmtpWire.codigo("<html>") == nil)
        #expect(SmtpWire.codigo("") == nil)
        #expect(SmtpWire.texto("250 OK, mandou bem") == "OK, mandou bem")
    }

    @Test("As capacidades são lidas por palavra, não por pedaço de texto")
    func capacidades() {
        let linhas = ["servidor.com diz oi", "SIZE 35882577", "STARTTLS", "AUTH PLAIN LOGIN"]
        #expect(SmtpWire.anuncia("STARTTLS", em: linhas))
        #expect(!SmtpWire.anuncia("STARTTLS", em: ["servidor.com diz oi", "SIZE 100"]))
        // "AUTHENTICATION" não anuncia "AUTH": um casamento por substring
        // mandaria credencial para um servidor que não pediu nenhuma.
        #expect(!SmtpWire.anuncia("AUTH", em: ["AUTHENTICATION-RESULTS x"]))
        #expect(SmtpWire.mecanismos(em: linhas) == ["PLAIN", "LOGIN"])
        #expect(SmtpWire.mecanismos(em: ["SIZE 10"]).isEmpty)
    }

    // MARK: As credenciais

    @Test("O AUTH PLAIN monta identidade, usuário e senha separados por NUL")
    func authPlain() {
        let comando = SmtpWire.authPlain(user: "eu@x.com", password: "senha")
        let base64 = String(comando.dropFirst("AUTH PLAIN ".count))
        let bytes = try? #require(Data(base64Encoded: base64))
        // A ordem e os dois NUL são o formato do RFC 4616. Montar isto errado
        // devolve 535 e a pessoa vai trocar uma senha que estava certa.
        #expect(Array(bytes!) == [0] + Array("eu@x.com".utf8) + [0] + Array("senha".utf8))
    }

    @Test("O AUTH LOGIN manda cada metade em base64 sozinha")
    func authLogin() {
        #expect(SmtpWire.authLogin() == "AUTH LOGIN")
        #expect(SmtpWire.base64("eu@x.com") == Data("eu@x.com".utf8).base64EncodedString())
    }

    // MARK: O envelope

    @Test("O envelope põe os endereços entre sinais de menor e maior")
    func envelope() {
        #expect(SmtpWire.mailFrom("eu@x.com") == "MAIL FROM:<eu@x.com>")
        #expect(SmtpWire.rcptTo("ela@y.com") == "RCPT TO:<ela@y.com>")
        #expect(SmtpWire.ehlo(host: "[127.0.0.1]") == "EHLO [127.0.0.1]")
    }

    // MARK: O DATA

    @Test("A linha que começa com ponto ganha um ponto a mais")
    func dotStuffing() {
        // **É a regra que ninguém vê falhar.** Uma linha começando com "." —
        // uma citação com "...", uma lista colada de outro lugar — encerraria
        // o DATA no meio da mensagem: o destinatário recebe a mensagem
        // cortada, e o resto do corpo vira comando para o servidor.
        let corpo = SmtpWire.dotStuffed("linha um\n.escondido\nfim")
        #expect(corpo.contains("\r\n..escondido\r\n"))
        #expect(corpo.hasSuffix("\r\n.\r\n"))
        // O ponto **no meio** da linha não é tocado.
        #expect(SmtpWire.dotStuffed("a.b").contains("a.b"))
    }

    @Test("O corpo do DATA sai com CRLF mesmo vindo com LF")
    func dataNormaliza() {
        let corpo = SmtpWire.dotStuffed("um\ndois")
        #expect(corpo == "um\r\ndois\r\n.\r\n")
    }

    // MARK: Os erros

    @Test("O 4xx do SMTP é transitório, e a fila tem de tentar de novo")
    func transitorio() {
        // Greylisting é o caso mais comum de primeira entrega a um domínio
        // novo, e a única forma de passar por ele é tentar mais tarde. Tratado
        // como permanente, o envio pararia para sempre por causa de uma
        // resposta que dizia "daqui a pouco".
        let erro = SmtpWire.erro(SmtpWire.Reply(code: 451, text: "greylisted", lines: []))
        #expect(erro == .transitorio("o servidor de envio respondeu 451: greylisted"))
        #expect(!OutboxExecutor.ehPermanente(erro))
    }

    @Test("Credencial recusada pede reconexão, não repetição")
    func autenticacao() {
        for codigo in [530, 534, 535] {
            #expect(SmtpWire.erro(SmtpWire.Reply(code: codigo, text: "no", lines: [])) == .autenticacao)
        }
        // E ela **para** a fila: insistir com a senha errada não conserta, e
        // esconderia da pessoa a única frase que diz o que aconteceu.
        #expect(OutboxExecutor.ehPermanente(.autenticacao))
    }

    @Test("O 5xx que não é credencial para a fila com a frase do servidor")
    func permanente() {
        let erro = SmtpWire.erro(
            SmtpWire.Reply(code: 550, text: "usuário não existe", lines: [])
        )
        // **Não** vira `.servidor`: `ehPermanente` lê o número daquele caso
        // como código HTTP, onde 5xx é servidor passando mal e portanto
        // repetível. Um endereço digitado errado seria repetido para sempre.
        #expect(erro == .recusado("o servidor de envio respondeu 550: usuário não existe"))
        #expect(OutboxExecutor.ehPermanente(erro))
    }

    // MARK: A descoberta do servidor

    @Test("O servidor de envio é derivado do de leitura")
    func descoberta() {
        func destino(_ host: String) -> SmtpEndpoint? {
            SmtpDiscovery.endpoint(forImap: ImapEndpoint(host: host, port: 993, security: .tls))
        }
        #expect(destino("imap.gmail.com")?.host == "smtp.gmail.com")
        #expect(destino("imap.mail.me.com")?.host == "smtp.mail.me.com")
        #expect(destino("imap.hostinger.com")?.host == "smtp.hostinger.com")
        // A exceção que a troca de prefixo não pega.
        #expect(destino("outlook.office365.com")?.host == "smtp.office365.com")
        // Host genérico que serve as duas pontas fica como está — um
        // `smtp.mail.…` não existiria.
        #expect(destino("mail.meudominio.com.br")?.host == "mail.meudominio.com.br")
        #expect(destino("meudominio.com.br")?.host == "smtp.meudominio.com.br")
        // A porta é sempre a de submissão, com STARTTLS obrigatório: 587 em
        // claro sem subir o túnel é a senha da pessoa no fio.
        #expect(destino("imap.gmail.com")?.port == 587)
        #expect(destino("imap.gmail.com")?.security == .startTLS)
        // Conta sem servidor de leitura não tem de onde derivar.
        #expect(SmtpDiscovery.endpoint(forImap: nil) == nil)
    }
}
