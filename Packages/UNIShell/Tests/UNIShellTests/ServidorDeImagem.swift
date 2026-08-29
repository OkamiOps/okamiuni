import Foundation
import Network

/// Um HTTP mínimo em `127.0.0.1:0` que serve **uma** imagem — com o atraso que
/// o teste pedir, e contando quantas vezes ela foi buscada.
///
/// ## Por que existe
///
/// Os dois defeitos do leitor de HTML são sobre rede lenta: a espera que não
/// aparecia enquanto onze imagens desciam, e as mesmas onze descendo de novo a
/// cada abertura. Nenhum dos dois se prova com um documento `data:` — e nenhum
/// teste deste projeto toca a rede de verdade. O caminho da casa é o do
/// `FakeImapServer`: um servidor de mentira em loopback, dentro do próprio
/// teste, que responde o mínimo e conta o que foi pedido.
///
/// Ele fala HTTP/1.1 com `Connection: close` e uma resposta por conexão — é
/// tudo o que a `WKWebView` precisa para buscar um `<img>`.
final class ServidorDeImagem: @unchecked Sendable {
    /// Um PNG de 1×1 transparente. O menor corpo que ainda é imagem.
    private static let pixel = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE\
        hQGAhKmMIQAAAABJRU5ErkJggg==
        """)!

    private let listener: NWListener
    private let fila = DispatchQueue(label: "uni.teste.servidor-de-imagem")
    private let trava = NSLock()
    private var _pedidos = 0
    private let atraso: TimeInterval
    /// A resposta fica presa até alguém soltar. É o que dá ao teste um
    /// "meio da carga" sem depender do relógio: enquanto a imagem não é
    /// solta, a página **não** tem como terminar de carregar.
    private let preso: Bool
    private let liberacao = DispatchSemaphore(value: 0)
    /// A imagem pode ser guardada por quem a buscou?
    private let cacheavel: Bool

    /// Quantas vezes a imagem foi **buscada pela rede**. É o número que separa
    /// "veio do cache" de "desceu de novo".
    var pedidos: Int { trava.withLock { _pedidos } }

    private(set) var porta: UInt16 = 0

    init(atraso: TimeInterval = 0, preso: Bool = false, cacheavel: Bool = true) throws {
        self.atraso = atraso
        self.preso = preso
        self.cacheavel = cacheavel
        let parametros = NWParameters.tcp
        parametros.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parametros)
        listener.newConnectionHandler = { [weak self] conexao in
            self?.atende(conexao)
        }
        let pronto = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] estado in
            if case .ready = estado {
                self?.porta = self?.listener.port?.rawValue ?? 0
                pronto.signal()
            }
        }
        listener.start(queue: fila)
        _ = pronto.wait(timeout: .now() + 5)
    }

    func para() {
        if preso { liberacao.signal() }
        listener.cancel()
    }

    /// Solta a imagem que estava presa.
    func solta() { liberacao.signal() }

    /// O endereço da imagem, do jeito que um `<img src>` a pede.
    var endereco: String { "http://127.0.0.1:\(porta)/pixel.png" }

    private func atende(_ conexao: NWConnection) {
        conexao.start(queue: fila)
        conexao.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] dados, _, _, _ in
            guard let self, dados != nil else { conexao.cancel(); return }
            self.trava.withLock { self._pedidos += 1 }
            // Numa fila própria: `fila` atende o listener, e prender a resposta
            // nela travaria o servidor inteiro.
            DispatchQueue.global().asyncAfter(deadline: .now() + self.atraso) {
                if self.preso { self.liberacao.wait() }
                conexao.send(content: self.resposta(), completion: .contentProcessed { _ in
                    conexao.cancel()
                })
            }
        }
    }

    private func resposta() -> Data {
        let corpo = Self.pixel
        let linhas = [
            "HTTP/1.1 200 OK",
            "Content-Type: image/png",
            "Content-Length: \(corpo.count)",
            "Cache-Control: \(cacheavel ? "max-age=600" : "no-store")",
            "Connection: close",
            "", "",
        ]
        return Data(linhas.joined(separator: "\r\n").utf8) + corpo
    }
}
