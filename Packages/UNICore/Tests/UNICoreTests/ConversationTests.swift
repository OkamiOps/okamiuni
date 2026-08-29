import Foundation
import Testing
@testable import UNICore

/// Uma mensagem de teste, com a chave de conversa e o que mais o caso pedir.
private func msg(
    _ id: String,
    thread: String? = nil,
    at segundos: TimeInterval,
    subject: String = "Lembrete rápido: nossa call amanhã",
    from: String = "Marina",
    bucket: TriageBucket = .today,
    isRead: Bool = true,
    isFlagged: Bool = false,
    dayOffset: Int = 0,
    accountID: String = "zoho"
) -> Message {
    Message(
        id: id, accountID: accountID,
        from: Contact(name: from, address: "\(from.lowercased())@x.com"),
        receivedAt: Date(timeIntervalSince1970: segundos),
        subject: subject, snippet: "trecho", body: [], tags: [],
        bucket: bucket, isRead: isRead, summary: nil, detectedEvent: nil,
        dayOffset: dayOffset, isFlagged: isFlagged, threadKey: thread
    )
}

@Suite("A conversa")
struct ConversationTests {

    /// A queixa do dono: três mensagens, uma linha.
    @Test("Três mensagens com a mesma chave viram uma conversa")
    func tresViramUma() throws {
        // A lista entrega as mais recentes primeiro.
        let conversas = Conversation.build(from: [
            msg("c", thread: "t1", at: 300, from: "Marina"),
            msg("b", thread: "t1", at: 200, from: "Ricardo"),
            msg("a", thread: "t1", at: 100, from: "Marina"),
        ])
        #expect(conversas.count == 1)
        let conversa = try #require(conversas.first)
        #expect(conversa.count == 3)
        // Dentro da conversa, a ordem é a que ela aconteceu.
        #expect(conversa.messages.map(\.id) == ["a", "b", "c"])
        #expect(conversa.latest.id == "c")
        #expect(conversa.countLabel == "3")
    }

    /// A garantia do Marco 1: sem chave, cada mensagem é uma conversa dela
    /// mesma — e a lista desenha o que sempre desenhou.
    @Test("Sem chave, cada mensagem é uma conversa de uma")
    func semChave() {
        let conversas = Conversation.build(from: [
            msg("a", at: 300), msg("b", at: 200), msg("c", at: 100),
        ])
        #expect(conversas.map(\.key) == ["a", "b", "c"])
        #expect(conversas.allSatisfy { $0.count == 1 })
        #expect(conversas.allSatisfy { $0.countLabel == nil })
    }

    @Test("As fixtures do Marco 1 não têm conversa nenhuma: sete linhas, sete mensagens")
    func fixturesIntactas() {
        let conversas = Conversation.build(from: Fixtures.messages)
        #expect(conversas.count == Fixtures.messages.count)
        #expect(conversas.allSatisfy { $0.countLabel == nil })
    }

    @Test("A conversa aparece na posição da mensagem mais recente dela")
    func posicaoNaLista() {
        let conversas = Conversation.build(from: [
            msg("z", at: 400, subject: "Outro"),
            msg("c", thread: "t1", at: 300),
            msg("a", thread: "t1", at: 100),
        ])
        #expect(conversas.map(\.key) == ["z", "t1"])
    }

