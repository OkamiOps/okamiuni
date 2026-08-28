import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Gmail API", .serialized)
struct GmailClientTests {
    private func fixture(_ nome: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(nome)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func cliente() -> GmailClient {
        GmailClient(
            session: StubURLProtocol.session(),
            accessToken: { "at-de-teste" },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
    }

    // MARK: Cabeçalhos de endereço

    @Test("O nome entre aspas e o endereço saem separados")
    func enderecoComNomeEntreAspas() {
        let contato = MailAddress.parse("\"Duarte, Marina\" <marina@clientepremium.com>")
        #expect(contato?.name == "Duarte, Marina")
        #expect(contato?.address == "marina@clientepremium.com")
    }

    @Test("Endereço sem nome usa o próprio endereço como nome")
    func enderecoSemNome() {
        // Nome vazio deixaria a lista com uma linha em branco onde o design
        // desenha o remetente. O endereço é o melhor nome disponível.
        #expect(MailAddress.parse("juridico@clientepremium.com")?.name == "juridico@clientepremium.com")
        #expect(MailAddress.parse("  <so@angulos.com> ")?.name == "so@angulos.com")
    }

    @Test("A lista respeita a vírgula dentro das aspas")
    func listaDeEnderecos() {
        // Cortar por vírgula sem olhar as aspas parte "Duarte, Marina" em dois
        // destinatários — e o "Responder a todos" mandaria email para "Duarte".
        let lista = MailAddress.parseList("\"Duarte, Marina\" <m@x.com>, Ricardo <r@y.com>")
        #expect(lista.count == 2)
        #expect(lista.first?.name == "Duarte, Marina")
        #expect(lista.last?.address == "r@y.com")
        #expect(MailAddress.parseList("").isEmpty)
    }

    // MARK: O parser

    @Test("A mensagem cheia sai inteira, com assunto decodificado e corpo em parágrafos")
    func mensagemCheia() throws {
        let mensagem = try GmailMessageParser.parse(fixture("gmail-message-full"))
        #expect(mensagem.id == "18f0a1b2c3")
        #expect(mensagem.labelIDs == ["INBOX", "UNREAD", "STARRED"])
        // internalDate vem em **milissegundos**; tratá-lo como segundos joga a
        // mensagem para o ano 58 mil e a lista fica em ordem aleatória.
        #expect(mensagem.internalDate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(mensagem.from.name == "Duarte, Marina")
        #expect(mensagem.from.address == "marina@clientepremium.com")
        #expect(mensagem.to.count == 2)
        #expect(mensagem.cc.map(\.address) == ["juridico@clientepremium.com"])
        // RFC 2047: o assunto chega codificado e tem de sair legível.
        #expect(mensagem.subject == "Revisão do contrato")
        #expect(mensagem.snippet == "A revisão do contrato ficou pronta")
        #expect(mensagem.body == ["A revisão do contrato ficou pronta.", "Podemos fechar quinta?"])
    }

    @Test("Entre `text/plain` e `text/html`, o parser fica com o texto")
    func preferenciaPorTextoSimples() throws {
        let mensagem = try GmailMessageParser.parse(fixture("gmail-message-full"))
        // O leitor do Marco 1 desenha `[String]` de parágrafos, não HTML. Pegar
        // a parte HTML encheria a tela de tags.
        #expect(!mensagem.body.contains { $0.contains("<p>") })
    }

    @Test("A mensagem em formato `metadata` vem sem corpo, e isso não é erro")
    func mensagemSemCorpo() throws {
        let mensagem = try GmailMessageParser.parse(fixture("gmail-message-metadata"))
        #expect(mensagem.body.isEmpty)
        #expect(mensagem.subject == "Boletim de agosto")
        #expect(mensagem.to.isEmpty)
        #expect(mensagem.from.address == "noticias@exemplo.com")
    }

    @Test("base64url decodifica onde o base64 comum falha")
    func base64URL() {
        #expect(GmailMessageParser.decodeBody(base64URL: "QSByZXZpc8OjbyE") == "A revisão!")
        // Padding ausente é o normal na API; com `=` também tem de funcionar.
        #expect(GmailMessageParser.decodeBody(base64URL: "QSByZXZpc8OjbyE=") == "A revisão!")
        #expect(GmailMessageParser.decodeBody(base64URL: "não é base64") == "")
    }

    @Test("Parágrafos saem das linhas em branco, e as pontas somem")
    func paragrafos() {
        #expect(GmailMessageParser.paragraphs(from: "Um.\n\nDois.\n\n\n  Três.  \n") == ["Um.", "Dois.", "Três."])
        #expect(GmailMessageParser.paragraphs(from: "   ").isEmpty)
        // Quebra simples dentro de um parágrafo continua sendo um parágrafo.
        #expect(GmailMessageParser.paragraphs(from: "Linha um\nlinha dois") == ["Linha um\nlinha dois"])
    }

    @Test("JSON fora do contrato não é engolido")
    func jsonInvalido() {
        #expect(throws: (any Error).self) {
            _ = try GmailMessageParser.parse(Data("{\"nada\":1}".utf8))
        }
    }

    // MARK: O cliente

    @Test("O perfil traz o endereço e o historyId que o Marco 3 vai usar")
    func perfil() async throws {
        StubURLProtocol.install(["/gmail/v1/users/me/profile": [.init(body: try fixture("gmail-profile"))]])
        defer { StubURLProtocol.reset() }

        let perfil = try await cliente().profile()
        #expect(perfil.emailAddress == "ricardo@gmail.com")
        #expect(perfil.historyID == "9928471")
    }

    @Test("Toda requisição leva o Bearer, e o token é pedido na hora")
    func bearerEmToda() async throws {
        StubURLProtocol.install(["/gmail/v1/users/me/profile": [.init(body: try fixture("gmail-profile"))]])
        defer { StubURLProtocol.reset() }

        let pedidos = Contador()
        let cliente = GmailClient(
            session: StubURLProtocol.session(),
            accessToken: { await pedidos.incrementaEDevolve() },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
        _ = try await cliente.profile()
        // Pedir o token **por requisição**, e não uma vez na construção, é o
        // que faz o refresh transparente chegar aqui: um token guardado no
        // init venceria no meio da carga inicial.
        #expect(await pedidos.total == 1)
    }

    @Test("Os rótulos vêm com a pasta Depois quando ela existe")
    func rotulos() async throws {
        StubURLProtocol.install(["/gmail/v1/users/me/labels": [.init(body: try fixture("gmail-labels"))]])
        defer { StubURLProtocol.reset() }

        let rotulos = try await cliente().labels()
        #expect(rotulos.count == 6)
        #expect(rotulos.first { $0.name == "OkamiUNI/Depois" }?.id == "Label_7")
    }

    @Test("A lista devolve ids e o token da próxima página")
    func lista() async throws {
        StubURLProtocol.install(["/gmail/v1/users/me/messages": [.init(body: try fixture("gmail-list"))]])
        defer { StubURLProtocol.reset() }

        let pagina = try await cliente().messageIDs(query: "newer_than:90d", pageToken: nil)
        #expect(pagina.ids == ["18f0a1b2c3", "18f0a1b2c4"])
        #expect(pagina.nextPageToken == "pagina-2")
    }

    @Test("Lista vazia devolve página vazia, e não erro")
    func listaVazia() async throws {
        // Uma conta nova, ou uma janela de 90 dias sem nada: `messages` some
        // do JSON inteiro. Tratar ausência como erro faria a conta parecer
        // quebrada quando ela só está vazia.
        StubURLProtocol.install([
            "/gmail/v1/users/me/messages": [.json("{\"resultSizeEstimate\":0}")],
        ])
        defer { StubURLProtocol.reset() }

        let pagina = try await cliente().messageIDs(query: "newer_than:90d", pageToken: nil)
        #expect(pagina.ids.isEmpty)
        #expect(pagina.nextPageToken == nil)
    }

    @Test("401 vira autenticação, 429 vira quota, 500 vira servidor")
    func errosDistintos() async throws {
        for (status, esperado) in [
            (401, SyncError.autenticacao),
            (403, SyncError.autorizacaoRevogada),
            (429, SyncError.quota),
            (503, SyncError.servidor(codigo: 503, mensagem: "Service Unavailable")),
        ] {
            StubURLProtocol.install([
                "/gmail/v1/users/me/profile": [.json(
                    "{\"error\":{\"code\":\(status),\"message\":\"Service Unavailable\"}}",
                    status: status
                )],
            ])
            await #expect(throws: esperado) { _ = try await self.cliente().profile() }
            StubURLProtocol.reset()
        }
    }
}

/// Conta quantas vezes o token foi pedido.
private actor Contador {
    private(set) var total = 0
    func incrementaEDevolve() -> String {
        total += 1
        return "at-de-teste"
    }
}
