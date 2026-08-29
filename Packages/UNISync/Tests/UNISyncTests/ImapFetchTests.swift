import Foundation
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

/// Desligar o grupo de event loops sem bloquear — a mesma razão de
/// `ImapSessionTests`: o `defer` de um teste `async` roda no pool cooperativo,
/// e um bloqueio ali derruba a suíte inteira em silêncio.
private func encerra(_ grupo: MultiThreadedEventLoopGroup) {
    grupo.shutdownGracefully { _ in }
}

@Suite("IMAP: pastas, seleção, busca e envelopes")
struct ImapFetchTests {
    // MARK: Interpretação pura

    @Test("As pastas saem do LIST com o papel já resolvido")
    func pastas() {
        let respostas: [ImapWire.Untagged] = [
            .list(name: "INBOX", attributes: ["\\HasNoChildren"]),
            .list(name: "[Gmail]/Todos os e-mails", attributes: ["\\All", "\\HasNoChildren"]),
            .list(name: "Lixeira", attributes: ["\\HasNoChildren"]),
            .list(name: "Projetos", attributes: ["\\Noselect", "\\HasChildren"]),
            .list(name: "OkamiUNI/Depois", attributes: ["\\HasNoChildren"]),
        ]
        let pastas = ImapWire.folders(from: respostas)
        #expect(pastas.map(\.role) == [.inbox, .archive, .trash, .later])
        // `\Noselect` não é pasta: é um nó da árvore. Tentar `SELECT` nele
        // devolve NO e derrubaria a carga inteira por causa de um separador.
        #expect(!pastas.contains { $0.name == "Projetos" })
    }

    @Test("O SELECT devolve UIDVALIDITY, UIDNEXT e quantas existem")
    func selecao() throws {
        let respostas: [ImapWire.Untagged] = [
            .exists(1_284),
            .ok(code: "UIDVALIDITY", value: "1755000000"),
            .ok(code: "UIDNEXT", value: "9002"),
        ]
        let status = try #require(ImapWire.status(from: respostas))
        #expect(status.uidValidity == 1_755_000_000)
        #expect(status.uidNext == 9_002)
        #expect(status.exists == 1_284)
    }

    @Test("SELECT sem UIDVALIDITY não vira status inventado")
    func selecaoSemUidValidity() {
        // Sem UIDVALIDITY não dá para identificar mensagem nenhuma de forma
        // estável. Devolver zero faria o Marco 3 achar que a pasta é sempre a
        // mesma e casar UID reciclado com mensagem errada.
        #expect(ImapWire.status(from: [.exists(3)]) == nil)
    }

