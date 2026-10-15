import Foundation
import Network
import UNICore
#if canImport(AppKit)
import AppKit
#endif

/// O que pode dar errado ao esperar o redirect do navegador em `127.0.0.1`.
public enum LoopbackRedirectError: LocalizedError, Sendable, Hashable {
    /// A porta fixa já está ocupada — outra cópia do OkamiUNI esperando um
    /// login, ou outro programa qualquer.
    case portBusy(UInt16)
    case cannotListen(String)
    /// Ninguém voltou do navegador dentro do prazo.
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .portBusy(let port):
            L10n.tr(
                "A porta \(String(port)) já está em uso. Feche a outra janela de login do OkamiUNI (ou o programa que ocupa a porta) e tente de novo."
            )
        case .cannotListen(let detalhe):
            L10n.tr("Não foi possível escutar o retorno do navegador: \(detalhe)")
        case .timedOut:
            L10n.tr("O login no navegador não voltou no tempo esperado.")
        }
    }
}

/// Quem abre o navegador **do sistema**.
///
/// Porta, e não chamada direta, pelo mesmo motivo de `AuthorizationPresenter`:
/// nenhum teste pode abrir um navegador.
public protocol SystemBrowserOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

public struct AppKitBrowserOpener: SystemBrowserOpening, Sendable {
    public init() {}

    public func open(_ url: URL) async -> Bool {
        #if canImport(AppKit)
        return await MainActor.run { NSWorkspace.shared.open(url) }
        #else
        return false
        #endif
    }
}

/// Um servidor HTTP de uma requisição só, em `127.0.0.1:53720`, para receber o
/// redirect do OAuth do Zoom e do Zoho.
///
/// **Por que não `ASWebAuthenticationSession`.** A sessão do sistema só captura
/// redirect de esquema próprio (`com.okamiops.okamiuni:`), e nem o Zoom nem o
/// Zoho aceitam esquema próprio num aplicativo instalado: o Zoom só reconhece
/// esquema custom dentro do Meeting SDK, e o Zoho exige `http`/`https`. O que
/// os dois aceitam é o loopback do RFC 8252 — `http://127.0.0.1:porta/caminho`
/// —, e para ouvir `http` é preciso ser o servidor. Daí abrir o navegador do
/// sistema com `NSWorkspace` e escutar aqui.
///
/// **Por que porta fixa.** O RFC 8252 recomenda porta efêmera, e o OAuth do
/// LiteLLM neste mesmo app faz assim. Zoom e Zoho, porém, conferem o
/// `redirect_uri` contra uma lista cadastrada no painel do desenvolvedor, e
/// uma porta que muda a cada login não cabe numa lista. 53720 é a porta que
/// vai no cadastro; se estiver ocupada, o erro diz isso em vez de falhar como
/// "login não voltou".
///
/// A porta fecha assim que a primeira requisição no caminho certo chega, e
/// também quando o prazo vence, quando a tarefa é cancelada ou quando
/// `cancel()` é chamado: nunca sobra escuta aberta depois de um login.
public final class LoopbackRedirectListener: @unchecked Sendable {
    public static let defaultPort: UInt16 = 53_720
    public static let defaultPath = "/oauth2redirect"

    /// Quanto o navegador pode mandar antes de desistirmos de achar a linha da
    /// requisição. Um GET de OAuth não passa de alguns kB.
    private static let maximumRequestBytes = 16_384

    private let port: UInt16
    private let path: String
    private let queue = DispatchQueue(label: "com.okamiops.okamiuni.meeting-oauth-loopback")

    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var pending: Result<URL, any Error>?
    private var finished = false
    private var timeoutItem: DispatchWorkItem?

    public init(port: UInt16 = LoopbackRedirectListener.defaultPort,
                path: String = LoopbackRedirectListener.defaultPath) {
        self.port = port
        self.path = path
    }

    /// O `redirect_uri` que vai na URL de autorização **e** no cadastro do
    /// serviço. Os dois têm de bater caractere por caractere.
    public var redirectURI: String { "http://127.0.0.1:\(port)\(path)" }

