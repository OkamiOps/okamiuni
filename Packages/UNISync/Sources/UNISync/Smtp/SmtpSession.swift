import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import UNICore
import os

/// Uma sessão SMTP de submissão, sobre NIO.
///
/// Ator, cadeado explícito e teto em toda espera — as três decisões são
/// herdadas do `ImapSession` porque os dois protocolos têm a mesma forma
/// (comando, resposta, um por vez) e os mesmos jeitos de travar. O comentário
/// longo daquele arquivo vale palavra por palavra aqui: ator **não** é fila, e
/// dois comandos em voo na mesma conexão embaralham as respostas.
///
/// ## O que ela promete
///
/// **A senha nunca sai em claro.** Numa porta de submissão (587) a conexão
/// nasce em claro e sobe com `STARTTLS` **antes** do `AUTH` — e se o servidor
/// não anunciar `STARTTLS`, ou recusá-lo, a sessão morre com `.tls` em vez de
/// seguir. Numa porta 465 o TLS é o primeiro byte. Não há caminho, nem com
/// bandeira, que mande credencial por um socket em claro fora do `@testable`.
public actor SmtpSession {
    /// O mesmo teto do IMAP, pela mesma razão: servidor que aceita a conexão e
    /// emudece é caso comum, e sem teto o envio some numa espera eterna.
    static let tetoPadrao = TimeAmount.seconds(30)

    private let channel: any Channel
    private let handler: SmtpChannelHandler
    private let teto: TimeAmount
    private let host: String
    private var closed = false
    private var ocupado = false
    private var fila: [CheckedContinuation<Void, Never>] = []
    /// As linhas do último EHLO: quem oferece o quê. Elas mudam depois do
    /// `STARTTLS` (é por isso que o EHLO é repetido), e é a lista de depois que
    /// vale para escolher o mecanismo de autenticação.
    private var capacidades: [String] = []

    private static let log = Logger(subsystem: "com.okamiops.okamiuni", category: "SmtpSession")

    private init(channel: any Channel, handler: SmtpChannelHandler, teto: TimeAmount, host: String) {
        self.channel = channel
        self.handler = handler
        self.teto = teto
        self.host = host
    }

    /// Conecta, sobe o TLS que a porta pedir, e apresenta-se.
    ///
    /// Único `connect` público, e sem alavanca de insegurança — a mesma
    /// promessa do `ImapSession.connect`: quem quiser falar em claro precisa do
    /// `@testable`.
    public static func connect(
        endpoint: SmtpEndpoint, group: any EventLoopGroup
    ) async throws -> SmtpSession {
        try await connect(endpoint: endpoint, group: group, allowInsecure: false)
    }

    static func connect(
        endpoint: SmtpEndpoint,
        group: any EventLoopGroup,
        allowInsecure: Bool,
        teto: TimeAmount = SmtpSession.tetoPadrao
    ) async throws -> SmtpSession {
        let handler = SmtpChannelHandler()
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(20))
            .channelInitializer { canal in
                canal.eventLoop.makeCompletedFuture {
                    var handlers: [any ChannelHandler] = []
                    if endpoint.security == .tls {
                        handlers.append(try Self.tlsHandler(host: endpoint.host))
                    }
                    handlers.append(ByteToMessageHandler(SmtpLineDecoder()))
                    handlers.append(handler)
                    try canal.pipeline.syncOperations.addHandlers(handlers)
                }
            }

        let canal: any Channel
        do {
            canal = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch let erro as SyncError {
            throw erro
        } catch {
            throw SmtpChannelHandler.traduz(error, redeSePreciso: "\(endpoint.host):\(endpoint.port)")
        }

        let sessao = SmtpSession(channel: canal, handler: handler, teto: teto, host: endpoint.host)
        do {
            // A saudação: `220` é o servidor pronto. `554` é "não falo com
            // você" — recusa que o `guard` abaixo pega antes de qualquer
            // comando sair.
            let saudacao = try await handler.waitForGreeting(on: canal, teto: teto)
            guard saudacao.code == 220 else { throw SmtpWire.erro(saudacao) }
            try await sessao.apresenta()
            if endpoint.security == .startTLS, !allowInsecure {
                try await sessao.upgradeToTLS(host: endpoint.host)
            }
        } catch {
            await sessao.encerraCom()
            throw error
        }
        return sessao
    }

    // MARK: O cadeado

    private func adquire() async {
        guard ocupado else {
            ocupado = true
            return
        }
        await withCheckedContinuation { continuation in fila.append(continuation) }
    }

    private func libera() {
        if fila.isEmpty { ocupado = false } else { fila.removeFirst().resume() }
    }

    // MARK: TLS

    /// Sobe para TLS antes de qualquer credencial. Recusa **não** é degradação.
    ///
    /// A ausência do anúncio conta como recusa, e é o ponto que mais importa:
    /// um atacante no meio consegue tirar a linha `250-STARTTLS` do EHLO em
    /// claro (é o ataque de *stripping*, e ele é o motivo de a submissão em 587
    /// exigir TLS). Seguir sem TLS porque "o servidor não ofereceu" seria
    /// mandar a senha da pessoa exatamente para quem tirou a linha.
    private func upgradeToTLS(host: String) async throws {
        guard SmtpWire.anuncia("STARTTLS", em: capacidades) else {
            throw SyncError.tls("O servidor de envio não oferece STARTTLS na porta de submissão.")
        }
        let resposta = try await manda(SmtpWire.startTLS())
        guard resposta.code == 220 else {
            throw SyncError.tls("O servidor recusou STARTTLS: \(resposta.text)")
        }
        do {
            let canal = channel
            let manipulador = handler
            try await canal.eventLoop.submit {
                // A mesma defesa em profundidade do IMAP: nada pode estar
                // bufferizado quando o túnel sobe, senão bytes emendados por
                // alguém no meio seriam lidos como se tivessem vindo de dentro
                // dele. Conferir e inserir no mesmo bloco da event loop é o que
                // não deixa janela entre as duas coisas.
                try manipulador.verificaFronteiraLimpa()
                try canal.pipeline.syncOperations.addHandler(
                    Self.tlsHandler(host: host), position: .first
                )
            }.get()
        } catch {
            throw error as? SyncError ?? SyncError.tls(String(describing: error))
        }
        // O EHLO é repetido **de dentro do túnel**: a lista de capacidades em
        // claro não vale nada (foi ela que o atacante teria editado), e é a
        // segunda que decide o mecanismo de autenticação.
        try await apresenta()
    }

    private static func tlsHandler(host: String) throws -> NIOSSLClientHandler {
        let contexto = try NIOSSLContext(configuration: .makeClientConfiguration())
        if ImapEndpoint.ehIPLiteral(host) {
            log.warning("""
                TLS para \(host, privacy: .private) sem verificação de nome do certificado: \
                o host é um endereço literal, e SNI não aceita IP.
                """)
        }
        return try NIOSSLClientHandler(context: contexto, serverHostname: ImapSession.sni(host))
    }

    // MARK: Comandos

    /// `EHLO`, guardando o que o servidor anuncia.
    ///
    /// Sem `HELO` de reserva: um servidor de submissão que não fala ESMTP não
    /// tem `STARTTLS` nem `AUTH`, e mandar credencial para ele é o que esta
    /// sessão promete nunca fazer.
    private func apresenta() async throws {
        let resposta = try await manda(SmtpWire.ehlo(host: nomeDeQuemFala()))
        guard resposta.code == 250 else { throw SmtpWire.erro(resposta) }
        capacidades = resposta.lines
    }

    /// O nome que vai no EHLO. Um literal, e não o nome da máquina da pessoa:
    /// o `hostname` de um Mac costuma ser o nome que ela deu ao computador
    /// ("MacBook da Marina"), e ele viajaria em claro para todo servidor de
    /// envio. Nenhum provedor de submissão exige mais que um nome sintático.
    private func nomeDeQuemFala() -> String { "[127.0.0.1]" }

    /// Autentica. `AUTH PLAIN` quando o servidor o anuncia; `AUTH LOGIN` como
    /// reserva, que é o que provedores antigos ainda são os únicos a oferecer.
    public func login(user: String, password: String) async throws {
        let mecanismos = SmtpWire.mecanismos(em: capacidades)
        if mecanismos.isEmpty || mecanismos.contains("PLAIN") {
            let resposta = try await manda(SmtpWire.authPlain(user: user, password: password))
            guard resposta.code == 235 else { throw SmtpWire.erro(resposta) }
            return
        }
        guard mecanismos.contains("LOGIN") else {
            throw SyncError.autenticacao
        }
        let pedeUsuario = try await manda(SmtpWire.authLogin())
        guard pedeUsuario.code == 334 else { throw SmtpWire.erro(pedeUsuario) }
        let pedeSenha = try await manda(SmtpWire.base64(user))
        guard pedeSenha.code == 334 else { throw SmtpWire.erro(pedeSenha) }
        let fim = try await manda(SmtpWire.base64(password))
        guard fim.code == 235 else { throw SmtpWire.erro(fim) }
    }

    /// O envelope e o corpo: `MAIL FROM`, um `RCPT TO` por destinatário,
    /// `DATA`.
    ///
    /// **Um `RCPT TO` recusado derruba o envio inteiro**, e é uma escolha:
    /// seguir com os que sobraram entregaria a mensagem pela metade sem que
    /// ninguém soubesse quem ficou de fora. O erro traz o endereço, que é o que
    /// a pessoa precisa para corrigir.
    public func send(from: String, recipients: [String], raw: String) async throws {
        guard !recipients.isEmpty else {
            throw SyncError.resposta("A mensagem não tem destinatário nenhum.")
        }
        let remetente = try await manda(SmtpWire.mailFrom(from))
        guard remetente.code == 250 else { throw SmtpWire.erro(remetente) }
        for destinatario in recipients {
            let resposta = try await manda(SmtpWire.rcptTo(destinatario))
            // 251 é "não é meu, encaminho" — aceito, e portanto sucesso.
            guard resposta.code == 250 || resposta.code == 251 else {
                // O endereço entra na frase: "550 usuário desconhecido" sem
                // dizer **qual** endereço deixa a pessoa conferindo os cinco
                // destinatários um a um.
                switch SmtpWire.erro(resposta) {
                case .recusado(let detalhe): throw SyncError.recusado("\(destinatario): \(detalhe)")
                case .transitorio(let detalhe): throw SyncError.transitorio("\(destinatario): \(detalhe)")
                case let outro: throw outro
                }
            }
        }
        let abertura = try await manda(SmtpWire.data())
        guard abertura.code == 354 else { throw SmtpWire.erro(abertura) }
        // O corpo vai **sem** terminador extra: `dotStuffed` já fecha com o
        // ponto sozinho, e um CRLF a mais deixaria uma linha em branco depois
        // do fim do `DATA` que o servidor leria como comando vazio.
        let entregue = try await manda(SmtpWire.dotStuffed(raw), terminador: false)
        guard entregue.code == 250 else { throw SmtpWire.erro(entregue) }
    }

    /// Sai e fecha. Idempotente e sem lançar, como o `logout` do IMAP: sair já
    /// é o caminho de saída.
    public func quit() async {
        guard !closed else { return }
        closed = true
        _ = try? await manda(SmtpWire.quit(), jaFechando: true)
        try? await channel.close()
    }

    private func encerraCom() async {
        closed = true
        try? await channel.close()
    }

    @discardableResult
    private func manda(
        _ comando: String, terminador: Bool = true, jaFechando: Bool = false
    ) async throws -> SmtpWire.Reply {
        guard !closed || jaFechando else {
            throw SyncError.rede("A sessão SMTP já foi encerrada.")
        }
        await adquire()
        defer { libera() }
        var buffer = channel.allocator.buffer(capacity: comando.utf8.count + 2)
        buffer.writeString(comando)
        if terminador { buffer.writeString("\r\n") }
        return try await handler.send(buffer, on: channel, teto: teto)
    }
}

