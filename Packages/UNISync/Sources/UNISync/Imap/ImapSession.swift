import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import UNICore

/// Uma sessão IMAP, sobre NIO.
///
/// Ator porque uma conexão IMAP é estritamente sequencial: um comando por vez,
/// a resposta tagueada fecha o comando, e o próximo só entra depois. Dois
/// comandos em voo na mesma conexão embaralham as respostas untagged — e as
/// untagged são justamente o conteúdo (`FETCH`, `LIST`, `SEARCH`).
///
/// **Ator não é fila.** Todo `await` solta a isolação, e dois chamadores podem
/// entrar no mesmo método enquanto o primeiro espera a rede. Por isso a
/// sequencialidade tem um cadeado explícito (`adquire`/`libera`) e não a
/// aparência de um: sem ele, o segundo comando sobrescrevia a continuation do
/// primeiro, que vazava — a sessão travava para sempre e o runtime só
/// resmungava `SWIFT TASK CONTINUATION MISUSE`.
public actor ImapSession {
    /// Quanto tempo uma espera pode durar antes de virar erro.
    ///
    /// Existe porque servidor que aceita a conexão e emudece é caso comum
    /// (balanceador que aceita e não repassa, provedor sob carga), e sem teto
    /// a espera é eterna: a carga inicial some e o app parece só estar devagar.
    static let tetoPadrao = TimeAmount.seconds(15)

    private let channel: any Channel
    private let handler: ImapChannelHandler
    private let teto: TimeAmount
    private var tagCounter = 0
    private var closed = false

    // O cadeado do "um comando por vez".
    private var ocupado = false
    private var fila: [CheckedContinuation<Void, Never>] = []

    private init(channel: any Channel, handler: ImapChannelHandler, teto: TimeAmount) {
        self.channel = channel
        self.handler = handler
        self.teto = teto
    }

    /// Conecta, sobe o TLS que o endpoint pedir, e espera a saudação.
    ///
    /// Este é o único `connect` público, e ele **não** tem como pedir conexão
    /// insegura. A promessa "produção sempre TLS" é do compilador: quem quiser
    /// falar em claro precisa do `@testable`.
    public static func connect(
        endpoint: ImapEndpoint,
        group: any EventLoopGroup
    ) async throws -> ImapSession {
        try await connect(endpoint: endpoint, group: group, allowInsecure: false)
    }

    /// A versão com as duas alavancas de teste.
    ///
    /// `allowInsecure` existe **para o teste**, e só para ele: o servidor IMAP
    /// falso roda dentro do processo do teste, em `127.0.0.1`, sem certificado
    /// nenhum, e exigir TLS ali significaria gerar e confiar num certificado só
    /// para provar coisas que não são sobre TLS. `teto` é a mesma história: o
    /// teste que prova o timeout não pode levar quinze segundos.
    static func connect(
        endpoint: ImapEndpoint,
        group: any EventLoopGroup,
        allowInsecure: Bool,
        teto: TimeAmount = ImapSession.tetoPadrao
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
                    // O quadro é da biblioteca, e não do nosso
                    // `CRLFLineDecoder`: o literal `{n}` é contado em bytes e
                    // tem CRLF dentro, e cortar por linha o partiria em
                    // pedaços que o parser leria como respostas soltas. O teto
                    // é o mesmo dos nossos cortes por linha — 64 KiB —, e ele
                    // vale para a linha, não para o literal, que atravessa em
                    // pedaços sem encher o buffer.
                    handlers.append(ByteToMessageHandler(
                        FrameDecoder(frameSizeLimit: CRLFLineDecoder.tetoDaLinha)
                    ))
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
            throw ImapChannelHandler.traduz(error, redeSePreciso: "\(endpoint.host):\(endpoint.port)")
        }

        // A saudação chega sozinha, sem tag. Esperá-la aqui é o que garante
        // que o primeiro comando não seja escrito antes de o servidor estar de
        // pé — e é onde um servidor que responde `* BYE` na cara já é recusado.
        // É também onde o handshake do TLS implícito falha: ele estoura
        // enquanto ninguém pediu nada, e a saudação é quem está esperando.
        let saudacao: String
        do {
            saudacao = try await handler.waitForGreeting(on: canal, teto: teto)
        } catch {
            try? await canal.close()
            throw error
        }
        guard !saudacao.uppercased().contains("BYE") else {
            try? await canal.close()
            throw SyncError.servidor(codigo: 0, mensagem: saudacao)
        }

        let sessao = ImapSession(channel: canal, handler: handler, teto: teto)
        if endpoint.security == .startTLS, !allowInsecure {
            try await sessao.upgradeToTLS(host: endpoint.host)
        }
        return sessao
    }

    // MARK: O cadeado

    /// Espera a vez. Quem chega enquanto outro comando está em voo entra na
    /// fila em vez de atropelar a continuation dele.
    private func adquire() async {
        guard ocupado else {
            ocupado = true
            return
        }
        await withCheckedContinuation { continuation in
            fila.append(continuation)
        }
    }

    private func libera() {
        if fila.isEmpty {
            ocupado = false
        } else {
            fila.removeFirst().resume()
        }
    }

    // MARK: TLS

    /// Sobe a conexão em claro para TLS, antes de qualquer credencial.
    ///
    /// Recusa não é degradação: se o servidor diz `NO` ao `STARTTLS`, a sessão
    /// morre com `.tls`. Seguir em claro seria mandar a senha da pessoa em
    /// texto puro no primeiro provedor que resolvesse não anunciar `STARTTLS`,
    /// e ela não teria como saber.
    private func upgradeToTLS(host: String) async throws {
        let resultado: ImapCommandResult
        do {
            let tag = proximaTag()
            resultado = try await send(comando: ImapWire.startTLS(tag: tag), tag: tag)
        } catch {
            await encerraCom()
            throw error
        }
        guard resultado.status == .ok else {
            await encerraCom()
            throw SyncError.tls("O servidor recusou STARTTLS: \(resultado.text)")
        }
        do {
            // Antes do decodificador de linhas: a partir daqui os bytes do
            // socket são do TLS, e só saem em claro depois deste handler.
            //
            // O `verificaFronteira` é a defesa em profundidade contra injeção
            // no comando de texto puro (a família do CVE-2011-0411): um
            // atacante no meio pode emendar bytes logo depois do `OK` do
            // STARTTLS, e eles seriam lidos como se tivessem vindo de dentro do
            // túnel. Nada pode estar bufferizado quando o TLS entra — e a
            // conferência acontece **na event loop**, no mesmo bloco que insere
            // o handler, para não haver janela entre conferir e inserir.
            let canal = channel
            let handler = handler
            try await canal.eventLoop.submit {
                try handler.verificaFronteiraLimpa()
                try canal.pipeline.syncOperations.addHandler(
                    Self.tlsHandler(host: host), position: .first
                )
            }.get()
        } catch {
            await encerraCom()
            throw error as? SyncError ?? SyncError.tls(String(describing: error))
        }
    }

    private func encerraCom() async {
        closed = true
        try? await channel.close()
    }

    /// O handler de TLS do cliente.
    private static func tlsHandler(host: String) throws -> NIOSSLClientHandler {
        let contexto = try NIOSSLContext(configuration: .makeClientConfiguration())
        return try NIOSSLClientHandler(context: contexto, serverHostname: Self.sni(host))
    }

    /// O nome que vai no SNI, ou `nil` quando o host é um endereço literal.
    ///
    /// SNI não aceita IP, e passar um faria o `NIOSSLClientHandler` lançar
    /// antes mesmo de tocar a rede. O preço é honesto e precisa ser dito:
    /// **sem `serverHostname`, a verificação de nome do certificado não
    /// acontece** — o NIOSSL continua validando a cadeia contra as âncoras do
    /// sistema, mas ninguém confere se o certificado é *daquele* servidor.
    /// Conectar a IMAP por IP literal é, por isso, mais fraco do que conectar
    /// por nome; a interface de contas deve pedir nome de host.
    static func sni(_ host: String) -> String? {
        if host.contains(":") { return nil } // IPv6 literal
        let partes = host.split(separator: ".", omittingEmptySubsequences: false)
        if partes.count == 4, partes.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return nil // IPv4 literal
        }
        return host
    }

    // MARK: Comandos

    private func proximaTag() -> String {
        tagCounter += 1
        return ImapWire.tag(tagCounter)
    }

    /// Manda um comando já montado e devolve a resposta tagueada **crua**, sem
    /// julgar `OK`/`NO`/`BAD`. É o que o `STARTTLS` usa, onde `NO` tem
    /// significado próprio, e o que o `LOGOUT` usa, que sai com a sessão já
    /// marcada como fechada.
    private func send(comando: String, tag: String) async throws -> ImapCommandResult {
        await adquire()
        defer { libera() }

        var buffer = channel.allocator.buffer(capacity: comando.utf8.count + 2)
        buffer.writeString(comando)
        buffer.writeString("\r\n")

        return try await handler.send(buffer, tag: tag, on: channel, teto: teto)
    }

    /// O próximo comando, e a resposta tagueada dele, já traduzida em erro
    /// quando não é `OK`.
    ///
    /// `internal` e não `private` porque a Task 10 chama daqui de dentro do
    /// mesmo ator, e porque os testes de `ImapSession` afirmam o texto exato
    /// que sai. O closure é chamado **uma vez só**: chamá-lo duas vezes (uma
    /// para espiar o comando, outra para mandar) transformaria qualquer
    /// construção com efeito colateral num bug silencioso.
    @discardableResult
    func run(_ build: (String) -> String) async throws -> ImapCommandResult {
        guard !closed else { throw SyncError.rede("A sessão IMAP já foi encerrada.") }
        let tag = proximaTag()
        let comando = build(tag)
        let resultado = try await send(comando: comando, tag: tag)
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

    /// As pastas do servidor, com o papel já resolvido.
    public func folders() async throws -> [ImapFolder] {
        let resultado = try await run { ImapWire.list(tag: $0) }
        return ImapWire.folders(from: resultado.untagged)
    }

    /// Seleciona a pasta e devolve `UIDVALIDITY`, `UIDNEXT` e o total.
    ///
    /// Lança quando o servidor não manda `UIDVALIDITY`: sem ele não existe
    /// identidade estável para UID nenhum, e seguir em frente gravaria
    /// mensagens que o Marco 3 não conseguiria casar de volta.
    public func select(_ folder: ImapFolder) async throws -> ImapMailboxStatus {
        let resultado = try await run { ImapWire.select(tag: $0, mailbox: folder.name) }
        guard let status = ImapWire.status(from: resultado.untagged) else {
            throw SyncError.resposta("O servidor selecionou \(folder.name) sem informar UIDVALIDITY.")
        }
        return status
    }

    /// Os UIDs da pasta selecionada desde uma data.
    public func uids(since: Date, calendar: Calendar) async throws -> [Int64] {
        let resultado = try await run {
            ImapWire.uidSearchSince(tag: $0, date: since, calendar: calendar)
        }
        return ImapWire.uids(from: resultado.untagged)
    }

    /// Envelopes em lotes de `ImapWire.fetchBatchSize`.
    ///
    /// O laço é cancelável: `Task.checkCancellation()` a cada lote é o que faz
    /// "fechar o app no meio da carga" parar em segundos em vez de segurar a
    /// conexão até a caixa acabar.
    public func envelopes(uids: [Int64]) async throws -> [ImapEnvelope] {
        var todos: [ImapEnvelope] = []
        for lote in stride(from: 0, to: uids.count, by: ImapWire.fetchBatchSize) {
            try Task.checkCancellation()
            let fatia = Array(uids[lote..<min(lote + ImapWire.fetchBatchSize, uids.count)])
            let resultado = try await run { ImapWire.uidFetchEnvelopes(tag: $0, uids: fatia) }
            todos.append(contentsOf: ImapWire.envelopes(from: resultado.untagged))
        }
        return todos
    }

    /// O corpo em texto de uma mensagem, por demanda.
    public func bodyText(uid: Int64) async throws -> [String] {
        let resultado = try await run { ImapWire.uidFetchBody(tag: $0, uid: uid) }
        return ImapWire.bodyText(from: resultado.untagged, uid: uid)
    }

    /// Sai e fecha. Idempotente: sair duas vezes é o mesmo estado.
    ///
    /// Não lança, e é de propósito: encerrar já é o caminho de saída, e um erro
    /// aqui não muda nada que alguém possa fazer.
    ///
    /// `closed` sobe **antes** do `await`: um segundo `logout()` durante a
    /// espera do primeiro mandaria um `LOGOUT` numa conexão que já está saindo.
    /// Por isso o `LOGOUT` desce por `send`, e não por `run` — é o único
    /// comando que tem o direito de sair com a sessão já marcada como fechada.
    public func logout() async {
        guard !closed else { return }
        closed = true
        let tag = proximaTag()
        _ = try? await send(comando: ImapWire.logout(tag: tag), tag: tag)
        try? await channel.close()
    }
}