    @Test("Não lida é `alguma` não lida, não `a mais recente`")
    func naoLida() throws {
        let conversa = try #require(
            Conversation.build(from: [
                msg("b", thread: "t1", at: 200, isRead: true),
                msg("a", thread: "t1", at: 100, isRead: false),
            ]).first
        )
        #expect(conversa.hasUnread)
        #expect(!conversa.latest.isRead == false)
    }

    @Test("Sinalizada segue a mesma regra de `alguma`")
    func sinalizada() throws {
        let conversa = try #require(
            Conversation.build(from: [
                msg("b", thread: "t1", at: 200),
                msg("a", thread: "t1", at: 100, isFlagged: true),
            ]).first
        )
        #expect(conversa.isFlagged)
    }

    /// Duas mensagens no mesmo segundo — o que uma importação produz — não
    /// podem trocar de lugar entre dois retratos.
    @Test("O empate de horário é desfeito pelo id, sempre do mesmo jeito")
    func empateEstavel() throws {
        let conversa = try #require(
            Conversation.build(from: [
                msg("b", thread: "t1", at: 100), msg("a", thread: "t1", at: 100),
            ]).first
        )
        let outraOrdem = try #require(
            Conversation.build(from: [
                msg("a", thread: "t1", at: 100), msg("b", thread: "t1", at: 100),
            ]).first
        )
        #expect(conversa.messages.map(\.id) == outraOrdem.messages.map(\.id))
    }

    @Test("Uma conversa sem mensagem nenhuma não existe")
    func vazia() {
        #expect(Conversation(key: "t1", messages: []) == nil)
        #expect(Conversation.build(from: []).isEmpty)
    }

    @Test("A chave de agrupamento é a `threadKey`, e o id quando não há")
    func chaveDeAgrupamento() {
        #expect(msg("a", thread: "t1", at: 1).conversationKey == "t1")
        #expect(msg("a", at: 1).conversationKey == "a")
    }

    /// Copiar a mensagem (marcar como lida, mover de caixa) não pode tirá-la da
    /// conversa dela — e o esquecimento **compila**, que é por isso que este
    /// teste existe.
    @Test("Os campos da conversa atravessam as cópias da mensagem")
    func copiasPreservam() {
        let original = msg("a", thread: "t1", at: 1)
        #expect(original.withRead(false).threadKey == "t1")
        #expect(original.withBucket(.archived).threadKey == "t1")
        #expect(original.withFlagged(true).threadKey == "t1")
        #expect(original.withBody(["x"], html: nil, calendarICS: nil).threadKey == "t1")
    }
}

@Suite("O MailStore agindo sobre a conversa")
@MainActor
struct ConversationStoreTests {

    /// Uma porta que só anota o que recebeu — é ela que prova que a operação
    /// sai com **todos** os ids, e não uma por mensagem.
    private final class Espia: MailCommandPort, @unchecked Sendable {
        var moves: [(TriageBucket, [String])] = []
        var deletes: [[String]] = []
        var reads: [(Bool, [String])] = []
        var flags: [(Bool, [String])] = []
        var apagados: [[String]] = []

        func setRead(_ isRead: Bool, accountID: String, messageIDs: [String]) throws {
            reads.append((isRead, messageIDs))
        }
        func setFlagged(_ isFlagged: Bool, accountID: String, messageIDs: [String]) throws {
            flags.append((isFlagged, messageIDs))
        }
        func move(to bucket: TriageBucket, accountID: String, messageIDs: [String]) throws {
            moves.append((bucket, messageIDs))
        }
        func delete(accountID: String, messageIDs: [String]) throws {
            deletes.append(messageIDs)
        }
        func deletePermanently(accountID: String, messageIDs: [String]) throws {
            apagados.append(messageIDs)
        }
        func emptyTrash(accountID: String) throws {}
    }

