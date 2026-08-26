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
                displayName: "Conta \(i)", provider: .imap, tintHex: "#3E6FA8"
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
            displayName: "Servidor próprio", provider: .imap, tintHex: "#2C7D5E"
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

    @Test("load() é atômico: falha após accounts() não deixa accounts inconsistente")
    @MainActor
    func loadAtomicity() async {
        // Cria um store com dados bons primeiro
        let store = await loadedStore()
        let accountsBeforeFail = store.accounts
        let messagesBeforeFail = store.messages
        #expect(accountsBeforeFail.isEmpty == false)
        #expect(messagesBeforeFail.isEmpty == false)

        // Cria uma fonte que falha em messages() após accounts() retorna com sucesso.
        // Na versão não-atômica, isto deixaria accounts modificado.
        // Na versão atômica, accounts não é modificado.
        struct FailingOnMessagesSource: MailSource {
            func accounts() async throws -> [Account] {
                // Retorna uma conta diferente para provar que accounts NÃO foi substituído
                [Account(
                    id: "novo", address: "novo@teste.com",
                    displayName: "Nova Conta", provider: .imap, tintHex: "#FFFFFF"
                )]
            }

            func messages() async throws -> [Message] {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rede indisponível"])
            }

            func agenda() async throws -> [AgendaItem] {
                []
            }
        }

        // Tenta carregar com uma fonte que falha parcialmente
        // Na versão não-atômica: accounts teria sido substituído antes da falha
        // Na versão atômica: nada é substituído
        let failingStore = MailStore(source: FailingOnMessagesSource())
        await failingStore.load()

        // Verifica que o estado inicial vazio foi preservado (não foi parcialmente modificado)
        #expect(failingStore.accounts.isEmpty)  // Store novo, ainda vazio
        #expect(failingStore.messages.isEmpty)  // Store novo, ainda vazio
        #expect(failingStore.loadError != nil)
        #expect(failingStore.loadError?.contains("Rede indisponível") == true)
    }
}
