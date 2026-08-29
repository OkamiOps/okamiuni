import Foundation
import Network
import os

/// De onde vêm os avisos de "o caminho de rede mudou".
///
/// Existe como protocolo por uma razão só, e ela é do teste: `NWPathMonitor`
/// observa a rede **da máquina**, e um teste que dependa dela é um teste que
/// passa no wi-fi do escritório e falha no avião. A regra que importa — "voltou
/// a ser satisfeito, então sincronize" — é pura, e é ela que é provada.
public protocol NetworkPathSource: Sendable {
    /// `true` para caminho satisfeito. O fluxo termina quando a fonte para.
    func paths() -> AsyncStream<Bool>
}

/// A fonte de verdade: o `NWPathMonitor` do sistema.
public struct SystemNetworkPathSource: NetworkPathSource {
    public init() {}

    public func paths() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { caminho in
                continuation.yield(caminho.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.okamiops.okamiuni.rede"))
        }
    }
}

/// Quem repara que a rede voltou — e acorda quem estava esperando por ela.
///
/// **É a peça que faz o app parar de esperar o relógio.** Sem ela, uma ação
/// feita no avião só chega ao servidor no próximo ciclo ocioso (até um minuto
/// depois de a rede voltar), e uma mensagem que chegou enquanto o notebook
/// estava fechado espera o mesmo minuto. Com ela, o momento em que o caminho
/// volta a ser satisfeito é o momento em que os dois lados andam.
///
/// **Os dois lados**, e não um: a sincronização traz o que chegou, e o
/// `OutboxSignal` empurra o que ficou na fila. Acordar só um deixaria metade do
/// app esperando o relógio de qualquer jeito.
public actor NetworkWatcher {
    private let source: any NetworkPathSource
    private let onReturn: @Sendable () async -> Void
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "NetworkWatcher")

    private var observando: Task<Void, Never>?
    /// Se o último caminho visto estava satisfeito. Começa em `false` —
    /// **desconhecido conta como fora do ar**, e a primeira notícia de rede boa
    /// dispara um ciclo. Um ciclo a mais na abertura é barato; um ciclo a menos
    /// seria uma conta parada esperando o relógio logo depois de o app subir.
    private var satisfeito = false

    public init(
        source: any NetworkPathSource = SystemNetworkPathSource(),
        onReturn: @Sendable @escaping () async -> Void
    ) {
        self.source = source
        self.onReturn = onReturn
    }

    /// Começa a observar. Idempotente.
    public func start() {
        guard observando == nil else { return }
        observando = Task { [weak self, source] in
            for await agora in source.paths() {
                guard let self else { return }
                await self.registra(agora)
            }
        }
    }

    public func stop() {
        observando?.cancel()
        observando = nil
    }

    /// Um caminho observado. **Só a transição dispara**: um `NWPathMonitor`
    /// avisa a cada mudança de interface (wi-fi que troca de canal, VPN que
    /// sobe), e disparar em toda notícia faria a sincronização correr dezenas
    /// de vezes por minuto num notebook que anda pela casa.
    ///
    /// `internal` para o teste poder afirmar a regra sem fonte nenhuma no meio.
    func registra(_ agora: Bool) async {
        let antes = satisfeito
        satisfeito = agora
        guard agora, !antes else { return }
        log.notice("A rede voltou: sincronizando e destravando a fila.")
        await onReturn()
    }
}
