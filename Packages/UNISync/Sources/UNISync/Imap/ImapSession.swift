import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import UNICore

/// Uma sessão IMAP, sobre NIO.
///
/// Ator porque uma conexão IMAP é estritamente sequencial: um comando por vez,
/// a resposta tagueada fecha o comando, e o próximo só entra depois. Dois
/// comandos em voo na mesma conexão embaralham as respostas untagged — e as
/// untagged são justamente o conteúdo (`FETCH`, `LIST`, `SEARCH`).
public actor ImapSession {
    private let channel: any Channel
    private let handler: ImapChannelHandler
    private var tagCounter = 0
    private var closed = false

    private init(channel: any Channel, handler: ImapChannelHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Conecta, sobe o TLS que o endpoint pedir, e espera a saudação.
    ///
    /// `allowInsecure` existe **para o teste**, e só para ele: o servidor IMAP
    /// falso roda dentro do processo do teste, em `127.0.0.1`, sem certificado
    /// nenhum, e exigir TLS ali significaria gerar e confiar num certificado
    /// só para provar coisas que não são sobre TLS. Em produção ninguém passa
    /// esse parâmetro, e o padrão `false` é o que garante que uma conta
    /// `.startTLS` faz `STARTTLS` de verdade antes de mandar a senha.
    public static func connect(
        endpoint: ImapEndpoint,
        group: any EventLoopGroup,
        allowInsecure: Bool = false
    ) async throws -> ImapSession {
        let handler = ImapChannelHandler()
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(20))
            .channelInitializer { canal in
                // `syncOperations` e não `pipeline.addHandlers`: nenhum handler
                // do NIO é `Sendable` nesta versão, e a variante assíncrona só
                // aceita handlers `Sendable`. Aqui já estamos na event loop do
                // canal, que é exatamente o que a variante síncrona exige.
                canal.eventLoop.makeCompletedFuture {
                    var handlers: [any ChannelHandler] = []
                    if endpoint.security == .tls {
                        // TLS implícito: o handler entra antes de tudo, e o
                        // primeiro byte já é do handshake.
                        handlers.append(try Self.tlsHandler(host: endpoint.host))
                    }
                    handlers.append(ByteToMessageHandler(CRLFLineDecoder()))
                    handlers.append(handler)
                    try canal.pipeline.syncOperations.addHandlers(handlers)
                }
            }

        let canal: any Channel
        do {
            canal = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch let erro as NIOSSLError {
            throw SyncError.tls(String(describing: erro))
        } catch let erro as SyncError {
            throw erro
        } catch {
            throw SyncError.rede("\(endpoint.host):\(endpoint.port) — \(error.localizedDescription)")
        }

        // A saudação chega sozinha, sem tag. Esperá-la aqui é o que garante
        // que o primeiro comando não seja escrito antes de o servidor estar de
        // pé — e é onde um servidor que responde `* BYE` na cara já é recusado.
        let saudacao: String
        do {
            saudacao = try await handler.waitForGreeting()
        } catch {
            try? await canal.close()
            throw error
        }
        guard !saudacao.uppercased().contains("BYE") else {
            try? await canal.close()
            throw SyncError.servidor(codigo: 0, mensagem: saudacao)
        }

        let sessao = ImapSession(channel: canal, handler: handler)
        if endpoint.security == .startTLS, !allowInsecure {
            try await sessao.upgradeToTLS(host: endpoint.host)
        }
        return sessao
    }

    /// Sobe a conexão em claro para TLS, antes de qualquer credencial.
    ///
    /// Recusa não é degradação: se o servidor diz `NO` ao `STARTTLS`, a sessão
    /// morre com `.tls`. Seguir em claro seria mandar a senha da pessoa em
    /// texto puro no primeiro provedor que resolvesse não anunciar `STARTTLS`,
    /// e ela não teria como saber.
    private func upgradeToTLS(host: String) async throws {
        let resultado: ImapCommandResult
        do {
            resultado = try await send { ImapWire.startTLS(tag: $0) }
        } catch {
            try? await channel.close()
            closed = true
            throw error
        }
        guard resultado.status == .ok else {
            try? await channel.close()
            closed = true
            throw SyncError.tls("O servidor recusou STARTTLS: \(resultado.text)")
        }
        do {
            // Antes do decodificador de linhas: a partir daqui os bytes do
            // socket são do TLS, e só saem em claro depois deste handler.
            let canal = channel
            try await canal.eventLoop.submit {
                try canal.pipeline.syncOperations.addHandler(
                    Self.tlsHandler(host: host), position: .first
                )
            }.get()
        } catch {
            try? await channel.close()
            closed = true
            throw SyncError.tls(String(describing: error))
        }
    }

    /// O handler de TLS do cliente.
    ///
    /// `serverHostname` só entra quando o host é um nome: SNI não aceita
    /// endereço IP literal, e passar um faria o `NIOSSLClientHandler` lançar
    /// antes mesmo de tocar a rede.
    private static func tlsHandler(host: String) throws -> NIOSSLClientHandler {
        let contexto = try NIOSSLContext(configuration: .makeClientConfiguration())
        return try NIOSSLClientHandler(context: contexto, serverHostname: Self.sni(host))
    }

    static func sni(_ host: String) -> String? {
        if host.contains(":") { return nil } // IPv6 literal
        let partes = host.split(separator: ".", omittingEmptySubsequences: false)
        if partes.count == 4, partes.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return nil // IPv4 literal
        }
        return host
    }

    /// Manda o próximo comando e devolve a resposta tagueada **crua**, sem
    /// julgar `OK`/`NO`/`BAD`. É o que o `STARTTLS` usa, onde `NO` tem
    /// significado próprio.
    private func send(_ build: (String) -> String) async throws -> ImapCommandResult {
        tagCounter += 1
        let tag = ImapWire.tag(tagCounter)
        let comando = build(tag)

        var buffer = channel.allocator.buffer(capacity: comando.utf8.count + 2)
        buffer.writeString(comando)
        buffer.writeString("\r\n")

        return try await handler.send(buffer, tag: tag, on: channel)
    }

    /// O próximo comando, e a resposta tagueada dele, já traduzida em erro
    /// quando não é `OK`.
    ///
    /// `internal` e não `private` porque a Task 10 chama daqui de dentro do
    /// mesmo ator, e porque os testes de `ImapSession` afirmam o texto exato
    /// que sai.
    @discardableResult
    func run(_ build: (String) -> String) async throws -> ImapCommandResult {
        guard !closed else { throw SyncError.rede("A sessão IMAP já foi encerrada.") }
        let comando = build("")
        let resultado = try await send(build)
        switch resultado.status {
        case .ok:
            return resultado
        case .no:
            // `NO` é recusa com motivo. Autenticação tem código próprio porque
            // pede ação própria: reconectar, não tentar de novo.
            if resultado.text.uppercased().contains("AUTHENTICATIONFAILED")
                || resultado.text.uppercased().contains("INVALID CREDENTIALS")
                || comando.contains(" LOGIN ") {
                throw SyncError.autenticacao
            }
            if resultado.text.uppercased().contains("THROTTLED")
                || resultado.text.uppercased().contains("OVERQUOTA") {
                throw SyncError.quota
            }
            throw SyncError.servidor(codigo: 0, mensagem: resultado.text)
        case .bad:
            // `BAD` é erro **nosso**: comando malformado. Engoli-lo esconderia
            // um defeito do `ImapWire` atrás de uma mensagem de rede.
            throw SyncError.resposta("O servidor IMAP recusou o comando: \(resultado.text)")
        }
    }

    public func login(user: String, password: String) async throws {
        _ = try await run { ImapWire.login(tag: $0, user: user, password: password) }
    }

    /// Sai e fecha. Idempotente: sair duas vezes é o mesmo estado.
    ///
    /// Não lança, e é de propósito: encerrar já é o caminho de saída, e um erro
    /// aqui não muda nada que alguém possa fazer.
    ///
    /// `closed` sobe **antes** do `await`: um ator não é um cadeado, e um
    /// segundo `logout()` durante a espera do primeiro mandaria um `LOGOUT`
    /// numa conexão que já está saindo. Por isso o `LOGOUT` desce por `send`, e
    /// não por `run` — é o único comando que tem o direito de sair com a sessão
    /// já marcada como fechada.
    public func logout() async {
        guard !closed else { return }
        closed = true
        _ = try? await send { ImapWire.logout(tag: $0) }
        try? await channel.close()
    }
}

