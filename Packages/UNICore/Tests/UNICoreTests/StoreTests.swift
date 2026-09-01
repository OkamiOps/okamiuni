import Testing
import Foundation
@testable import UNICore

@Suite("MailStore")
struct StoreTests {

    @MainActor
    private func loadedStore() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("carrega as contas que a fonte entregar")
    @MainActor
    func loadsAccounts() async {
        let store = await loadedStore()
        #expect(store.accounts.isEmpty == false)
        // Sem asserção de quantidade: o número de contas é do usuário.
        #expect(Set(store.accounts.map(\.id)).count == store.accounts.count)
    }

    /// O produto aceita qualquer quantidade de contas, de qualquer provedor,
    /// em qualquer domínio. Estes três testes existem para que nenhuma
    /// mudança futura reintroduza um limite por descuido.
    @Test("funciona sem nenhuma conta")
    @MainActor
    func handlesZeroAccounts() async {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: [])
        )
        await store.load()
        #expect(store.accounts.isEmpty)
        #expect(store.visibleMessages.isEmpty)
        #expect(store.selectedMessage == nil)
        #expect(store.loadError == nil)
    }

    @Test("funciona com muitas contas em domínios arbitrários")
    @MainActor
    func handlesManyAccounts() async {
        let many = (1...30).map { i in
            Account(
                id: "acc\(i)", address: "pessoa@dominio\(i).com.br",
                displayName: "Conta \(i)", provider: .imap, host: "dominio\(i)",
                tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
            )
        }
        let store = MailStore(
            source: InMemoryMailSource(accounts: many, messages: [], agenda: [])
        )
        await store.load()
        #expect(store.accounts.count == 30)
        #expect(store.account("acc17")?.address == "pessoa@dominio17.com.br")
    }

    @Test("uma conta de provedor desconhecido é tratada como IMAP normal")
    @MainActor
    func unknownProviderIsOrdinary() async throws {
        let obscure = Account(
            id: "servidor-proprio", address: "eu@meuservidor.xyz",
            displayName: "Servidor próprio", provider: .imap, host: "meuservidor",
            tintLightHex: "#2C7D5E", tintDarkHex: "#7CBAAA"
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [obscure], messages: [], agenda: [])
        )
        await store.load()
        let found = try #require(store.account("servidor-proprio"))
        #expect(found.provider == .imap)
        // Afirmava `host == "servidor-proprio"`, o próprio `id` — verdadeiro
        // por construção enquanto `host` era `var host { id }`, e passava com
        // o defeito que o dono do projeto viu na tela. O `host` é o nome que
        // se lê; o `id` é a chave interna, e eles não têm de coincidir.
        #expect(found.host == "meuservidor")
        #expect(found.host != found.id)
    }

    @Test("a caixa Tudo mostra mais mensagens que Hoje")
    @MainActor
    func bucketFiltering() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        let all = store.visibleMessages.count
        store.select(bucket: .today)
        let today = store.visibleMessages.count
        #expect(all > 0)
        #expect(today > 0)
        #expect(all >= today)
    }

    /// Uma conta e quatro mensagens que só casam por UM campo cada — nome,
    /// endereço, assunto ou trecho — mais uma que não casa em campo nenhum.
    /// Isto prova que a busca de fato olha os quatro campos que promete:
    /// reduzir `matches` a um só campo (como `[message.from.name]`) faz
    /// exatamente três das quatro sumirem, e o teste cai.
    @MainActor
    private func searchFixtureStore() -> MailStore {
        let account = Account(
            id: "acc1", address: "acc1@example.com", displayName: "Conta 1",
            provider: .imap, host: "acc1host", tintLightHex: "#000000", tintDarkHex: "#FFFFFF"
        )
        func message(_ id: String, name: String, address: String, subject: String, snippet: String) -> Message {
            Message(
                id: id, accountID: account.id,
                from: Contact(name: name, address: address),
                receivedAt: Date(), subject: subject, snippet: snippet, body: [],
                tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil
            )
        }
        let messages = [
            message("byName", name: "Marina Alves", address: "outro@x.com", subject: "assunto qualquer", snippet: "trecho qualquer"),
            message("byAddress", name: "Fulano", address: "marina@x.com", subject: "assunto qualquer", snippet: "trecho qualquer"),
            message("bySubject", name: "Fulano", address: "outro@x.com", subject: "falar com Marina amanhã", snippet: "trecho qualquer"),
            message("bySnippet", name: "Fulano", address: "outro@x.com", subject: "assunto qualquer", snippet: "combinei com a Marina"),
            message("noMatch", name: "Fulano", address: "outro@x.com", subject: "assunto qualquer", snippet: "trecho qualquer"),
        ]
        let source = InMemoryMailSource(accounts: [account], messages: messages, agenda: [], pendingItems: [])
        return MailStore(source: source)
    }

    @Test("a busca casa remetente, endereço, assunto e trecho — os quatro campos")
    @MainActor
    func searchMatchesEveryPromisedField() async {
        let store = searchFixtureStore()
        await store.load()
        store.select(bucket: .all)
        store.query = "Marina"
        let ids = Set(store.visibleMessages.map(\.id))
        #expect(ids == ["byName", "byAddress", "bySubject", "bySnippet"])
    }

    @Test("a busca dobra acento: \"Revisao\" acha \"Revisão\"")
    @MainActor
    func searchFoldsAccents() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        store.query = "Revisao"
        #expect(store.visibleMessages.contains { $0.subject.contains("Revisão") })
    }

    @Test("busca sem resultado devolve lista vazia, não a lista inteira")
    @MainActor
    func searchMiss() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        store.query = "zzzznadaaqui"
        #expect(store.visibleMessages.isEmpty)
    }

    @Test("Tudo acha o que saiu de Hoje; apagar o termo desliga o recorte")
    @MainActor
    func searchEverywhereFindsArchived() async {
        let account = Account(
            id: "acc1", address: "acc1@example.com", displayName: "Conta 1",
            provider: .imap, host: "acc1host", tintLightHex: "#000000", tintDarkHex: "#FFFFFF"
        )
        let hoje = Message(
            id: "hoje", accountID: account.id,
            from: Contact(name: "Beatriz", address: "beatriz@x.com"),
            receivedAt: Fixtures.today, subject: "Na caixa", snippet: "", body: [],
            tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil
        )
        let arquivo = Message(
            id: "arquivo", accountID: account.id,
            from: Contact(name: "Beatriz", address: "beatriz@x.com"),
            receivedAt: Fixtures.today, subject: "Arquivada", snippet: "", body: [],
            tags: [], bucket: .archived, isRead: true, summary: nil, detectedEvent: nil
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [hoje, arquivo], agenda: [])
        )
        await store.load()
        store.select(bucket: .today)
        store.query = "Beatriz"
        #expect(Set(store.visibleMessages.map(\.id)) == ["hoje"])
        store.searchEverywhere = true
        #expect(store.searchesEverywhereNow)
        #expect(Set(store.visibleMessages.map(\.id)) == ["hoje", "arquivo"])
        store.query = ""
        #expect(store.searchEverywhere == false)
        #expect(store.visibleMessages.contains { $0.id == "hoje" })
        #expect(!store.visibleMessages.contains { $0.id == "arquivo" })
    }

    @Test("selecionar uma mensagem marca como lida")
    @MainActor
    func selectionMarksRead() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let first = try #require(store.visibleMessages.first)
        store.select(message: first.id)
        #expect(store.selectedMessage?.id == first.id)
        #expect(store.selectedMessage?.isRead == true)
    }

    @Test("mudar de caixa nunca deixa a seleção apontando para fora da visão")
    @MainActor
    func selectionNeverEscapesView() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let archived = try #require(
            store.visibleMessages.first { $0.bucket == .archived }
        )
        store.select(message: archived.id)
        store.select(bucket: .today)

        // Este teste afirmava `selectedMessage == nil`, escrito quando limpar
        // era o comportamento pretendido — antes de existir seleção padrão.
        // A intenção dele continua valendo; a asserção é que era mais forte
        // que a intenção. O invariante real é este:
        #expect(store.selectedMessage?.id != archived.id)
        if let selected = store.selectedMessage {
            #expect(store.visibleMessages.contains { $0.id == selected.id })
        }
    }

    // MARK: - O dia sobrevive à triagem

    /// `dayOffset` e `replyHints` têm valor padrão no `init`, e o `move` e o
    /// `markRead` **reconstroem** a mensagem. Esquecer de passá-los adiante ali
    /// não daria erro de compilação: daria uma mensagem de ontem reaparecendo
    /// sob o cabeçalho "Hoje" depois de arquivar, e as sugestões de resposta
    /// sumindo depois de abrir. Nenhum dos dois é visível num diff.
    @Test("mover de caixa não muda o dia em que a mensagem chegou")
    @MainActor
    func movePreservesTheDay() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let yesterday = try #require(store.messages.first { $0.dayOffset == -1 })

        store.move(yesterday, to: .archived)

        let after = try #require(store.messages.first { $0.id == yesterday.id })
        #expect(after.bucket == .archived)
        #expect(after.dayOffset == -1)
        #expect(after.replyHints == yesterday.replyHints)
    }

    @Test("marcar como lida não muda o dia nem as sugestões")
    @MainActor
    func readingPreservesTheDay() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let before = try #require(store.messages.first { $0.dayOffset == -1 && !$0.replyHints.isEmpty })

        store.select(message: before.id)

        let after = try #require(store.messages.first { $0.id == before.id })
        #expect(after.isRead)
        #expect(after.dayOffset == -1)
        #expect(after.replyHints == before.replyHints)
    }

    // MARK: - Seleção padrão (Task P, defeito 2)

    @Test("load() abre a primeira mensagem da caixa, como o protótipo")
    @MainActor
    func loadSelectsFirstVisibleMessage() async throws {
        let store = await loadedStore()
        let first = try #require(store.visibleMessages.first)
        #expect(store.selectedMessageID == first.id)
        // O protótipo abre em `selected: 'm1'` — Marina Duarte, a primeira de "hoje".
        #expect(store.selectedMessage?.from.name == "Marina Duarte")
    }

    @Test("a seleção padrão nunca aponta para fora de visibleMessages")
    @MainActor
    func defaultSelectionStaysInsideTheView() async throws {
        let store = await loadedStore()
        let selected = try #require(store.selectedMessage)
        #expect(store.visibleMessages.contains { $0.id == selected.id })
    }

    @Test("caixa vazia continua sem seleção, para o leitor mostrar o estado vazio")
    @MainActor
    func emptyBucketHasNoDefaultSelection() async {
        // A fonte entrega mensagens, mas nenhuma delas cai na caixa aberta
        // (o padrão é "Hoje" e todas estão arquivadas). A lista fica vazia,
        // então o leitor deve mostrar "Nada aqui. Bom sinal." — e não uma
        // mensagem que a lista não está mostrando.
        let archivedOnly = Fixtures.messages.filter { $0.bucket == .archived }
        #expect(archivedOnly.isEmpty == false)  // a premissa do teste

        let store = MailStore(
            source: InMemoryMailSource(
                accounts: Fixtures.accounts,
                messages: archivedOnly,
                agenda: Fixtures.agenda
            )
        )
        await store.load()
        #expect(store.bucket == .today)
        #expect(store.messages.isEmpty == false)  // há mensagem, só não nesta caixa
        #expect(store.visibleMessages.isEmpty)
        #expect(store.selectedMessage == nil)
    }

    @Test("recarregar não tira o usuário da mensagem que ele já tinha aberto")
    @MainActor
    func reloadKeepsAnExistingSelection() async throws {
        let store = await loadedStore()
        let other = try #require(store.visibleMessages.dropFirst().first)
        store.select(message: other.id)
        await store.load()
        #expect(store.selectedMessageID == other.id)
    }

    // MARK: - Triagem move a mensagem, não a visão (Task P, rodada 1)

    @Test("triar move a mensagem de caixa e não mexe na caixa aberta")
    @MainActor
    func triageMovesTheMessageNotTheView() async throws {
        let store = await loadedStore()
        let bucketBefore = store.bucket
        let message = try #require(store.visibleMessages.first)
        #expect(message.bucket == .today)

        store.move(message, to: .later)

        // A caixa aberta é da lista, não do botão.
        #expect(store.bucket == bucketBefore)
        // A mensagem trocou de caixa.
        let moved = try #require(store.messages.first { $0.id == message.id })
        #expect(moved.bucket == .later)
    }

    @Test("depois de mover, a seleção passa para a próxima da lista")
    @MainActor
    func movingSelectsTheNextMessage() async throws {
        let store = await loadedStore()
        let first = try #require(store.visibleMessages.first)
        let second = try #require(store.visibleMessages.dropFirst().first)
        #expect(store.selectedMessageID == first.id)

        store.move(first, to: .later)

        #expect(store.selectedMessageID == second.id)
        // E continua dentro da visão — a mesma invariante da troca de caixa.
        #expect(store.visibleMessages.contains { $0.id == store.selectedMessageID })
    }

    @Test("mover a última da caixa cai na anterior, nunca fora da visão")
    @MainActor
    func movingTheLastFallsBackToThePrevious() async throws {
        let store = await loadedStore()
        let visible = store.visibleMessages
        #expect(visible.count >= 2)
        let last = try #require(visible.last)
        let previous = try #require(visible.dropLast().last)

        store.select(message: last.id)
        store.move(last, to: .archived)

        #expect(store.selectedMessageID == previous.id)
        #expect(store.visibleMessages.contains { $0.id == previous.id })
    }

    @Test("esvaziar a caixa triando deixa o leitor sem seleção")
    @MainActor
    func emptyingTheBucketClearsTheSelection() async {
        let store = await loadedStore()
        // Move tudo o que está visível para outra caixa, uma a uma. O limite
        // existe para o teste falhar em vez de travar se `move` deixar de
        // esvaziar a caixa — foi o que aconteceu ao rodar contra o código
        // antigo, que trocava a visão em vez de mover a mensagem.
        let limit = store.messages.count + 1
        var moves = 0
        while let visible = store.visibleMessages.first, moves < limit {
            store.move(visible, to: .archived)
            moves += 1
        }
        #expect(moves < limit)
        #expect(store.visibleMessages.isEmpty)
        #expect(store.selectedMessage == nil)
    }

    @Test("na caixa Tudo, mover não tira a mensagem do leitor")
    @MainActor
    func movingInsideTheAllBucketKeepsTheSelection() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let message = try #require(store.visibleMessages.first)
        store.select(message: message.id)

        store.move(message, to: .archived)

        // "Tudo" aceita qualquer caixa, então ela continua visível.
        #expect(store.selectedMessageID == message.id)
        #expect(store.messages.first { $0.id == message.id }?.bucket == .archived)
    }

    @Test("mover para a caixa em que a mensagem já está não faz nada")
    @MainActor
    func movingToTheSameBucketIsANoOp() async throws {
        let store = await loadedStore()
        let message = try #require(store.visibleMessages.first)
        let selectionBefore = store.selectedMessageID

        store.move(message, to: message.bucket)

        #expect(store.selectedMessageID == selectionBefore)
        #expect(store.messages.first { $0.id == message.id }?.bucket == message.bucket)
    }

    /// `Fixtures.month` já nasce ordenado, então carregar ele não prova que
    /// `load()` ordena nada — passa igual sem o `.sorted` em `MessageStore`.
    /// Embaralha a entrada na fonte para forçar `load()` a de fato ordenar.
    @Test("a trilha de agenda vem ordenada por horário")
    @MainActor
    func agendaSorted() async {
        let account = Account(
            id: "acc1", address: "acc1@example.com", displayName: "Conta 1",
            provider: .imap, host: "acc1host", tintLightHex: "#000000", tintDarkHex: "#FFFFFF"
        )
        let shuffled = [
            AgendaItem(id: "a", title: "C", startMinute: 900, endMinute: 930, accountID: account.id),
            AgendaItem(id: "b", title: "A", startMinute: 60, endMinute: 90, accountID: account.id),
            AgendaItem(id: "c", title: "D", startMinute: 1200, endMinute: 1230, accountID: account.id),
            AgendaItem(id: "d", title: "B", startMinute: 480, endMinute: 510, accountID: account.id),
        ]
        let source = InMemoryMailSource(accounts: [account], messages: [], agenda: shuffled, pendingItems: [])
        let store = MailStore(source: source)
        await store.load()
        let starts = store.agenda.map(\.startMinute)
        #expect(starts == [60, 480, 900, 1200])
        #expect(starts == starts.sorted())
    }

    @Test("load() é atômico: falha após accounts() não deixa o estado anterior inconsistente")
    @MainActor
    func loadAtomicity() async {
        // Fonte com estado: sucesso na primeira chamada, falha na segunda.
        // Isto testa atomicidade NO MESMO STORE, o cenário real.
        actor TogglableSource: MailSource {
            private var attemptCount = 0

            func accounts() async throws -> [Account] {
                attemptCount += 1
                if attemptCount == 2 {
                    // Na segunda tentativa, devolve uma conta diferente
                    // (provaria que accounts foi parcialmente escrito, se não-atômico)
                    return [Account(
                        id: "replacementacc", address: "replacement@teste.com",
                        displayName: "Conta de Reposição", provider: .imap, host: "reposicao",
                        tintLightHex: "#ABCDEF", tintDarkHex: "#D5E3F7"
                    )]
                }
                // Primeira tentativa: devolve dados bons
                return Fixtures.accounts
            }

            func messages() async throws -> [Message] {
                if attemptCount == 2 {
                    // Na segunda tentativa, lança após accounts() ter sucesso
                    throw NSError(
                        domain: "test", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Falha de rede no messages()"]
                    )
                }
                // Primeira tentativa: devolve dados bons
                return Fixtures.messages
            }

            func agenda() async throws -> [AgendaItem] {
                if attemptCount == 2 {
                    throw NSError(
                        domain: "test", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Falha de rede no agenda()"]
                    )
                }
                return Fixtures.agenda
            }

            func pendingItems() async throws -> [PendingItem] {
                Fixtures.pendingItems
            }
        }

        let source = TogglableSource()
        let store = MailStore(source: source)

        // (a) Carrega com sucesso — o store fica com dados bons
        await store.load()
        let accountsAfterFirstLoad = store.accounts
        let messagesAfterFirstLoad = store.messages
        let agendaAfterFirstLoad = store.agenda
        #expect(accountsAfterFirstLoad.isEmpty == false)
        #expect(messagesAfterFirstLoad.isEmpty == false)
        #expect(agendaAfterFirstLoad.isEmpty == false)
        #expect(store.loadError == nil)

        // (b) Tenta carregar de novo com o MESMO STORE (mesmo source, mas segundo estado)
        // A fonte falhará em messages() APÓS accounts() retornar com sucesso
        // (Na versão não-atômica, accounts teria sido substituído na segunda tentativa)
        await store.load()

        // (c) Verifica que o estado bom foi PRESERVADO ATOMICAMENTE
        // accounts deve continuar exatamente como era, NÃO com a conta de reposição
        #expect(store.accounts == accountsAfterFirstLoad)
        #expect(store.messages == messagesAfterFirstLoad)
        #expect(store.agenda == agendaAfterFirstLoad)
        // Especificamente, accounts NÃO foi substituído:
        #expect(store.accounts.contains { $0.id == "replacementacc" } == false)

        // (d) loadError foi preenchido
        #expect(store.loadError != nil)
        #expect(store.loadError?.contains("Falha de rede no messages()") == true)
    }

    @Test("filtrar por conta reduz visibleMessages")
    @MainActor
    func accountFilterReducesVisible() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        let allCount = store.visibleMessages.count
        #expect(allCount > 0)

        // Seleciona a primeira conta
        guard let firstAccount = store.accounts.first else {
            Issue.record("Nenhuma conta nos fixtures")
            return
        }

        // Computa o número exato de mensagens dessa conta
        let expectedFiltered = store.messages.filter { $0.accountID == firstAccount.id }.count

        store.select(account: firstAccount.id)
        let filteredCount = store.visibleMessages.count

        // Verifica igualdade exata contra o valor computado
        #expect(filteredCount == expectedFiltered)
        // E, se essa conta não tem todas as mensagens, verifica que filtrou
        if expectedFiltered < allCount {
            #expect(filteredCount < allCount)
        }
        // Verifica que todas as mensagens visíveis pertencem à conta selecionada
        #expect(store.visibleMessages.allSatisfy { $0.accountID == firstAccount.id })
    }

    @Test("clicar de novo na mesma conta desliga o filtro")
    @MainActor
    func accountFilterToggle() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        guard let firstAccount = store.accounts.first else {
            Issue.record("Nenhuma conta nos fixtures")
            return
        }

        let beforeFilter = store.visibleMessages.count

        // Seleciona
        store.select(account: firstAccount.id)
        #expect(store.selectedAccountID == firstAccount.id)

        // Clica de novo na mesma
        store.select(account: firstAccount.id)
        #expect(store.selectedAccountID == nil)

        // Deve voltar ao número anterior
        #expect(store.visibleMessages.count == beforeFilter)
    }

    @Test("count(for:) respeita o filtro de conta")
    @MainActor
    func countRespectsAccountFilter() async {
        let store = await loadedStore()
        guard let firstAccount = store.accounts.first else {
            Issue.record("Nenhuma conta nos fixtures")
            return
        }

        let countBeforeFilter = store.count(for: .all)
        store.select(account: firstAccount.id)
        let countAfterFilter = store.count(for: .all)

        // Ao filtrar, o contador deve diminuir ou ser igual
        #expect(countAfterFilter <= countBeforeFilter)
    }

    @Test("filtro por conta e busca se combinam")
    @MainActor
    func accountFilterAndSearchCombine() async {
        let store = await loadedStore()
        store.select(bucket: .all)

        // Busca por "Marina" — nas fixtures, apenas m1 (zoho) contém Marina
        store.query = "Marina"
        let searchOnlyCount = store.visibleMessages.count
        #expect(searchOnlyCount == 1) // Exatamente m1

        // Filtra para zoho (que tem a mensagem com Marina)
        store.select(account: "zoho")
        let marinaPlusZohoCount = store.visibleMessages.count
        #expect(marinaPlusZohoCount == 1) // Mesma mensagem

        // Limpa busca, verifica que agora há mais mensagens zoho (m1 + m2)
        store.query = ""
        let zohoAllCount = store.visibleMessages.count
        #expect(zohoAllCount == 2) // m1 e m2 são em zoho

        // Busca de novo por Marina, com filtro zoho ainda ativo
        store.query = "Marina"
        let marinaPlusZohoAgainCount = store.visibleMessages.count
        #expect(marinaPlusZohoAgainCount == 1) // Volta a 1

        // Muda para gmail
        store.query = "Marina"
        store.select(account: "gmail")
        let marinaInGmailCount = store.visibleMessages.count
        #expect(marinaInGmailCount == 0) // gmail não tem Marina
    }
}

