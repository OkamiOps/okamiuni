import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

private func msg(
    _ id: String,
    thread: String? = nil,
    at segundos: TimeInterval,
    dayOffset: Int = 0,
    subject: String = "Lembrete rápido: nossa call amanhã",
    from: String = "Marina",
    body: [String] = [],
    snippet: String = "trecho",
    isRead: Bool = true,
    rfcMessageID: String? = nil,
    references: [String] = []
) -> Message {
    Message(
        id: id, accountID: "zoho",
        from: Contact(name: from, address: "\(from.lowercased())@x.com"),
        receivedAt: Date(timeIntervalSince1970: segundos),
        subject: subject, snippet: snippet, body: body, tags: [],
        bucket: .today, isRead: isRead, summary: nil, detectedEvent: nil,
        dayOffset: dayOffset,
        rfcMessageID: rfcMessageID, references: references, threadKey: thread
    )
}

@Suite("A lista agrupada por conversa")
struct ConversationListTests {

    /// A ordem das duas operações não é livre: agrupar por dia primeiro
    /// partiria em duas linhas a conversa que começou ontem e foi respondida
    /// hoje — a conversa mais comum que existe.
    @Test("A conversa que atravessa o dia fica numa linha só, no dia da mais recente")
    func conversaAtravessaODia() throws {
        let grupos = MessageGroup.build(from: [
            msg("b", thread: "t1", at: 300, dayOffset: 0),
            msg("a", thread: "t1", at: 100, dayOffset: -1),
        ])
        #expect(grupos.count == 1)
        #expect(grupos.first?.label == "Hoje")
        #expect(grupos.first?.conversations.count == 1)
        #expect(grupos.first?.conversations.first?.count == 2)
    }

    @Test("Sem conversa nenhuma, os grupos são os de sempre — mensagem por mensagem")
    func semConversa() throws {
        let grupos = MessageGroup.build(from: [
            msg("b", at: 300, dayOffset: 0), msg("a", at: 100, dayOffset: -1),
        ])
        #expect(grupos.map(\.label) == ["Hoje", "Ontem"])
        #expect(grupos.map { $0.messages.map(\.id) } == [["b"], ["a"]])
    }

    @MainActor
    @Test("As sete fixtures continuam sendo sete linhas, em dois grupos")
    func fixturesIntactas() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        let grupos = MessageGroup.build(from: store.visibleMessages)
        #expect(grupos.map(\.label) == ["Hoje", "Ontem"])
        #expect(grupos.flatMap(\.conversations).count == 7)
        #expect(grupos.flatMap(\.conversations).allSatisfy { $0.countLabel == nil })
    }
}

@Suite("A ação disparada na linha alcança a conversa")
@MainActor
struct ConversationActionTests {

    private func store(_ messages: [Message]) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: messages, agenda: [])
        )
        await store.load()
        store.select(bucket: .all)
        return store
    }

    private var trio: [Message] {
        [
            msg("c", thread: "t1", at: 300, isRead: false),
            msg("b", thread: "t1", at: 200),
            msg("a", thread: "t1", at: 100, isRead: false),
        ]
    }

    /// O menu de contexto é montado sobre a mensagem mais recente, mas o que
    /// ele faz alcança a conversa — a linha é a conversa.
    @Test("Arquivar pelo menu da linha arquiva as três")
    func arquivarPeloMenu() async throws {
        let store = await store(trio)
        let lista = MessageList(store: store)
        let conversa = try #require(store.visibleConversations.first)
        #expect(lista.act(.move(messageID: "c", to: .archived), on: conversa))
        #expect(store.messages.allSatisfy { $0.bucket == .archived })
    }

    @Test("Marcar como lida pelo menu da linha alcança as três")
    func lerPeloMenu() async throws {
        let store = await store(trio)
        let lista = MessageList(store: store)
        let conversa = try #require(store.visibleConversations.first)
        #expect(lista.act(.setRead(messageID: "c", isRead: true), on: conversa))
        #expect(store.messages.allSatisfy { $0.isRead })
    }

    /// Apagar a conversa deixa uma faixa com "Desfazer" que devolve **as
    /// três** — e a nota diz quantas foram, senão "Desfazer" devolveria três
    /// linhas depois de uma frase que só falou de uma.
    @Test("Apagar a conversa dá um recibo que desfaz as três")
    func apagarComRecibo() async throws {
        let store = await store(trio)
        let lista = MessageList(store: store)
        let conversa = try #require(store.visibleConversations.first)
        #expect(lista.act(.move(messageID: "c", to: .trash), on: conversa))
        #expect(store.messages.allSatisfy { $0.bucket == .trash })

        let recibo = try #require(lista.receipts.current)
        #expect(recibo.note.contains("3 mensagens"))
        StoreCommand.run(recibo.undo, on: store)
        #expect(store.messages.allSatisfy { $0.bucket == .today })
    }

    /// A tecla ⌫ age onde o clique agiria: na linha, que é a conversa.
    @Test("O ⌫ na conversa aberta manda as três para a Lixeira")
    func teclaApagaAConversa() async throws {
        let store = await store(trio)
        let lista = MessageList(store: store)
        store.select(message: "c")
        #expect(lista.deleteSelected())
        #expect(store.messages.allSatisfy { $0.bucket == .trash })
    }

    /// A conversa de uma mensagem só continua caindo no caminho de sempre —
    /// é assim que os retratos e os testes do Marco 1 seguem valendo.
    @Test("Numa conversa de uma mensagem, nada de novo acontece")
    func umaMensagemSegueOCaminhoDeSempre() async throws {
        let store = await store([msg("z", at: 400, subject: "Outro", isRead: false)])
        let lista = MessageList(store: store)
        let conversa = try #require(store.visibleConversations.first)
        #expect(lista.act(.move(messageID: "z", to: .trash), on: conversa))
        let recibo = try #require(lista.receipts.current)
        #expect(!recibo.note.contains("mensagens"))
    }
}