/// A resposta tagueada de um comando, com as linhas untagged que vieram antes.
struct ImapCommandResult: Sendable {
    enum Status: Sendable { case ok, no, bad }
    let status: Status
    /// O texto depois de `OK`/`NO`/`BAD`.
    let text: String
    /// As linhas `*` que chegaram enquanto o comando estava em voo, já
    /// traduzidas por `ImapResponseAdapter`. É onde moram `LIST`, `SEARCH`,
    /// `FETCH`, `EXISTS` e os códigos de `SELECT`.
    let untagged: [ImapWire.Untagged]
}

/// Corta o fluxo de bytes em linhas de protocolo.
///
/// O `swift-nio` desta versão não traz nenhum decodificador de linhas — o
/// `LineBasedFrameDecoder` mora no `swift-nio-extras`, que não é dependência
/// deste marco. São poucas linhas nossas em vez de um quarto pacote, e elas
/// cortam por CRLF, que é o que o RFC 3501 manda.
///
/// `decodeLast` **não** é implementado de propósito: o padrão do NIO drena o
/// que dá e descarta o resto sem `\n`, e descartar é o comportamento seguro.
/// Emitir o rabo truncado como se fosse linha inteira faria um `A0001 OK` (que
/// o servidor ainda ia continuar escrevendo) virar resposta válida.
struct CRLFLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    /// Teto de uma linha de protocolo.
    ///
    /// Sem teto, um servidor (ou alguém no meio) que despeje bytes sem `\n`
    /// faz o `ByteToMessageHandler` crescer o buffer até a memória acabar —
    /// negação de serviço com uma conexão só. 64 KiB é folgado para as linhas
    /// que o IMAP manda de fato; conteúdo grande vem em literal `{n}`, que a
    /// Task 10 lê com o decodificador da biblioteca.
    static let tetoDaLinha = 64 * 1024

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let visao = buffer.readableBytesView
        guard let fim = visao.firstIndex(of: UInt8(ascii: "\n")) else {
            if buffer.readableBytes > Self.tetoDaLinha {
                throw SyncError.resposta(
                    "O servidor IMAP mandou uma linha maior que \(Self.tetoDaLinha) bytes sem terminador."
                )
            }
            return .needMoreData
        }
        var linha = buffer.readSlice(length: fim - visao.startIndex)!
        buffer.moveReaderIndex(forwardBy: 1) // o `\n`
        if linha.readableBytesView.last == UInt8(ascii: "\r") {
            linha = linha.readSlice(length: linha.readableBytes - 1)!
        }
        context.fireChannelRead(wrapInboundOut(linha))
        return .continue
    }
}