@Suite("Seleção padrão fora do load")
@MainActor
struct DefaultSelectionTests {

    private func loaded() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    /// O defeito: `select(bucket:)` e `select(account:)` limpavam a seleção que
    /// saiu da visão mas nunca escolhiam outra, então o leitor abria vazio com
    /// mensagens na lista. `load()` já fazia certo; as outras duas portas não.
    @Test("trocar para uma caixa que não contém a seleção escolhe outra, não o vazio",
          arguments: [TriageBucket.later, .archived, .all])
    func bucketSwitchKeepsAReader(target: TriageBucket) async {
        let store = await loaded()
        store.select(bucket: target)
        try? #require(store.visibleMessages.isEmpty == false)
        #expect(store.selectedMessageID != nil,
                "caixa \(target) tem \(store.visibleMessages.count) mensagens e nenhuma selecionada")
        #expect(store.visibleMessages.contains { $0.id == store.selectedMessageID })
    }

    @Test("filtrar por uma conta que não tem a mensagem selecionada escolhe outra")
    func accountFilterKeepsAReader() async {
        let store = await loaded()
        store.select(bucket: .all)
        // uma conta diferente da que dona da mensagem selecionada
        let selectedAccount = store.selectedMessage?.accountID
        let other = store.messages.first { $0.accountID != selectedAccount }?.accountID
        let target = try? #require(other)
        store.select(account: target)
        try? #require(store.visibleMessages.isEmpty == false)
        #expect(store.selectedMessageID != nil,
                "conta \(target ?? "?") tem \(store.visibleMessages.count) mensagens e nenhuma selecionada")
        #expect(store.visibleMessages.contains { $0.id == store.selectedMessageID })
    }

    @Test("numa visão sem mensagens a seleção é nil, para o estado vazio aparecer")
    func emptyViewHasNoSelection() async {
        let store = await loaded()
        store.select(bucket: .all)
        store.select(account: "conta-que-nao-existe")
        #expect(store.visibleMessages.isEmpty)
        #expect(store.selectedMessageID == nil)
    }

    @Test("trocar de caixa não tira o usuário de uma mensagem que continua visível")
    func staysOnMessageStillInView() async {
        let store = await loaded()
        store.select(bucket: .all)
        let chosen = store.visibleMessages[1].id
        store.select(message: chosen)
        store.select(bucket: .all)   // mesma caixa: nada deve mudar
        #expect(store.selectedMessageID == chosen)
    }
}