    @Test("Os UIDs saem do SEARCH em ordem crescente e sem repetição")
    func uids() {
        #expect(ImapWire.uids(from: [.search([9_001, 8_999]), .search([8_999, 9_002])])
            == [8_999, 9_001, 9_002])
        #expect(ImapWire.uids(from: [.search([])]).isEmpty)
    }

    @Test("Os envelopes viram mensagens com remetente, flags e data")
    func envelopes() throws {
        let linha = ImapWire.FetchLine(
            uid: 9_001,
            flags: ["\\Seen", "\\Flagged"],
            internalDate: Date(timeIntervalSince1970: 1_800_000_000),
            from: "\"Duarte, Marina\" <marina@clientepremium.com>",
            to: "Ricardo <ricardo@empresa.com>, contato@meusite.com",
            cc: "juridico@clientepremium.com",
            subject: "=?UTF-8?B?UmV2aXPDo28gZG8gY29udHJhdG8=?=",
            text: nil
        )
        let envelope = try #require(ImapWire.envelopes(from: [.fetch(linha)]).first)
        #expect(envelope.uid == 9_001)
        #expect(envelope.from.name == "Duarte, Marina")
        #expect(envelope.to.count == 2)
        #expect(envelope.cc.map(\.address) == ["juridico@clientepremium.com"])
        // O mesmo decodificador do Gmail: o assunto acentuado chega codificado
        // no IMAP também, e uma segunda implementação divergiria da primeira.
        #expect(envelope.subject == "Revisão do contrato")
        #expect(envelope.isRead)
        #expect(envelope.isFlagged)
    }

    @Test("Sem `\\Seen`, a mensagem é não lida; sem `\\Flagged`, sem estrela")
    func flagsAusentes() throws {
        let linha = ImapWire.FetchLine(
            uid: 9_002, flags: [], internalDate: Date(timeIntervalSince1970: 1),
            from: "a@b.com", to: nil, cc: nil, subject: "Oi", text: nil
        )
        let envelope = try #require(ImapWire.envelopes(from: [.fetch(linha)]).first)
        #expect(!envelope.isRead)
        #expect(!envelope.isFlagged)
        #expect(envelope.to.isEmpty)
    }

    @Test("Envelope sem INTERNALDATE é descartado, não datado com `agora`")
    func envelopeSemData() {
        // Datar com `Date()` colocaria toda mensagem quebrada no topo da lista,
        // acima do que chegou hoje de verdade. Ficar de fora é honesto: a
        // mensagem volta na próxima passada, com data.
        let linha = ImapWire.FetchLine(
            uid: 9_003, flags: [], internalDate: nil,
            from: "a@b.com", to: nil, cc: nil, subject: "Oi", text: nil
        )
        #expect(ImapWire.envelopes(from: [.fetch(linha)]).isEmpty)
    }

    @Test("O corpo vira parágrafos pelo mesmo caminho do Gmail")
    func corpo() {
        let linha = ImapWire.FetchLine(
            uid: 9_001, flags: [], internalDate: nil, from: nil, to: nil, cc: nil,
            subject: nil, text: "Primeiro.\r\n\r\nSegundo.\r\n"
        )
        #expect(ImapWire.bodyText(from: [.fetch(linha)], uid: 9_001) == ["Primeiro.", "Segundo."])
        #expect(ImapWire.bodyText(from: [.fetch(linha)], uid: 7).isEmpty)
    }

    @Test("O corpo multipart é decodificado com o cabeçalho que veio no mesmo FETCH")
    func corpoMultipart() {
        // O que o servidor manda de verdade quando a mensagem tem duas partes.
        // Sem os cabeçalhos ao lado, isto era gravado como leitura — é o
        // defeito que o dono via.
        let linha = ImapWire.FetchLine(
            uid: 9_001, flags: [], internalDate: nil, from: nil, to: nil, cc: nil,
            subject: nil,
            text: """
                --xyz\r
                Content-Type: text/plain; charset="utf-8"\r
                Content-Transfer-Encoding: quoted-printable\r
                \r
                A revis=C3=A3o do contrato ficou pronta.\r
                --xyz\r
                Content-Type: text/html; charset="utf-8"\r
                \r
                <p>tags</p>\r
                --xyz--\r
                """,
            contentHeader: "Content-Type: multipart/alternative; boundary=\"xyz\"\r\n"
                + "Content-Transfer-Encoding: 7bit\r\n\r\n"
        )
        #expect(ImapWire.bodyText(from: [.fetch(linha)], uid: 9_001)
                == ["A revisão do contrato ficou pronta."])
    }

    @Test("O comando de corpo pede os cabeçalhos de conteúdo junto, com PEEK nos dois")
    func comandoDeCorpo() {
        let comando = ImapWire.uidFetchBody(tag: "A007", uid: 9_001)
        #expect(comando == "A007 UID FETCH 9001 "
                + "(BODY.PEEK[HEADER.FIELDS (CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] "
                + "BODY.PEEK[TEXT])")
        // `PEEK` nos dois: ler para o cache não é a pessoa ter lido a mensagem,
        // e um `BODY[...]` sem PEEK marcaria `\Seen` no servidor.
        #expect(!comando.replacingOccurrences(of: "BODY.PEEK", with: "").contains("BODY["))
    }

    @Test("Sem os cabeçalhos, o decodificador fareja a fronteira do próprio texto")
    func corpoSemCabecalho() {
        // Servidor que devolve o rótulo com outra grafia, ou um banco velho: o
        // `contentHeader` chega nulo e a decodificação continua acontecendo.
        let linha = ImapWire.FetchLine(
            uid: 9_001, flags: [], internalDate: nil, from: nil, to: nil, cc: nil,
            subject: nil,
            text: """
                --abcd\r
                Content-Type: text/plain; charset="utf-8"\r
                \r
                Farejada.\r
                --abcd--\r
                """
        )
        #expect(ImapWire.bodyText(from: [.fetch(linha)], uid: 9_001) == ["Farejada."])
    }

    @Test("O lote é de 200, e o comando lista os UIDs pedidos")
    func lote() {
        #expect(ImapWire.fetchBatchSize == 200)
        #expect(ImapWire.uidFetchEnvelopes(tag: "A005", uids: [1, 2, 3])
            == "A005 UID FETCH 1,2,3 (UID FLAGS INTERNALDATE ENVELOPE)")
    }

    @Test("UIDVALIDITY trocada é detectada; primeira vez não é troca")
    func uidValidityTrocada() {
        #expect(!ImapUidValidity.changed(previous: nil, current: 1_755_000_000))
        #expect(!ImapUidValidity.changed(previous: 1_755_000_000, current: 1_755_000_000))
        #expect(ImapUidValidity.changed(previous: 1_755_000_000, current: 1_900_000_000))
    }

    // MARK: Os literais

    @Test("O literal é cortado pelo tamanho declarado, e não pelo primeiro `)`")
    func literalCortadoPeloTamanho() throws {
        // O `)` que fecha o FETCH vem **depois** do literal, na mesma linha
        // lógica. Cortar nele é fácil e errado: um corpo que contenha `)` sairia
        // pela metade, e todo corpo ganharia um parêntese no fim.
        // O corpo tem um `)` dentro **de propósito**: é o que separa "contei os
        // bytes" de "cortei no primeiro parêntese", que dão a mesma resposta em
        // qualquer corpo bem-comportado e respostas diferentes num de verdade.
        let linha = "1 FETCH (UID 9001 BODY[TEXT] {22}\r\nPrimeiro.)\r\n\r\nSegundo.)"
        guard case .fetch(let fetch) = try ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
            Issue.record("Esperava um `.fetch`.")
            return
        }
        #expect(fetch.text == "Primeiro.)\r\n\r\nSegundo.")
    }

    @Test("Um assunto em literal não desloca os campos do ENVELOPE")
    func assuntoEmLiteral() throws {
        // Dovecot e Courier mandam o assunto em literal quando ele é 8-bit ou
        // longo. Cortar por espaço sem saber onde o literal está empurra TODOS
        // os campos seguintes uma casa: `from`, `to` e `cc` viram nil e a
        // mensagem chega com "Remetente desconhecido".
        let linha = "1 FETCH (UID 9001 ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" "
            + "{20}\r\nRevisão do contrato "
            + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL "
            + "((\"Ricardo\" NIL \"ricardo\" \"empresa.com\")) NIL NIL NIL NIL))"
        guard case .fetch(let fetch) = try ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
            Issue.record("Esperava um `.fetch`.")
            return
        }
        #expect(fetch.subject == "Revisão do contrato")
        #expect(fetch.from == "Marina <marina@clientepremium.com>")
        #expect(fetch.to == "Ricardo <ricardo@empresa.com>")
    }

    @Test("Um nome de remetente em literal também é lido, e não some")
    func remetenteEmLiteral() throws {
        let linha = "1 FETCH (UID 9001 ENVELOPE (NIL \"Assunto\" "
            + "(({6}\r\nMarina NIL \"marina\" \"clientepremium.com\")) NIL NIL NIL NIL NIL NIL NIL))"
        guard case .fetch(let fetch) = try ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
            Issue.record("Esperava um `.fetch`.")
            return
        }
        #expect(fetch.subject == "Assunto")
        #expect(fetch.from == "Marina <marina@clientepremium.com>")
    }

    @Test("Assunto e remetente, os dois em literal, na mesma resposta")
    func assuntoERemetenteEmLiteral() throws {
        let linha = "1 FETCH (UID 9001 ENVELOPE (NIL {20}\r\nRevisão do contrato "
            + "(({14}\r\nDuarte, Marina NIL \"marina\" \"clientepremium.com\")) NIL NIL "
            + "((\"Ricardo\" NIL \"ricardo\" \"empresa.com\")) NIL NIL NIL NIL))"
        guard case .fetch(let fetch) = try ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
            Issue.record("Esperava um `.fetch`.")
            return
        }
        #expect(fetch.subject == "Revisão do contrato")
        #expect(fetch.from == "Duarte, Marina <marina@clientepremium.com>")
        #expect(fetch.to == "Ricardo <ricardo@empresa.com>")
    }

    @Test("`{4}` no meio da linha, sem CRLF, é texto — e não cabeçalho de literal")
    func chavesSemCRLFNaoSaoLiteral() throws {
        // Um assunto pode conter `{4}`: é texto de outra pessoa. Sem exigir o
        // CRLF, o mapa de literais mascararia os quatro bytes seguintes — aqui,
        // o " NIL" do campo `from` — e voltaria a deslocar os campos, que é
        // exatamente o defeito que o mapa existe para impedir. É também o que
        // alinha esta leitura com a do `CRLFLineDecoder`, que só reconhece
        // literal no fim da linha.
        let linha = "1 FETCH (UID 9001 ENVELOPE (NIL {4} NIL NIL NIL "
            + "((\"Ricardo\" NIL \"ricardo\" \"empresa.com\")) NIL NIL NIL NIL))"
        guard case .fetch(let fetch) = try ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
            Issue.record("Esperava um `.fetch`.")
            return
        }
        #expect(fetch.uid == 9_001)
        #expect(fetch.subject == "{4}")
        #expect(fetch.from == nil)
        #expect(fetch.to == "Ricardo <ricardo@empresa.com>")
    }

    @Test("Um `UID 999` escrito dentro do corpo não vira o UID da resposta")
    func uidEscritoNoCorpo() throws {
        // O corpo é texto de outra pessoa; procurar chave de protocolo dentro
        // dele é ler a mensagem como se fosse o protocolo. Uma linha "UID 999"
        // num email — uma cola de suporte, um log — trocaria a identidade da
        // mensagem inteira.
        let linha = "1 FETCH (BODY[TEXT] {13}\r\nUID 999 e tal UID 9001)"
        guard case .fetch(let fetch) = try ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
            Issue.record("Esperava um `.fetch`.")
            return
        }
        #expect(fetch.uid == 9_001)
        #expect(fetch.text == "UID 999 e tal")
    }

    // MARK: O tamanho absurdo de literal

    @Test("Vinte dígitos dentro de `{}` viram erro de resposta, e não SIGTRAP")
    func literalComTamanhoImpossivel() {
        // Este teste não afirma um valor: ele afirma que o processo **continua
        // vivo**. O laço de dígitos multiplicava e somava em `Int`, e em Swift
        // isso armadilha no estouro — vinte noves matavam o app inteiro com
        // signal 5, dentro do `channelRead` do NIO, com a carga em voo.
        //
        // O caminho é o normal, não um canto: TODA linha untagged passa por
        // `untagged(fromLogicalLine:)`, e a primeira coisa que ela faz é varrer
        // a linha à procura de cabeçalho de literal. Basta a saudação e uma
        // linha para o servidor derrubar o cliente.
        //
        // MUTAÇÃO QUE ISTO PEGA: tirar o `guard digitos <= tetoDeDigitos` de
        // `Analise.cabecalho` faz o processo de teste **morrer** (signal 5) —
        // vermelho da forma mais barulhenta que existe.
        #expect(throws: SyncError.self) {
            try ImapResponseAdapter.untagged(
                fromLogicalLine: "* OK [ALERT] {99999999999999999999} bytes"
            )
        }
        // O teto é de dígitos, e não de valor: doze dígitos passam pela guarda
        // e são recusados adiante por não terem CRLF — a linha vira `.outra`,
        // que é o comportamento de sempre.
        #expect(throws: SyncError.self) {
            try ImapResponseAdapter.untagged(fromLogicalLine: "* OK [ALERT] {1234567890123} bytes")
        }
        #expect(throws: Never.self) {
            try ImapResponseAdapter.untagged(fromLogicalLine: "* OK [ALERT] {123456789012} bytes")
        }
    }

    @Test("O teto de dígitos do UID é o mesmo, e o UID absurdo não vira mensagem")
    func uidComDigitosDemais() throws {
        // O `Int64(_: String)` já devolvia `nil` no estouro, então aqui nunca
        // houve trap — o que havia era duas regras diferentes para a mesma
        // pergunta no mesmo arquivo. `fetch` sem UID não é `.fetch`.
        let linha = "1 FETCH (UID 99999999999999999999 FLAGS (\\Seen))"
        guard case .outra = try ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
            Issue.record("Um UID de vinte dígitos não é UID: a linha não podia virar `.fetch`.")
            return
        }
    }

    // MARK: O nome da pasta no LIST

    @Test("O nome da pasta é o que vem depois do separador — citado, átomo ou literal")
    func nomeDaPastaNoList() throws {
        // `* LIST (…) "/" INBOX` é legal no RFC 3501: o nome na forma átomo,
        // sem aspas. Ler "a última string citada" devolveria o separador `/`
        // como nome — a INBOX sumiria e uma pasta chamada "/" tomaria o lugar.
        func nome(_ linha: String) throws -> String? {
            guard case .list(let nome, _) = try ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
                return nil
            }
            return nome
        }
        #expect(try nome("* LIST (\\HasNoChildren) \"/\" \"INBOX\"") == "INBOX")
        #expect(try nome("* LIST (\\HasNoChildren) \"/\" INBOX") == "INBOX")
        #expect(try nome("* LIST (\\HasNoChildren) \".\" INBOX.Enviados") == "INBOX.Enviados")
        #expect(try nome("* LIST (\\HasNoChildren) \"/\" {6}\r\nEnviad") == "Enviad")
        #expect(try nome("* LIST (\\Noselect) \"/\" \"[Gmail]\"") == "[Gmail]")
    }

    /// O `[APPENDUID 42 9]` da resposta do `APPEND` (RFC 4315).
    ///
    /// Ele é o endereço da cópia que acabou de ser gravada em Enviadas, e é o
    /// que dá à linha local o mesmo id que a leitura seguinte da pasta daria —
    /// sem ele, a mensagem que a pessoa mandou apareceria duas vezes na caixa
    /// dela: a nossa e a do servidor.
    @Test("O APPENDUID diz onde a cópia ficou — e a ausência dele não é erro")
    func appendUIDLido() {
        let carimbo = ImapWire.appendUID(from: "[APPENDUID 42 9] gravada")
        #expect(carimbo == ImapWire.AppendUID(uidValidity: 42, uid: 9))
        // Caixa alta ou baixa é a mesma resposta: o RFC não obriga nenhuma, e
        // servidor que manda minúscula existe.
        #expect(ImapWire.appendUID(from: "[appenduid 1755000000 7] ok")
            == ImapWire.AppendUID(uidValidity: 1_755_000_000, uid: 7))

        // Servidor sem UIDPLUS não manda o código, e isso **não** é falha: a
        // mensagem já saiu, e a cópia entra pela leitura normal da pasta.
        #expect(ImapWire.appendUID(from: "APPEND completed") == nil)
        // Nem código de outro assunto, nem código truncado, viram coordenada
        // inventada — casar por engano poria a linha de Enviadas num UID que
        // pertence a outra mensagem.
        #expect(ImapWire.appendUID(from: "[UIDVALIDITY 42] ok") == nil)
        #expect(ImapWire.appendUID(from: "[APPENDUID 42] ok") == nil)
        #expect(ImapWire.appendUID(from: "[APPENDUID quarenta 9] ok") == nil)
    }

    // MARK: De ponta a ponta, contra o servidor falso

    @Test("A sessão lista, seleciona, busca e traz envelopes — nessa ordem")
    func pontaAPonta() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LIST": [
                "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
                "* LIST (\\Trash \\HasNoChildren) \"/\" \"Lixeira\"",
                "TAG OK LIST completed",
            ],
            "SELECT": [
                "* 2 EXISTS",
                "* OK [UIDVALIDITY 1755000000] UIDs valid",
                "* OK [UIDNEXT 9003] Predicted next UID",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            "UID SEARCH": ["* SEARCH 9001 9002", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                "* 1 FETCH (UID 9001 FLAGS (\\Seen) INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" "
                + "ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"Assunto\" "
                + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL "
                + "((\"Ricardo\" NIL \"ricardo\" \"empresa.com\")) NIL NIL NIL NIL))",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = TimeZone(identifier: "UTC")!

        // `allowInsecure: true` porque o servidor falso fala em claro: é a
        // versão `internal` do `connect`, a mesma que os testes da Task 9 usam.
        let sessao = try await ImapSession.connect(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo,
            allowInsecure: true,
            teto: .seconds(5)
        )
        try await sessao.login(user: "eu@x.com", password: "senha")

        let pastas = try await sessao.folders()
        #expect(pastas.map(\.role) == [.inbox, .trash])

        let inbox = try #require(pastas.first { $0.role == .inbox })
        let status = try await sessao.select(inbox)
        #expect(status.uidValidity == 1_755_000_000)
        #expect(status.exists == 2)

        let uids = try await sessao.uids(
            since: calendario.date(from: DateComponents(year: 2026, month: 5, day: 27))!,
            calendar: calendario
        )
        #expect(uids == [9_001, 9_002])

        let envelopes = try await sessao.envelopes(uids: uids)
        #expect(envelopes.map(\.uid) == [9_001])
        #expect(envelopes.first?.from.address == "marina@clientepremium.com")
        #expect(envelopes.first?.isRead == true)

        await sessao.logout()

        // A ordem importa: buscar antes de selecionar procuraria na pasta
        // errada, e o servidor não avisaria.
        let ordem = servidor.commands.map { linha -> String in
            let resto = linha.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            return resto.split(separator: " ").prefix(2).joined(separator: " ")
        }
        #expect(ordem.firstIndex { $0.hasPrefix("SELECT") }! < ordem.firstIndex { $0.hasPrefix("UID SEARCH") }!)
    }

    @Test("O corpo chega como literal `{n}` e mesmo assim vira uma linha só")
    func corpoComLiteralDePontaAPonta() async throws {
        // Este é o caso que o corte por CRLF sozinho **não** resolve: o corpo
        // vem contado em bytes e tem CRLF dentro. Sem o `CRLFLineDecoder`
        // juntar o literal à linha, cada parágrafo chegaria como uma resposta
        // solta e o corpo sairia vazio.
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "UID FETCH": [
                "* 1 FETCH (UID 9001 BODY[TEXT] {22}\r\nPrimeiro.)\r\n\r\nSegundo.)",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo,
            allowInsecure: true,
            teto: .seconds(5)
        )
        try await sessao.login(user: "eu@x.com", password: "senha")
        #expect(try await sessao.bodyText(uid: 9_001) == ["Primeiro.)", "Segundo."])
        await sessao.logout()
    }

    @Test("Corpo vazio (`{0}`) responde na hora, e não morre de teto de tempo")
    func corpoVazioDePontaAPonta() async throws {
        // Convite de agenda e mensagem só-com-anexo devolvem `BODY[TEXT] {0}`.
        // A Task 13 chama `bodyText` por pasta: um caso desses parando a
        // conexão por quinze segundos derruba a carga inicial inteira.
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            // Numa escrita **só**, de propósito: é assim que o servidor manda
            // de verdade, e é a forma em que um framer que trava no `{0}` fica
            // sem bytes novos para destravá-lo. Em duas escritas o defeito se
            // esconde, porque a segunda acorda o framer por acidente.
            "UID FETCH": ["CRU:* 1 FETCH (UID 9001 BODY[TEXT] {0}\r\n)\r\nTAG OK UID FETCH completed\r\n"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        // Teto curto de propósito: se o `{0}` prender a resposta tagueada, este
        // teste falha por tempo em vez de passar devagar.
        let sessao = try await ImapSession.connect(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo, allowInsecure: true, teto: .milliseconds(500)
        )
        try await sessao.login(user: "eu@x.com", password: "senha")
        #expect(try await sessao.bodyText(uid: 9_001).isEmpty)
        await sessao.logout()
    }

    @Test("Acento no corpo atravessa o fio inteiro sem virar `?`")
    func corpoAcentuadoDePontaAPonta() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "UID FETCH": [
                "* 1 FETCH (UID 9001 BODY[TEXT] {24}\r\nA ação foi concluída.)",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerra(grupo) }

        let sessao = try await ImapSession.connect(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo, allowInsecure: true, teto: .seconds(5)
        )
        try await sessao.login(user: "eu@x.com", password: "senha")
        #expect(try await sessao.bodyText(uid: 9_001) == ["A ação foi concluída."])
        await sessao.logout()
    }
}
