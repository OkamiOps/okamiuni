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

    // MARK: A costura dos literais

    @Test("Um quadro que termina em `{n}` é cabeçalho de literal, e não fim de linha")
    func cabecalhoDeLiteral() {
        // É esta pergunta que decide se a linha lógica acabou ou se ainda vem
        // conteúdo contado em bytes. Errar aqui parte o corpo de toda mensagem
        // em pedaços que o parser lê como respostas soltas.
        #expect(ImapResponseAdapter.terminaEmCabecalhoDeLiteral("* 1 FETCH (BODY[TEXT] {21}\r\n"))
        #expect(ImapResponseAdapter.terminaEmCabecalhoDeLiteral("* 1 FETCH (BODY[TEXT] {21+}\r\n"))
        #expect(ImapResponseAdapter.terminaEmCabecalhoDeLiteral("* 1 FETCH (BODY[TEXT] ~{21}\r\n"))
        #expect(!ImapResponseAdapter.terminaEmCabecalhoDeLiteral("* OK [UIDVALIDITY 1] ok\r\n"))
        #expect(!ImapResponseAdapter.terminaEmCabecalhoDeLiteral("* 1 FETCH (BODY[TEXT] {})\r\n"))
        #expect(!ImapResponseAdapter.terminaEmCabecalhoDeLiteral("A0001 OK FETCH completed\r\n"))
    }

    @Test("O literal é cortado pelo tamanho declarado, e não pelo primeiro `)`")
    func literalCortadoPeloTamanho() {
        // O `)` que fecha o FETCH vem **depois** do literal, na mesma linha
        // lógica. Cortar nele é fácil e errado: um corpo que contenha `)` sairia
        // pela metade, e todo corpo ganharia um parêntese no fim.
        // O corpo tem um `)` dentro **de propósito**: é o que separa "contei os
        // bytes" de "cortei no primeiro parêntese", que dão a mesma resposta em
        // qualquer corpo bem-comportado e respostas diferentes num de verdade.
        let linha = "1 FETCH (UID 9001 BODY[TEXT] {22}\r\nPrimeiro.)\r\n\r\nSegundo.)"
        guard case .fetch(let fetch) = ImapResponseAdapter.untagged(fromLogicalLine: linha) else {
            Issue.record("Esperava um `.fetch`.")
            return
        }
        #expect(fetch.text == "Primeiro.)\r\n\r\nSegundo.")
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
        // vem contado em bytes e tem CRLF dentro. Sem o quadro do
        // `swift-nio-imap` juntando o literal, cada parágrafo chegaria como uma
        // resposta solta e o corpo sairia vazio.
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
}