@Suite("Filtro de conta na agenda")
@MainActor
struct AgendaAccountFilterTests {

    private func loaded() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    /// O defeito: clicar numa caixa filtrava a lista de mensagens e **não** a
    /// grade da agenda. Metade da janela mentia sobre o que estava mostrando.
    @Test("selecionar uma conta tira da agenda os compromissos das outras")
    func filtersByAccount() async throws {
        let store = await loaded()
        let todas = store.visibleAgenda
        let conta = try #require(todas.first?.accountID)
        try #require(todas.contains { $0.accountID != conta })   // há mistura

        store.select(account: conta)
        #expect(store.visibleAgenda.isEmpty == false)
        #expect(store.visibleAgenda.allSatisfy { $0.accountID == conta })
        #expect(store.visibleAgenda.count < todas.count)
    }

    @Test("sem conta selecionada a agenda mostra tudo")
    func noFilterShowsAll() async {
        let store = await loaded()
        #expect(store.visibleAgenda.count == store.agenda.count)
    }

    @Test("desligar o filtro devolve a agenda inteira")
    func togglingBack() async throws {
        let store = await loaded()
        let total = store.agenda.count
        let conta = try #require(store.agenda.first?.accountID)
        store.select(account: conta)
        #expect(store.visibleAgenda.count < total)
        store.select(account: conta)   // clicar de novo desliga
        #expect(store.visibleAgenda.count == total)
    }

