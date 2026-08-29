import Foundation
import Testing
@testable import UNICore

/// Uma porta de contatos que o teste conduz: conta as chamadas e só responde
/// quando mandarem — o mesmo desenho de `PortaConduzida` em
/// `BodyOnDemandTests`, e pela mesma razão: provar a guarda contra resposta
/// fora de ordem exige controlar quando cada chamada retorna.
private actor PortaDeContatosConduzida: ContactDirectoryPort {
    private var chamadas = 0
    private var respostas: [Result<[DirectoryContact]?, any Error>]
    private var liberadasAte = -1
    private var pendentes: [Int: CheckedContinuation<Void, Never>] = [:]
    private var avisos: [Int: CheckedContinuation<Void, Never>] = [:]

    init(respostas: [Result<[DirectoryContact]?, any Error>]) {
        self.respostas = respostas
    }

    func contacts(accountID: String?) async throws -> [DirectoryContact]? {
        let minhaVez = chamadas
        chamadas += 1
        avisos.removeValue(forKey: minhaVez)?.resume()
        if minhaVez > liberadasAte {
            await withCheckedContinuation { continuation in pendentes[minhaVez] = continuation }
        }
        return try respostas[minhaVez].get()
    }

    /// Espera a chamada de índice `indice` **começar** — não que ela termine.
    func esperaChamada(_ indice: Int) async {
        if chamadas > indice { return }
        await withCheckedContinuation { continuation in avisos[indice] = continuation }
    }

    /// Libera as chamadas até o índice `ate` (inclusive) para responder — as
    /// já em espera, e qualquer uma futura com índice até aqui.
    func libera(ate: Int) {
        liberadasAte = max(liberadasAte, ate)
        for (indice, continuacao) in pendentes where indice <= ate {
            continuacao.resume()
            pendentes.removeValue(forKey: indice)
        }
    }

    var quantasChamadas: Int { chamadas }
}

private func conta(_ id: String) -> Account {
    Account(
        id: id, address: "\(id)@x.com", displayName: id,
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )
}

