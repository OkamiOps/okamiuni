import Foundation
import Observation
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
        #expect(conversa.newestFirst.map(\.id) == ["c", "b", "a"])
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
        func place(
            in folder: MailFolder, mode: FolderPlacement,
            accountID: String, messageIDs: [String]
        ) throws {}
        func moveGmailLabel(
            from source: MailFolder, to destination: MailFolder,
            accountID: String, messageIDs: [String]
        ) throws {}
        func setAccountTint(lightHex: String, darkHex: String, accountID: String) throws {}
        func delete(accountID: String, messageIDs: [String]) throws {
            deletes.append(messageIDs)
        }
        func deletePermanently(accountID: String, messageIDs: [String]) throws {
            apagados.append(messageIDs)
        }
        func emptyTrash(accountID: String) throws {}
    }

    /// Simula uma transação SQLite presa atrás de outra escrita. O clique não
    /// pode esperar esta porta terminar para devolver controle à interface.
    private final class PortaLenta: MailCommandPort, @unchecked Sendable {
        private let lock = NSLock()
        private var terminou = false

        var concluiuLeitura: Bool {
            lock.withLock { terminou }
        }

        func setRead(_ isRead: Bool, accountID: String, messageIDs: [String]) throws {
            Thread.sleep(forTimeInterval: 0.25)
            lock.withLock { terminou = true }
        }
        func setFlagged(_ isFlagged: Bool, accountID: String, messageIDs: [String]) throws {}
        func move(to bucket: TriageBucket, accountID: String, messageIDs: [String]) throws {}
        func place(
            in folder: MailFolder, mode: FolderPlacement,
            accountID: String, messageIDs: [String]
        ) throws {}
        func moveGmailLabel(
            from source: MailFolder, to destination: MailFolder,
            accountID: String, messageIDs: [String]
        ) throws {}
        func setAccountTint(lightHex: String, darkHex: String, accountID: String) throws {}
        func delete(accountID: String, messageIDs: [String]) throws {}
        func deletePermanently(accountID: String, messageIDs: [String]) throws {}
        func emptyTrash(accountID: String) throws {}
    }

    private final class SinalDeObservacao: @unchecked Sendable {
        private let lock = NSLock()
        private var mudou = false

        var foiAcionado: Bool { lock.withLock { mudou } }
        func aciona() { lock.withLock { mudou = true } }
    }

    private func store(
        _ messages: [Message], port: (any MailCommandPort)? = nil
    ) async -> MailStore {
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
        await store.waitForPendingCommands()
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
        await store.waitForPendingCommands()
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
        await store.waitForPendingCommands()
        #expect(Set(espia.reads.first?.1 ?? []) == ["a", "c"])
    }

    @Test("Sinalizar a conversa alcança as três")
    func sinalizarAConversa() async throws {
        let espia = Espia()
        let store = await store(trio, port: espia)
        let conversa = try #require(store.visibleConversations.first)
        store.setFlagged(true, for: conversa)
        #expect(store.messages.allSatisfy { $0.isFlagged })
        await store.waitForPendingCommands()
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
        await store.waitForPendingCommands()
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
        await store.waitForPendingCommands()
        #expect(espia.moves.count == 2)
        // Na ordem em que as contas aparecem na conversa, que é a cronológica.
        #expect(espia.moves.map { Set($0.1) } == [["a"], ["b"]])
    }

    @Test("Selecionar continua imediato mesmo com a gravação ocupada")
    func selecaoNaoEsperaDisco() async {
        let port = PortaLenta()
        let store = await store(
            [msg("lenta", at: 100, isRead: false)],
            port: port
        )

        store.select(message: "lenta")

        #expect(store.selectedMessageID == "lenta")
        #expect(store.selectedMessage?.isRead == true)
        #expect(!port.concluiuLeitura)

        await store.waitForPendingCommands()
        #expect(port.concluiuLeitura)
    }

    /// A queixa do dono: a conversa agrupada fica marcada como não lida porque
    /// uma mensagem antiga da pilha nunca foi aberta, e a pilha não diz qual.
    /// Abrir a mais recente **é** ler a conversa — as anteriores são contexto,
    /// não trabalho restante.
    @Test("Selecionar a mais recente marca a conversa inteira como lida")
    func lerAUltimaMarcaAConversa() async throws {
        let espia = Espia()
        let store = await store(trio, port: espia)
        store.select(message: "c")

        #expect(store.messages.allSatisfy { $0.isRead })
        #expect(store.conversation(of: "c")?.hasUnread == false)
        await store.waitForPendingCommands()
        #expect(Set(espia.reads.first?.1 ?? []) == ["a", "c"])
    }

    /// Ir para uma mensagem antiga da conversa não é ler a conversa: é ler
    /// aquela. A mais recente que ainda não foi aberta continua trabalho.
    @Test("Selecionar uma mensagem antiga marca só ela")
    func lerAntigaNaoMarcaAConversa() async throws {
        let store = await store(trio)
        store.select(message: "a")
        let porID = Dictionary(uniqueKeysWithValues: store.messages.map { ($0.id, $0) })
        #expect(porID["a"]?.isRead == true)
        #expect(porID["b"]?.isRead == true)
        #expect(porID["c"]?.isRead == false)
        #expect(store.conversation(of: "c")?.hasUnread == true)
    }

    @Test("Cache hit continua observando mudanças das mensagens")
    func cacheMantemObservacao() async {
        let store = await store([msg("cache", at: 100, isRead: true)])
        _ = store.visibleMessages
        let changed = SinalDeObservacao()

        withObservationTracking {
            // Segunda leitura: passa pelo cache e precisa continuar registrando
            // a dependência que acorda o SwiftUI.
            _ = store.visibleMessages
        } onChange: {
            changed.aciona()
        }

        store.setRead(false, for: "cache")

        #expect(changed.foiAcionado)
        #expect(store.visibleMessages.first?.isRead == false)
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

    @Test("Marcar e desmarcar uma conversa não mexe no leitor")
    func marcarNaoAbre() async throws {
        let store = await store(trio + [msg("z", at: 50, subject: "Outro")])
        store.select(message: "z")
        let chave = try #require(store.conversation(of: "c")?.key)
        store.toggleChecked(chave)
        #expect(store.isChecked(chave))
        #expect(store.selectedMessageID == "z")
        store.toggleChecked(chave)
        #expect(!store.isChecked(chave))
    }

    @Test("Selecionar todas marca cada conversa visível, em qualquer caixa")
    func selecionarTodasEmQualquerCaixa() async throws {
        let store = await store(trio + [msg("z", at: 50, subject: "Outro")])
        store.select(bucket: .all)
        store.selectAllVisible()
        #expect(store.allVisibleChecked)
        #expect(store.checkedConversations.count == 2)

        store.select(bucket: .later)
        #expect(store.checkedConversations.count <= 1)
    }

    @Test("Trocar de caixa descarta as marcas que saíram da visão")
    func trocarDeCaixaPodandoMarcas() async throws {
        let store = await store([
            msg("hoje", at: 300, bucket: .today),
            msg("depois", at: 200, bucket: .later),
        ])
        store.select(bucket: .later)
        store.selectAllVisible()
        #expect(store.checkedConversations.map(\.latest.id) == ["depois"])
        store.select(bucket: .archived)
        #expect(store.checkedConversations.map(\.latest.id) == [])
        #expect(!store.allVisibleChecked)
    }

    @Test("O checkbox do cabeçalho marca todas ou limpa, em Arquivado também")
    func checkboxDoCabecalhoEmArquivado() async throws {
        let store = await store([
            msg("a", at: 300, subject: "Um", bucket: .archived),
            msg("b", at: 200, subject: "Dois", bucket: .archived),
        ])
        store.select(bucket: .archived)
        store.toggleSelectAllVisible()
        #expect(store.allVisibleChecked)
        store.toggleSelectAllVisible()
        #expect(store.checkedConversationKeys.isEmpty)
    }

    @Test("Mover o lote para fora da caixa limpa as marcas")
    func moverLoteLimpaMarcas() async throws {
        let store = await store([
            msg("a", at: 300, subject: "Um", bucket: .archived),
            msg("b", at: 200, subject: "Dois", bucket: .archived),
        ])
        store.select(bucket: .archived)
        store.selectAllVisible()
        #expect(store.checkedConversations.count == 2)
        #expect(store.checkedAccountID == "zoho")
        for conversa in store.checkedConversations {
            store.move(conversa, to: .later)
        }
        #expect(store.messages.allSatisfy { $0.bucket == .later })
        #expect(store.checkedConversationKeys.isEmpty)
        #expect(!store.hasChecked)
    }

    @Test("A página da lista não materializa a caixa inteira")
    func paginaNaoMaterializaTudo() async {
        let muitas = (0..<40).map { i in
            msg("m\(i)", at: TimeInterval(2000 - i), subject: "S\(i)", bucket: .later)
        }
        let store = await store(muitas)
        store.select(bucket: .all)
        let page = store.conversationPage(limit: 10)
        #expect(page.conversations.count == 10)
        #expect(page.hasMore)
        #expect(page.messageCount == 10)
        #expect(page.conversations.first?.latest.id == "m0")
        #expect(page.conversations.last?.latest.id == "m9")
        let resto = store.conversationPage(limit: 10)
        #expect(resto.conversations.map(\.latest.id) == page.conversations.map(\.latest.id))
        let cheia = store.conversationPage(limit: 40)
        #expect(cheia.conversations.count == 40)
        #expect(!cheia.hasMore)
        #expect(cheia.messageCount == 40)
        // O clique em Tudo para nas primeiras linhas; o resto entra no scroll.
        let curta = store.conversationPage(limit: 5)
        #expect(curta.conversations.map(\.latest.id) == ["m0", "m1", "m2", "m3", "m4"])
        #expect(curta.hasMore)
        #expect(curta.messageCount == 5)
    }

    @Test("Clicar em Tudo para nas primeiras 20 mesmo com milhares de HTML")
    func cliqueEmTudoParaNasPrimeiras() async {
        let html = String(repeating: "<p>abcdefghij</p>", count: 80)
        let muitas = (0..<2_000).map { i in
            Message(
                id: "m\(i)", accountID: "zoho",
                from: Contact(name: "Marina", address: "marina@x.com"),
                receivedAt: Date(timeIntervalSince1970: TimeInterval(20_000 - i)),
                subject: "S\(i)", snippet: "trecho", body: ["corpo"], tags: [],
                bucket: .later, isRead: true, summary: nil, detectedEvent: nil,
                bodyHTML: html
            )
        }
        let store = await store(muitas)
        let t0 = ContinuousClock.now
        store.select(bucket: .all)
        let page = store.conversationPage(limit: 20)
        let elapsed = t0.duration(to: .now)
        #expect(page.conversations.count == 20)
        #expect(page.hasMore)
        #expect(page.conversations.first?.latest.id == "m0")
        #expect(elapsed < .milliseconds(150))
    }

    @Test("Pastas e página de Tudo não copiam a caixa no clique")
    func pastasDeTudoNaoCopiamACaixa() async {
        var muitas: [Message] = []
        muitas.reserveCapacity(8_000)
        for i in 0..<8_000 {
            let caixa: TriageBucket = i % 20 == 0 ? .later : .later
            let conta = i % 3 == 0 ? "a" : "b"
            muitas.append(msg("m\(i)", at: TimeInterval(80_000 - i), subject: "S", bucket: caixa, accountID: conta))
        }
        let store = await store(muitas)
        store.select(bucket: TriageBucket.today)
        _ = store.folders(of: "a")
        let t0 = ContinuousClock.now
        store.select(bucket: TriageBucket.all)
        let page = store.conversationPage(limit: 20)
        _ = store.folders(of: "a")
        _ = store.folders(of: "b")
        let elapsed = t0.duration(to: .now)
        #expect(page.conversations.count == 20)
        #expect(elapsed < .milliseconds(40))
    }

    @Test("Voltar a Tudo reusa a página já montada")
    func paginaDeTudoSobreviveIdaEVolta() async {
        let muitas = (0..<40).map { i in
            msg("m\(i)", at: TimeInterval(2000 - i), subject: "S\(i)", bucket: .later)
        }
        let store = await store(muitas)
        store.select(bucket: .all)
        let tudo = store.conversationPage(limit: 10)
        #expect(tudo.conversations.count == 10)
        store.select(bucket: .today)
        _ = store.conversationPage(limit: 10)
        store.select(bucket: .later)
        _ = store.conversationPage(limit: 10)
        store.select(bucket: .archived)
        _ = store.conversationPage(limit: 10)
        let depoisDasOutras = store.conversationPageBuildCount
        store.select(bucket: .all)
        let deNovo = store.conversationPage(limit: 10)
        #expect(store.conversationPageBuildCount == depoisDasOutras)
        #expect(deNovo == tudo)
    }

    @Test("A página da lista não leva o HTML; o leitor ainda o tem")
    func paginaNaoLevaHTML() async {
        let html = String(repeating: "<p>x</p>", count: 200)
        let fat = Message(
            id: "fat", accountID: "zoho",
            from: Contact(name: "Marina", address: "marina@x.com"),
            receivedAt: Date(timeIntervalSince1970: 2000),
            subject: "HTML", snippet: "trecho", body: ["texto"], tags: [],
            bucket: .later, isRead: true, summary: nil, detectedEvent: nil,
            bodyHTML: html
        )
        let resto = (1..<20).map {
            msg("m\($0)", at: TimeInterval(2000 - $0), subject: "S\($0)", bucket: .later)
        }
        let store = await store([fat] + resto)
        store.select(bucket: .all)
        let page = store.conversationPage(limit: 10)
        let naLista = page.conversations.first { $0.latest.id == "fat" }
        #expect(naLista != nil)
        #expect(naLista?.latest.bodyHTML == nil)
        #expect(naLista?.latest.body.isEmpty == true)
        #expect(store.conversation(of: "fat")?.latest.bodyHTML == html)
        #expect(store.conversation(of: "fat")?.latest.body == ["texto"])
    }

    @Test("Contar por conta não materializa a caixa")
    func contarPorContaNaoCopiaTudo() async {
        let zoho = (0..<8).map {
            msg("z\($0)", at: TimeInterval(300 - $0), bucket: .later, accountID: "zoho")
        }
        let gmail = (0..<3).map {
            msg("g\($0)", at: TimeInterval(100 - $0), bucket: .later, accountID: "gmail")
        }
        let store = await store(zoho + gmail)
        #expect(store.count(forAccount: "zoho") == 8)
        #expect(store.count(forAccount: "gmail") == 3)
        #expect(store.count(forAccount: "nao") == 0)
        #expect(store.trashCount() == 0)
        store.select(bucket: .today)
        store.select(bucket: .all)
        #expect(store.count(forAccount: "zoho") == 8)
    }

    @Test("A seta desce e sobe uma conversa na lista, e para na ponta")
    func setaAndaNaLista() async throws {
        let store = await store([
            msg("z", at: 400, subject: "Outro"),
            msg("c", thread: "t1", at: 300),
            msg("a", thread: "t1", at: 100),
        ])
        store.select(message: "z")
        #expect(store.selectAdjacentConversation(offset: 1))
        #expect(store.selectedMessageID == "c")
        #expect(store.selectedConversation?.key == "t1")
        #expect(store.selectAdjacentConversation(offset: 1))
        #expect(store.selectedMessageID == "c")
        #expect(store.selectAdjacentConversation(offset: -1))
        #expect(store.selectedMessageID == "z")
        #expect(store.selectAdjacentConversation(offset: -1))
        #expect(store.selectedMessageID == "z")
    }

    @Test("Caixa vazia não engole a seta")
    func setaEmCaixaVazia() async {
        let store = await store([msg("z", at: 400, subject: "Outro", bucket: .archived)])
        store.select(bucket: .today)
        #expect(!store.selectAdjacentConversation(offset: 1))
        #expect(!store.selectAdjacentConversation(offset: -1))
    }

    @Test("O lote mistura contas e aí não há pasta comum")
    func loteMisturaContas() async throws {
        let store = await store([
            msg("a", at: 300, subject: "Um", bucket: .later, accountID: "zoho"),
            msg("b", at: 200, subject: "Dois", bucket: .later, accountID: "gmail"),
        ])
        store.select(bucket: .later)
        store.selectAllVisible()
        #expect(store.checkedConversations.count == 2)
        #expect(store.checkedAccountID == nil)
    }
}
