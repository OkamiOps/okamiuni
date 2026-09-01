import Foundation
import GRDB
import NIOCore
import UNICore
import os

/// A busca do corpo por demanda — a `BodyFetching` de verdade.
///
/// **É o que faltava para "o resto desce por demanda" deixar de ser uma frase.**
/// A carga inicial baixa o corpo cheio das 50 mais recentes de cada pasta; as
/// outras entram no banco só com envelope. Sem esta peça, abrir a quinquagésima
/// primeira mensagem mostrava uma coluna em branco, para sempre — 39 das 83
/// mensagens do dono estão nesse estado.
///
/// Ator por uma razão concreta: a sessão IMAP é cara (TCP, TLS, `LOGIN`) e a
/// pessoa abre uma mensagem atrás da outra. Reabrir a conexão por mensagem
/// somaria meio segundo a cada clique. A sessão fica guardada por conta e é
/// **descartada** ao primeiro erro de rede — o mesmo idioma do `ImapMirror`, e
/// pela mesma razão: o app fica aberto o dia todo e o servidor derruba conexão
/// ociosa sem avisar.
public actor DatabaseBodyFetcher: BodyFetching {
    private let database: SyncDatabase
    private let secrets: any SecretStore
    private let auth: GoogleAuth?
    private let session: URLSession
    private let gmailBaseURL: URL
    private let eventLoopGroup: any EventLoopGroup
    private let imapConnect: @Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "BodyFetcher")

    private var sessoes: [String: ImapSession] = [:]

    public init(
        database: SyncDatabase,
        secrets: any SecretStore,
        auth: GoogleAuth?,
        session: URLSession,
        gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!,
        eventLoopGroup: any EventLoopGroup,
        imapConnect: @Sendable @escaping (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
            = { endpoint, grupo in try await ImapSession.connect(endpoint: endpoint, group: grupo) }
    ) {
        self.database = database
        self.secrets = secrets
        self.auth = auth
        self.session = session
        self.gmailBaseURL = gmailBaseURL
        self.eventLoopGroup = eventLoopGroup
        self.imapConnect = imapConnect
    }

    public func fetchBody(accountID: String, messageID: String) async throws -> FetchedBody {
        if let local = try await corpoLocal(messageID) { return local }
        guard let conta = try await database.pool.read({ db in
            try AccountRecord.fetchOne(db, key: accountID)?.account
        }) else {
            throw SyncError.resposta("A conta desta mensagem não está mais cadastrada.")
        }
        // As coordenadas do servidor saem do **id**, que já as contém, e não de
        // um segundo cadastro para manter em dia — a mesma decisão que a fila de
        // saída tomou (ver `MessageIdentity.parse`).
        guard let onde = MessageIdentity.parse(messageID, accountID: accountID) else {
            throw SyncError.resposta("Não foi possível descobrir onde esta mensagem está no servidor.")
        }

        let corpo = try await busca(onde, conta: conta)
        // **Gravar é parte do contrato, não efeito colateral.** Sem esta
        // escrita, sair da mensagem e voltar pagaria a viagem de novo, a busca
        // continuaria sem achar o que a pessoa acabou de ler, e o app offline
        // voltaria a mostrar a coluna em branco.
        try await grava(corpo, messageID: messageID)
        let attachments = try await database.pool.read { db in
            try MessageAttachmentRecord
                .filter(Column("messageID") == messageID)
                .order(Column("id"))
                .fetchAll(db)
                .map(\.attachment)
        }
        return FetchedBody(
            paragraphs: corpo.paragraphs,
            // `""` e não `nil`: a mensagem passou pelo decodificador, e a
            // resposta "ela não tem HTML" é uma resposta. Devolver `nil` aqui
            // faria o leitor rebuscá-la a cada abertura, para sempre.
            html: corpo.html ?? "",
            calendarICS: corpo.calendar,
            attachments: attachments
        )
    }

    /// Corpo que o app já gravou — rascunho local, ou mensagem cujo envelope
    /// chegou sem o texto na lista. Sem isto, `local-draft-…` não tem
    /// coordenada de servidor e a busca rebentava com "não foi possível
    /// descobrir onde esta mensagem está".
    private func corpoLocal(_ messageID: String) async throws -> FetchedBody? {
        try await database.pool.read { db in
            guard let linha = try MessageBodyRecord
                .filter(Column("messageID") == messageID)
                .fetchOne(db)
            else { return nil }
            let anexos = try MessageAttachmentRecord
                .filter(Column("messageID") == messageID)
                .order(Column("id"))
                .fetchAll(db)
                .map(\.attachment)
            return FetchedBody(
                paragraphs: linha.body,
                html: linha.html ?? "",
                calendarICS: linha.calendarICS,
                attachments: anexos
            )
        }
    }

    // MARK: A viagem

    private func busca(_ onde: MessageCoordinate, conta: Account) async throws -> MimeBody.Decoded {
        switch onde {
        case .gmail(let serverID):
            guard let auth else { throw SyncError.semClientID }
            let id = conta.id
            let cliente = GmailClient(
                session: session,
                accessToken: { try await auth.accessToken(for: id) },
                baseURL: gmailBaseURL
            )
            // `.full`, e não `.metadata`: é justamente o corpo que falta. O
            // parser é o mesmo da carga — inclusive o caminho novo que converte
            // a mensagem só de HTML em texto.
            //
            // E **com as imagens embutidas resolvidas**: a `messages.get` do
            // Gmail entrega o HTML e deixa as imagens `cid:` para trás, como
            // `attachmentId`. Sem esta rota, a newsletter que é só imagem abria
            // em branco e a mensagem com uma foto no meio abria com um buraco —
            // ver `GmailInlineAttachments`, que é a dívida da M3-8 paga.
            let mensagem = try await GmailInlineAttachments.message(cliente, id: serverID)
            // Os metadados dos anexos comuns vêm no mesmo `messages.get`.
            // Só os bytes pequenos já presentes são cacheados; os demais ficam
            // com o `attachmentId` para a porta de download buscá-los depois.
            try await database.pool.write { db in
                let messageID = MessageIdentity.gmail(accountID: conta.id, serverID: serverID)
                try InitialLoader.gravaAnexos(
                    db, messageID: messageID,
                    anexos: mensagem.attachments.enumerated().map { index, attachment in
                        MessageAttachmentRecord(
                            id: "\(messageID):gmail:\(index)", messageID: messageID,
                            filename: attachment.filename, mimeType: attachment.mimeType,
                            byteCount: attachment.byteCount,
                            remoteID: attachment.attachmentID, data: attachment.inlineData
                        )
                    }
                )
            }
            let ics = await GmailCalendar.completar(
                mensagem, cliente: cliente, serverID: serverID
            )
            return MimeBody.Decoded(
                text: mensagem.body.joined(separator: "\n\n"),
                html: mensagem.html, calendar: ics
            )

        case .imap(let pasta, let uidValidity, let uid):
            do {
                return try await buscaNoImap(
                    conta: conta, pasta: pasta, uidValidity: uidValidity, uid: uid
                )
            } catch let erro as SyncError where ehDeConexao(erro) {
                // Conexão morta na prateleira: uma segunda chance, com sessão
                // nova. É o caso mais provável de todos — o servidor derruba a
                // conexão ociosa e ninguém nos avisa até tentarmos usá-la.
                await descarta(conta.id)
                log.notice("A sessão de corpo caiu; reconectando uma vez.")
                return try await buscaNoImap(
                    conta: conta, pasta: pasta, uidValidity: uidValidity, uid: uid
                )
            }
        }
    }

    private func buscaNoImap(
        conta: Account, pasta: String, uidValidity: Int64, uid: Int64
    ) async throws -> MimeBody.Decoded {
        let sessao = try await sessaoAtiva(conta)
        let status = try await sessao.select(ImapFolder(name: pasta, specialUse: nil))
        // O UID sozinho não identifica nada: o servidor pode ter reciclado os
        // UIDs desde 1. Buscar assim mesmo gravaria o corpo de **outra**
        // mensagem sob este id — trocar de conteúdo em silêncio é pior do que
        // falhar em voz alta, e a pasta será recarregada do zero na próxima
        // carga (é o que `sync_state` já garante).
        guard status.uidValidity == uidValidity else {
            throw SyncError.resposta(
                "A pasta \(pasta) reciclou os identificadores no servidor; "
                + "esta mensagem será recarregada."
            )
        }
        return try await sessao.bodyDecoded(uid: uid)
    }

    private func sessaoAtiva(_ conta: Account) async throws -> ImapSession {
        if let guardada = sessoes[conta.id] { return guardada }
        guard let endpoint = conta.imap else {
            throw SyncError.resposta("A conta não tem servidor IMAP configurado.")
        }
        guard case .password(let senha)? = try secrets.secret(for: conta.id) else {
            throw SyncError.autenticacao
        }
        let nova = try await imapConnect(endpoint, eventLoopGroup)
        try await nova.login(user: conta.address, password: senha)
        sessoes[conta.id] = nova
        return nova
    }

    private func descarta(_ accountID: String) async {
        guard let sessao = sessoes.removeValue(forKey: accountID) else { return }
        await sessao.logout()
    }

    /// Fecha as conexões guardadas. O app não chama (ele morre com elas), mas o
    /// teste chama — e um servidor falso esperando por um `LOGOUT` que nunca
    /// vem é uma suíte que trava sem falhar.
    public func close() async {
        for id in sessoes.keys { await descarta(id) }
    }

    private func ehDeConexao(_ erro: SyncError) -> Bool {
        switch erro {
        case .rede, .tls: true
        default: false
        }
    }

    // MARK: A escrita

    private func grava(_ corpo: MimeBody.Decoded, messageID: String) async throws {
        let paragrafos = corpo.paragraphs
        // Sem texto, sem HTML e sem convite não há linha a gravar — mas basta
        // **um** dos três para haver: o convite de agenda é justamente a
        // mensagem sem parágrafo nenhum.
        guard !paragrafos.isEmpty || corpo.html != nil || corpo.calendar != nil || !corpo.attachments.isEmpty else { return }
        try await database.pool.write { db in
            try InitialLoader.gravaCorpo(
                db, id: messageID, paragrafos: paragrafos,
                html: corpo.html ?? "", calendarICS: corpo.calendar
            )
            if !corpo.attachments.isEmpty {
                try InitialLoader.gravaAnexos(
                    db, messageID: messageID,
                    anexos: corpo.attachments.enumerated().map { index, attachment in
                        MessageAttachmentRecord(
                            id: "\(messageID):imap:\(index)", messageID: messageID,
                            filename: attachment.filename, mimeType: attachment.mimeType,
                            byteCount: attachment.byteCount, data: attachment.data
                        )
                    }
                )
            }
            // A prévia da lista de uma mensagem sem corpo é o **assunto** (ver
            // `InitialLoader.gravaImap`): a linha repetia o assunto duas vezes,
            // uma em cima da outra. Agora que há corpo, ela mostra a primeira
            // linha dele — e a troca é condicional para nunca sobrescrever a
            // prévia que o servidor deu (o `snippet` do Gmail).
            guard let primeiro = paragrafos.first else { return }
            try db.execute(
                sql: "UPDATE message SET snippet = ? WHERE id = ? AND snippet = subject",
                arguments: [primeiro, messageID]
            )
        }
    }
}