/// O handler que junta as linhas até a resposta tagueada.
///
/// Uma requisição em voo por vez, garantida pelo cadeado do ator acima — e
/// conferida aqui de novo, porque garantia que só existe no chamador é a que
/// some no primeiro refactor. O `continuation` é o que transforma o callback do
/// NIO em `await`.
final class ImapChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = FramingResult
    typealias OutboundOut = ByteBuffer

    private let lock = NSLock()
    private var greeting: CheckedContinuation<String, any Error>?
    private var greetingLine: String?
    private var greetingFailure: (any Error)?
    private var pendingTag: String?
    private var pending: CheckedContinuation<ImapCommandResult, any Error>?
    private var collected: [ImapWire.Untagged] = []
    /// A costura dos quadros da biblioteca em linhas lógicas. Só é tocada na
    /// event loop — em `channelRead` e no bloco que sobe o TLS —, e por isso
    /// não entra no `lock`.
    private var costura = ImapFrameJoiner()
    private var falhaFinal: (any Error)?
    private var relogio: Scheduled<Void>?
    private var cancelamentoPendente = false
    /// Linhas que chegaram sem ninguém ter pedido nada. Fora da saudação, é
    /// exatamente o sintoma de dado injetado antes do TLS.
    private var linhasOrfas = 0

    // MARK: Espera da saudação

    func waitForGreeting(on channel: any Channel, teto: TimeAmount) async throws -> String {
        try await withTaskCancellationHandler {
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
                if consomeCancelamento() {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                greeting = continuation
                agenda(teto, on: channel, motivo: "A saudação do servidor IMAP não chegou")
                lock.unlock()
            }
        } onCancel: {
            cancela()
        }
    }

    // MARK: Envio

    func send(
        _ buffer: ByteBuffer, tag: String, on channel: any Channel, teto: TimeAmount
    ) async throws -> ImapCommandResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                // Uma conexão que já caiu não ganha mais um comando pendurado:
                // a falha que derrubou a anterior vale para esta também.
                if let erro = falhaFinal {
                    lock.unlock()
                    continuation.resume(throwing: erro)
                    return
                }
                // Cinto e suspensório do cadeado do ator: sobrescrever `pending`
                // vazaria a continuation do comando anterior, e a sessão nunca
                // mais responderia. Recusar é ruidoso; vazar é mudo.
                if pending != nil {
                    lock.unlock()
                    continuation.resume(throwing: SyncError.rede(
                        "Já havia um comando IMAP em voo nesta conexão."
                    ))
                    return
                }
                if consomeCancelamento() {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingTag = tag
                pending = continuation
                collected = []
                agenda(teto, on: channel, motivo: "O servidor IMAP não respondeu a \(tag)")
                lock.unlock()
                channel.writeAndFlush(buffer).whenFailure { erro in
                    self.falha(Self.traduz(erro))
                }
            }
        } onCancel: {
            cancela()
        }
    }

    // MARK: Fronteira do STARTTLS

    /// Lança se houver qualquer resto de conversa em claro na hora de ligar o
    /// TLS. Chamada **na event loop**, junto com a inserção do handler.
    func verificaFronteiraLimpa() throws {
        lock.lock()
        // `costura.montando` entra na conta: uma linha lógica pela metade é
        // conversa em claro pendurada tanto quanto uma linha inteira.
        let sujo = !collected.isEmpty || linhasOrfas > 0 || pending != nil || costura.montando
        lock.unlock()
        if sujo {
            throw SyncError.tls(
                "O servidor mandou dados depois do OK do STARTTLS e antes do TLS subir — a conexão foi descartada."
            )
        }
    }

    // MARK: Leitura

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let quadro = unwrapInboundIn(data)
        let linha: String
        do {
            guard let completa = try costura.junta(quadro) else { return }
            linha = completa
        } catch {
            falha(Self.traduz(error))
            context.close(promise: nil)
            return
        }

        lock.lock()
        if let continuation = greeting {
            greeting = nil
            greetingLine = linha
            desagenda()
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
            linhasOrfas += 1
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
            desagenda()
            lock.unlock()
            continuation?.resume(returning: resultado)
        } else {
            collected.append(ImapResponseAdapter.untagged(fromLogicalLine: linha))
            lock.unlock()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        falha(Self.traduz(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        falha(SyncError.rede("O servidor IMAP fechou a conexão."))
    }

    // MARK: Erros, tempo e cancelamento

    /// Erro do NIOSSL é erro de **TLS**, e não de rede.
    ///
    /// A diferença não é cosmética: `.rede` manda a pessoa conferir a conexão,
    /// e `.tls` manda conferir a porta e a forma de TLS da conta — que é o que
    /// de fato resolve quando o handshake falha. O `catch NIOSSLError` no
    /// `connect` só via erro de **construção** do handler; o handshake falha
    /// depois, e chega por `errorCaught`.
    static func traduz(_ erro: any Error, redeSePreciso prefixo: String? = nil) -> SyncError {
        if let erro = erro as? SyncError { return erro }
        let tipo = String(reflecting: type(of: erro))
        if erro is NIOSSLError || erro is NIOSSLExtraError || tipo.hasPrefix("NIOSSL.") {
            return .tls(String(describing: erro))
        }
        if let prefixo {
            return .rede("\(prefixo) — \(erro.localizedDescription)")
        }
        return .rede(erro.localizedDescription)
    }

    /// Marca um teto de tempo para a espera corrente. Chamada com o `lock`.
    private func agenda(_ teto: TimeAmount, on channel: any Channel, motivo: String) {
        let segundos = Double(teto.nanoseconds) / 1_000_000_000
        relogio = channel.eventLoop.scheduleTask(in: teto) { [weak self] in
            self?.falha(.rede(String(format: "%@ em %.1fs.", motivo, segundos)))
        }
    }

    /// Cancela o teto. Chamada com o `lock`.
    private func desagenda() {
        relogio?.cancel()
        relogio = nil
    }

    /// `true` se o cancelamento chegou antes de a espera ser registrada.
    /// Chamada com o `lock`.
    private func consomeCancelamento() -> Bool {
        if cancelamentoPendente {
            cancelamentoPendente = false
            return true
        }
        return Task.isCancelled
    }

    /// `Task.cancel()` acorda quem espera. Sem isto, cancelar uma sincronização
    /// não interrompia nada — o `withCheckedThrowingContinuation` puro ignora
    /// cancelamento, e a tarefa "cancelada" continuava pendurada na rede.
    private func cancela() {
        lock.lock()
        let saudacao = greeting
        let comando = pending
        greeting = nil
        pending = nil
        pendingTag = nil
        desagenda()
        if saudacao == nil, comando == nil { cancelamentoPendente = true }
        lock.unlock()
        saudacao?.resume(throwing: CancellationError())
        comando?.resume(throwing: CancellationError())
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
        desagenda()
        if falhaFinal == nil { falhaFinal = erro }
        if greetingLine == nil, greetingFailure == nil { greetingFailure = erro }
        lock.unlock()
        saudacao?.resume(throwing: erro)
        comando?.resume(throwing: erro)
    }
}
