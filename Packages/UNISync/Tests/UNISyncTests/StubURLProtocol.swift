import Foundation

/// O servidor HTTP dos testes: um `URLProtocol` que responde do roteiro em
/// memória. **Nenhum teste deste pacote toca rede externa**, e é esta classe
/// que garante isso — uma URL fora do roteiro derruba o teste em vez de sair
/// pela placa de rede.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data(), headers: [String: String] = ["Content-Type": "application/json"]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    /// O que cada caminho responde, e o que foi pedido — protegidos por lock
    /// porque o `URLSession` chama isto de outra fila.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var recorded: [(path: String, body: String)] = []

    /// Instala um roteiro. Cada caminho tem uma **fila** de respostas: a
    /// primeira chamada consome a primeira, e é assim que se testa "o refresh
    /// falha, e o seguinte funciona".
    static func install(_ routes: [String: [Reply]]) {
        lock.lock()
        defer { lock.unlock() }
        self.routes = routes
        recorded = []
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        recorded = []
    }

    /// O que o cliente pediu, na ordem. É como o teste afirma que o corpo do
    /// POST levou `grant_type=refresh_token` e não outra coisa.
    static var requests: [(path: String, body: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Uma `URLSession` que só fala com este stub.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let caminho = request.url?.path ?? ""
        // `httpBody` vem nulo quando o corpo foi entregue por stream, que é o
        // que o URLSession faz com `uploadTask`. O `GoogleAuth` usa
        // `httpBody`, então ler daqui basta — e quando não bastar, o teste
        // grava string vazia em vez de mentir.
        let corpo = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            ?? request.httpBodyStream.map { fluxo in
                fluxo.open()
                defer { fluxo.close() }
                var dados = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while fluxo.hasBytesAvailable {
                    let lidos = fluxo.read(&buffer, maxLength: buffer.count)
                    if lidos <= 0 { break }
                    dados.append(contentsOf: buffer[0..<lidos])
                }
                return String(data: dados, encoding: .utf8) ?? ""
            } ?? ""

        Self.lock.lock()
        Self.recorded.append((path: caminho, body: corpo))
        let resposta: Reply?
        if var fila = Self.routes[caminho], !fila.isEmpty {
            resposta = fila.removeFirst()
            Self.routes[caminho] = fila
        } else {
            resposta = nil
        }
        Self.lock.unlock()

        guard let resposta, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(
                .unsupportedURL,
                userInfo: [NSLocalizedDescriptionKey: "Nenhuma resposta no roteiro para \(caminho)"]
            ))
            return
        }

        let http = HTTPURLResponse(
            url: url, statusCode: resposta.status,
            httpVersion: "HTTP/1.1", headerFields: resposta.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resposta.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
