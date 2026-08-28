import Foundation
import NIOCore
import NIOPosix
@testable import UNISync

/// Um servidor IMAP em memória, com roteiro por teste.
///
/// **É o que faz "nenhum teste toca rede externa" ser verdade para o IMAP.**
/// Ele liga em `127.0.0.1:0` (porta que o sistema escolhe), fala o mínimo do
/// protocolo — saudação, comandos com tag, resposta tagueada — e devolve o que
/// o roteiro mandar, na ordem.
///
/// O roteiro é `[verbo: [linhasDeResposta]]`: o servidor casa pelo **verbo** do
/// comando (o que vem depois da tag), o que deixa os testes legíveis sem
/// precisar prever a numeração das tags.
final class FakeImapServer: @unchecked Sendable {
    struct Script: Sendable {
        /// A saudação, antes de qualquer comando. String vazia = servidor que
        /// aceita a conexão e emudece, que é o caso que prova o teto de tempo.
        var greeting: String
        /// Verbo (em maiúsculas) → linhas de resposta. A linha que começa com
        /// `TAG ` tem a tag substituída pela do comando recebido. Lista vazia =
        /// o servidor recebe o comando e não responde nada.
        var replies: [String: [String]]

        init(
            greeting: String = "* OK [CAPABILITY IMAP4rev1 STARTTLS] OkamiUNI falso pronto",
            replies: [String: [String]]
        ) {
            self.greeting = greeting
            self.replies = replies
        }
    }

    private let group: MultiThreadedEventLoopGroup
    private var channel: (any Channel)?
    private let script: Script
    private let lock = NSLock()
    private var received: [String] = []

    init(script: Script) {
        self.script = script
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Sobe e devolve a porta escolhida pelo sistema.
    func start() throws -> Int {
        let script = script
        let registrar: @Sendable (String) -> Void = { [weak self] linha in
            guard let self else { return }
            self.lock.lock()
            self.received.append(linha)
            self.lock.unlock()
        }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { canal in
                // `syncOperations`: os handlers do NIO não são `Sendable`, e a
                // variante assíncrona exige que sejam. Já estamos na event loop.
                canal.eventLoop.makeCompletedFuture {
                    try canal.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(CRLFLineDecoder()),
                        ScriptedHandler(script: script, registrar: registrar),
                    ])
                }
            }
        let canal = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = canal
        guard let porta = canal.localAddress?.port else {
            throw NSError(domain: "FakeImapServer", code: 1)
        }
        return porta
    }

    /// Os comandos que o cliente mandou, na ordem. É como o teste afirma que a
    /// sessão fez `SELECT` antes de `UID SEARCH`, e não o contrário.
    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Fecha **sem bloquear** a thread de quem chama.
    ///
    /// `close().wait()` e `syncShutdownGracefully()` param a thread até o NIO
    /// terminar, e o `defer` que chama isto roda no pool cooperativo do Swift
    /// — uma thread por núcleo, que não cresce. Alguns testes de IMAP em
    /// paralelo bastam para todas ficarem paradas aqui ao mesmo tempo, e aí a
    /// suíte trava sem falhar. Pedir e sair é o que o teste precisa: o processo
    /// termina logo depois de qualquer jeito.
    func stop() {
        channel?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    private final class ScriptedHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let script: Script
        private let registrar: @Sendable (String) -> Void

        init(script: Script, registrar: @escaping @Sendable (String) -> Void) {
            self.script = script
            self.registrar = registrar
        }

        func channelActive(context: ChannelHandlerContext) {
            guard !script.greeting.isEmpty else { return }
            escreve(context, script.greeting)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            let linha = (buffer.readString(length: buffer.readableBytes) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !linha.isEmpty else { return }
            registrar(linha)

            let partes = linha.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let tag = String(partes.first ?? "*")
            let resto = partes.count > 1 ? String(partes[1]) : ""
            // O verbo é a primeira palavra do comando; `UID SEARCH` e
            // `UID FETCH` contam como verbos de duas palavras.
            let palavras = resto.split(separator: " ").map { $0.uppercased() }
            let verbo: String = {
                if palavras.first == "UID", palavras.count >= 2 { return "UID \(palavras[1])" }
                return palavras.first ?? ""
            }()

            guard let linhas = script.replies[verbo] else {
                escreve(context, "\(tag) BAD comando fora do roteiro: \(verbo)")
                return
            }
            for modelo in linhas {
                escreve(context, modelo.replacingOccurrences(of: "TAG ", with: "\(tag) "))
            }
            if verbo == "LOGOUT" { context.close(promise: nil) }
        }

        private func escreve(_ context: ChannelHandlerContext, _ texto: String) {
            var buffer = context.channel.allocator.buffer(capacity: texto.utf8.count + 2)
            buffer.writeString(texto)
            buffer.writeString("\r\n")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
