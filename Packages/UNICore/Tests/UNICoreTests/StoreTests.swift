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
                displayName: "Conta \(i)", provider: .imap, tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
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
            displayName: "Servidor próprio", provider: .imap, tintLightHex: "#2C7D5E", tintDarkHex: "#7CBAAA"
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [obscure], messages: [], agenda: [])
        )
        await store.load()
        let found = try #require(store.account("servidor-proprio"))
        #expect(found.provider == .imap)
        #expect(found.host == "servidor-proprio")
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

    @Test("a busca casa remetente, assunto e trecho, ignorando acento e caixa")
    @MainActor
    func searchMatches() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        store.query = "MARINA"
        #expect(store.visibleMessages.allSatisfy {
            $0.from.name.localizedCaseInsensitiveContains("marina")
                || $0.subject.localizedCaseInsensitiveContains("marina")
                || $0.snippet.localizedCaseInsensitiveContains("marina")
        })
        #expect(store.visibleMessages.isEmpty == false)
    }

    @Test("busca sem resultado devolve lista vazia, não a lista inteira")
    @MainActor
    func searchMiss() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        store.query = "zzzznadaaqui"
        #expect(store.visibleMessages.isEmpty)
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

    @Test("mudar de caixa limpa a seleção que não pertence mais à visão")
    @MainActor
    func selectionClearedOnBucketChange() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let archived = try #require(
            store.visibleMessages.first { $0.bucket == .archived }
        )
        store.select(message: archived.id)
        store.select(bucket: .today)
        #expect(store.selectedMessage == nil)
    }

    @Test("a trilha de agenda vem ordenada por horário")
    @MainActor
    func agendaSorted() async {
        let store = await loadedStore()
        let starts = store.agenda.map(\.startMinute)
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
                        displayName: "Conta de Reposição", provider: .imap, tintLightHex: "#ABCDEF", tintDarkHex: "#D5E3F7"
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
        store.select(account: firstAccount.id)
        let filteredCount = store.visibleMessages.count

        // Deve ter reduzido, a menos que todas as mensagens sejam dessa conta
        #expect(filteredCount <= allCount)
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
        guard let firstAccount = store.accounts.first else {
            Issue.record("Nenhuma conta nos fixtures")
            return
        }

        let allCount = store.visibleMessages.count

        // Busca por um termo (deve haver resultados)
        store.query = "Marina"
        let searchCount = store.visibleMessages.count
        #expect(searchCount > 0)
        #expect(searchCount <= allCount)

        // Agora filtra por conta
        store.select(account: firstAccount.id)
        let combinedCount = store.visibleMessages.count

        // Deve ser no máximo o resultado da busca
        #expect(combinedCount <= searchCount)
    }
}
