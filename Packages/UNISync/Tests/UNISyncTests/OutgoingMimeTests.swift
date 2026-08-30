import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("A mensagem que sai, em RFC 5322")
struct OutgoingMimeTests {
    /// 22/08/2026, 14:03:11 em UTC. Fixo porque um teste que afirma o
    /// cabeçalho `Date:` não pode depender do segundo em que rodou.
    private let quando = Date(timeIntervalSince1970: 1_787_407_391)
    private let utc = TimeZone(identifier: "UTC")!

    private func mensagem(
        to: [OutgoingAddress] = [OutgoingAddress(name: "Marina", address: "marina@clientepremium.com")],
        cc: [OutgoingAddress] = [],
        bcc: [OutgoingAddress] = [],
        subject: String = "Contrato",
        plainText: String = "Segue em anexo.",
        html: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = []
    ) -> OutgoingMessage {
        OutgoingMessage(
            messageID: "abc-123@meudominio.com.br",
            accountID: "conta-a",
            from: OutgoingAddress(name: "Eu", address: "eu@meudominio.com.br"),
            to: to, cc: cc, bcc: bcc,
            subject: subject, plainText: plainText, html: html,
            inReplyTo: inReplyTo, references: references
        )
    }

    private func linhas(_ texto: String) -> [String] {
        texto.components(separatedBy: "\r\n")
    }

    // MARK: Os cabeçalhos

    @Test("A mensagem simples sai com os cabeçalhos na ordem, e o corpo depois da linha em branco")
    func mensagemSimples() {
        let texto = OutgoingMime.compose(mensagem(), date: quando, includeBcc: false)
        let partes = linhas(texto)
        #expect(partes[0] == "From: Eu <eu@meudominio.com.br>")
        #expect(partes[1] == "To: Marina <marina@clientepremium.com>")
        #expect(partes[2] == "Subject: Contrato")
        #expect(partes[4] == "Message-ID: <abc-123@meudominio.com.br>")
        #expect(partes.contains("MIME-Version: 1.0"))
        #expect(partes.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(partes.contains("Content-Transfer-Encoding: quoted-printable"))
        // A linha em branco separa cabeçalho de corpo — sem ela, o corpo é
        // lido como mais cabeçalhos e a mensagem chega vazia.
        let branco = try? #require(partes.firstIndex(of: ""))
        #expect(branco != nil)
        #expect(partes.last == "Segue em anexo.")
    }

    @Test("Toda linha termina em CRLF, nunca em LF sozinho")
    func terminadores() {
        let texto = OutgoingMime.compose(
            mensagem(plainText: "primeira\nsegunda"), date: quando, includeBcc: false
        )
        // Um LF sem CR antes é o defeito clássico de quem monta a mensagem com
        // `\n`: alguns servidores recusam o `DATA` inteiro, outros entregam a
        // mensagem com o corpo grudado numa linha só.
        for (indice, escalar) in Array(texto.unicodeScalars).enumerated() where escalar == "\n" {
            let anterior = Array(texto.unicodeScalars)[indice - 1]
            #expect(anterior == "\r")
        }
    }

    @Test("A cópia oculta só vira cabeçalho quando quem pede é o Gmail")
    func copiaOculta() {
        let comOculta = mensagem(bcc: [OutgoingAddress(name: "", address: "socio@meudominio.com.br")])
        let peloSmtp = OutgoingMime.compose(comOculta, date: quando, includeBcc: false)
        let peloGmail = OutgoingMime.compose(comOculta, date: quando, includeBcc: true)
        // No SMTP a cópia oculta viaja no `RCPT TO`. Um cabeçalho `Bcc` aqui a
        // mostraria para todo mundo que recebeu — o vazamento que nenhum
        // desfazer conserta.
        #expect(!peloSmtp.contains("Bcc:"))
        #expect(!peloSmtp.contains("socio@meudominio.com.br"))
        // No Gmail é o contrário: a API monta os destinatários a partir do
        // texto, então sem o cabeçalho a cópia oculta não é enviada a ninguém.
        #expect(peloGmail.contains("Bcc: socio@meudominio.com.br"))
        // E ela continua na lista de quem recebe, nos dois casos.
        #expect(comOculta.recipients.contains("socio@meudominio.com.br"))
    }

