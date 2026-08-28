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
        /// Quanto tempo o "servidor" segura a resposta antes de a entregar.
        ///
        /// Zero — o padrão — responde **de forma síncrona**, dentro do próprio
        /// `startLoading`, que é como este stub sempre se comportou: nenhum
        /// teste antigo muda de caminho por causa deste campo.
        ///
        /// Existe para o único tipo de afirmação que precisa de tempo passando:
        /// a de que duas requisições estão em voo **ao mesmo tempo**. Com
        /// resposta instantânea, uma busca sequencial e uma concorrente são
        /// indistinguíveis — as duas registram os mesmos pedidos na mesma ordem.
        var delay: TimeInterval

        init(
            status: Int = 200, body: Data = Data(),
            headers: [String: String] = ["Content-Type": "application/json"],
            delay: TimeInterval = 0
        ) {
            self.status = status
            self.body = body
            self.headers = headers
            self.delay = delay
        }

        static func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> Reply {
            Reply(status: status, body: Data(text.utf8), delay: delay)
        }
    }

    /// O cabeçalho que carrega o identificador da sessão em toda requisição.
    /// `httpAdditionalHeaders` da configuração o adiciona sozinho a cada
    /// pedido — o código de produção (`GmailClient`, `GoogleAuth`) nunca
    /// precisa saber que o stub existe.
    private static let sessionHeader = "X-StubURLProtocol-Session"
    /// A chave da propriedade carimbada em `canonicalRequest(for:)` e lida de
    /// volta em `startLoading()`. É o mecanismo documentado do `URLProtocol`
    /// para amarrar dado próprio a uma requisição que sobrevive até o
    /// `startLoading` da instância.
    private static let sessionPropertyKey = "StubURLProtocol.sessionID"

    /// Uma tabela **por sessão**, e não uma tabela única para o processo
    /// inteiro. Antes disto era `static var routes`/`recorded` compartilhados:
    /// duas suítes (`GoogleAuthTests`, `GmailClientTests`) rodando em
    /// paralelo faziam o `install()` de uma apagar o roteiro da outra
    /// enquanto ela tinha uma requisição em voo — `.serialized` no `@Suite`
    /// só serializa os testes *dentro* da própria suíte, nunca entre suítes.
    /// Isolando por `UUID` de sessão, duas suítes podem rodar ao mesmo tempo
    /// sem uma pisar no roteiro da outra, e o `.serialized` das duas suítes
    /// pôde sair.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routesByID: [UUID: [String: [Reply]]] = [:]
    nonisolated(unsafe) private static var recordedByID: [UUID: [Recorded]] = [:]
    /// Quantas requisições desta sessão estão em voo agora, e quantas já
    /// estiveram ao mesmo tempo. É a observação determinística de
    /// concorrência: uma busca sequencial nunca passa de 1.
    nonisolated(unsafe) private static var emVooByID: [UUID: Int] = [:]
    nonisolated(unsafe) private static var picoByID: [UUID: Int] = [:]

    /// Uma requisição como ela chegou.
    ///
    /// `query` e `authorization` entraram na Task 12 e são aditivos: sem a
    /// primeira, um teste não consegue afirmar que foi o **servidor** que
    /// filtrou os 90 dias (o `q=newer_than:90d` viaja na query, não no corpo),
    /// e trocar a consulta por outra passaria despercebido. Sem a segunda,
    /// não há como distinguir um replay que renovou o token de um replay que
    /// reenviou o mesmo token vencido — que é exatamente o defeito que o
    /// refresh pós-401 existe para não ter.
    struct Recorded: Sendable {
        var path: String
        var body: String
        var query: String
        var authorization: String?
    }

    /// Uma `URLSession` isolada, com o roteiro já instalado na criação: cada
    /// chamada tem seu próprio `UUID`, seu próprio roteiro e seu próprio log
    /// de requisições, sem tocar o de nenhuma outra sessão rodando junto.
    static func session(routes: [String: [Reply]] = [:]) -> URLSession {
        let id = UUID()
        lock.lock()
        routesByID[id] = routes
        recordedByID[id] = []
        emVooByID[id] = 0
        picoByID[id] = 0
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        // `httpAdditionalHeaders` é aplicado pelo `URLSession` a toda
        // requisição feita por esta sessão — é assim que o identificador
        // chega ao `canonicalRequest(for:)` sem que quem monta o
        // `URLRequest` (o `GmailClient`, o `GoogleAuth`) precise participar.
        config.httpAdditionalHeaders = [sessionHeader: id.uuidString]
        return URLSession(configuration: config)
    }

    /// O que uma sessão específica pediu, na ordem. É como o teste afirma que
    /// o corpo do POST levou `grant_type=refresh_token` e não outra coisa —
    /// sem risco de ler o que outra sessão, de outra suíte, gravou ao mesmo
    /// tempo.
    static func requests(for session: URLSession) -> [Recorded] {
        guard let id = sessionID(of: session) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return recordedByID[id] ?? []
    }

    /// O maior número de requisições que esta sessão teve em voo ao mesmo
    /// tempo. Um significa "estritamente sequencial".
    static func maxConcurrent(for session: URLSession) -> Int {
        guard let id = sessionID(of: session) else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return picoByID[id] ?? 0
    }

    private static func sessionID(of session: URLSession) -> UUID? {
        (session.configuration.httpAdditionalHeaders?[sessionHeader] as? String)
            .flatMap(UUID.init(uuidString:))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    /// Carimba o `UUID` da sessão como propriedade da requisição canônica.
    /// O `URLProtocol` garante que essa propriedade sobrevive até
    /// `startLoading()` ler `self.request` — é o ponto de entrada oficial
    /// para dado próprio de protocolo, e não uma convenção informal.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        guard let idString = request.value(forHTTPHeaderField: sessionHeader),
              let id = UUID(uuidString: idString),
              let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest
        else { return request }
        URLProtocol.setProperty(id, forKey: sessionPropertyKey, in: mutable)
        return mutable as URLRequest
    }

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

        let sessaoID = URLProtocol.property(forKey: Self.sessionPropertyKey, in: request) as? UUID

        Self.lock.lock()
        if let sessaoID {
            Self.recordedByID[sessaoID, default: []].append(Recorded(
                path: caminho, body: corpo,
                query: request.url?.query ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization")
            ))
        }
        let resposta: Reply?
        if let sessaoID, var fila = Self.routesByID[sessaoID]?[caminho], !fila.isEmpty {
            resposta = fila.removeFirst()
            Self.routesByID[sessaoID]?[caminho] = fila
        } else {
            resposta = nil
        }
        if let sessaoID {
            let agora = (Self.emVooByID[sessaoID] ?? 0) + 1
            Self.emVooByID[sessaoID] = agora
            Self.picoByID[sessaoID] = max(Self.picoByID[sessaoID] ?? 0, agora)
        }
        Self.lock.unlock()

        guard let resposta, let url = request.url else {
            Self.saiDeVoo(sessaoID)
            client?.urlProtocol(self, didFailWithError: URLError(
                .unsupportedURL,
                userInfo: [NSLocalizedDescriptionKey: "Nenhuma resposta no roteiro para \(caminho)"]
            ))
            return
        }

        // Sem atraso, a entrega é síncrona — o comportamento de sempre.
        guard resposta.delay > 0 else {
            Self.saiDeVoo(sessaoID)
            entrega(resposta, url: url)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + resposta.delay) { [weak self] in
            Self.saiDeVoo(sessaoID)
            guard let self, !self.parado else { return }
            self.entrega(resposta, url: url)
        }
    }

    private func entrega(_ resposta: Reply, url: URL) {
        let http = HTTPURLResponse(
            url: url, statusCode: resposta.status,
            httpVersion: "HTTP/1.1", headerFields: resposta.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resposta.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func saiDeVoo(_ sessaoID: UUID?) {
        guard let sessaoID else { return }
        lock.lock()
        emVooByID[sessaoID] = max(0, (emVooByID[sessaoID] ?? 1) - 1)
        lock.unlock()
    }

    private let parouLock = NSLock()
    private var parouMesmo = false
    private var parado: Bool {
        parouLock.lock()
        defer { parouLock.unlock() }
        return parouMesmo
    }

    override func stopLoading() {
        parouLock.lock()
        parouMesmo = true
        parouLock.unlock()
    }
}
