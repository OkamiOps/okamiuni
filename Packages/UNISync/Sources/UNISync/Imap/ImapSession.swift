import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import UNICore
import os

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
                    // O decodificador entrega **linha lógica**: a linha até o
                    // CRLF com os literais `{n}` já juntos. O handler recebe
                    // resposta inteira ou nada.
                    handlers.append(ByteToMessageHandler(
                        CRLFLineDecoder(pendencia: handler.pendencia)
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
    ///
    /// Host em IP literal **continua permitido** — servidor interno acessível só
    /// por endereço existe, e recusá-lo trocaria um enfraquecimento por uma
    /// impossibilidade. O que ele deixa de ser é **silencioso**: a perda da
    /// verificação de nome vai para o log aqui, e a janela de Contas mostra a
    /// nota ao lado do campo (`AddAccountForm`, pela mesma
    /// `ImapEndpoint.ehIPLiteral`).
    private static func tlsHandler(host: String) throws -> NIOSSLClientHandler {
        let contexto = try NIOSSLContext(configuration: .makeClientConfiguration())
        if ImapEndpoint.ehIPLiteral(host) {
            log.warning("""
                TLS para \(host, privacy: .private) sem verificação de nome do certificado: \
                o host é um endereço literal, e SNI não aceita IP. A cadeia continua validada \
                contra as âncoras do sistema, mas ninguém confere se o certificado é deste servidor.
                """)
        }
        return try NIOSSLClientHandler(context: contexto, serverHostname: Self.sni(host))
    }

    private static let log = Logger(subsystem: "com.okamiops.okamiuni", category: "ImapSession")

    /// O nome que vai no SNI, ou `nil` quando o host é um endereço literal.
    ///
    /// SNI não aceita IP, e passar um faria o `NIOSSLClientHandler` lançar
    /// antes mesmo de tocar a rede. O preço é honesto e precisa ser dito:
    /// **sem `serverHostname`, a verificação de nome do certificado não
    /// acontece** — o NIOSSL continua validando a cadeia contra as âncoras do
    /// sistema, mas ninguém confere se o certificado é *daquele* servidor.
    /// Conectar a IMAP por IP literal é, por isso, mais fraco do que conectar
    /// por nome.
    ///
    /// A decisão de quem é literal mora em `ImapEndpoint.ehIPLiteral`, e não
    /// aqui: quem avisa a pessoa (a janela de Contas) e quem perde a verificação
    /// (esta função) têm de responder a mesma coisa, senão o aviso aparece onde
    /// não há perda, ou — pior — não aparece onde há.
    static func sni(_ host: String) -> String? {
        ImapEndpoint.ehIPLiteral(host) ? nil : host
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

    // MARK: A escrita — o espelho da triagem
    //
    // Todos entram pelo mesmo `run(_:)` do idioma que já existe aqui: o
    // comando é montado puro no `ImapWire`, a resposta tagueada vira `OK` ou
    // erro, e nenhum deles precisa de estado novo no ator.

    /// Põe ou tira bandeiras dos UIDs da pasta selecionada.
    public func store(uids: [Int64], flags: [String], add: Bool) async throws {
        guard !uids.isEmpty else { return }
        _ = try await run { ImapWire.uidStore(tag: $0, uids: uids, flags: flags, add: add) }
    }

    /// Copia UIDs da pasta selecionada para outra.
    public func copy(uids: [Int64], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        _ = try await run { ImapWire.uidCopy(tag: $0, uids: uids, mailbox: mailbox) }
    }

    /// Remove de vez as mensagens marcadas `\Deleted` na pasta selecionada.
    public func expunge() async throws {
        _ = try await run { ImapWire.expunge(tag: $0) }
    }

    /// Marca a caixa selecionada **inteira** como `\Deleted`. O par disto é
    /// `expunge()`, e só os dois juntos esvaziam a lixeira.
    public func markAllDeleted() async throws {
        _ = try await run { ImapWire.storeAllDeleted(tag: $0) }
    }

    /// Cria uma pasta. **Não lança quando ela já existe**, e isso é a metade
    /// IMAP do "criada no primeiro uso": o servidor responde `NO
    /// [ALREADYEXISTS]` (ou só um `NO` com o texto), e tratar isso como falha
    /// pararia a fila da conta por causa de uma pasta que está exatamente como
    /// precisamos que esteja.
    public func create(mailbox: String) async throws {
        do {
            _ = try await run { ImapWire.create(tag: $0, mailbox: mailbox) }
        } catch SyncError.servidor(_, let mensagem) {
            let dobrado = mensagem.uppercased()
            guard dobrado.contains("ALREADYEXISTS") || dobrado.contains("ALREADY EXISTS")
                || dobrado.contains("EXISTS")
            else { throw SyncError.servidor(codigo: 0, mensagem: mensagem) }
        }
    }

    /// Grava uma mensagem inteira numa pasta — é assim que a cópia do que foi
    /// enviado aparece em Enviadas numa conta IMAP.
    ///
    /// Exige `LITERAL+` no servidor, e quem chama confere antes
    /// (`capabilities()`): ver a nota de `ImapWire.append`. `\Seen` porque a
    /// pessoa acabou de escrever a mensagem — uma cópia da própria mensagem
    /// chegando "não lida" é um contador que sobe sem nada novo ter chegado.
    ///
    /// Devolve o `APPENDUID` quando o servidor o manda — ver
    /// `ImapWire.appendUID(from:)`: é o endereço da cópia, e é o que permite
    /// gravá-la localmente com o mesmo id que a leitura da pasta daria.
    @discardableResult
    public func append(
        mailbox: String, flags: [String] = ["\\Seen"], raw: String
    ) async throws -> ImapWire.AppendUID? {
        let resultado = try await run {
            ImapWire.append(tag: $0, mailbox: mailbox, flags: flags, raw: raw)
        }
        return ImapWire.appendUID(from: resultado.text)
    }

    /// Quais destes UIDs ainda estão na pasta selecionada.
    public func existingUIDs(_ uids: [Int64]) async throws -> [Int64] {
        guard !uids.isEmpty else { return [] }
        let resultado = try await run { ImapWire.uidSearchUID(tag: $0, uids: uids) }
        return ImapWire.uids(from: resultado.untagged)
    }

    /// Os UIDs da pasta selecionada cujo `Message-ID` é este. Vazio significa
    /// "esta mensagem não está aqui" — é a pergunta que torna o mover
    /// idempotente.
    public func uids(messageID: String) async throws -> [Int64] {
        let resultado = try await run { ImapWire.uidSearchMessageID(tag: $0, messageID: messageID) }
        return ImapWire.uids(from: resultado.untagged)
    }

    /// O `Message-ID` de um UID da pasta selecionada, ou `nil` se a mensagem
    /// não estiver mais lá (ou não tiver o cabeçalho — mensagem sem
    /// `Message-ID` existe, e é malformada).
    public func messageID(uid: Int64) async throws -> String? {
        let resultado = try await run { ImapWire.uidFetchMessageID(tag: $0, uid: uid) }
        for resposta in resultado.untagged {
            guard case .fetch(let linha) = resposta, linha.uid == uid,
                  let cabecalho = linha.messageIDHeader else { continue }
            return ImapWire.messageID(fromHeader: cabecalho)
        }
        return nil
    }

    // MARK: A sincronização contínua

    /// O que o servidor anuncia saber fazer, em maiúsculas.
    ///
    /// Perguntado **depois do login**, por quem chama: a lista muda com a
    /// autenticação, e servidor que só oferece `IDLE` a sessão autenticada
    /// existe. Falhar aqui não é fatal para quem chama — sem a lista, o
    /// caminho honesto é o polling, e é isso que o coordenador faz.
    public func capabilities() async throws -> Set<String> {
        let resultado = try await run { ImapWire.capability(tag: $0) }
        return ImapWire.capabilities(from: resultado.untagged)
    }

    /// Os UIDs da pasta selecionada a partir de um piso, **filtrados**.
    ///
    /// O filtro é a parte que importa. `UID SEARCH UID 42:*` sobre uma caixa
    /// cujo maior UID é 30 devolve `30` — o RFC manda o servidor tratar `*`
    /// como o maior UID existente, e o intervalo passa a ser `30:42`. Sem o
    /// filtro, uma caixa parada anunciaria a mesma mensagem como nova em todo
    /// ciclo, para sempre, e o delta gravaria por cima dela sem parar.
    public func uids(from piso: Int64) async throws -> [Int64] {
        let resultado = try await run { ImapWire.uidSearchFrom(tag: $0, uid: piso) }
        return ImapWire.uids(from: resultado.untagged).filter { $0 >= piso }
    }

    /// As bandeiras dos UIDs pedidos, em lotes.
    ///
    /// **O que não volta é o que sumiu**: o dicionário devolvido não tem chave
    /// para o UID expurgado, e é assim que o delta descobre o apagamento feito
    /// noutro cliente. Por isso o lote é `ImapWire.fetchBatchSize` e não a
    /// lista inteira — um `UID FETCH` de milhares de UIDs numa linha só é o
    /// tipo de comando que servidor recusa com `BAD`.
    public func flags(uids: [Int64]) async throws -> [Int64: [String]] {
        var todas: [Int64: [String]] = [:]
        for lote in stride(from: 0, to: uids.count, by: ImapWire.fetchBatchSize) {
            try Task.checkCancellation()
            let fatia = Array(uids[lote..<min(lote + ImapWire.fetchBatchSize, uids.count)])
            let resultado = try await run { ImapWire.uidFetchFlags(tag: $0, uids: fatia) }
            todas.merge(ImapWire.flags(from: resultado.untagged)) { _, novo in novo }
        }
        return todas
    }

    /// Fica em `IDLE` até o servidor dizer que algo mudou, até o teto, ou até o
    /// cancelamento. Devolve `true` quando foi **atividade** que acordou.
    ///
    /// ## Por que ele não é um `run` como os outros
    ///
    /// Todo comando daqui manda uma linha e espera a resposta tagueada. O
    /// `IDLE` (RFC 2177) quebra isso de propósito: o servidor responde `+
    /// idling`, despeja untagged enquanto quiser, e **só** fecha o comando
    /// depois de o cliente escrever `DONE`. Quem espera a resposta tagueada,
    /// então, não pode ser quem decide quando parar — são duas esperas
    /// simultâneas na mesma conexão, e é por isso que o comando viaja numa
    /// `Task` própria enquanto esta função espera o sinal.
    ///
    /// ## O que ele promete
    ///
    /// **O `DONE` sai sempre.** Acordado por atividade, por teto ou por
    /// cancelamento, o caminho de saída é o mesmo: escrever `DONE` e esperar o
    /// `OK`. Sair sem ele deixaria a conexão num estado em que nenhum comando
    /// seguinte é aceito — e o delta que viria em seguida morreria de teto de
    /// tempo culpando o servidor.
    ///
    /// O teto **existe e é obrigatório**: o RFC recomenda reengatar em menos de
    /// 29 minutos, porque é isso que impede o servidor (e todo NAT no caminho)
    /// de considerar a conexão morta. Quem chama passa 25.
    public func idle(limite: TimeAmount) async throws -> Bool {
        guard !closed else { throw SyncError.rede("A sessão IMAP já foi encerrada.") }
        await adquire()
        defer { libera() }

        let tag = proximaTag()
        handler.armaIdle()

        var abertura = channel.allocator.buffer(capacity: 16)
        abertura.writeString(ImapWire.idle(tag: tag))
        abertura.writeString("\r\n")
        // O teto do comando é o do IDLE **mais folga**: quem termina o comando
        // é o `DONE` que esta função escreve, e ele só é escrito depois de o
        // limite passar. Um teto igual ao limite seria uma corrida perdida.
        let canal = channel
        let manipulador = handler
        let tetoDoComando = TimeAmount.nanoseconds(limite.nanoseconds + teto.nanoseconds)
        let comando = Task {
            try await manipulador.send(abertura, tag: tag, on: canal, teto: tetoDoComando)
        }

        let acordou = await handler.esperaIdle(limite: limite, on: channel.eventLoop)

        var fim = channel.allocator.buffer(capacity: 8)
        fim.writeString(ImapWire.done())
        fim.writeString("\r\n")
        channel.writeAndFlush(fim, promise: nil)

        let resultado = try await comando.value
        guard resultado.status == .ok else {
            throw SyncError.servidor(codigo: 0, mensagem: resultado.text)
        }
        // Cancelamento continua sendo cancelamento: o `DONE` saiu e o comando
        // fechou, e só então o laço de fora tem o direito de morrer.
        try Task.checkCancellation()
        return acordou
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

/// Quantos bytes o decodificador está segurando por não terem virado linha
/// ainda.
///
/// Existe por causa do STARTTLS: meia linha parada dentro do decodificador é
/// conversa em claro que o túnel cobriria sem ninguém ver. O `ByteToMessageHandler`
/// não conta nada disso para fora, então o decodificador anota aqui e o handler
/// lê — os dois na event loop, nunca fora dela.
final class PendenciaDeBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var quantos = 0

    var bytes: Int {
        get { lock.lock(); defer { lock.unlock() }; return quantos }
        set { lock.lock(); quantos = newValue; lock.unlock() }
    }
}

/// Corta o fluxo de bytes em **linhas lógicas** de protocolo.
///
/// Uma linha lógica é a resposta inteira: a linha até o CRLF **mais** os
/// literais `{n}` que ela abrir, com o conteúdo deles junto. Isso é mais do que
/// cortar por CRLF, e a diferença não é acadêmica — o corpo de qualquer
/// mensagem chega em literal e tem CRLF dentro, então quem corta por linha
/// entrega o corpo picado em pedaços que o parser lê como respostas soltas.
///
/// **Por que não o `FrameDecoder` do `swift-nio-imap`:** ele foi usado na
/// primeira versão desta tarefa e falha em dois pontos que a carga inicial
/// atravessa todo dia. Um literal de tamanho zero — `BODY[TEXT] {0}`, que é o
/// que um convite ou uma mensagem só-com-anexo devolve — faz o `FramingParser`
/// devolver `.incomplete` e **segurar no buffer dele** o resto da linha e a
/// resposta tagueada seguinte, que só saem quando outros bytes chegarem; o
/// comando morre de teto de tempo culpando o servidor. E o conteúdo do literal
/// sai em pedaços arbitrários, de modo que um caractere multibyte cortado ao
/// meio vira dois `U+FFFD` — o "ç" some e a contagem de bytes do literal
/// escorrega junto. Os dois foram reproduzidos contra a 0.4.0 antes de escrever
/// isto. Aqui, a linha lógica sai inteira ou não sai, e o conteúdo é
/// decodificado uma vez só, no fim.
///
/// `decodeLast` **não** é implementado de propósito: o padrão do NIO drena o
/// que dá e descarta o resto sem `\n`, e descartar é o comportamento seguro.
/// Emitir o rabo truncado como se fosse linha inteira faria um `A0001 OK` (que
/// o servidor ainda ia continuar escrevendo) virar resposta válida.
struct CRLFLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    /// Teto da parte **de linha** de uma resposta.
    ///
    /// Sem teto, um servidor (ou alguém no meio) que despeje bytes sem `\n`
    /// faz o `ByteToMessageHandler` crescer o buffer até a memória acabar —
    /// negação de serviço com uma conexão só. 64 KiB é folgado para as linhas
    /// que o IMAP manda de fato.
    static let tetoDaLinha = 64 * 1024

    /// Teto do conteúdo de um literal.
    ///
    /// O corpo de uma mensagem é grande de propósito, então o teto de linha não
    /// serve aqui — mas "sem teto" também não: o tamanho vem declarado pelo
    /// servidor, e aceitar `{9999999999}` é entregar a memória do processo a
    /// quem estiver do outro lado. Oito mebibytes cobrem qualquer corpo de texto
    /// real com folga, e a recusa é imediata, na leitura do cabeçalho, antes de
    /// reservar byte nenhum.
    static let tetoDoLiteral = 8 * 1024 * 1024

    /// Teto da linha lógica **inteira** — e este nunca rearma.
    ///
    /// Os outros dois são por parte: `tetoDaLinha` mede só a parte-de-linha
    /// corrente e recomeça do zero depois de cada literal; `tetoDoLiteral` mede
    /// um literal de cada vez. Nenhum dos dois olha a **soma**, e uma linha
    /// lógica só acaba num `\n` que não abre literal — então um servidor que
    /// encadeia literais indefinidamente
    ///
    ///     * 1 FETCH (UID 1 X {8388608}\r\n<8 MiB> Y {8388608}\r\n<8 MiB> …
    ///
    /// fazia o `ByteToMessageHandler` crescer sem limite, sem emitir nada — e
    /// sem emitir nada nem o teto de tempo dispara, porque os bytes continuam
    /// chegando. Medido: 40 MiB absorvidos em 40 ciclos, `readInbound` devolvendo
    /// `nil`, nenhum erro. O número era escolha do atacante.
    ///
    /// O dobro do teto de literal cobre qualquer FETCH real com folga: a maior
    /// resposta legítima é um envelope (bytes) mais **um** corpo (8 MiB no
    /// máximo, pelo teto acima). Duas vezes isso já é resposta que ninguém manda.
    static let tetoDaLinhaLogica = 2 * tetoDoLiteral

    let pendencia: PendenciaDeBytes

    init(pendencia: PendenciaDeBytes = PendenciaDeBytes()) {
        self.pendencia = pendencia
    }

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // `varrido` é quanto da linha lógica corrente já foi conferido; ele
        // sobrevive entre chamadas dentro da mesma linha, e é o que impede
        // reprocessar o corpo inteiro a cada pedaço que chega da rede.
        while true {
            let visao = buffer.readableBytesView
            let base = visao.startIndex

            if restanteDoLiteral > 0 {
                let disponivel = visao.count - varrido
                guard disponivel > 0 else { return pare(&buffer) }
                let pega = min(disponivel, restanteDoLiteral)
                varrido += pega
                restanteDoLiteral -= pega
                try confereTetoDaLinhaLogica()
                if restanteDoLiteral > 0 { return pare(&buffer) }
                // O literal acabou: daqui para a frente é parte-de-linha de
                // novo, e a contagem do teto recomeça do zero.
                inicioDaParteCorrente = varrido
                continue
            }

            guard let fim = visao[visao.index(base, offsetBy: varrido)...]
                .firstIndex(of: UInt8(ascii: "\n"))
            else {
                varrido = visao.count
                // **Só a parte-de-linha** conta para o teto. Somar os bytes do
                // literal aqui faria um corpo de 68 KiB estourar um teto que
                // não é dele — e só quando a leitura do socket terminasse no
                // fim do literal, ou seja, uma falha intermitente que depende
                // da segmentação TCP e culpa o servidor. Também deixaria o teto
                // de literal inalcançável: o de linha dispararia antes.
                if varrido - inicioDaParteCorrente > Self.tetoDaLinha {
                    throw SyncError.resposta(
                        "O servidor IMAP mandou uma linha maior que \(Self.tetoDaLinha) bytes sem terminador."
                    )
                }
                // ...mas a **soma** conta, e esta conta nunca recomeça.
                try confereTetoDaLinhaLogica()
                return pare(&buffer)
            }

            let depoisDoLF = visao.distance(from: base, to: fim) + 1

            // A linha só acaba aqui se ela **não** terminar abrindo um literal.
            // Tamanho zero não abre nada: o conteúdo é vazio e o resto da linha
            // vem logo em seguida, na mesma varredura. É exatamente o caso em
            // que o framer da biblioteca prendia a resposta tagueada.
            if let tamanho = try Self.tamanhoDoLiteral(visao, ate: depoisDoLF - 1) {
                guard tamanho <= Self.tetoDoLiteral else {
                    // O tamanho e o UID entram na mensagem de propósito: quem
                    // carrega (Task 13) registra a falha desta mensagem e segue
                    // com as outras, e um log sem o UID não diz qual pular.
                    let uid = Self.uidDaParte(visao, de: inicioDaParteCorrente, ate: depoisDoLF)
                    throw SyncError.resposta(
                        "O servidor IMAP anunciou um literal de \(tamanho) bytes"
                        + (uid.map { " para o UID \($0)" } ?? "")
                        + ", acima do teto de \(Self.tetoDoLiteral)."
                    )
                }
                // O literal que **cabe** sozinho pode não caber na soma: recusar
                // aqui, no cabeçalho, é recusar antes de reservar byte nenhum.
                guard depoisDoLF + tamanho <= Self.tetoDaLinhaLogica else {
                    throw SyncError.resposta(
                        "O servidor IMAP encadeou literais além de \(Self.tetoDaLinhaLogica) bytes "
                        + "numa linha lógica só — a conexão foi descartada."
                    )
                }
                restanteDoLiteral = tamanho
                varrido = depoisDoLF
                inicioDaParteCorrente = depoisDoLF
                continue
            }

            var linha = buffer.readSlice(length: depoisDoLF - 1)!
            buffer.moveReaderIndex(forwardBy: 1) // o `\n`
            if linha.readableBytesView.last == UInt8(ascii: "\r") {
                linha = linha.readSlice(length: linha.readableBytes - 1)!
            }
            varrido = 0
            inicioDaParteCorrente = 0
            pendencia.bytes = buffer.readableBytes
            context.fireChannelRead(wrapInboundOut(linha))
            return .continue
        }
    }

    /// O tamanho do literal que a linha abre no fim, ou `nil` se ela não abre
    /// nenhum. `fimExclusivo` é o índice do `\n`.
    ///
    /// A leitura é para trás, em bytes: `\r\n` é um grafema só para o Swift, e
    /// o cabeçalho é ASCII puro.
    ///
    /// Lança quando o cabeçalho **é** um cabeçalho mas o tamanho é absurdo.
    /// Devolver `nil` ali seria seguir lendo a linha como se o literal não
    /// existisse, e o que vem depois é conteúdo sendo interpretado como
    /// protocolo — dessincronia silenciosa, que é o pior jeito de errar.
    static func tamanhoDoLiteral(_ visao: ByteBufferView, ate fimExclusivo: Int) throws -> Int? {
        let base = visao.startIndex
        var i = fimExclusivo
        func byte(_ posicao: Int) -> UInt8? {
            guard posicao >= 0, posicao < visao.count else { return nil }
            return visao[visao.index(base, offsetBy: posicao)]
        }
        if byte(i - 1) == UInt8(ascii: "\r") { i -= 1 }
        guard byte(i - 1) == UInt8(ascii: "}") else { return nil }
        i -= 1
        if let anterior = byte(i - 1), anterior == UInt8(ascii: "+") || anterior == UInt8(ascii: "-") {
            i -= 1 // LITERAL+ / LITERAL-
        }
        var digitos: [UInt8] = []
        while let digito = byte(i - 1), digito >= UInt8(ascii: "0"), digito <= UInt8(ascii: "9") {
            digitos.append(digito)
            i -= 1
            // Além disto não é número, é despejo: pare de ler e deixe o `{`
            // faltando decidir que não era cabeçalho nenhum.
            if digitos.count > 30 { return nil }
        }
        guard !digitos.isEmpty else { return nil }
        if byte(i - 1) == UInt8(ascii: "~") { i -= 1 } // literal binário
        guard byte(i - 1) == UInt8(ascii: "{") else { return nil }
        // Daqui para baixo é cabeçalho de verdade: um tamanho impossível não é
        // "não era literal", é uma conexão que não dá mais para acompanhar.
        guard digitos.count <= 12, let tamanho = Int(String(decoding: digitos.reversed(), as: UTF8.self))
        else {
            throw SyncError.resposta(
                "O servidor IMAP anunciou um literal com \(digitos.count) dígitos de tamanho — "
                + "a sincronia da conexão se perdeu."
            )
        }
        return tamanho
    }

    /// O `UID` escrito na parte-de-linha corrente, para a mensagem de erro.
    ///
    /// Só a parte corrente: procurar na linha lógica inteira acharia um
    /// `UID 999` escrito dentro do corpo de outra mensagem.
    static func uidDaParte(_ visao: ByteBufferView, de inicio: Int, ate fim: Int) -> Int64? {
        let base = visao.startIndex
        let alvo = Array("UID ".utf8)
        var i = max(0, inicio)
        let limite = min(fim, visao.count)
        while i + alvo.count <= limite {
            var casou = true
            for j in 0..<alvo.count where visao[visao.index(base, offsetBy: i + j)] != alvo[j] {
                casou = false
                break
            }
            if casou {
                var digitos = ""
                var k = i + alvo.count
                while k < limite {
                    let byte = visao[visao.index(base, offsetBy: k)]
                    guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { break }
                    digitos.append(Character(UnicodeScalar(byte)))
                    k += 1
                }
                return Int64(digitos)
            }
            i += 1
        }
        return nil
    }

    private var varrido = 0
    private var restanteDoLiteral = 0
    /// Onde a parte-de-linha corrente começa, dentro da linha lógica. Zero no
    /// começo da linha; logo depois de cada literal, onde ele terminou.
    private var inicioDaParteCorrente = 0

    /// O teto que não rearma. `varrido` é a posição dentro da linha **lógica**,
    /// e conta os bytes de literal junto — é exatamente a soma que faltava.
    private func confereTetoDaLinhaLogica() throws {
        guard varrido > Self.tetoDaLinhaLogica else { return }
        throw SyncError.resposta(
            "O servidor IMAP mandou uma linha lógica maior que \(Self.tetoDaLinhaLogica) bytes "
            + "— a conexão foi descartada."
        )
    }

    private mutating func pare(_ buffer: inout ByteBuffer) -> DecodingState {
        pendencia.bytes = buffer.readableBytes
        return .needMoreData
    }
}

/// O handler que junta as linhas até a resposta tagueada.
///
/// Uma requisição em voo por vez, garantida pelo cadeado do ator acima — e
/// conferida aqui de novo, porque garantia que só existe no chamador é a que
/// some no primeiro refactor. O `continuation` é o que transforma o callback do
/// NIO em `await`.
final class ImapChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Quantos bytes o decodificador está segurando sem terem virado linha.
    /// Compartilhado com ele; conferido na fronteira do STARTTLS.
    let pendencia = PendenciaDeBytes()

    private let lock = NSLock()
    private var greeting: CheckedContinuation<String, any Error>?
    private var greetingLine: String?
    private var greetingFailure: (any Error)?
    private var pendingTag: String?
    private var pending: CheckedContinuation<ImapCommandResult, any Error>?
    private var collected: [ImapWire.Untagged] = []
    private var falhaFinal: (any Error)?
    private var relogio: Scheduled<Void>?
    private var cancelamentoPendente = false
    /// Linhas que chegaram sem ninguém ter pedido nada. Fora da saudação, é
    /// exatamente o sintoma de dado injetado antes do TLS.
    private var linhasOrfas = 0

    // O estado do IDLE. Ele vive ao lado do comando, e não no lugar dele: o
    // `IDLE` continua sendo um comando com tag, esperado por `send` como
    // qualquer outro — o que muda é que quem decide escrever o `DONE` precisa
    // de um segundo sinal, e é este.
    private var idleArmado = false
    private var idleAtividade = false
    private var idleContinuation: CheckedContinuation<Bool, Never>?
    private var relogioIdle: Scheduled<Void>?

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

    // MARK: IDLE

    /// Liga a escuta de atividade. Chamada **antes** de o `IDLE` ser escrito:
    /// um servidor rápido pode mandar o `* 2 EXISTS` antes de esta função
    /// voltar, e armar depois perderia justamente o aviso que se foi esperar.
    func armaIdle() {
        lock.lock()
        idleArmado = true
        idleAtividade = false
        lock.unlock()
    }

    /// Espera atividade, o teto, ou o cancelamento. `true` só para atividade.
    ///
    /// O teto é agendado na event loop do canal — o mesmo relógio dos outros
    /// tetos deste arquivo. Nenhuma espera daqui é sem teto, e esta não é
    /// exceção: um servidor que aceita o `IDLE` e nunca mais fala prenderia a
    /// sincronização da conta para sempre, calado.
    /// - Parameter loop: a event loop que agenda o teto. Uma `EventLoop`, e não
    ///   o `Channel` inteiro, porque é só disso que esta função precisa — e
    ///   porque é o que deixa a corrida ser encenada num teste sem socket.
    func esperaIdle(limite: TimeAmount, on loop: any EventLoop) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                // Atividade que chegou entre `armaIdle` e aqui já está anotada:
                // responder na hora é o que impede o aviso de se perder.
                if idleAtividade || !idleArmado {
                    let houve = idleAtividade
                    idleArmado = false
                    lock.unlock()
                    continuation.resume(returning: houve)
                    return
                }
                idleContinuation = continuation
                relogioIdle = loop.scheduleTask(in: limite) { [weak self] in
                    self?.acordaIdle(false)
                }
                lock.unlock()
            }
        } onCancel: {
            acordaIdle(false)
        }
    }

    /// Acorda quem espera o IDLE. Nunca chamada com o `lock` tomado — ela o
    /// toma.
    ///
    /// `internal`, e não `private`, pela mesma razão que `AccountDirector.registra`
    /// é: há um caminho aqui que **não** dá para provocar de fora sem depender
    /// de tempo — o aviso que chega entre `armaIdle` e `esperaIdle`, na janela
    /// de um `await`. Contra o servidor falso em loopback ele quase nunca cai
    /// desse lado, e um teste que só quase prova não prova. A porta não abre
    /// nada que o `@testable` já não abrisse; ela só dá nome ao que provar.
    func acordaIdle(_ atividade: Bool) {
        lock.lock()
        guard idleArmado else {
            lock.unlock()
            return
        }
        if atividade { idleAtividade = true }
        let continuation = idleContinuation
        let houve = idleAtividade
        idleContinuation = nil
        // O relógio só sai quando alguém de fato foi acordado: atividade que
        // chega antes da espera anota e **continua armada**, senão o teto
        // sumiria junto com a anotação.
        if continuation != nil {
            idleArmado = false
            relogioIdle?.cancel()
            relogioIdle = nil
        }
        lock.unlock()
        continuation?.resume(returning: houve)
    }

    /// A linha untagged é aviso de mudança na caixa?
    ///
    /// `EXISTS` (chegou mensagem), `EXPUNGE` (sumiu mensagem) e `FETCH` não
    /// solicitado (mudou bandeira) são os três que o RFC 2177 permite durante o
    /// IDLE, e são exatamente os três que o delta sabe explicar. O resto —
    /// `RECENT`, `OK` de manutenção, o `+ idling` da abertura — não move nada e
    /// acordar por causa dele seria um ciclo de rede por nada.
    static func ehAvisoDeMudanca(_ resposta: ImapWire.Untagged) -> Bool {
        switch resposta {
        case .exists, .expunge, .fetch: true
        default: false
        }
    }

    // MARK: Fronteira do STARTTLS

    /// Lança se houver qualquer resto de conversa em claro na hora de ligar o
    /// TLS. Chamada **na event loop**, junto com a inserção do handler.
    func verificaFronteiraLimpa() throws {
        lock.lock()
        // `pendencia.bytes` entra na conta: meia linha parada **dentro** do
        // decodificador é conversa em claro que o túnel cobriria sem ninguém
        // ver — e ela nunca chega a virar linha coletada, então nenhum dos
        // outros três sinais a enxerga.
        let sujo = !collected.isEmpty || linhasOrfas > 0 || pending != nil || pendencia.bytes > 0
        lock.unlock()
        if sujo {
            throw SyncError.tls(
                "O servidor mandou dados depois do OK do STARTTLS e antes do TLS subir — a conexão foi descartada."
            )
        }
    }

    // MARK: Leitura

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        // Uma decodificação **só**, sobre a linha lógica inteira: decodificar
        // pedaço a pedaço partiria qualquer caractere multibyte que caísse na
        // emenda em dois `U+FFFD`.
        let linha = (buffer.readString(length: buffer.readableBytes) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !linha.isEmpty else { return }

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
            // A leitura sai de baixo do cadeado de propósito: ela pode **lançar**
            // (cabeçalho de literal com tamanho impossível), e `falha` toma o
            // mesmo cadeado. Antes de o adapter lançar, esta linha derrubava o
            // processo inteiro com SIGTRAP, aqui dentro da event loop.
            lock.unlock()
            do {
                let resposta = try ImapResponseAdapter.untagged(fromLogicalLine: linha)
                lock.lock()
                collected.append(resposta)
                lock.unlock()
                // Fora do cadeado, como todo o resto deste ramo: `acordaIdle`
                // toma o mesmo `lock`.
                if Self.ehAvisoDeMudanca(resposta) { acordaIdle(true) }
            } catch {
                falha(Self.traduz(error))
                context.close(promise: nil)
            }
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
        // Uma conexão que caiu não vai mandar `EXISTS` nenhum: quem espera o
        // IDLE tem de sair agora. Sem isto, a conta ficaria os 25 minutos do
        // teto parada sobre um socket morto, e a sincronização "contínua"
        // pararia em silêncio — que é o defeito que esta tarefa existe para
        // consertar, de volta por outra porta.
        acordaIdle(false)
    }
}