/// Corta o fluxo em linhas de protocolo. CRLF, com teto.
///
/// Próprio, e não o decodificador do IMAP: aquele entende os literais `{n}` do
/// IMAP, e uma resposta SMTP que por acaso terminasse em `{12}` viraria uma
/// espera por doze bytes que nunca chegam. Protocolos diferentes, gramáticas
/// diferentes.
struct SmtpLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    /// Uma linha de resposta SMTP cabe em 512 bytes pelo RFC; 8 KiB é folga
    /// para servidores prolixos e ainda é teto. Sem teto, quem estiver do outro
    /// lado escolhe quanta memória o processo gasta.
    static let tetoDaLinha = 8 * 1024

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let visao = buffer.readableBytesView
        guard let fim = visao.firstIndex(of: UInt8(ascii: "\n")) else {
            guard visao.count <= Self.tetoDaLinha else {
                throw SyncError.resposta(
                    "O servidor de envio mandou uma linha maior que \(Self.tetoDaLinha) bytes sem terminador."
                )
            }
            return .needMoreData
        }
        let comprimento = visao.distance(from: visao.startIndex, to: fim)
        var linha = buffer.readSlice(length: comprimento)!
        buffer.moveReaderIndex(forwardBy: 1)
        if linha.readableBytesView.last == UInt8(ascii: "\r") {
            linha = linha.readSlice(length: linha.readableBytes - 1)!
        }
        context.fireChannelRead(wrapInboundOut(linha))
        return .continue
    }
}

