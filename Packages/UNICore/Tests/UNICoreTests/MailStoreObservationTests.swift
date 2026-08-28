import Foundation
import Testing
@testable import UNICore

@Suite("MailStore observando e buscando no corpo")
@MainActor
struct MailStoreObservationTests {
    @Test("Uma fonte sem observação entrega um snapshot só, e `load()` continua igual")
    func fonteSemObservacaoContinuaIgual() async throws {
        // A garantia dos 812: `InMemoryMailSource` não implementa `snapshots()`
        // e nada muda para quem já a usava.
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(!store.messages.isEmpty)
        #expect(store.loadError == nil)

        var quantos = 0
        for try await snapshot in InMemoryMailSource.fixtures.snapshots() {
            quantos += 1
            #expect(snapshot.accounts.count == Fixtures.accounts.count)
        }
        #expect(quantos == 1)
    }

    @Test("`observe()` aplica cada snapshot que chega")
    func observeAplicaCadaSnapshot() async throws {
        let fonte = FonteEmSequencia(snapshots: [
            MailSnapshot(accounts: Fixtures.accounts, messages: [], agenda: [], pendingItems: []),
            MailSnapshot(
                accounts: Fixtures.accounts,
                messages: [Message.preview(id: "novo")],
                agenda: [], pendingItems: []
            ),
        ])
        let store = MailStore(source: fonte)
        await store.observe()
        #expect(store.messages.map(\.id) == ["novo"])
        #expect(store.loadError == nil)
    }

    @Test("Erro no meio da observação vira `loadError`, e o que já estava fica")
    func erroNaObservacao() async throws {
        let fonte = FonteEmSequencia(
            snapshots: [MailSnapshot(
                accounts: Fixtures.accounts,
                messages: [Message.preview(id: "m1")],
                agenda: [], pendingItems: []
            )],
            erroDepois: FalhaDeTeste.rede
        )
        let store = MailStore(source: fonte)
        await store.observe()
        #expect(store.messages.map(\.id) == ["m1"])
        #expect(store.loadError == FalhaDeTeste.rede.localizedDescription)
    }

    /// A lição da Task 12, aplicada a `observe()`: quem **cancela** a
    /// observação (a janela que fecha, a conta que sai) não pediu um erro na
    /// tela. `CancellationError` chegando por `for try await` não pode virar
    /// `loadError` — seria uma escrita de estado num caminho cancelável, e o
    /// texto que apareceria na janela de Contas ("A operação foi cancelada")
    /// não descreve falha nenhuma.
    @Test("Observação cancelada não escreve erro nenhum na tela")
    func cancelarNaoViraErro() async throws {
        let fonte = FonteEmSequencia(
            snapshots: [MailSnapshot(
                accounts: Fixtures.accounts,
                messages: [Message.preview(id: "m1")],
                agenda: [], pendingItems: []
            )],
            erroDepois: CancellationError()
        )
        let store = MailStore(source: fonte)
        await store.observe()

        #expect(store.messages.map(\.id) == ["m1"])
        #expect(store.loadError == nil)
    }

    /// O mesmo, na busca de corpo: cancelar a consulta ao índice (a tecla
    /// seguinte chegou, a janela fechou) não é falha de busca.
    @Test("Busca de corpo cancelada não escreve erro nenhum na tela")
    func buscaCanceladaNaoViraErro() async throws {
        let store = MailStore(source: FonteQueCancela())
        await store.load()
        store.query = "orçamento"
        await store.refreshBodyMatches()
        #expect(store.loadError == nil)
    }

    @Test("A busca alcança o corpo quando a fonte sabe procurar nele")
    func buscaNoCorpo() async throws {
        // O `matches` do Marco 1 procura em remetente, assunto e prévia. O
        // corpo de mensagens antigas não está carregado, e é a fonte que sabe
        // procurar nele — no banco, com o índice.
        let fonte = FonteComCorpo(hits: ["m2"])
        let store = MailStore(source: fonte)
        await store.load()
        store.query = "orçamento"
        await store.refreshBodyMatches()
        #expect(store.visibleMessages.map(\.id) == ["m2"])
    }

    @Test("Busca vazia limpa os acertos de corpo")
    func buscaVaziaLimpa() async throws {
        let fonte = FonteComCorpo(hits: ["m2"])
        let store = MailStore(source: fonte)
        await store.load()
        store.query = "orçamento"
        await store.refreshBodyMatches()
        store.query = ""
        await store.refreshBodyMatches()
        #expect(store.visibleMessages.count == 2)
    }

    /// A distinção que o `nil` carrega: uma fonte que **não sabe** procurar no
    /// corpo não pode esvaziar a lista. Sem ela, cada tecla digitada sobre as
    /// fixtures deixaria a caixa vazia.
    @Test("Fonte que não sabe procurar no corpo deixa a busca do Marco 1 valendo")
    func fonteSemCorpoNaoEsvazia() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.query = "Marina"
        await store.refreshBodyMatches()
        #expect(!store.visibleMessages.isEmpty)
    }
}

private enum FalhaDeTeste: Error, LocalizedError {
    case rede
    var errorDescription: String? { "A rede caiu no teste." }
}

private struct FonteEmSequencia: MailSource {
    /// Não se chama `snapshots` porque `MailSource.snapshots()` já ocupa o
    /// nome — a propriedade armazenada e o requisito do protocolo colidiriam.
    let retratos: [MailSnapshot]
    var erroDepois: (any Error)?

    init(snapshots: [MailSnapshot], erroDepois: (any Error)? = nil) {
        self.retratos = snapshots
        self.erroDepois = erroDepois
    }

    func accounts() async throws -> [Account] { retratos.last?.accounts ?? [] }
    func messages() async throws -> [Message] { retratos.last?.messages ?? [] }
    func agenda() async throws -> [AgendaItem] { retratos.last?.agenda ?? [] }
    func pendingItems() async throws -> [PendingItem] { retratos.last?.pendingItems ?? [] }

    func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        let lista = retratos
        let erro = erroDepois
        return AsyncThrowingStream { continuation in
            for snapshot in lista { continuation.yield(snapshot) }
            continuation.finish(throwing: erro)
        }
    }
}

/// A consulta ao índice que morreu por cancelamento, e não por falha.
private struct FonteQueCancela: MailSource {
    func accounts() async throws -> [Account] { Fixtures.accounts }
    func messages() async throws -> [Message] { [Message.preview(id: "m1")] }
    func agenda() async throws -> [AgendaItem] { [] }
    func pendingItems() async throws -> [PendingItem] { [] }
    func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? {
        throw CancellationError()
    }
}

private struct FonteComCorpo: MailSource {
    let hits: Set<String>

    func accounts() async throws -> [Account] { Fixtures.accounts }
    func messages() async throws -> [Message] {
        [Message.preview(id: "m1"), Message.preview(id: "m2")]
    }
    func agenda() async throws -> [AgendaItem] { [] }
    func pendingItems() async throws -> [PendingItem] { [] }
    func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? { hits }
}
