import Foundation
import Testing
@testable import UNISync

/// Um contador que atravessa a fronteira de isolação.
private final class Chamadas: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func mais() { lock.lock(); n += 1; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// A rede voltando — e o que acontece quando ela volta.
///
/// **Nada aqui observa a rede da máquina.** O `NWPathMonitor` de verdade é uma
/// fonte injetável (`NetworkPathSource`) justamente por isso: um teste que
/// dependesse dele passaria no wi-fi do escritório e falharia no avião. A regra
/// que importa — "voltou a ser satisfeito, então sincronize" — é pura, e é ela
/// que está provada aqui.
@Suite("A rede voltando")
struct NetworkWatcherTests {
    @Test("A primeira notícia de rede boa já dispara um ciclo")
    func primeiraNoticiaDispara() async {
        // Desconhecido conta como fora do ar: um ciclo a mais na abertura é
        // barato, e um a menos seria uma conta parada logo depois de o app subir.
        let chamadas = Chamadas()
        let vigia = NetworkWatcher(source: FonteVazia()) { chamadas.mais() }
        await vigia.registra(true)
        #expect(chamadas.total == 1)
    }

    @Test("Rede boa repetida NÃO dispara de novo")
    func repeticaoNaoDispara() async {
        // O `NWPathMonitor` avisa a cada mudança de interface — wi-fi trocando
        // de canal, VPN subindo. Disparar em toda notícia faria a
        // sincronização correr dezenas de vezes por minuto num notebook que
        // anda pela casa.
        let chamadas = Chamadas()
        let vigia = NetworkWatcher(source: FonteVazia()) { chamadas.mais() }
        await vigia.registra(true)
        await vigia.registra(true)
        await vigia.registra(true)
        #expect(chamadas.total == 1)
    }

    @Test("Caiu e voltou dispara outra vez — é para isso que ele existe")
    func transicaoDeVoltaDispara() async {
        let chamadas = Chamadas()
        let vigia = NetworkWatcher(source: FonteVazia()) { chamadas.mais() }
        await vigia.registra(true)
        await vigia.registra(false)
        await vigia.registra(true)
        #expect(chamadas.total == 2)
    }

    @Test("Rede caindo não dispara nada")
    func quedaNaoDispara() async {
        // Sincronizar no instante em que a rede cai é gastar uma tentativa para
        // receber o erro que já se sabe.
        let chamadas = Chamadas()
        let vigia = NetworkWatcher(source: FonteVazia()) { chamadas.mais() }
        await vigia.registra(false)
        await vigia.registra(false)
        #expect(chamadas.total == 0)
    }

    @Test("A fonte alimenta o vigia de ponta a ponta")
    func fonteAlimentaOVigia() async throws {
        let chamadas = Chamadas()
        let fonte = FonteDeRoteiro(caminhos: [false, true, true, false, true])
        let vigia = NetworkWatcher(source: fonte) { chamadas.mais() }
        await vigia.start()
        // O fluxo é finito: esperar por ele é esperar o roteiro acabar.
        try await esperaAte { chamadas.total == 2 }
        await vigia.stop()
        #expect(chamadas.total == 2)
    }

    @Test("`notifyAll` acorda a fila de TODAS as contas")
    func sinalAcordaTodasAsFilas() {
        // Descobrir quais contas existem para chamar `notify` uma a uma seria
        // refazer, de fora, a lista que o sinal já tem dentro.
        let sinal = OutboxSignal()
        let uma = Chamadas()
        let outra = Chamadas()
        sinal.register(accountID: "a") { uma.mais() }
        sinal.register(accountID: "b") { outra.mais() }

        sinal.notifyAll()

        #expect(uma.total == 1)
        #expect(outra.total == 1)

        // E quem saiu não é acordado: o `forget` continua valendo.
        sinal.forget(accountID: "a")
        sinal.notifyAll()
        #expect(uma.total == 1)
        #expect(outra.total == 2)
    }

    // MARK: As fontes de mentira

    /// Uma fonte que nunca diz nada. Para os testes que chamam `registra`
    /// direto — a regra não precisa de fluxo nenhum para ser afirmada.
    private struct FonteVazia: NetworkPathSource {
        func paths() -> AsyncStream<Bool> {
            AsyncStream { $0.finish() }
        }
    }

    /// Uma fonte com roteiro: os caminhos, na ordem, e depois o fim.
    private struct FonteDeRoteiro: NetworkPathSource {
        let caminhos: [Bool]

        func paths() -> AsyncStream<Bool> {
            AsyncStream { continuation in
                for caminho in caminhos { continuation.yield(caminho) }
                continuation.finish()
            }
        }
    }

    /// Espera uma condição com **teto**: um teste que espera para sempre é uma
    /// suíte que trava sem falhar, e é regra da casa que toda espera tenha teto.
    private func esperaAte(
        _ condicao: @Sendable () -> Bool, teto: TimeInterval = 2
    ) async throws {
        let limite = Date().addingTimeInterval(teto)
        while !condicao(), Date() < limite {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condicao())
    }
}