    /// Qualquer provedor, não só as quatro das fixtures.
    @Test("uma conta que não existe esvazia a agenda em vez de ignorar o filtro")
    func unknownAccountEmpties() async {
        let store = await loaded()
        store.select(account: "conta-de-provedor-qualquer")
        #expect(store.visibleAgenda.isEmpty)
    }
}

@Suite("Colocar na agenda")
@MainActor
struct AddToAgendaTests {

    private func loaded() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    /// m1 (Marina Duarte, conta zoho) é a mensagem com `detectedEvent` que o
    /// design nomeia: "Call de contrato · qui 27, 15:00", 27/08 15:00–16:00.
    private func messageWithEvent(_ store: MailStore) throws -> (Message, DetectedEvent) {
        let message = try #require(store.messages.first { $0.id == "m1" })
        let event = try #require(message.detectedEvent)
        return (message, event)
    }

    @Test("cria o compromisso com a conta da mensagem de origem")
    func usesMessageAccount() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        #expect(message.accountID == "zoho")

        let item = try #require(store.addToAgenda(event, from: message))
        #expect(item.accountID == "zoho")
        #expect(store.agenda.contains { $0.id == item.id })
        let detalhe = try #require(item.detail)
        #expect(detalhe.organizer.address == message.from.address)
        #expect(detalhe.organizer.address != "ricardo@empresa.com")
        #expect(detalhe.note.contains("zoho"))
        #expect(detalhe.note != Fixtures.eventDefault.note)
    }

    /// É o filtro por caixa que o dono do projeto pediu explicitamente
    /// (`MailStore.visibleAgenda`): sem `accountID` certo, o item some ao
    /// filtrar pela própria conta que o criou.
    @Test("o compromisso continua visível quando a conta de origem é filtrada")
    func staysVisibleUnderItsOwnAccountFilter() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        let item = try #require(store.addToAgenda(event, from: message))

        store.select(account: message.accountID)
        #expect(store.visibleAgenda.contains { $0.id == item.id })

        store.select(account: message.accountID)  // desliga o filtro
        let otherAccount = try #require(store.accounts.first { $0.id != message.accountID })
        store.select(account: otherAccount.id)
        #expect(store.visibleAgenda.contains { $0.id == item.id } == false)
    }

    /// A conversão bate com a que `DetectedEventConversionTests` trava em
    /// isolamento — aqui é a integração com o `MailStore` de verdade.
    @Test("o horário do item bate com o que a mensagem detectou")
    func matchesDetectedSchedule() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        let item = try #require(store.addToAgenda(event, from: message))

        #expect(item.dayOffset == 2)      // 25/08 -> 27/08
        #expect(item.startMinute == 900)  // 15:00
        #expect(item.endMinute == 960)    // 16:00
        #expect(item.title == event.label)
    }

    // MARK: - O segundo clique

    @Test("um segundo clique no mesmo botão não duplica o compromisso")
    func secondClickDoesNotDuplicate() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        let before = store.agenda.count

        let first = store.addToAgenda(event, from: message)
        #expect(first != nil)
        #expect(store.agenda.count == before + 1)

        let second = store.addToAgenda(event, from: message)
        #expect(second == nil)
        #expect(store.agenda.count == before + 1)  // continua em +1, não +2
    }

    /// O aviso "Videoconferência atualizada" é outra mensagem, sem ICS, com
    /// o mesmo título e horário que o convite já pôs na agenda.
    @Test("evento detectado noutra mensagem não duplica o compromisso que já está lá")
    func detectedEventOnUpdateEmailDoesNotDuplicate() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        let first = try #require(store.addToAgenda(event, from: message))
        let aviso = Message(
            id: "aviso-calendar", accountID: message.accountID, from: message.from,
            receivedAt: message.receivedAt,
            subject: "Videoconferência atualizada: \(event.label)",
            snippet: event.label, body: [], tags: [], bucket: .today, isRead: false,
            summary: "A reunião foi atualizada.", detectedEvent: event
        )
        #expect(store.existingAgendaItem(for: event, from: aviso)?.id == first.id)
        #expect(store.addToAgenda(event, from: aviso) == nil)
        #expect(store.agenda.filter { $0.title == first.title }.count == 1)
    }

    @Test("o id do item criado é o id determinístico da mensagem")
    func idIsDeterministic() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        let item = try #require(store.addToAgenda(event, from: message))
        #expect(item.id == DetectedEventConversion.agendaID(forMessageID: message.id))
    }

    // MARK: - Desfazer

    @Test("desfazer tira o compromisso da agenda")
    func undoRemoves() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        let item = try #require(store.addToAgenda(event, from: message))
        #expect(store.agenda.contains { $0.id == item.id })

        store.removeFromAgenda(item.id)
        #expect(store.agenda.contains { $0.id == item.id } == false)
    }

    /// Desfazer o que já não está lá — clique duplo em "Desfazer", ou alguém
    /// tirou por outro caminho — não é erro, e devolve ao estado de antes: um
    /// novo clique em "Colocar na agenda" volta a criar o compromisso.
    @Test("desfazer duas vezes não é erro, e o compromisso pode voltar a ser criado")
    func undoTwiceThenRecreate() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        let item = try #require(store.addToAgenda(event, from: message))

        store.removeFromAgenda(item.id)
        store.removeFromAgenda(item.id)  // segunda vez: nada para tirar
        #expect(store.agenda.contains { $0.id == item.id } == false)

        let recreated = try #require(store.addToAgenda(event, from: message))
        #expect(recreated.id == item.id)
        #expect(store.agenda.filter { $0.id == item.id }.count == 1)
    }

    @Test("a agenda continua ordenada por horário depois de um compromisso novo")
    func staysSorted() async throws {
        let store = await loaded()
        let (message, event) = try messageWithEvent(store)
        _ = store.addToAgenda(event, from: message)
        let starts = store.agenda.map(\.startMinute)
        #expect(starts == starts.sorted())
    }
}

