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
        /// Respostas que **mudam a cada chamada** do mesmo verbo, na ordem: a
        /// n-ésima chamada usa a n-ésima entrada, e a última se repete daí em
        /// diante. É o que deixa um teste encenar "o primeiro corpo estoura o
        /// teto do literal, o segundo desce inteiro" — sem isso o roteiro é
        /// estático e a mesma falha se repetiria para sempre.
        ///
        /// A contagem é do **servidor**, não da conexão: reconectar depois de
        /// uma falha não pode rebobinar o roteiro, senão o teste que prova a
        /// reconexão gira em círculos.
        var rounds: [String: [[String]]]
        /// Verbo → quanto o servidor **segura** a resposta antes de escrever.
        ///
        /// Zero (a ausência) responde na hora, como sempre. Existe para o
        /// único tipo de afirmação que precisa de um comando ainda em voo
        /// quando o seguinte chega: a da fila do ator. Com resposta instantânea
        /// os dois comandos nunca se sobrepõem, e "esperou a vez" e "não
        /// precisou esperar" ficam indistinguíveis.
        var atrasos: [String: TimeInterval]

        init(
            greeting: String = "* OK [CAPABILITY IMAP4rev1 STARTTLS] OkamiUNI falso pronto",
            replies: [String: [String]],
            rounds: [String: [[String]]] = [:],
            atrasos: [String: TimeInterval] = [:]
        ) {
            self.greeting = greeting
            self.replies = replies
            self.rounds = rounds
            self.atrasos = atrasos
        }
    }

    /// A chave que separa o `FETCH` de corpo do `FETCH` de envelope.
    ///
    /// Os dois usam o mesmo verbo (`UID FETCH`), e um roteiro com uma chave só
    /// não consegue dar respostas diferentes a eles. Quando esta chave existe
    /// no roteiro, ela vale para os comandos que pedem `BODY.PEEK`; quando não
    /// existe, tudo continua caindo em `UID FETCH`, como nos testes da Task 10.
    static let chaveDeCorpo = "UID FETCH BODY"

    /// O `UID FETCH` que pede **só o cabeçalho `Message-ID`** — o do espelho da
    /// triagem, que precisa da identidade da mensagem para saber se ela já está
    /// no destino. Ele também casa `BODY.PEEK`, então esta chave é conferida
    /// **antes** de `chaveDeCorpo`: sem isso, um roteiro que responde corpo
    /// responderia corpo à pergunta do cabeçalho.
    static let chaveDeCabecalho = "UID FETCH HEADER"

    /// O `UID SEARCH HEADER Message-ID …` — "esta mensagem já está nesta
    /// pasta?". Separado do `UID SEARCH UID …` ("este UID ainda está aqui?")
    /// pela mesma razão que o cabeçalho é separado do corpo: são duas
    /// perguntas diferentes, e o teste da idempotência do mover precisa
    /// responder coisas diferentes às duas.
    static let chaveDeBuscaPorHeader = "UID SEARCH HEADER"

    /// O `UID FETCH … (UID FLAGS)` do delta — só as bandeiras, sem envelope.
    ///
    /// Separado do `UID FETCH` de envelope porque um ciclo de sincronização
    /// manda os dois, na mesma conexão, um atrás do outro: um roteiro com uma
    /// chave só responderia envelope à pergunta das bandeiras. O casamento é
    /// pelo parêntese **exato** (`(UID FLAGS)`) e não por "contém FLAGS" — o
    /// comando de envelope é `(UID FLAGS INTERNALDATE ENVELOPE)`, e um
    /// casamento largo devolveria bandeiras onde se esperava envelope.
    static let chaveDeBandeiras = "UID FETCH FLAGS"

    private let group: MultiThreadedEventLoopGroup
    private var channel: (any Channel)?
    private let script: Script
    private let lock = NSLock()
    private var received: [String] = []
    /// Quantas vezes cada chave de roteiro já foi servida. Vive no servidor, e
    /// não no handler, para sobreviver a uma reconexão.
    private var rodadas: [String: Int] = [:]

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
                // `syncOperations`: os handlers do NIO não são `Sendable`, e a
                // variante assíncrona exige que sejam. Já estamos na event loop.
                canal.eventLoop.makeCompletedFuture {
                    try canal.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(CRLFLineDecoder()),
                        ScriptedHandler(
                            script: script, registrar: registrar, proximaRodada: proximaRodada
                        ),
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
        private let proximaRodada: @Sendable (String) -> Int

        init(
            script: Script,
            registrar: @escaping @Sendable (String) -> Void,
            proximaRodada: @escaping @Sendable (String) -> Int
        ) {
            self.script = script
            self.registrar = registrar
            self.proximaRodada = proximaRodada
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

            // `DONE` é a única linha do protocolo **sem tag**: ela fecha o
            // `IDLE` que está aberto, e a resposta tagueada que o servidor
            // manda em seguida leva a tag daquele `IDLE`. Lê-la como qualquer
            // outro comando faria a primeira palavra (`DONE`) virar tag, e o
            // cliente esperaria para sempre por uma resposta que nunca casaria.
            if linha.uppercased() == "DONE" {
                responde(context, chave: "DONE", verbo: "DONE", tag: tagDoIdle ?? "*")
                tagDoIdle = nil
                return
            }

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

            // A chave mais específica primeiro: o `FETCH` de corpo pede
            // `BODY.PEEK`, e o roteiro pode querer respondê-lo de outro jeito.
            let chave: String = {
                let maiusculo = resto.uppercased()
                func escrita(_ chave: String) -> Bool {
                    script.replies[chave] != nil || script.rounds[chave] != nil
                }
                // `HEADER.FIELDS (MESSAGE-ID)`, e não "contém HEADER.FIELDS":
                // o `FETCH` de corpo passou a pedir os cabeçalhos de conteúdo
                // na mesma linha, e um casamento largo o mandaria para a
                // resposta de identidade do espelho — corpo respondido com
                // `Message-ID`, sem erro nenhum na tela.
                if verbo == "UID FETCH", maiusculo.contains("HEADER.FIELDS (MESSAGE-ID)"),
                   escrita(FakeImapServer.chaveDeCabecalho) {
                    return FakeImapServer.chaveDeCabecalho
                }
                if verbo == "UID FETCH", maiusculo.contains("(UID FLAGS)"),
                   escrita(FakeImapServer.chaveDeBandeiras) {
                    return FakeImapServer.chaveDeBandeiras
                }
                if verbo == "UID FETCH", maiusculo.contains("BODY.PEEK"),
                   escrita(FakeImapServer.chaveDeCorpo) {
                    return FakeImapServer.chaveDeCorpo
                }
                if verbo == "UID SEARCH", maiusculo.contains("HEADER"),
                   escrita(FakeImapServer.chaveDeBuscaPorHeader) {
                    return FakeImapServer.chaveDeBuscaPorHeader
                }
                return verbo
            }()

            // A tag do `IDLE` fica guardada para o `DONE` que vem depois.
            if verbo == "IDLE" { tagDoIdle = tag }
            responde(context, chave: chave, verbo: verbo, tag: tag)
        }

        /// A tag do `IDLE` em voo nesta conexão. Vive no handler, e não no
        /// servidor, porque o `IDLE` é por conexão — e só é tocada na event
        /// loop do canal.
        private var tagDoIdle: String?

        private func responde(
            _ context: ChannelHandlerContext, chave: String, verbo: String, tag: String
        ) {
            let linhasDoRoteiro: [String]? = {
                if let rodadas = script.rounds[chave], !rodadas.isEmpty {
                    return rodadas[min(proximaRodada(chave), rodadas.count - 1)]
                }
                return script.replies[chave]
            }()
            guard let linhas = linhasDoRoteiro else {
                escreve(context, "\(tag) BAD comando fora do roteiro: \(verbo)")
                return
            }
            // Sem `@Sendable`: o `scheduleTask` desta event loop roda no mesmo
            // fio, e é por isso que o `context` pode atravessar.
            let escrever: () -> Void = { [weak self] in
                guard let self else { return }
                for modelo in linhas {
                    let texto = modelo.replacingOccurrences(of: "TAG ", with: "\(tag) ")
                    // `CRU:` manda os bytes **sem** terminador. É o que deixa um
                    // teste encenar meia linha no fio — o caso que a fronteira do
                    // STARTTLS precisa enxergar e que nenhuma linha inteira produz.
                    if texto.hasPrefix("CRU:") {
                        self.escreve(context, String(texto.dropFirst(4)), terminador: false)
                    } else {
                        self.escreve(context, texto)
                    }
                }
                if verbo == "LOGOUT" { context.close(promise: nil) }
            }
            // O atraso corre na própria event loop do canal: nada bloqueia, e a
            // ordem das escritas continua sendo a do roteiro.
            if let atraso = script.atrasos[chave], atraso > 0 {
                context.eventLoop.scheduleTask(
                    in: .nanoseconds(Int64(atraso * 1_000_000_000)), escrever
                )
            } else {
                escrever()
            }
        }

        private func escreve(
            _ context: ChannelHandlerContext, _ texto: String, terminador: Bool = true
        ) {
            var buffer = context.channel.allocator.buffer(capacity: texto.utf8.count + 2)
            buffer.writeString(texto)
            if terminador { buffer.writeString("\r\n") }
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