    private func store(_ messages: [Message], port: Espia? = nil) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: messages, agenda: []),
            commandPort: port
        )
        await store.load()
        store.select(bucket: .all)
        return store
    }

    private var trio: [Message] {
        [
            msg("c", thread: "t1", at: 300, bucket: .today, isRead: false),
            msg("b", thread: "t1", at: 200, bucket: .later, isRead: true),
            msg("a", thread: "t1", at: 100, bucket: .today, isRead: false),
        ]
    }

    @Test("A lista mostra uma linha, com as três dentro")
    func umaLinha() async {
        let store = await store(trio)
        #expect(store.visibleMessages.count == 3)
        #expect(store.visibleConversations.count == 1)
        #expect(store.visibleConversations.first?.count == 3)
    }

    @Test("Arquivar a conversa arquiva as três — numa operação só por conta")
    func arquivarAlcancaTodas() async throws {
        let espia = Espia()
        let store = await store(trio, port: espia)
        let conversa = try #require(store.visibleConversations.first)
        store.move(conversa, to: .archived)

        #expect(store.messages.allSatisfy { $0.bucket == .archived })
        // Uma operação, com os três ids — e não três operações.
        #expect(espia.moves.count == 1)
        #expect(espia.moves.first?.0 == .archived)
        #expect(Set(espia.moves.first?.1 ?? []) == ["a", "b", "c"])
    }

    @Test("Apagar a conversa é `delete`, não `move` — e leva as três")
    func apagarAlcancaTodas() async throws {
        let espia = Espia()
        let store = await store(trio, port: espia)
        let conversa = try #require(store.visibleConversations.first)
        store.move(conversa, to: .trash)
        #expect(espia.moves.isEmpty)
        #expect(Set(espia.deletes.first ?? []) == ["a", "b", "c"])
    }

    @Test("Marcar a conversa como lida alcança só as que não estavam")
    func lerAConversa() async throws {
        let espia = Espia()
        let store = await store(trio, port: espia)
        let conversa = try #require(store.visibleConversations.first)
        store.setRead(true, for: conversa)
        #expect(store.messages.allSatisfy { $0.isRead })
        #expect(Set(espia.reads.first?.1 ?? []) == ["a", "c"])
    }

    @Test("Sinalizar a conversa alcança as três")
    func sinalizarAConversa() async throws {
        let espia = Espia()
        let store = await store(trio, port: espia)
        let conversa = try #require(store.visibleConversations.first)
        store.setFlagged(true, for: conversa)
        #expect(store.messages.allSatisfy { $0.isFlagged })
        #expect(Set(espia.flags.first?.1 ?? []) == ["a", "b", "c"])
    }

    /// O "Desfazer" de uma ação de conversa devolve **cada** mensagem ao lugar
    /// dela: as três vinham de caixas diferentes.
    @Test("Desfazer devolve cada mensagem à caixa em que ela estava")
    func desfazerPorMensagem() async throws {
        let store = await store(trio)
        let conversa = try #require(store.visibleConversations.first)
        let antes = store.states(of: conversa.messageIDs)
        store.move(conversa, to: .archived)
        store.restore(antes)

        let porID = Dictionary(uniqueKeysWithValues: store.messages.map { ($0.id, $0) })
        #expect(porID["a"]?.bucket == .today)
        #expect(porID["b"]?.bucket == .later)
        #expect(porID["c"]?.bucket == .today)
        #expect(porID["a"]?.isRead == false)
        #expect(porID["b"]?.isRead == true)
    }

    @Test("Apagar de vez a conversa tira as três, e o cofre devolve as três")
    func apagarDeVez() async throws {
        let espia = Espia()
        let store = await store(trio, port: espia)
        let conversa = try #require(store.visibleConversations.first)
        store.deleteForever(conversa)
        #expect(store.messages.isEmpty)
        #expect(Set(espia.apagados.first ?? []) == ["a", "b", "c"])
        for id in conversa.messageIDs { store.restoreDeleted(id) }
        #expect(store.messages.count == 3)
    }

    /// Uma conversa **pode** cruzar contas — a mesma troca chega no trabalho e
    /// no pessoal. A porta é por conta, e mandar os ids das duas numa chamada
    /// só faria o espelho procurar no servidor errado.
    @Test("Conversa que cruza contas vira uma operação por conta")
    func duasContas() async throws {
        let espia = Espia()
        let store = await store([
            msg("b", thread: "t1", at: 200, accountID: "gmail"),
            msg("a", thread: "t1", at: 100, accountID: "zoho"),
        ], port: espia)
        let conversa = try #require(store.visibleConversations.first)
        store.move(conversa, to: .archived)
        #expect(espia.moves.count == 2)
        // Na ordem em que as contas aparecem na conversa, que é a cronológica.
        #expect(espia.moves.map { Set($0.1) } == [["a"], ["b"]])
    }

    @Test("A seleção anda para a linha seguinte quando a conversa aberta sai da caixa")
    func selecaoAnda() async throws {
        let store = await store(trio + [msg("z", at: 50, subject: "Outro")])
        store.select(message: "c")
        let conversa = try #require(store.conversation(of: "c"))
        store.move(conversa, to: .archived)
        // A conversa inteira saiu de "Tudo"? Não: "Tudo" contém arquivado. A
        // seleção fica onde estava — mover dentro da visão não move ninguém.
        #expect(store.selectedMessageID == "c")

        store.select(bucket: .today)
        store.select(message: "z")
        #expect(store.selectedMessageID == "z")
    }

    @Test("A conversa de uma mensagem selecionada é achável pelo id de qualquer uma delas")
    func conversaDaMensagem() async throws {
        let store = await store(trio)
        store.select(message: "a")
        #expect(store.selectedConversation?.key == "t1")
        #expect(store.conversation(of: "b")?.count == 3)
        #expect(store.conversation(of: "inexistente") == nil)
    }
}