/// A lixeira como **lugar**, e não como sumiço.
@Suite("Lixeira")
@MainActor
struct TrashTests {

    private func store() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    /// Apagar é um `move` como outro qualquer: a mensagem continua no store, e
    /// "Desfazer" é o mesmo `move` de volta que o arraste já usa.
    @Test("apagar move para a Lixeira sem tirar a mensagem do store")
    func deleteMovesToTrash() async {
        let store = await store()
        let antes = store.messages.count
        let message = store.messages.first { $0.id == "m1" }!

        store.move(message, to: .trash)

        #expect(store.messages.count == antes)
        #expect(store.messages.first { $0.id == "m1" }?.bucket == .trash)
        #expect(store.trashCount() == 1)
    }

    /// O que a caixa aberta deixa de mostrar é a metade visível de "apagar
    /// pareceu apagar".
    @Test("a apagada some de «Tudo» e do contador dela")
    func trashedMessageLeavesTheAllView() async {
        let store = await store()
        let antes = store.count(for: .all)
        store.move(store.messages.first { $0.id == "m1" }!, to: .trash)

        #expect(store.count(for: .all) == antes - 1)
        #expect(store.count(for: .trash) == 1)
        store.select(bucket: .all)
        #expect(!store.visibleMessages.contains { $0.id == "m1" })
    }

