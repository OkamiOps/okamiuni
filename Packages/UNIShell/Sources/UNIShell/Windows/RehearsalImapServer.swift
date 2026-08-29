import Foundation
import NIOCore
import NIOPosix

/// O servidor IMAP falso do **ensaio**, em 127.0.0.1, porta escolhida pelo
/// sistema.
///
/// Mora no alvo de produção porque o ensaio roda dentro do app de verdade — é
/// essa a diferença entre ensaio e teste de View, e é o que fez o arraste do
/// Marco 1 parar de mentir. Ele só sobe quando `--ensaiar-contas` está na linha
/// de comando; sem a bandeira, nada aqui é construído.
///
/// O roteiro é **fixo**: uma caixa de entrada com duas mensagens. O ensaio
/// prova o **fluxo**, não o protocolo — o protocolo tem os testes das Tasks 9 e
/// 10, contra o `FakeImapServer` com roteiro por teste. Roteiro fixo também é o
/// que deixa `respostas(para:)` ser uma função pura, aferível sem socket.
public final class RehearsalImapServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: (any Channel)?

    public init() {}

    /// Sobe e devolve a porta que o sistema escolheu.
    ///
    /// `port: 0` e `host: "127.0.0.1"`, sempre: é o par que faz o ensaio rodar
    /// num notebook desligado da internet e não disputar porta com nada.
    public func start() throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { canal in
                // `syncOperations`: nenhum handler do NIO é `Sendable`, e a
                // variante assíncrona exige que sejam. Aqui já estamos na event
                // loop do canal, que é o que a variante síncrona pede.
                canal.eventLoop.makeCompletedFuture {
                    try canal.pipeline.syncOperations.addHandler(Handler())
                }
            }
        let canal = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        lock.lock()
        channel = canal
        lock.unlock()
        guard let porta = canal.localAddress?.port else {
            throw SyncErrorDeEnsaio.semPorta
        }
        return porta
    }

    /// Fecha **sem bloquear** a thread de quem chama.
    ///
    /// `close().wait()` e `syncShutdownGracefully()` param a thread até o NIO
    /// terminar, e quem chama isto é o driver do ensaio, que corre no pool
    /// cooperativo do Swift — uma thread por núcleo, que não cresce. Pedir e
    /// sair basta: o processo encerra logo depois de qualquer jeito.
    public func stop() {
        lock.lock()
        let canal = channel
        channel = nil
        lock.unlock()
        canal?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    enum SyncErrorDeEnsaio: Error { case semPorta }

    // MARK: O roteiro

    /// As linhas que o servidor devolve a um comando, com a tag já trocada.
    ///
    /// Função pura, `static`, e é por isso que o roteiro tem teste sem socket:
    /// o que o `ImapSession` lê deste servidor é exatamente o que sai daqui.
    static func respostas(para comando: String) -> [String] {
        let linha = comando.trimmingCharacters(in: .whitespacesAndNewlines)
        let partes = linha.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let tag = String(partes.first ?? "*")
        let resto = partes.count > 1 ? String(partes[1]) : ""
        let palavras = resto.split(separator: " ").map { $0.uppercased() }
        // `UID SEARCH` e `UID FETCH` são verbos de **duas** palavras: casar só
        // pela primeira jogaria os dois no mesmo balde e o `SEARCH` receberia
        // envelopes.
        let verbo = palavras.first == "UID" && palavras.count >= 2
            ? "UID \(palavras[1])"
            : (palavras.first ?? "")
        let modelos = roteiro[verbo] ?? ["TAG BAD comando fora do roteiro do ensaio"]
        return modelos.map { $0.replacingOccurrences(of: "TAG ", with: "\(tag) ") }
    }

    static let saudacao = "* OK [CAPABILITY IMAP4rev1] OkamiUNI ensaio pronto"

    /// Uma caixa de entrada, duas mensagens. Nada mais — o que este servidor
    /// existe para provar é que a conta desce do fio para o banco e a janela
    /// mostra "2 mensagens".
    private static let roteiro: [String: [String]] = [
        "LOGIN": ["TAG OK LOGIN completed"],
        "LIST": [
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
            "TAG OK LIST completed",
        ],
        "SELECT": [
            "* 2 EXISTS",
            "* OK [UIDVALIDITY 1755000000] UIDs valid",
            "* OK [UIDNEXT 9003] Predicted next UID",
            "TAG OK [READ-WRITE] SELECT completed",
        ],
        "UID SEARCH": ["* SEARCH 9001 9002", "TAG OK UID SEARCH completed"],
        "UID FETCH": [
            "* 1 FETCH (UID 9001 FLAGS (\\Seen) INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" "
            + "ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"Revisao do contrato\" "
            + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL "
            + "((\"Ricardo\" NIL \"contato\" \"meusite.com\")) NIL NIL NIL NIL))",
            "* 2 FETCH (UID 9002 FLAGS () INTERNALDATE \"25-Aug-2026 08:00:00 -0300\" "
            + "ENVELOPE (\"Tue, 25 Aug 2026 08:00:00 -0300\" \"Boletim\" "
            + "((\"Noticias\" NIL \"noticias\" \"exemplo.com\")) NIL NIL NIL NIL NIL NIL NIL))",
            "TAG OK UID FETCH completed",
        ],
        "LOGOUT": ["TAG OK LOGOUT completed"],
    ]

    // MARK: O cano

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        /// O que chegou e ainda não fechou uma linha. O ensaio não precisa do
        /// `CRLFLineDecoder` do `UNISync` — nenhum comando que o cliente manda
        /// aqui tem literal `{n}` —, e emendar os pedaços à mão evita puxar o
        /// `NIOExtras` para dentro do alvo do app.
        private var pendente = ""

        func channelActive(context: ChannelHandlerContext) {
            escreve(context, RehearsalImapServer.saudacao)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            pendente += buffer.readString(length: buffer.readableBytes) ?? ""
            while let fim = pendente.range(of: "\r\n") {
                let linha = String(pendente[..<fim.lowerBound])
                pendente = String(pendente[fim.upperBound...])
                guard !linha.isEmpty else { continue }
                for resposta in RehearsalImapServer.respostas(para: linha) {
                    escreve(context, resposta)
                }
                if linha.uppercased().contains(" LOGOUT") { context.close(promise: nil) }
            }
        }

        private func escreve(_ context: ChannelHandlerContext, _ texto: String) {
            var buffer = context.channel.allocator.buffer(capacity: texto.utf8.count + 2)
            buffer.writeString(texto)
            buffer.writeString("\r\n")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