@Suite("O catálogo real de contatos, do lado do MailStore")
@MainActor
struct ContactPoolOnDemandTests {
    @Test("Sem porta, o catálogo é sempre Fixtures.contacts — o Marco 1 intacto")
    func semPorta() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        #expect(store.contactPool.map(\.address) == Fixtures.contacts.map(\.address))
        await store.load()
        #expect(store.contactPool.map(\.address) == Fixtures.contacts.map(\.address))
    }

    @Test("Com porta e conta, o catálogo é o que a porta devolve")
    func comPortaEConta() async {
        let real = [DirectoryContact(name: "Pessoa Real", address: "real@x.com", org: "", frequency: 5)]
        let porta = PortaDeContatosConduzida(respostas: [.success(real)])
        await porta.libera(ate: 0)
        let fonte = InMemoryMailSource(accounts: [conta("a")], messages: [], agenda: [])
        let store = MailStore(source: fonte, contactPort: porta)
        await store.load()
        #expect(store.contactPool == real)
    }

    @Test("Porta devolvendo nil (banco sem conta) cai em Fixtures.contacts")
    func portaSemContaCaiNasFixtures() async {
        let porta = PortaDeContatosConduzida(respostas: [.success(nil)])
        await porta.libera(ate: 0)
        // Fonte com conta (para simular o app: `accounts` refletindo o
        // retrato), mas a porta é quem decide se o banco tem conta — este é
        // o caso limite documentado no protocolo.
        let fonte = InMemoryMailSource(accounts: [conta("a")], messages: [], agenda: [])
        let store = MailStore(source: fonte, contactPort: porta)
        await store.load()
        #expect(store.contactPool.map(\.address) == Fixtures.contacts.map(\.address))
    }

    @Test("Falha da porta vira loadError e não apaga o catálogo anterior")
    func falhaViraLoadError() async {
        struct Falha: LocalizedError { var errorDescription: String? { "não deu" } }
        let porta = PortaDeContatosConduzida(respostas: [.failure(Falha())])
        await porta.libera(ate: 0)
        let fonte = InMemoryMailSource(accounts: [conta("a")], messages: [], agenda: [])
        let store = MailStore(source: fonte, contactPort: porta)
        let anterior = store.contactPool
        await store.load()
        #expect(store.loadError == "não deu")
        #expect(store.contactPool == anterior)
    }

    @Test("Duas contas iguais em sequência não disparam uma segunda consulta")
    func semConsultaRepetida() async {
        let real = [DirectoryContact(name: "Pessoa", address: "p@x.com", org: "", frequency: 1)]
        let porta = PortaDeContatosConduzida(respostas: [.success(real), .success(real)])
        await porta.libera(ate: 0)
        let fonte = InMemoryMailSource(accounts: [conta("a")], messages: [], agenda: [])
        let store = MailStore(source: fonte, contactPort: porta)
        await store.load()
        await store.load()
        #expect(await porta.quantasChamadas == 1)
    }

    /// **A resposta atrasada de uma conta velha não pode sobrescrever a de
    /// uma conta mais nova** — o mesmo defeito que
    /// `termoAntigoNaoSobrescreveOAtual` prova para a busca de corpo, aqui
    /// sobre a troca de conta em vez do termo digitado.
    ///
    /// Dois `load()` no mesmo `store`, contra uma fonte cujo retrato muda de
    /// conta a cada chamada: o primeiro começa e fica preso na porta de
    /// contatos; o segundo lê a conta nova, dispara a consulta dele e
    /// **responde primeiro**. Só depois o primeiro é liberado, atrasado — e a
    /// resposta dele tem de ser descartada, porque a geração já é outra.
    @Test("Resposta atrasada de uma conta antiga não sobrescreve a conta atual")
    func contaAntigaNaoSobrescreveAAtual() async throws {
        let velho = [DirectoryContact(name: "Velho", address: "velho@x.com", org: "", frequency: 1)]
        let novo = [DirectoryContact(name: "Novo", address: "novo@x.com", org: "", frequency: 1)]
        let porta = PortaDeContatosConduzida(respostas: [.success(velho), .success(novo)])
        let fonte = FonteQueMudaDeConta(contas: [[conta("a")], [conta("b")]])
        let store = MailStore(source: fonte, contactPort: porta)

        // Primeiro `load()`: lê a conta "a", dispara a consulta #0 na porta —
        // que fica presa até o teste liberar.
        let primeiro = Task { await store.load() }
        await porta.esperaChamada(0)

        // Segundo `load()`: lê a conta "b" (a fonte muda a cada chamada) e
        // dispara a consulta #1, também presa.
        let segundo = Task { await store.load() }
        await porta.esperaChamada(1)

        // A #1 (conta "b", a atual) responde primeiro.
        await porta.libera(ate: 1)
        await segundo.value
        #expect(store.contactPool == novo)

        // Só agora a #0 (conta "a", presa desde o início) é liberada,
        // atrasada. A geração já avançou para a consulta da conta "b" — a
        // resposta de "a" tem de ser descartada.
        await porta.libera(ate: 0)
        await primeiro.value
        #expect(store.contactPool == novo, "a resposta atrasada da conta antiga sobrescreveu a atual")
    }
}

/// Uma fonte cujo retrato muda de conta a cada chamada a `snapshot()` — a
/// simulação mais simples de "a pessoa trocou de conta entre dois `load()`".
private actor FonteQueMudaDeConta: MailSource {
    private var chamada = 0
    private let contas: [[Account]]

    init(contas: [[Account]]) { self.contas = contas }

    func accounts() async throws -> [Account] { contas.last ?? [] }
    func messages() async throws -> [Message] { [] }
    func agenda() async throws -> [AgendaItem] { [] }
    func pendingItems() async throws -> [PendingItem] { [] }

    func snapshot() async throws -> MailSnapshot {
        let indice = min(chamada, contas.count - 1)
        chamada += 1
        return MailSnapshot(accounts: contas[indice], messages: [], agenda: [], pendingItems: [])
    }
}