    @Test("apagar definitivamente tira do store — e «Desfazer» a devolve inteira")
    func deleteForeverIsUndoable() async {
        let store = await store()
        let original = store.messages.first { $0.id == "m1" }!
        store.move(original, to: .trash)
        let antes = store.messages.count

        store.deleteForever("m1")
        #expect(store.messages.count == antes - 1)
        #expect(store.messages.first { $0.id == "m1" } == nil)

        store.restoreDeleted("m1")
        #expect(store.messages.first { $0.id == "m1" }?.bucket == .trash)
        // Volta **inteira**: o corpo, as sugestões, o dia. Guardar só o id
        // teria devolvido uma casca.
        #expect(store.messages.first { $0.id == "m1" }?.body == original.body)
        #expect(store.messages.first { $0.id == "m1" }?.replyHints == original.replyHints)
    }

    /// A mesma regra de `removeFromAgenda`: desfazer o que já voltou não é
    /// erro, e não pode duplicar a mensagem na lista.
    @Test("desfazer duas vezes não cria uma segunda cópia")
    func restoringTwiceIsHarmless() async {
        let store = await store()
        store.move(store.messages.first { $0.id == "m1" }!, to: .trash)
        store.deleteForever("m1")
        store.restoreDeleted("m1")
        store.restoreDeleted("m1")

        #expect(store.messages.filter { $0.id == "m1" }.count == 1)
    }