    /// Sobe a escuta. Chame **antes** de abrir o navegador: se a porta estiver
    /// ocupada, é melhor a pessoa descobrir sem o navegador ter aberto.
    public func start() throws {
        let parameters = NWParameters.tcp
        // Só o loopback. Sem isto, o `NWListener` aceitaria conexão de
        // qualquer interface, e um código de autorização chegaria pela rede
        // local.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.acceptLocalOnly = true
        // `includePeerToPeer` fica desligado: isto não é Bonjour, é um
        // socket local.
        parameters.includePeerToPeer = false

        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters)
        } catch {
            throw Self.translate(error, port: port)
        }
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.finish(.failure(Self.translate(error, port: self.port)))
            }
        }
        lock.lock()
        listener = nwListener
        lock.unlock()
        nwListener.start(queue: queue)
    }

    /// Espera a requisição. Lança `LoopbackRedirectError.timedOut` no prazo e
    /// `CancellationError` quando a tarefa é cancelada.
    public func wait(timeout: TimeInterval = 300) async throws -> URL {
        let item = DispatchWorkItem { [weak self] in
            self?.finish(.failure(LoopbackRedirectError.timedOut))
        }
        arm(item)
        queue.asyncAfter(deadline: .now() + max(1, timeout), execute: item)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let pronto = pending {
                    pending = nil
                    lock.unlock()
                    cont.resume(with: pronto)
                    return
                }
                continuation = cont
                lock.unlock()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    /// Guarda o item do prazo. Síncrono e separado de `wait()` porque
    /// `NSLock.lock()` é proibido em contexto assíncrono — e com razão: travar
    /// uma thread cooperativa pode bloquear o pool inteiro. Aqui a seção
    /// crítica é uma atribuição, sem suspensão dentro dela.
    private func arm(_ item: DispatchWorkItem) {
        lock.lock()
        timeoutItem = item
        lock.unlock()
    }

    /// Desiste e fecha a porta. Chamar duas vezes não faz mal.
    public func cancel() {
        finish(.failure(CancellationError()))
    }

    // MARK: Entrada

    private var nwPort: NWEndpoint.Port {
        NWEndpoint.Port(rawValue: port) ?? .any
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self] dados, _, acabou, erro in
            guard let self else {
                connection.cancel()
                return
            }
            var acumulado = buffer
            if let dados { acumulado.append(dados) }

            if erro != nil || acumulado.count > Self.maximumRequestBytes {
                connection.cancel()
                return
            }
            // A linha da requisição é a primeira; esperar os cabeçalhos
            // inteiros é o que garante que ela chegou completa mesmo quando o
            // navegador parte o pacote.
            guard let texto = String(data: acumulado, encoding: .utf8),
                  texto.contains("\r\n\r\n") || acabou
            else {
                self.receive(connection, buffer: acumulado)
                return
            }
            self.handle(texto, on: connection)
        }
    }

    private func handle(_ texto: String, on connection: NWConnection) {
        guard let target = Self.requestTarget(texto) else {
            respond(connection, status: "400 Bad Request", body: Self.errorPage)
            return
        }
        guard target == path || target.hasPrefix(path + "?") else {
            // Favicon e outras curiosidades do navegador não terminam o
            // login: respondem 404 e a escuta continua.
            respond(connection, status: "404 Not Found", body: Self.errorPage)
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)\(target)") else {
            respond(connection, status: "400 Bad Request", body: Self.errorPage)
            return
        }
        respond(connection, status: "200 OK", body: Self.successPage) { [weak self] in
            self?.finish(.success(url))
        }
    }

    private static func requestTarget(_ texto: String) -> String? {
        guard let linha = texto.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let partes = linha.split(separator: " ")
        guard partes.count >= 2, partes[0] == "GET" else { return nil }
        return String(partes[1])
    }

    private func respond(
        _ connection: NWConnection, status: String, body: String,
        then depois: (@Sendable () -> Void)? = nil
    ) {
        let corpo = Data(body.utf8)
        let cabecalho = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(corpo.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
        var resposta = Data(cabecalho.utf8)
        resposta.append(corpo)
        connection.send(content: resposta, completion: .contentProcessed { _ in
            connection.cancel()
            depois?()
        })
    }

    private func finish(_ resultado: Result<URL, any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let aberto = listener
        listener = nil
        let prazo = timeoutItem
        timeoutItem = nil
        if cont == nil { pending = resultado }
        lock.unlock()

        prazo?.cancel()
        aberto?.cancel()
        cont?.resume(with: resultado)
    }

    private static func translate(_ error: any Error, port: UInt16) -> any Error {
        if let nw = error as? NWError, case .posix(let code) = nw,
           code == .EADDRINUSE || code == .EACCES {
            return LoopbackRedirectError.portBusy(port)
        }
        return LoopbackRedirectError.cannotListen(error.localizedDescription)
    }

    // MARK: As duas páginas

    /// Sem nada da URL dentro: o código de autorização fica em memória e não
    /// atravessa o HTML, onde qualquer extensão do navegador o leria.
    private static let successPage = """
        <!doctype html>
        <html lang="pt-BR">
        <head><meta charset="utf-8"><title>OkamiUNI</title></head>
        <body style="font: 16px -apple-system, system-ui, sans-serif; margin: 4rem auto; max-width: 28rem; text-align: center; color: #1c1c1e;">
        <h1 style="font-size: 1.25rem;">Pronto</h1>
        <p>Pode voltar ao OkamiUNI. Esta aba já pode ser fechada.</p>
        </body>
        </html>
        """

    private static let errorPage = """
        <!doctype html>
        <html lang="pt-BR">
        <head><meta charset="utf-8"><title>OkamiUNI</title></head>
        <body style="font: 16px -apple-system, system-ui, sans-serif; margin: 4rem auto; max-width: 28rem; text-align: center; color: #1c1c1e;">
        <p>Esta página não é do login do OkamiUNI.</p>
        </body>
        </html>
        """
}
