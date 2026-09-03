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
        /// Quais caixas **existem** neste servidor.
        ///
        /// `nil` — o padrão — desliga a encenação inteira e o servidor continua
        /// respondendo do roteiro por verbo, como sempre fez: nenhum teste
        /// antigo muda de caminho.
        ///
        /// Com um conjunto, o servidor passa a ter a única memória que o
        /// `[TRYCREATE]` do RFC 2180 exige para ser encenado de verdade: um
        /// `SELECT` ou um `UID COPY` para uma caixa de fora do conjunto é
        /// recusado com o código que o protocolo manda, e um `CREATE` a
        /// acrescenta — de modo que a **segunda** tentativa passa. Sem esta
        /// memória, "criou e conseguiu mover" e "nunca precisou criar" ficam
        /// indistinguíveis: o roteiro estático responderia `OK` ao `COPY` de
        /// qualquer jeito.
        var mailboxes: Set<String>?

        init(
            greeting: String = "* OK [CAPABILITY IMAP4rev1 STARTTLS] OkamiUNI falso pronto",
            replies: [String: [String]],
            rounds: [String: [[String]]] = [:],
            atrasos: [String: TimeInterval] = [:],
            mailboxes: Set<String>? = nil
        ) {
            self.greeting = greeting
            self.replies = replies
            self.rounds = rounds
            self.atrasos = atrasos
            self.mailboxes = mailboxes
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
    /// As caixas que existem agora. Vive no servidor, e não no handler, pela
    /// mesma razão das rodadas: um `CREATE` feito numa conexão continua valendo
    /// na seguinte — que é o que o mundo real faz, e o que o teste da fila
    /// (tentar de novo depois do recuo) precisa que seja verdade.
    private var caixas: Set<String>?

    init(script: Script) {
        self.script = script
        caixas = script.mailboxes
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// As caixas que existem no servidor agora — o que o teste afirma depois de
    /// um `CREATE` automático.
    var mailboxes: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return caixas ?? []
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
        /// `nil` quando o roteiro não encena caixas; `true`/`false` quando
        /// encena. Três valores, e não dois, porque "não sei de caixa nenhuma"
        /// e "esta caixa não existe" são coisas diferentes.
        let existe: @Sendable (String) -> Bool? = { [weak self] nome in
            guard let self else { return nil }
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.caixas.map { $0.contains(nome) }
        }
        let cria: @Sendable (String) -> Void = { [weak self] nome in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.caixas != nil { self.caixas?.insert(nome) }
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
                            script: script, registrar: registrar, proximaRodada: proximaRodada,
                            existeCaixa: existe, criaCaixa: cria
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
        private let existeCaixa: @Sendable (String) -> Bool?
        private let criaCaixa: @Sendable (String) -> Void

        init(
            script: Script,
            registrar: @escaping @Sendable (String) -> Void,
            proximaRodada: @escaping @Sendable (String) -> Int,
            existeCaixa: @escaping @Sendable (String) -> Bool?,
            criaCaixa: @escaping @Sendable (String) -> Void
        ) {
            self.script = script
            self.registrar = registrar
            self.proximaRodada = proximaRodada
            self.existeCaixa = existeCaixa
            self.criaCaixa = criaCaixa
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
                // `BODY.PEEK[TEXT]`, e não "contém BODY.PEEK": o `FETCH` de
                // **envelope** passou a pedir os cabeçalhos de lista na mesma
                // linha (ver `ImapWire.camposDeLista`), e um casamento largo o
                // mandaria para a resposta de corpo — a carga inteira vindo
                // como um corpo só, sem erro nenhum na tela.
                if verbo == "UID FETCH", maiusculo.contains("BODY.PEEK[TEXT]"),
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

            // As caixas que existem, quando o roteiro as encena. Vem **antes**
            // do roteiro por verbo: um `SELECT` de caixa inexistente é recusado
            // mesmo que o roteiro tenha uma resposta de `SELECT` pronta — que é
            // o ponto, já que todo roteiro tem.
            if let resposta = respostaDeCaixa(verbo: verbo, resto: resto, tag: tag) {
                escreve(context, resposta)
                return
            }
            responde(context, chave: chave, verbo: verbo, tag: tag)
        }

        /// A resposta que a existência (ou não) da caixa impõe, ou `nil` para
        /// "deixe o roteiro responder".
        ///
        /// Os três verbos que olham para a caixa por nome são os três que
        /// importam ao `[TRYCREATE]`: `SELECT` (o espelho seleciona o destino
        /// antes de copiar, para perguntar se a mensagem já está lá), `UID COPY`
        /// (a cópia em si) e `CREATE` (a saída).
        private func respostaDeCaixa(verbo: String, resto: String, tag: String) -> String? {
            switch verbo {
            case "CREATE":
                guard let nome = Self.caixaDoComando(resto),
                      existeCaixa(nome) != nil else { return nil }
                criaCaixa(nome)
                return "\(tag) OK CREATE completo"
            case "SELECT":
                guard let nome = Self.caixaDoComando(resto),
                      existeCaixa(nome) == false else { return nil }
                // O código do RFC 5530, que é o que servidores modernos mandam
                // no `SELECT` de uma caixa que não existe.
                return "\(tag) NO [NONEXISTENT] Mailbox does not exist"
            case "UID COPY":
                guard let nome = Self.caixaDoComando(resto),
                      existeCaixa(nome) == false else { return nil }
                // E o do RFC 3501/2180 no `COPY`: "crie e tente de novo".
                return "\(tag) NO [TRYCREATE] Mailbox does not exist"
            default:
                return nil
            }
        }

        /// O nome da caixa de um comando: o **último** item da linha, sem as
        /// aspas. Vale para os três (`SELECT "X"`, `CREATE "X"`,
        /// `UID COPY 9001 "X"`), que é exatamente o formato que o `ImapWire`
        /// monta.
        private static func caixaDoComando(_ resto: String) -> String? {
            guard let ultimo = resto.split(separator: " ").last else { return nil }
            let cru = String(ultimo)
            guard cru.hasPrefix("\""), cru.hasSuffix("\""), cru.count >= 2 else { return cru }
            return String(cru.dropFirst().dropLast())
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