    @Test("a seleção anda para a próxima quando a apagada era a que estava aberta")
    func selectionMovesOnAfterDeleteForever() async {
        let store = await store()
        store.select(bucket: .trash)
        for id in ["m1", "m4"] {
            store.move(store.messages.first { $0.id == id }!, to: .trash)
        }
        store.select(message: "m1")

        store.deleteForever("m1")

        #expect(store.selectedMessageID == "m4")
    }

    @Test("esvaziar leva só a Lixeira, e só a da conta pedida")
    func emptyTrashRespectsTheAccountFilter() async {
        let store = await store()
        store.move(store.messages.first { $0.id == "m1" }!, to: .trash)   // zoho
        store.move(store.messages.first { $0.id == "m2" }!, to: .trash)   // host
        let antes = store.messages.count

        #expect(store.emptyTrash(accountID: "zoho") == 1)
        #expect(store.messages.count == antes - 1)
        #expect(store.messages.first { $0.id == "m2" }?.bucket == .trash)
        #expect(store.trashCount() == 1)
    }

    /// É o que faz "esvaziar" ser a palavra certa: depois dele não há cofre
    /// nenhum guardando o que foi jogado fora.
    @Test("esvaziar é sem volta: nem o «Desfazer» de apagar definitivamente sobrevive")
    func emptyTrashClearsTheUndoVault() async {
        let store = await store()
        store.move(store.messages.first { $0.id == "m1" }!, to: .trash)
        store.deleteForever("m1")

        #expect(store.emptyTrash() == 0)  // a m1 já não está na Lixeira
        store.restoreDeleted("m1")
        #expect(store.messages.first { $0.id == "m1" } == nil)
    }

