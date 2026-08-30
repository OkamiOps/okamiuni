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

    @Test("A conta filtrada que sai do retrato leva o filtro embora")
    func contaRemovidaLimpaOFiltro() async throws {
        // A armadilha que o Marco 2 criou: com o banco como fonte, remover a
        // conta que está filtrando esvazia a lista **e** tira da tela o único
        // caminho de volta — "Limpar filtro" mora no menu de contexto da linha
        // da conta, que sumiu junto. O app pareceria quebrado, sem nada
        // clicável que o consertasse.
        let semHost = Fixtures.accounts.filter { $0.id != "host" }
        let fonte = FonteEmSequencia(snapshots: [
            MailSnapshot(
                accounts: Fixtures.accounts, messages: Fixtures.messages,
                agenda: [], pendingItems: []
            ),
            MailSnapshot(
                accounts: semHost,
                messages: Fixtures.messages.filter { $0.accountID != "host" },
                agenda: [], pendingItems: []
            ),
        ])
        let store = MailStore(source: fonte)
        store.select(account: "host")
        await store.observe()

        #expect(store.selectedAccountID == nil)
        #expect(!store.visibleMessages.isEmpty)
        #expect(store.selectedMessage != nil)
        // E o filtro de uma conta que **continua** existindo não é mexido: a
        // limpeza é da conta que sumiu, não de toda remoção.
        #expect(store.accounts.map(\.id) == semHost.map(\.id))
    }

    @Test("Filtro de conta que continua no retrato sobrevive")
    func contaQueFicaMantemOFiltro() async throws {
        let fonte = FonteEmSequencia(snapshots: [
            MailSnapshot(
                accounts: Fixtures.accounts, messages: Fixtures.messages,
                agenda: [], pendingItems: []
            ),
            MailSnapshot(
                accounts: Fixtures.accounts,
                messages: Fixtures.messages, agenda: [], pendingItems: []
            ),
        ])
        let store = MailStore(source: fonte)
        store.select(account: "host")
        await store.observe()
        #expect(store.selectedAccountID == "host")
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
        // Este ensaio verifica a busca, não a semântica temporal de Hoje.
        // As datas fixas da fonte pertencem ao passado, então a visão neutra é
        // Tudo — exatamente onde uma busca global continua encontrando-as.
        store.select(bucket: .all)
        store.query = "orçamento"
        await store.refreshBodyMatches()
        #expect(store.visibleMessages.map(\.id) == ["m2"])
    }

    @Test("Busca vazia limpa os acertos de corpo")
    func buscaVaziaLimpa() async throws {
        let fonte = FonteComCorpo(hits: ["m2"])
        let store = MailStore(source: fonte)
        await store.load()
        store.select(bucket: .all)
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

    /// **A resposta atrasada de um termo velho não pode sobrescrever o termo
    /// atual.**
    ///
    /// A reprodução do revisor: "a" → "ab". A pessoa digita "a", o índice do
    /// banco começa a procurar; antes de responder, ela digita mais uma letra
    /// e a busca de "ab" dispara também. Sem carimbo, as duas gravam direto em
    /// `bodyHits` — e quem escrever por último vence, não quem tem o termo
    /// atual. Aqui "ab" responde primeiro e "a" responde depois, atrasada: o
    /// defeito é a resposta de "a" apagar os acertos de "ab" que já estavam na
    /// tela.
    ///
    /// `FonteControlavel` segura cada consulta numa continuação até o teste
    /// mandar liberar — é o que torna a ordem determinística em vez de uma
    /// corrida de verdade.
    @Test("Resposta atrasada de um termo antigo não sobrescreve o termo atual")
    func termoAntigoNaoSobrescreveOAtual() async throws {
        let fonte = FonteControlavel(hits: ["a": ["m1"], "ab": ["m2"]])
        let store = MailStore(source: fonte)
        await store.load()
        store.select(bucket: .all)

        store.query = "a"
        async let buscaA: Void = store.refreshBodyMatches()
        await fonte.aguardaPedido("a")

        store.query = "ab"
        async let buscaAB: Void = store.refreshBodyMatches()
        await fonte.aguardaPedido("ab")

        // "ab" responde primeiro — é o termo atual, e a lista deve mostrar o
        // acerto dele.
        fonte.libera("ab")
        await buscaAB
        #expect(store.visibleMessages.map(\.id) == ["m2"], "o acerto de 'ab' não chegou à lista")

        // "a" só responde agora, atrasada. Descartada: não é mais o termo
        // atual, e escrever por cima apagaria o que "ab" acabou de acertar.
        fonte.libera("a")
        await buscaA
        #expect(
            store.visibleMessages.map(\.id) == ["m2"],
            "a resposta atrasada de 'a' sobrescreveu o acerto de 'ab'"
        )
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

/// Uma fonte cuja `bodyMatches` fica **presa** até o teste mandar liberar —
/// termo por termo. É o que torna determinística a ordem "'ab' responde antes
/// de 'a', embora 'a' tenha sido pedido primeiro", em vez de depender de uma
/// corrida de verdade contra o agendador.
///
/// `@unchecked Sendable` com trava porque `MailSource` é `Sendable` e os dois
/// lados — a consulta que chega e o teste que libera — mexem no mesmo estado
/// de fora do ator.
private final class FonteControlavel: MailSource, @unchecked Sendable {
    private let trava = NSLock()
    private let hits: [String: Set<String>]
    private var liberacoes: [String: CheckedContinuation<Void, Never>] = [:]
    private var pedidosPendentes: Set<String> = []
    private var avisosDePedido: [String: CheckedContinuation<Void, Never>] = [:]

    init(hits: [String: Set<String>]) { self.hits = hits }

    func accounts() async throws -> [Account] { Fixtures.accounts }
    func messages() async throws -> [Message] {
        [Message.preview(id: "m1"), Message.preview(id: "m2")]
    }
    func agenda() async throws -> [AgendaItem] { [] }
    func pendingItems() async throws -> [PendingItem] { [] }

    func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? {
        let avisador = registraPedido(term)
        avisador?.resume()

        await withCheckedContinuation { (continuacao: CheckedContinuation<Void, Never>) in
            registraLiberacao(term, continuacao)
        }
        return hits[term] ?? []
    }

    /// Espera a consulta deste termo **chegar** à fonte, sem se importar se
    /// chegou antes ou depois desta chamada — as duas ordens são possíveis
    /// dependendo de quando o agendador roda a tarefa filha do `async let`.
    func aguardaPedido(_ term: String) async {
        if jaPediu(term) { return }
        await withCheckedContinuation { (continuacao: CheckedContinuation<Void, Never>) in
            registraAviso(term, continuacao)
        }
    }

    /// Destrava a consulta deste termo, que devolve o que `hits[term]` tiver.
    func libera(_ term: String) {
        trava.lock()
        let continuacao = liberacoes.removeValue(forKey: term)
        trava.unlock()
        continuacao?.resume()
    }

    // MARK: A trava, isolada em funções síncronas — `NSLock` não pode ser
    // usada direto dentro do corpo de uma função `async`.

    private func registraPedido(_ term: String) -> CheckedContinuation<Void, Never>? {
        trava.lock()
        defer { trava.unlock() }
        pedidosPendentes.insert(term)
        return avisosDePedido.removeValue(forKey: term)
    }

    private func registraLiberacao(_ term: String, _ continuacao: CheckedContinuation<Void, Never>) {
        trava.lock()
        defer { trava.unlock() }
        liberacoes[term] = continuacao
    }

    private func jaPediu(_ term: String) -> Bool {
        trava.lock()
        defer { trava.unlock() }
        return pedidosPendentes.contains(term)
    }

    private func registraAviso(_ term: String, _ continuacao: CheckedContinuation<Void, Never>) {
        trava.lock()
        defer { trava.unlock() }
        avisosDePedido[term] = continuacao
    }
}
