import Foundation
import NIOCore
import NIOPosix
@testable import UNISync

/// Um servidor SMTP em memória, com roteiro por teste.
///
/// **É o que faz "nenhum teste toca rede externa" ser verdade para o envio.**
/// Irmão do `FakeImapServer`, e escrito na mesma forma: liga em `127.0.0.1:0`,
/// casa o comando pelo **verbo** (a primeira palavra) e devolve o que o roteiro
/// mandar.
///
/// O que ele tem que o do IMAP não tem é o **modo DATA**: depois de responder
/// `354`, tudo o que chega deixa de ser comando e vira corpo, até a linha com
/// um ponto sozinho. É por isso que ele guarda `corpos` — é lá que um teste
/// confere que o dot-stuffing aconteceu e que a mensagem chegou inteira.
final class FakeSmtpServer: @unchecked Sendable {
    struct Script: Sendable {
        /// A saudação. Vazia = servidor que aceita a conexão e emudece.
        var greeting: String
        /// Verbo (maiúsculas) → linhas de resposta.
        var replies: [String: [String]]
        /// Respostas que **mudam a cada chamada** do mesmo verbo, na ordem —
        /// o `AUTH LOGIN`, que responde `334` duas vezes e `235` na terceira,
        /// não caberia num roteiro estático.
        var rounds: [String: [[String]]]

        init(
            greeting: String = "220 okamiuni.falso ESMTP pronto",
            replies: [String: [String]] = [:],
            rounds: [String: [[String]]] = [:]
        ) {
            self.greeting = greeting
            self.replies = replies
            self.rounds = rounds
        }

        /// O roteiro de um servidor que aceita tudo: EHLO com STARTTLS e AUTH
        /// PLAIN, credencial aceita, envelope aceito, mensagem aceita.
        static func aceitaTudo(
            capacidades: [String] = ["250-okamiuni.falso", "250-SIZE 35882577", "250 AUTH PLAIN LOGIN"]
        ) -> Script {
            Script(replies: [
                "EHLO": capacidades,
                "AUTH": ["235 2.7.0 autenticado"],
                "MAIL": ["250 2.1.0 remetente ok"],
                "RCPT": ["250 2.1.5 destinatário ok"],
                "DATA": ["354 mande a mensagem, termine com ponto"],
                "CORPO": ["250 2.0.0 aceito como <id-do-servidor>"],
                "QUIT": ["221 2.0.0 tchau"],
            ])
        }
    }

    /// A chave do roteiro para a resposta ao **corpo** — o que o servidor diz
    /// depois do ponto sozinho que fecha o `DATA`.
    static let chaveDoCorpo = "CORPO"

    private let group: MultiThreadedEventLoopGroup
    private var channel: (any Channel)?
    private let script: Script
    private let lock = NSLock()
    private var recebidos: [String] = []
    private var mensagens: [String] = []
    private var rodadas: [String: Int] = [:]