@Suite("A linha da conversa")
@MainActor
struct ConversationRowTests {

    private func linha(count: Int, unread: Bool?) -> MessageRow {
        MessageRow(
            message: msg("a", at: 100, isRead: true),
            accountHost: "zoho", accountTint: .red, isSelected: false,
            conversationCount: count, unread: unread
        )
    }

    /// O selo é o "3" do webmail. Ele **não existe** com uma mensagem só — um
    /// "1" em toda linha de uma caixa sem conversa mudaria o desenho de tudo o
    /// que o Marco 1 já tinha.
    @Test("O selo aparece a partir de duas mensagens, e não antes")
    func selo() throws {
        let semSelo = try #require(Render.bitmap(
            linha(count: 1, unread: nil), size: CGSize(width: 370, height: 120), theme: .tinta
        ))
        let comSelo = try #require(Render.bitmap(
            linha(count: 3, unread: nil), size: CGSize(width: 370, height: 120), theme: .tinta
        ))
        // O selo desenha uma pastilha em `surface3` que a linha sem ele não
        // tem: pixels a mais dessa cor é a medida que cai junto com o selo.
        #expect(comSelo.pixels(matching: Theme.tinta.surface3) > semSelo.pixels(matching: Theme.tinta.surface3))
    }

    /// A não lida da conversa é "alguma não lida", e a linha desenha a marca
    /// mesmo com a mais recente já lida.
    @Test("A marca de não lida obedece à conversa, não só à mensagem da linha")
    func naoLidaDaConversa() throws {
        let lida = try #require(Render.bitmap(
            linha(count: 3, unread: false), size: CGSize(width: 370, height: 120), theme: .tinta
        ))
        let comNaoLida = try #require(Render.bitmap(
            linha(count: 3, unread: true), size: CGSize(width: 370, height: 120), theme: .tinta
        ))
        #expect(comNaoLida.pixels(matching: Theme.tinta.accent) > lida.pixels(matching: Theme.tinta.accent))
    }
}

@Suite("O leitor empilha a conversa")
@MainActor
struct ConversationReaderTests {

    private func store(_ messages: [Message]) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: messages, agenda: [])
        )
        await store.load()
        return store
    }

    @Test("A primeira linha da mensagem recolhida sai do corpo, e da prévia quando não há corpo")
    func primeiraLinha() {
        #expect(
            ReaderPane.primeiraLinha(de: msg("a", at: 1, body: ["Oi Marina\nsegue o contrato"]))
                == "Oi Marina"
        )
        #expect(
            ReaderPane.primeiraLinha(de: msg("a", at: 1, body: [], snippet: "só a prévia"))
                == "só a prévia"
        )
    }

    /// Abrir a conversa abre a mais recente, e marca **ela** como lida — não a
    /// pilha inteira.
    @Test("Abrir a conversa marca lida só a mensagem expandida")
    func abrirMarcaSoAExpandida() async throws {
        let store = await store([
            msg("c", thread: "t1", at: 300, isRead: false),
            msg("a", thread: "t1", at: 100, isRead: false),
        ])
        store.select(message: "c")
        let porID = Dictionary(uniqueKeysWithValues: store.messages.map { ($0.id, $0) })
        #expect(porID["c"]?.isRead == true)
        #expect(porID["a"]?.isRead == false)
        // E a conversa continua marcada como não lida na lista, porque uma
        // delas ainda está por ler.
        #expect(store.conversation(of: "c")?.hasUnread == true)
    }

    @Test("O leitor da conversa desenha as duas, e o da mensagem só desenha uma")
    func desenhaAPilha() async throws {
        let comConversa = await store([
            msg("c", thread: "t1", at: 300, from: "Marina", body: ["resposta"]),
            msg("a", thread: "t1", at: 100, from: "Ricardo", body: ["original"]),
        ])
        comConversa.select(message: "c")
        let pilha = try #require(
            Render.bitmap(
                ReaderPane(store: comConversa).environment(ThemeStore()),
                size: CGSize(width: 700, height: 600), theme: .tinta
            )
        )

        let sozinha = await store([msg("c", thread: "t1", at: 300, from: "Marina", body: ["resposta"])])
        sozinha.select(message: "c")
        let simples = try #require(
            Render.bitmap(
                ReaderPane(store: sozinha).environment(ThemeStore()),
                size: CGSize(width: 700, height: 600), theme: .tinta
            )
        )
        // A pilha tem uma linha recolhida a mais — logo, mais tinta escrita.
        #expect(pilha.pixelsDiffering(from: simples) > 0)
    }
}