    @Test("lixeira vazia não é esvaziada duas vezes")
    func emptyingAnEmptyTrashDoesNothing() async {
        let store = await store()
        let antes = store.messages.count
        #expect(store.emptyTrash() == 0)
        #expect(store.messages.count == antes)
    }

    /// "Marcar tudo como lido" em "Tudo" não pode alcançar o que foi apagado:
    /// ele herda a regra de `TriageBucket.contains`, e não a repete.
    @Test("«Marcar tudo como lido» em «Tudo» não toca na Lixeira")
    func markAllReadSkipsTheTrash() async {
        let store = await store()
        store.move(store.messages.first { $0.id == "m1" }!, to: .trash)

        store.markAllRead(in: .all)

        #expect(store.messages.first { $0.id == "m1" }?.isRead == false)
        #expect(store.unreadCount(in: .trash) == 1)
    }
}

/// A estrela no store. É estado da mensagem, e não da caixa.
@Suite("Sinalizar")
@MainActor
struct FlagTests {

    private func store() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("sinalizar liga e desliga, e não mexe na caixa nem na seleção")
    func flaggingIsOrthogonalToTriage() async {
        let store = await store()
        store.select(message: "m1")
        let caixa = store.messages.first { $0.id == "m1" }?.bucket

        store.setFlagged(true, for: "m1")
        #expect(store.messages.first { $0.id == "m1" }?.isFlagged == true)
        #expect(store.messages.first { $0.id == "m1" }?.bucket == caixa)
        #expect(store.selectedMessageID == "m1")

        store.setFlagged(false, for: "m1")
        #expect(store.messages.first { $0.id == "m1" }?.isFlagged == false)
    }

    /// Arquivar não apaga a estrela: são dois estados independentes, e a
    /// reconstrução da mensagem em `move` tem de carregar os dois.
    @Test("a estrela sobrevive à triagem")
    func flagSurvivesAMove() async {
        let store = await store()
        store.setFlagged(true, for: "m1")
        store.move(store.messages.first { $0.id == "m1" }!, to: .archived)

        #expect(store.messages.first { $0.id == "m1" }?.isFlagged == true)
        #expect(store.messages.first { $0.id == "m1" }?.bucket == .archived)
    }

    /// E ela sobrevive à ida e volta da Lixeira — que é onde o cofre guarda a
    /// mensagem inteira, não uma casca.
    @Test("a estrela volta com a mensagem apagada de vez e restaurada")
    func flagSurvivesDeleteAndRestore() async {
        let store = await store()
        store.setFlagged(true, for: "m1")
        store.move(store.messages.first { $0.id == "m1" }!, to: .trash)
        store.deleteForever("m1")
        store.restoreDeleted("m1")

        #expect(store.messages.first { $0.id == "m1" }?.isFlagged == true)
    }

    @Test("marcar como lida não apaga a estrela")
    func readingDoesNotClearTheFlag() async {
        let store = await store()
        store.setFlagged(true, for: "m1")
        store.setRead(true, for: "m1")

        #expect(store.messages.first { $0.id == "m1" }?.isFlagged == true)
        #expect(store.messages.first { $0.id == "m1" }?.isRead == true)
    }
}

/// Tirar da agenda o que o app pôs lá — o inverso de "Colocar na agenda".
@Suite("Tirar da agenda")
@MainActor
struct RemoveFromAgendaTests {

    private func store() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("tirar e desfazer devolvem o compromisso inteiro, na ordem de horário")
    func removingIsUndoable() async {
        let store = await store()
        let message = store.messages.first { $0.id == "m1" }!
        let criado = store.addToAgenda(message.detectedEvent!, from: message)!

        store.removeFromAgenda(criado.id)
        #expect(!store.agenda.contains { $0.id == criado.id })

        store.restoreToAgenda(criado.id)
        #expect(store.agenda.contains(criado))
        // A trilha e as três grades esperam a lista ordenada por horário.
        let inicios = store.agenda.map(\.startMinute)
        #expect(inicios == inicios.sorted())
    }

    /// A mesma regra de `restoreDeleted`: desfazer o que já voltou não é erro,
    /// e não pode duplicar o compromisso nas quatro superfícies que o desenham.
    @Test("desfazer duas vezes não põe o compromisso duas vezes na agenda")
    func restoringTwiceIsHarmless() async {
        let store = await store()
        let message = store.messages.first { $0.id == "m1" }!
        let criado = store.addToAgenda(message.detectedEvent!, from: message)!

        store.removeFromAgenda(criado.id)
        store.restoreToAgenda(criado.id)
        store.restoreToAgenda(criado.id)

        #expect(store.agenda.filter { $0.id == criado.id }.count == 1)
    }

    @Test("desfazer um id que nunca saiu não inventa compromisso nenhum")
    func restoringAnUnknownIDDoesNothing() async {
        let store = await store()
        let antes = store.agenda.count
        store.restoreToAgenda("email-nao-existe")
        #expect(store.agenda.count == antes)
    }
}