/// O handler que junta as linhas até a que fecha a resposta.
///
/// Irmão do `ImapChannelHandler`, e mais simples por um motivo: no SMTP não há
/// tag. Quem diz que a resposta acabou é o quarto byte da linha — espaço fecha,
/// hífen continua. Ver `SmtpWire.ehFinal`.
final class SmtpChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let lock = NSLock()
    private var greeting: CheckedContinuation<SmtpWire.Reply, any Error>?
    private var greetingReply: SmtpWire.Reply?
    private var greetingFailure: (any Error)?
    private var pending: CheckedContinuation<SmtpWire.Reply, any Error>?
    private var linhas: [String] = []
    private var codigo: Int?
    private var falhaFinal: (any Error)?
    private var relogio: Scheduled<Void>?
    private var cancelamentoPendente = false
    /// Linhas que chegaram sem ninguém ter pedido nada — o sintoma de bytes
    /// injetados antes de o TLS subir.
    private var linhasOrfas = 0

    func waitForGreeting(on channel: any Channel, teto: TimeAmount) async throws -> SmtpWire.Reply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pronta = greetingReply {
                    lock.unlock()
                    continuation.resume(returning: pronta)
                    return
                }
                if let erro = greetingFailure {
                    lock.unlock()
                    continuation.resume(throwing: erro)
                    return
                }
                if consomeCancelamento() {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                greeting = continuation
                agenda(teto, on: channel, motivo: "A saudação do servidor de envio não chegou")
                lock.unlock()
            }
        } onCancel: {
            cancela()
        }
    }

    func send(
        _ buffer: ByteBuffer, on channel: any Channel, teto: TimeAmount
    ) async throws -> SmtpWire.Reply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let erro = falhaFinal {
                    lock.unlock()
                    continuation.resume(throwing: erro)
                    return
                }
                // Cinto e suspensório do cadeado do ator, como no IMAP:
                // sobrescrever `pending` vazaria a continuation anterior.
                if pending != nil {
                    lock.unlock()
                    continuation.resume(throwing: SyncError.rede(
                        "Já havia um comando SMTP em voo nesta conexão."
                    ))
                    return
                }
                if consomeCancelamento() {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending = continuation
                linhas = []
                codigo = nil
                agenda(teto, on: channel, motivo: "O servidor de envio não respondeu")
                lock.unlock()
                channel.writeAndFlush(buffer).whenFailure { erro in
                    self.falha(Self.traduz(erro))
                }
            }
        } onCancel: {
            cancela()
        }
    }

    /// Lança se houver resto de conversa em claro na hora de ligar o TLS.
    func verificaFronteiraLimpa() throws {
        lock.lock()
        let sujo = !linhas.isEmpty || linhasOrfas > 0 || pending != nil
        lock.unlock()
        if sujo {
            throw SyncError.tls(
                "O servidor mandou dados depois do 220 do STARTTLS e antes do TLS subir — a conexão foi descartada."
            )
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let linha = (buffer.readString(length: buffer.readableBytes) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !linha.isEmpty else { return }

        lock.lock()
        guard let numero = SmtpWire.codigo(linha) else {
            lock.unlock()
            falha(.resposta("O servidor de envio respondeu sem código: \(linha)"))
            context.close(promise: nil)
            return
        }
        linhas.append(SmtpWire.texto(linha))
        codigo = numero
        guard SmtpWire.ehFinal(linha) else {
            lock.unlock()
            return
        }
        let resposta = SmtpWire.Reply(code: numero, text: SmtpWire.texto(linha), lines: linhas)
        let saudacao = greeting
        let comando = pending
        greeting = nil
        pending = nil
        linhas = []
        codigo = nil
        // **A saudação que chega antes de alguém esperá-la fica guardada.**
        // Ela é escrita pelo servidor assim que o socket abre, e quem a espera
        // só se registra depois de o `connect` voltar — numa máquina ocupada, a
        // ordem se inverte. Sem a prateleira, a linha era contada como órfã e
        // descartada, e a conexão morria de teto de tempo culpando um servidor
        // que tinha respondido na hora. (O `ImapChannelHandler` já guardava a
        // dele; este não, e a suíte inteira rodando em paralelo foi o que
        // revelou a diferença.)
        var guardouSaudacao = false
        if saudacao != nil || (comando == nil && greetingReply == nil) {
            greetingReply = resposta
            guardouSaudacao = true
        }
        // Resposta que ninguém pediu, com a saudação já entregue, é o sintoma
        // de bytes injetados — o que a fronteira do STARTTLS confere.
        if saudacao == nil, comando == nil, !guardouSaudacao { linhasOrfas += 1 }
        desagenda()
        lock.unlock()
        saudacao?.resume(returning: resposta)
        comando?.resume(returning: resposta)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        falha(Self.traduz(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        falha(SyncError.rede("O servidor de envio fechou a conexão."))
    }

    /// Erro do NIOSSL é erro de **TLS**, e não de rede — a mesma tradução do
    /// IMAP, e pela mesma razão: as duas frases mandam a pessoa fazer coisas
    /// diferentes, e só uma delas resolve.
    static func traduz(_ erro: any Error, redeSePreciso prefixo: String? = nil) -> SyncError {
        if let erro = erro as? SyncError { return erro }
        let tipo = String(reflecting: type(of: erro))
        if erro is NIOSSLError || erro is NIOSSLExtraError || tipo.hasPrefix("NIOSSL.") {
            return .tls(String(describing: erro))
        }
        if let prefixo { return .rede("\(prefixo) — \(erro.localizedDescription)") }
        return .rede(erro.localizedDescription)
    }

    private func agenda(_ teto: TimeAmount, on channel: any Channel, motivo: String) {
        let segundos = Double(teto.nanoseconds) / 1_000_000_000
        relogio = channel.eventLoop.scheduleTask(in: teto) { [weak self] in
            self?.falha(.rede(String(format: "%@ em %.1fs.", motivo, segundos)))
        }
    }

    private func desagenda() {
        relogio?.cancel()
        relogio = nil
    }

    private func consomeCancelamento() -> Bool {
        if cancelamentoPendente {
            cancelamentoPendente = false
            return true
        }
        return Task.isCancelled
    }

    private func cancela() {
        lock.lock()
        let saudacao = greeting
        let comando = pending
        greeting = nil
        pending = nil
        desagenda()
        if saudacao == nil, comando == nil { cancelamentoPendente = true }
        lock.unlock()
        saudacao?.resume(throwing: CancellationError())
        comando?.resume(throwing: CancellationError())
    }

    private func falha(_ erro: SyncError) {
        lock.lock()
        let saudacao = greeting
        let comando = pending
        greeting = nil
        pending = nil
        desagenda()
        if falhaFinal == nil { falhaFinal = erro }
        if greetingReply == nil, greetingFailure == nil { greetingFailure = erro }
        lock.unlock()
        saudacao?.resume(throwing: erro)
        comando?.resume(throwing: erro)
    }
}