    init(script: Script) {
        self.script = script
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func start() throws -> Int {
        let script = script
        let registrar: @Sendable (String) -> Void = { [weak self] linha in
            guard let self else { return }
            self.lock.lock()
            self.recebidos.append(linha)
            self.lock.unlock()
        }
        let guardaCorpo: @Sendable (String) -> Void = { [weak self] corpo in
            guard let self else { return }
            self.lock.lock()
            self.mensagens.append(corpo)
            self.lock.unlock()
        }
        let proximaRodada: @Sendable (String) -> Int = { [weak self] chave in
            guard let self else { return 0 }
            self.lock.lock()
            defer { self.lock.unlock() }
            let atual = self.rodadas[chave] ?? 0
            self.rodadas[chave] = atual + 1
            return atual
        }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { canal in
                canal.eventLoop.makeCompletedFuture {
                    try canal.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(SmtpLineDecoder()),
                        ScriptedHandler(
                            script: script, registrar: registrar,
                            guardaCorpo: guardaCorpo, proximaRodada: proximaRodada
                        ),
                    ])
                }
            }
        let canal = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = canal
        guard let porta = canal.localAddress?.port else {
            throw NSError(domain: "FakeSmtpServer", code: 1)
        }
        return porta
    }

    /// Os comandos recebidos, na ordem. É como o teste afirma que o
    /// `STARTTLS` veio antes do `AUTH`, e não o contrário.
    var comandos: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recebidos
    }

    /// Os corpos entregues, como o servidor os viu — com o dot-stuffing ainda
    /// aplicado, que é o ponto de vista de quem confere a regra.
    var corpos: [String] {
        lock.lock()
        defer { lock.unlock() }
        return mensagens
    }

    /// Fecha sem bloquear a thread de quem chama — a mesma razão do
    /// `FakeImapServer.stop`.
    func stop() {
        channel?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    private final class ScriptedHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let script: Script
        private let registrar: @Sendable (String) -> Void
        private let guardaCorpo: @Sendable (String) -> Void
        private let proximaRodada: @Sendable (String) -> Int
        /// As linhas do corpo, quando o `DATA` está aberto. Vive no handler
        /// porque o modo é da conexão.
        private var corpo: [String]?
        /// O servidor acabou de mandar um `334`? Então a próxima linha é a
        /// metade de uma credencial em base64, e não um comando — rotear pelo
        /// "verbo" faria a base64 virar um comando desconhecido.
        private var esperandoCredencial = false

        init(
            script: Script,
            registrar: @escaping @Sendable (String) -> Void,
            guardaCorpo: @escaping @Sendable (String) -> Void,
            proximaRodada: @escaping @Sendable (String) -> Int
        ) {
            self.script = script
            self.registrar = registrar
            self.guardaCorpo = guardaCorpo
            self.proximaRodada = proximaRodada
        }

        func channelActive(context: ChannelHandlerContext) {
            guard !script.greeting.isEmpty else { return }
            escreve(context, script.greeting)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            // Sem `trimming`: dentro do `DATA` o espaço no fim da linha é
            // conteúdo, e apará-lo esconderia justamente o que o
            // quoted-printable existe para preservar.
            let linha = buffer.readString(length: buffer.readableBytes) ?? ""

            // Modo DATA: tudo é corpo até o ponto sozinho.
            if corpo != nil {
                if linha == "." {
                    guardaCorpo(corpo!.joined(separator: "\r\n"))
                    corpo = nil
                    responde(context, chave: FakeSmtpServer.chaveDoCorpo)
                } else {
                    corpo?.append(linha)
                }
                return
            }

            // A linha em branco é registrada como qualquer outra, e recusada:
            // um servidor de verdade responde `500` a ela. Engoli-la aqui
            // deixaria passar um CRLF a mais mandado depois do ponto que fecha
            // o `DATA` — que é exatamente o defeito que ninguém vê.
            registrar(linha)
            guard !linha.isEmpty else {
                escreve(context, "500 5.5.2 linha vazia não é comando")
                return
            }
            if esperandoCredencial {
                responde(context, chave: "AUTH")
                return
            }
            let verbo = String(linha.split(separator: " ").first ?? "").uppercased()
            responde(context, chave: verbo)
            if verbo == "DATA" { corpo = [] }
        }

        private func responde(_ context: ChannelHandlerContext, chave: String) {
            let doRoteiro: [String]? = {
                if let rodadas = script.rounds[chave], !rodadas.isEmpty {
                    return rodadas[min(proximaRodada(chave), rodadas.count - 1)]
                }
                return script.replies[chave]
            }()
            guard let linhas = doRoteiro else {
                escreve(context, "500 comando fora do roteiro: \(chave)")
                return
            }
            for linha in linhas { escreve(context, linha) }
            esperandoCredencial = linhas.last?.hasPrefix("334") ?? false
            if chave == "QUIT" { context.close(promise: nil) }
        }

        private func escreve(_ context: ChannelHandlerContext, _ texto: String) {
            var buffer = context.channel.allocator.buffer(capacity: texto.utf8.count + 2)
            buffer.writeString(texto)
            buffer.writeString("\r\n")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