/// A resposta tagueada de um comando, com as linhas untagged que vieram antes.
struct ImapCommandResult: Sendable {
    enum Status: Sendable { case ok, no, bad }
    let status: Status
    /// O texto depois de `OK`/`NO`/`BAD`.
    let text: String
    /// As linhas `*` que chegaram enquanto o comando estava em voo. É onde
    /// moram `LIST`, `SEARCH`, `FETCH`, `EXISTS` e os códigos de `SELECT`.
    let untagged: [String]
}

/// Corta o fluxo de bytes em linhas de protocolo.
///
/// O `swift-nio` desta versão não traz nenhum decodificador de linhas — o
/// `LineBasedFrameDecoder` mora no `swift-nio-extras`, que não é dependência
/// deste marco. São quinze linhas nossas em vez de um quarto pacote, e elas
/// cortam por CRLF, que é o que o RFC 3501 manda.
struct CRLFLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let visao = buffer.readableBytesView
        guard let fim = visao.firstIndex(of: UInt8(ascii: "\n")) else { return .needMoreData }
        var linha = buffer.readSlice(length: fim - visao.startIndex)!
        buffer.moveReaderIndex(forwardBy: 1) // o `\n`
        if linha.readableBytesView.last == UInt8(ascii: "\r") {
            linha = linha.readSlice(length: linha.readableBytes - 1)!
        }
        context.fireChannelRead(wrapInboundOut(linha))
        return .continue
    }

    /// O que sobrou sem `\n` no fim ainda é uma linha: um servidor que fecha a
    /// conexão logo depois de escrever não pode fazer a última resposta sumir.
    mutating func decodeLast(
        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
    ) throws -> DecodingState {
        if try decode(context: context, buffer: &buffer) == .continue { return .continue }
        guard buffer.readableBytes > 0 else { return .needMoreData }
        let linha = buffer.readSlice(length: buffer.readableBytes)!
        context.fireChannelRead(wrapInboundOut(linha))
        return .needMoreData
    }
}