    @Test("anexo sai em mixed, com alternativa interna e base64 quebrado em 76")
    func attachmentUsesCorrectMultipartShape() throws {
        let attachment = try OutgoingAttachment(
            filename: "proposta final.pdf", mimeType: "application/pdf",
            data: Data(repeating: 0x41, count: 80)
        )
        let message = OutgoingMessage(
            messageID: "abc-123@meudominio.com.br", accountID: "conta-a",
            from: OutgoingAddress(name: "Eu", address: "eu@meudominio.com.br"),
            to: [OutgoingAddress(name: "Marina", address: "marina@clientepremium.com")],
            subject: "Contrato", plainText: "Segue.", html: "<strong>Segue.</strong>",
            attachments: [attachment]
        )
        let raw = OutgoingMime.compose(
            message, date: quando, includeBcc: false, boundary: "outer"
        )
        #expect(raw.contains("Content-Type: multipart/mixed; boundary=\"outer\""))
        #expect(raw.contains("Content-Type: multipart/alternative; boundary=\"outer-alt\""))
        #expect(raw.contains("Content-Disposition: attachment; filename*=utf-8''proposta%20final.pdf"))
        let encodedLines = raw.components(separatedBy: "\r\n")
            .filter { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") } }
        #expect(encodedLines.contains { $0.count == 76 })
        #expect(raw.contains("--outer--"))
    }

    @Test("Assunto com acento sai codificado em RFC 2047")
    func assuntoComAcento() {
        let texto = OutgoingMime.compose(
            mensagem(subject: "Reunião de terça"), date: quando, includeBcc: false
        )
        // Bytes crus num cabeçalho são o que faz "Reunião" virar "ReuniÃ£o" na
        // caixa de quem recebe — quando o servidor não recusa a mensagem antes.
        #expect(!texto.contains("Reunião de terça"))
        let esperado = "=?UTF-8?B?\(Data("Reunião de terça".utf8).base64EncodedString())?="
        #expect(texto.contains("Subject: \(esperado)"))
    }

    @Test("Assunto só em ASCII sai como veio")
    func assuntoSimples() {
        // Codificar o que não precisa deixaria todo assunto ilegível no texto
        // cru, e alguns filtros contam isso como sinal.
        #expect(OutgoingMime.encodeHeaderText("Contrato 2026") == "Contrato 2026")
    }

    @Test("Nome com vírgula é codificado, e não parte a lista em dois")
    func nomeComVirgula() {
        let lista = OutgoingMime.addressList([
            OutgoingAddress(name: "Duarte, Marina", address: "m@x.com"),
            OutgoingAddress(name: "Ricardo", address: "r@y.com"),
        ])
        // Escrito cru, "Duarte, Marina <m@x.com>" vira **dois** destinatários,
        // e o primeiro ("Duarte") não existe.
        #expect(!lista.contains("Duarte, Marina <m@x.com>"))
        #expect(lista.contains("=?UTF-8?B?"))
        #expect(lista.hasSuffix("Ricardo <r@y.com>"))
    }

    @Test("Endereço sem nome sai sozinho")
    func enderecoSemNome() {
        #expect(OutgoingMime.addressList([OutgoingAddress(name: "", address: "so@angulos.com")])
            == "so@angulos.com")
        // Nome igual ao endereço é o que o parser da entrada devolve quando não
        // havia nome nenhum; repeti-lo daria "x@y.com <x@y.com>".
        #expect(OutgoingMime.addressList([OutgoingAddress(name: "so@angulos.com", address: "so@angulos.com")])
            == "so@angulos.com")
    }

    @Test("A resposta carrega In-Reply-To e References")
    func resposta() {
        let texto = OutgoingMime.compose(
            mensagem(inReplyTo: "pai@servidor.com", references: ["avo@servidor.com", "pai@servidor.com"]),
            date: quando, includeBcc: false
        )
        // Sem estes dois, a resposta chega como conversa nova na caixa de quem
        // recebe — a thread se parte, e ninguém entende por quê.
        #expect(texto.contains("In-Reply-To: <pai@servidor.com>"))
        #expect(texto.contains("References: <avo@servidor.com> <pai@servidor.com>"))
    }

    @Test("A data sai em inglês, com fuso numérico")
    func data() {
        // Num aparelho em português, sem o locale POSIX, sairia "sex, 28 ago" —
        // e a linha `Date:` seria descartada por quem segue o RFC.
        #expect(OutgoingMime.rfc5322Date(quando, timeZone: utc) == "Sat, 22 Aug 2026 14:03:11 +0000")
    }

    // MARK: O corpo

    @Test("O corpo formatado sai em multipart/alternative, texto antes de HTML")
    func multipart() {
        let texto = OutgoingMime.compose(
            mensagem(plainText: "Olá", html: "<p><b>Olá</b></p>"),
            date: quando, includeBcc: false, boundary: "LINHA"
        )
        #expect(texto.contains("Content-Type: multipart/alternative; boundary=\"LINHA\""))
        let posicaoTexto = try? #require(texto.range(of: "Content-Type: text/plain"))
        let posicaoHTML = try? #require(texto.range(of: "Content-Type: text/html"))
        // A ordem é o contrato do `multipart/alternative`: o cliente mostra a
        // **última** parte que entende. Invertida, todo mundo veria o texto
        // pelado e a formatação seria escrita à toa.
        #expect(posicaoTexto!.lowerBound < posicaoHTML!.lowerBound)
        #expect(texto.contains("--LINHA"))
        #expect(texto.hasSuffix("--LINHA--"))
    }

    @Test("Sem formatação não há multipart nenhum")
    func semMultipart() {
        let texto = OutgoingMime.compose(mensagem(html: nil), date: quando, includeBcc: false)
        #expect(!texto.contains("multipart"))
        // HTML vazio conta como ausência: um `multipart` com uma parte vazia é
        // uma mensagem que alguns clientes mostram em branco.
        let vazio = OutgoingMime.compose(mensagem(html: ""), date: quando, includeBcc: false)
        #expect(!vazio.contains("multipart"))
    }

    @Test("O quoted-printable escapa o igual, o acento e o espaço final")
    func quotedPrintable() {
        // `=` primeiro: sem escapá-lo, tudo o que vem depois é lido como
        // sequência de escape.
        #expect(OutgoingMime.quotedPrintable("a=b") == "a=3Db")
        #expect(OutgoingMime.quotedPrintable("ção") == "=C3=A7=C3=A3o")
        // Espaço no fim da linha é aparado por qualquer servidor do caminho: o
        // texto chegaria diferente do que saiu.
        #expect(OutgoingMime.quotedPrintable("fim ") == "fim=20")
        #expect(OutgoingMime.quotedPrintable("a\nb") == "a\r\nb")
    }

    @Test("A linha longa é quebrada em pedaços que cabem no limite")
    func quebraSuave() {
        let longa = String(repeating: "x", count: 200)
        let saida = OutgoingMime.quotedPrintable(longa)
        // O RFC 5321 limita a linha a 998 bytes e o quoted-printable a 76: uma
        // linha colada de um navegador estoura os dois sozinha, e o servidor
        // corta a mensagem no meio.
        for linha in saida.components(separatedBy: "\r\n") {
            #expect(linha.count <= 76)
        }
        // A quebra é **suave**: o `=` no fim diz que a linha continua, e quem
        // lê remonta o texto original.
        #expect(saida.contains("=\r\n"))
        #expect(saida.replacingOccurrences(of: "=\r\n", with: "") == longa)
    }

    @Test("A quebra suave nunca parte uma sequência de escape ao meio")
    func quebraNaoParteEscape() {
        // 74 letras e um acento: o `=C3` cai exatamente na virada da coluna.
        let saida = OutgoingMime.quotedPrintable(String(repeating: "x", count: 74) + "ç")
        for linha in saida.components(separatedBy: "\r\n") where !linha.isEmpty {
            // Um `=` no fim é a quebra suave; um `=C` seria um escape partido,
            // e o "ç" chegaria como lixo.
            let ultimoIgual = linha.range(of: "=", options: .backwards)
            if let ultimoIgual, linha.distance(from: ultimoIgual.upperBound, to: linha.endIndex) < 2 {
                #expect(linha.hasSuffix("="))
            }
        }
        #expect(saida.replacingOccurrences(of: "=\r\n", with: "").hasSuffix("=C3=A7"))
    }

    // MARK: base64url

    @Test("O raw do Gmail vai em base64url, sem os caracteres que a URL come")
    func base64url() {
        // `+`, `/` e `=` têm significado em URL e em JSON de query: o alfabeto
        // comum devolve 400 numa mensagem que estava perfeita.
        let saida = OutgoingMime.base64URL("Assunto: çãé?>>>")
        #expect(!saida.contains("+"))
        #expect(!saida.contains("/"))
        #expect(!saida.contains("="))
        let devolta = saida
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let preenchido = devolta + String(repeating: "=", count: (4 - devolta.count % 4) % 4)
        let dados = try? #require(Data(base64Encoded: preenchido))
        #expect(String(data: dados!, encoding: .utf8) == "Assunto: çãé?>>>")
    }

    // MARK: Identidade

    @Test("O Message-ID nasce com o domínio de quem envia")
    func messageID() {
        // Domínio alheio ao remetente é o que alguns filtros contam como forja.
        #expect(OutgoingMessage.newMessageID(for: "eu@meudominio.com.br").hasSuffix("@meudominio.com.br"))
        #expect(OutgoingMessage.newMessageID(for: "sem-arroba").hasSuffix("@localhost"))
        // E ele é único: dois envios seguidos não podem compartilhar
        // identidade, senão o segundo seria tomado pelo primeiro e engolido.
        #expect(OutgoingMessage.newMessageID(for: "eu@x.com") != OutgoingMessage.newMessageID(for: "eu@x.com"))
    }

    @Test("A lista de quem recebe junta os três campos, sem repetir")
    func destinatarios() {
        let mensagem = mensagem(
            to: [OutgoingAddress(name: "A", address: "a@x.com")],
            cc: [OutgoingAddress(name: "B", address: "B@X.com")],
            bcc: [OutgoingAddress(name: "A de novo", address: "a@x.com")]
        )
        // Repetir um endereço no `RCPT TO` entrega a mesma mensagem duas vezes
        // para a mesma pessoa — e a comparação é sem caixa, senão "B@X.com" e
        // "b@x.com" passariam como dois.
        #expect(mensagem.recipients == ["a@x.com", "B@X.com"])
    }
}
