import Foundation

/// O aviso de "tem coisa nova na fila".
///
/// A porta de escrita (`DatabaseCommandPort`) enfileira e **avisa**; o executor
/// da conta acorda e consome. Sem isto, arquivar uma mensagem esperaria o
/// próximo ciclo ocioso do executor para chegar ao servidor — segundos de
/// atraso em cada ação, por nada.
///
/// Um objeto simples com um cadeado, e não um `AsyncStream` por conta: quem
/// avisa é síncrono (a transação do banco acabou de fechar) e quem ouve é um
/// ator. Uma closure `@Sendable` atravessa essa fronteira sem intermediário, e
/// não há buffer para transbordar — "acorde" repetido é "acorde".
///
/// `NWPathMonitor` (a rede voltando acordar todo mundo) é da tarefa 3; ele
/// entra aqui, chamando `notify` para cada conta.
public final class OutboxSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var ouvintes: [String: [@Sendable () -> Void]] = [:]

    public init() {}

    /// Registra quem acorda quando a conta receber operação nova.
    public func register(accountID: String, _ acorda: @escaping @Sendable () -> Void) {
        lock.lock()
        ouvintes[accountID, default: []].append(acorda)
        lock.unlock()
    }

    /// Avisa os executores desta conta. Conta sem ouvinte não é erro: o app
    /// pode estar sem executor (modo fixtures, conta recém-adicionada), e a
    /// operação continua no banco esperando quem a leve.
    public func notify(accountID: String) {
        lock.lock()
        let chamados = ouvintes[accountID] ?? []
        lock.unlock()
        for acorda in chamados { acorda() }
    }

    /// Avisa **todos** os executores. É o que a rede voltando pede: a fila
    /// parada de qualquer conta pode andar agora, e descobrir quais contas
    /// existem para chamar `notify` uma a uma seria refazer, de fora, a lista
    /// que este objeto já tem dentro.
    public func notifyAll() {
        lock.lock()
        let chamados = ouvintes.values.flatMap { $0 }
        lock.unlock()
        for acorda in chamados { acorda() }
    }

    /// Esquece os ouvintes de uma conta — usada quando a conta sai.
    public func forget(accountID: String) {
        lock.lock()
        ouvintes[accountID] = nil
        lock.unlock()
    }
}