/// O handler que junta as linhas até a resposta tagueada.
///
/// Uma requisição em voo por vez, garantida pelo ator acima. O `continuation`
/// é o que transforma o callback do NIO em `await`.
final class ImapChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let lock = NSLock()
    private var greeting: CheckedContinuation<String, any Error>?
    private var greetingLine: String?
    private var greetingFailure: (any Error)?
    private var pendingTag: String?
    private var pending: CheckedContinuation<ImapCommandResult, any Error>?
    private var collected: [String] = []
    private var falhaFinal: (any Error)?

    func waitForGreeting() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let linha = greetingLine {
                lock.unlock()
                continuation.resume(returning: linha)
                return
            }
            if let erro = greetingFailure {
                lock.unlock()
                continuation.resume(throwing: erro)
                return
            }
            greeting = continuation
            lock.unlock()
        }
    }

    func send(_ buffer: ByteBuffer, tag: String, on channel: any Channel) async throws -> ImapCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // Uma conexão que já caiu não ganha mais um comando pendurado: a
            // falha que derrubou a anterior vale para esta também.
            if let erro = falhaFinal {
                lock.unlock()
                continuation.resume(throwing: erro)
                return
            }
            pendingTag = tag
            pending = continuation
            collected = []
            lock.unlock()
            channel.writeAndFlush(buffer).whenFailure { erro in
                self.falha(SyncError.rede(erro.localizedDescription))
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let linha = (buffer.readString(length: buffer.readableBytes) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !linha.isEmpty else { return }

        lock.lock()
        if let continuation = greeting {
            greeting = nil
            greetingLine = linha
            lock.unlock()
            continuation.resume(returning: linha)
            return
        }
        if greetingLine == nil, pendingTag == nil {
            greetingLine = linha
            lock.unlock()
            return
        }
        guard let tag = pendingTag else {
            lock.unlock()
            return
        }
        if linha.hasPrefix(tag + " ") {
            let resto = String(linha.dropFirst(tag.count + 1))
            let partes = resto.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let palavra = String(partes.first ?? "").uppercased()
            let texto = partes.count > 1 ? String(partes[1]) : ""
            let status: ImapCommandResult.Status = palavra == "OK" ? .ok : (palavra == "NO" ? .no : .bad)
            let resultado = ImapCommandResult(status: status, text: texto, untagged: collected)
            let continuation = pending
            pending = nil
            pendingTag = nil
            collected = []
            lock.unlock()
            continuation?.resume(returning: resultado)
        } else {
            collected.append(linha)
            lock.unlock()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        falha(SyncError.rede(error.localizedDescription))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        falha(SyncError.rede("O servidor IMAP fechou a conexão."))
    }

    /// Uma falha acorda quem estiver esperando. Sem isto, uma conexão caída no
    /// meio de um comando deixaria a carga inicial travada para sempre — que é
    /// erro engolido na forma mais cara: o app parece só estar devagar.
    private func falha(_ erro: SyncError) {
        lock.lock()
        let saudacao = greeting
        let comando = pending
        greeting = nil
        pending = nil
        pendingTag = nil
        if falhaFinal == nil { falhaFinal = erro }
        if greetingLine == nil, greetingFailure == nil { greetingFailure = erro }
        lock.unlock()
        saudacao?.resume(throwing: erro)
        comando?.resume(throwing: erro)
    }
}
