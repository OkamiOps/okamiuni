import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision
import GRDB
import NIOCore
import UNICore

/// Conteúdo de anexos para o agente. O adaptador recebe apenas um
/// `AttachmentFetching`, portanto continua submetido às mesmas checagens de
/// conta/mensagem/anexo usadas pelo leitor e nunca abre um caminho local.
public actor DatabaseAgentAttachmentReader: AgentAttachmentReading {
    private let fetcher: any AttachmentFetching

    public init(fetcher: any AttachmentFetching) {
        self.fetcher = fetcher
    }

    public func readAttachment(
        accountID: String, messageID: String, attachmentID: String
    ) async throws -> AgentAttachmentContent {
        let fetched = try await fetcher.fetchAttachment(
            accountID: accountID, messageID: messageID, attachmentID: attachmentID
        )
        guard fetched.attachment.id == attachmentID else {
            throw AgentAttachmentReadError.unreadable("O servidor devolveu um anexo diferente do solicitado.")
        }
        let mime = fetched.attachment.mimeType
        if isText(mime: mime, filename: fetched.attachment.filename) {
            return extractText(data: fetched.data, mimeType: mime, kind: .text)
        }
        if mime == "application/pdf" || fetched.attachment.filename.lowercased().hasSuffix(".pdf") {
            return try extractPDF(data: fetched.data, mimeType: mime)
        }
        if mime.hasPrefix("image/") {
            return try extractImage(data: fetched.data, mimeType: mime)
        }
        throw AgentAttachmentReadError.unsupportedType(mime)
    }

    private func extractText(
        data: Data, mimeType: String, kind: AgentAttachmentContent.Kind
    ) -> AgentAttachmentContent {
        let bounded = Data(data.prefix(AgentMailCapabilities.maximumExtractedCharacters * 4))
        let text = String(data: bounded, encoding: .utf8)
            ?? String(data: bounded, encoding: .isoLatin1)
            ?? ""
        return AgentAttachmentContent(
            kind: kind, mimeType: mimeType,
            text: String(text.prefix(AgentMailCapabilities.maximumExtractedCharacters)),
            truncated: bounded.count < data.count || text.count > AgentMailCapabilities.maximumExtractedCharacters
        )
    }

    private func extractPDF(data: Data, mimeType: String) throws -> AgentAttachmentContent {
        guard let document = PDFDocument(data: data) else {
            throw AgentAttachmentReadError.unreadable("O PDF não pôde ser aberto para leitura.")
        }
        var text = ""
        var usedOCR = false
        let maximumPages = min(document.pageCount, 25)
        for pageIndex in 0..<maximumPages {
            try Task.checkCancellation()
            if text.count >= AgentMailCapabilities.maximumExtractedCharacters { break }
            let pageText = document.page(at: pageIndex)?.string ?? ""
            text += pageText
            if !pageText.hasSuffix("\n") { text += "\n" }
        }
        // PDF escaneado não traz camada de texto. OCR só entra nesse caso e
        // sobre poucas páginas, para uma fatura malformada não ocupar a sessão.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            usedOCR = true
            let maximumOCRPages = min(document.pageCount, 5)
            for pageIndex in 0..<maximumOCRPages {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex) else { continue }
                let image = page.thumbnail(of: NSSize(width: 1_600, height: 1_600), for: .mediaBox)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                text += try recognize(cgImage)
                text += "\n"
                if text.count >= AgentMailCapabilities.maximumExtractedCharacters { break }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentAttachmentReadError.unreadable("O PDF não contém texto legível. Tente uma versão com OCR.")
        }
        return AgentAttachmentContent(
            kind: .pdfText, mimeType: mimeType,
            text: String(trimmed.prefix(AgentMailCapabilities.maximumExtractedCharacters)),
            truncated: document.pageCount > maximumPages
                || (usedOCR && document.pageCount > 5)
                || text.count > AgentMailCapabilities.maximumExtractedCharacters
        )
    }

    private func extractImage(data: Data, mimeType: String) throws -> AgentAttachmentContent {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AgentAttachmentReadError.unreadable("A imagem não pôde ser aberta para OCR.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_000
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw AgentAttachmentReadError.unreadable("A imagem não pôde ser aberta para OCR.") }
        let text = try recognize(image).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgentAttachmentReadError.unreadable("A imagem não contém texto legível para OCR.")
        }
        return AgentAttachmentContent(
            kind: .imageOCR, mimeType: mimeType,
            text: String(text.prefix(AgentMailCapabilities.maximumExtractedCharacters)),
            truncated: text.count > AgentMailCapabilities.maximumExtractedCharacters
        )
    }

    private func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw AgentAttachmentReadError.unreadable("O OCR da imagem falhou: \(error.localizedDescription)")
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func isText(mime: String, filename: String) -> Bool {
        if mime.hasPrefix("text/") || ["application/json", "application/xml", "application/javascript"].contains(mime) {
            return true
        }
        return [".txt", ".csv", ".json", ".xml", ".md", ".log"].contains {
            filename.lowercased().hasSuffix($0)
        }
    }
}

/// Busca completa no SQLite e nos servidores que a conta já configurou.
///
/// A porta recebe os filtros antes de montar a resposta: aplicar o limite da
/// página de ferramenta antes de caixa/data esconderia resultados corretos em
/// acervos grandes. Gmail grava na pseudo-pasta neutra e IMAP guarda a pasta
/// real, exatamente como os caminhos de sincronização existentes.
public actor DatabaseAgentMailSearch: AgentMailSearching {
    private let database: SyncDatabase
    private let auth: GoogleAuth?
    private let session: URLSession
    private let gmailBaseURL: URL
    private let gmailAccessToken: (@Sendable (String) async throws -> String)?
    private let secrets: any SecretStore
    private let eventLoopGroup: any EventLoopGroup
    private let imapConnect: @Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession

    public init(
        database: SyncDatabase,
        secrets: any SecretStore,
        auth: GoogleAuth?,
        session: URLSession = .shared,
        gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!,
        eventLoopGroup: any EventLoopGroup,
        gmailAccessToken: (@Sendable (String) async throws -> String)? = nil,
        imapConnect: @Sendable @escaping (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
            = { endpoint, group in try await ImapSession.connect(endpoint: endpoint, group: group) }
    ) {
        self.database = database
        self.secrets = secrets
        self.auth = auth
        self.session = session
        self.gmailBaseURL = gmailBaseURL
        self.eventLoopGroup = eventLoopGroup
        self.gmailAccessToken = gmailAccessToken
        self.imapConnect = imapConnect
    }

    public func search(_ request: AgentMailSearchRequest) async throws -> AgentMailSearchResult {
        let accounts = try await database.pool.read { db in
            try AccountRecord.fetchAll(db).map(\.account)
                .filter { request.accountIDs.isEmpty || request.accountIDs.contains($0.id) }
        }
        var remote: [AgentRemoteSearchStatus] = []
        var searchedRemote = false
        if request.includeRemote {
            for account in accounts {
                if account.provider == .gmail, let accessToken = accessToken(for: account.id) {
                    do {
                        let count = try await searchGmail(account, request: request, accessToken: accessToken)
                        remote.append(.init(accountID: account.id, state: .searched, resultEstimate: count))
                        searchedRemote = true
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        remote.append(.init(accountID: account.id, state: .failed(error.localizedDescription)))
                    }
                } else if account.imap != nil {
                    do {
                        if let warning = try await searchImap(account, request: request) {
                            remote.append(.init(accountID: account.id, state: .partial(warning)))
                        } else {
                            remote.append(.init(accountID: account.id, state: .searched))
                        }
                        searchedRemote = true
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        remote.append(.init(accountID: account.id, state: .failed(error.localizedDescription)))
                    }
                } else if account.provider == .gmail {
                    remote.append(.init(
                        accountID: account.id,
                        state: .unavailable("A conta Gmail não tem sessão OAuth nem IMAP configurado para busca remota.")
                    ))
                } else {
                    remote.append(.init(
                        accountID: account.id,
                        state: .unavailable("Esta conta não tem um endpoint IMAP configurado para busca remota.")
                    ))
                }
            }
        }

        let local = try await DatabaseMailSource(database: database).messages()
        let matches = local.filter { matches($0, request: request) }
        return AgentMailSearchResult(
            messages: matches.sorted { $0.receivedAt > $1.receivedAt },
            scope: searchedRemote ? .localAndRemote : .localDatabase,
            remote: remote
        )
    }

    private func accessToken(for accountID: String) -> (@Sendable () async throws -> String)? {
        if let gmailAccessToken { return { try await gmailAccessToken(accountID) } }
        if let auth { return { try await auth.accessToken(for: accountID) } }
        return nil
    }

    private func searchGmail(
        _ account: Account, request: AgentMailSearchRequest,
        accessToken: @escaping @Sendable () async throws -> String
    ) async throws -> Int? {
        let client = GmailClient(session: session, accessToken: accessToken, baseURL: gmailBaseURL)
        var pageToken: String?
        var estimate: Int?
        repeat {
            try Task.checkCancellation()
            let page = try await client.messageIDs(query: gmailQuery(request), pageToken: pageToken)
            estimate = estimate ?? page.resultSizeEstimate
            var messages: [GmailMessage] = []
            for id in page.ids {
                try Task.checkCancellation()
                messages.append(try await client.message(id: id, format: .full))
            }
            try await persist(messages, account: account)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return estimate
    }

    private func searchImap(_ account: Account, request: AgentMailSearchRequest) async throws -> String? {
        guard let endpoint = account.imap else {
            throw SyncError.resposta("A conta não informou servidor IMAP.")
        }
        guard case .password(let password)? = try secrets.secret(for: account.id) else {
            throw SyncError.autenticacao
        }
        let imap = try await imapConnect(endpoint, eventLoopGroup)
        do {
            try await imap.login(user: account.address, password: password)
            let folders = try await database.pool.read { db in
                try FolderRecord
                    .filter(Column("accountID") == account.id)
                    .filter(Column("serverName") != FolderRecord.localDraftsServerName)
                    .filter(Column("serverName") != FolderRecord.gmailServerName)
                    .fetchAll(db)
            }.filter { includes(folder: $0, requestedBucket: request.bucket) }
            guard !folders.isEmpty else {
                throw SyncError.resposta("A conta ainda não tem pastas IMAP sincronizadas para pesquisar.")
            }
            var failures: [String] = []
            var didSearchFolder = false
            for folder in folders {
                try Task.checkCancellation()
                do {
                    let status = try await imap.select(ImapFolder(name: folder.serverName, specialUse: nil))
                    let terms = request.query.split(whereSeparator: \.isWhitespace).map(String.init)
                    let uids: [Int64]
                    if terms.isEmpty {
                        uids = try await imap.searchText("")
                    } else {
                        var intersection: Set<Int64>?
                        for term in terms {
                            try Task.checkCancellation()
                            let matches = Set(try await imap.searchText(term))
                            intersection = intersection.map { $0.intersection(matches) } ?? matches
                            if intersection?.isEmpty == true { break }
                        }
                        uids = Array(intersection ?? []).sorted()
                    }
                    let envelopes = try await imap.envelopes(uids: uids)
                    var bodies: [Int64: MimeBody.Decoded] = [:]
                    for envelope in envelopes {
                        try Task.checkCancellation()
                        bodies[envelope.uid] = try await imap.bodyDecoded(uid: envelope.uid)
                    }
                    try await persist(
                        envelopes, bodies: bodies, account: account, folder: folder,
                        uidValidity: status.uidValidity
                    )
                    didSearchFolder = true
                } catch {
                    if error is CancellationError { throw error }
                    failures.append("\(folder.displayName): \(error.localizedDescription)")
                }
            }
            guard didSearchFolder else {
                throw SyncError.resposta(failures.joined(separator: " | "))
            }
            if !failures.isEmpty {
                await imap.logout()
                return "Algumas pastas não puderam ser pesquisadas: \(failures.joined(separator: " | "))"
            }
        } catch {
            await imap.logout()
            throw error
        }
        await imap.logout()
        return nil
    }

    private func persist(_ messages: [GmailMessage], account: Account) async throws {
        guard !messages.isEmpty else { return }
        try await database.pool.write { db in
            let folder = FolderRecord.gmail(accountID: account.id)
            try folder.save(db)
            let pending = Self.pendingMessageIDs(db, accountID: account.id)
            let safe = messages.filter {
                !pending.contains(MessageIdentity.gmail(accountID: account.id, serverID: $0.id))
            }
            try InitialLoader.gravaMensagensDoGmail(
                db, safe.map { ($0, true) }, account: account,
                folderID: folder.id, laterLabelID: nil
            )
        }
    }

    private func persist(
        _ envelopes: [ImapEnvelope], bodies: [Int64: MimeBody.Decoded], account: Account,
        folder: FolderRecord, uidValidity: Int64
    ) async throws {
        guard !envelopes.isEmpty else { return }
        let role = FolderRole(rawValue: folder.role) ?? .other
        try await database.pool.write { db in
            let pending = Self.pendingMessageIDs(db, accountID: account.id)
            for envelope in envelopes {
                let id = MessageIdentity.imap(
                    accountID: account.id, folderID: folder.id,
                    uidValidity: uidValidity, uid: envelope.uid
                )
                guard !pending.contains(id) else { continue }
                let body = bodies[envelope.uid] ?? MimeBody.Decoded(text: "")
                let key = try ThreadKeyResolver.resolve(
                    db, accountID: account.id, messageID: envelope.messageID,
                    inReplyTo: envelope.inReplyTo, references: [],
                    subject: envelope.subject, fallback: id
                )
                let message = Message(
                    id: id, accountID: account.id, from: envelope.from, receivedAt: envelope.date,
                    subject: envelope.subject, snippet: body.paragraphs.first ?? envelope.subject,
                    body: body.paragraphs,
                    tags: TriageProjection.tag(folderRole: role, folderName: folder.serverName).map { [$0] } ?? [],
                    bucket: TriageProjection.bucket(role: role), isRead: envelope.isRead,
                    summary: nil, detectedEvent: nil, to: envelope.to, cc: envelope.cc,
                    isFlagged: envelope.isFlagged, serverID: String(envelope.uid), uidValidity: uidValidity,
                    rfcMessageID: envelope.messageID,
                    references: [envelope.inReplyTo].compactMap { $0 }, threadKey: key,
                    bulkMarks: envelope.bulkMarks
                )
                try MessageRecord(message, folderID: folder.id).savePreservingIntelligenceProjection(db)
                try InitialLoader.gravaCorpo(
                    db, id: id, paragrafos: body.paragraphs,
                    html: body.html ?? "", calendarICS: body.calendar
                )
                try InitialLoader.gravaAnexos(
                    db, messageID: id,
                    anexos: body.attachments.enumerated().map { index, attachment in
                        MessageAttachmentRecord(
                            id: "\(id):imap:\(index)", messageID: id,
                            filename: attachment.filename, mimeType: attachment.mimeType,
                            byteCount: attachment.byteCount, data: attachment.data
                        )
                    }
                )
            }
        }
    }

    private func matches(_ message: Message, request: AgentMailSearchRequest) -> Bool {
        guard request.accountIDs.isEmpty || request.accountIDs.contains(message.accountID),
              request.bucket == nil || request.bucket == message.bucket,
              request.receivedAfter == nil || message.receivedAt >= request.receivedAfter!,
              request.receivedBefore == nil || message.receivedAt < request.receivedBefore!
        else { return false }
        let terms = request.query.split(whereSeparator: \.isWhitespace).map { ContactDirectory.fold(String($0)) }
        let haystack = ContactDirectory.fold(([
            message.subject, message.from.name, message.from.address, message.snippet,
            message.body.joined(separator: "\n")
        ] + message.to.map(\.address) + message.cc.map(\.address)).joined(separator: " "))
        return terms.allSatisfy(haystack.contains)
    }

    private func gmailQuery(_ request: AgentMailSearchRequest) -> String {
        var parts = request.query.split(whereSeparator: \.isWhitespace).map(String.init)
        // O Gmail interpreta a forma yyyy/MM/dd em meia-noite PST. Usar
        // segundos UTC evita deslocar uma fronteira ISO para o dia anterior;
        // abre um segundo de folga e o filtro local abaixo aplica o intervalo
        // exato antes de devolver qualquer mensagem.
        if let after = request.receivedAfter {
            let second = Int64(after.timeIntervalSince1970.rounded(.down)) - 1
            parts.append("after:\(second)")
        }
        if let before = request.receivedBefore {
            let second = Int64(before.timeIntervalSince1970.rounded(.up))
            parts.append("before:\(second)")
        }
        switch request.bucket {
        case .today?: parts.append("in:inbox")
        case .later?: parts.append("label:\"\(TriageProjection.laterLabelName)\"")
        case .sent?: parts.append("in:sent")
        case .drafts?: parts.append("in:drafts")
        case .trash?: parts.append("in:trash")
        case .junk?: parts.append("in:spam")
        case .archived?: parts.append(contentsOf: ["-in:inbox", "-in:sent", "-in:drafts", "-in:spam", "-in:trash"])
        case .all?: parts.append(contentsOf: ["-in:sent", "-in:drafts", "-in:spam", "-in:trash"])
        case nil: break
        }
        return parts.joined(separator: " ")
    }

    private func includes(folder: FolderRecord, requestedBucket: TriageBucket?) -> Bool {
        guard let requestedBucket else { return true }
        let role = FolderRole(rawValue: folder.role) ?? .other
        let bucket = TriageProjection.bucket(role: role)
        if requestedBucket == .all {
            return ![TriageBucket.trash, .sent, .drafts, .junk].contains(bucket)
        }
        return bucket == requestedBucket
    }

    /// Uma busca remota não pode desfazer a projeção que acabou de entrar na
    /// fila local. O executor ainda não confirmou a alteração ao servidor;
    /// regravar o envelope antigo nesse intervalo faria a tela voltar de
    /// Arquivar para Hoje. A carga normal usa a mesma fila como fronteira de
    /// verdade, então este complemento segue a regra em vez de inventar uma
    /// segunda prioridade para o agente.
    private nonisolated static func pendingMessageIDs(_ db: Database, accountID: String) -> Set<String> {
        let rows = (try? OutboxRecord
            .filter(Column("accountID") == accountID)
            .filter(Column("state") != OutboxState.feita.rawValue)
            .fetchAll(db)) ?? []
        return Set(rows.flatMap { $0.operation?.messageIDs ?? [] })
    }
}

/// Adaptador de calendário das ferramentas. Ele usa a persistência já adotada
/// pelo MailStore e o mesmo `CalendarSyncing` de EventKit/CalDAV. Os eventos
/// novos não recebem convidados; eventos existentes com participantes são
/// recusados, pois o provedor pode enviar uma atualização a eles.
public actor DatabaseAgentCalendarManager: AgentCalendarManaging {
    private let database: SyncDatabase
    private let agenda: any AgendaPersisting
    private let calendarSync: (any CalendarSyncing)?
    private let referenceDay: @Sendable () -> Date

    public init(
        database: SyncDatabase, agenda: any AgendaPersisting,
        calendarSync: (any CalendarSyncing)? = nil,
        referenceDay: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.agenda = agenda
        self.calendarSync = calendarSync
        self.referenceDay = referenceDay
    }

    public func event(id: String) async throws -> AgendaItem? {
        let reference = Calendar.current.startOfDay(for: referenceDay())
        if let saved = try agenda.savedAgendaItems().first(where: { $0.id == id }) {
            return saved.item(referenceDay: reference)
        }
        guard let calendarSync else { return nil }
        return try await calendarSync.synchronize(referenceDay: reference, requestAuthorization: false)
            .first(where: { $0.id == id })
    }

    public func search(query: String, accountIDs: Set<String>) async throws -> [AgendaItem] {
        let reference = Calendar.current.startOfDay(for: referenceDay())
        var byID = Dictionary(
            uniqueKeysWithValues: try agenda.savedAgendaItems().map { ($0.id, $0.item(referenceDay: reference)) }
        )
        if let calendarSync {
            let synced = try await calendarSync.synchronize(referenceDay: reference, requestAuthorization: false)
            for item in synced { byID[item.id] = item }
        }
        let needle = ContactDirectory.fold(query)
        return byID.values.filter {
            (accountIDs.isEmpty || accountIDs.contains($0.accountID))
                && (needle.isEmpty || ContactDirectory.fold("\($0.title) \($0.detail?.place ?? "") \($0.detail?.visibleDescription ?? "")").contains(needle))
        }.sorted {
            $0.dayOffset == $1.dayOffset ? $0.startMinute < $1.startMinute : $0.dayOffset < $1.dayOffset
        }
    }

    public func create(_ draft: AgentCalendarDraft) async throws -> AgentCalendarMutation {
        if let existing = try await event(id: draft.id) {
            let proposed = try await item(from: draft, preserving: existing)
            guard equivalent(existing, proposed) else { throw AgentToolError.conflict }
            return AgentCalendarMutation(item: existing, sync: try await syncState(for: existing), didChange: false)
        }
        let item = try await item(from: draft)
        try agenda.saveAgendaItem(StoredAgendaItem(item, referenceDay: Calendar.current.startOfDay(for: referenceDay())))
        do {
            let state = try await synchronize(item)
            return AgentCalendarMutation(item: item, sync: state, didChange: true)
        } catch {
            try? agenda.removeAgendaItem(item.id)
            throw error
        }
    }

    public func update(_ draft: AgentCalendarDraft) async throws -> AgentCalendarMutation {
        guard let previous = try await event(id: draft.id) else {
            throw AgentToolError.unavailable("O compromisso não existe mais. Busque a agenda antes de atualizar.")
        }
        guard previous.accountID == draft.accountID else {
            throw AgentToolError.unavailable("O compromisso pertence a outra conta autorizada.")
        }
        try refuseParticipantMutation(of: previous)
        let item = try await item(from: draft, preserving: previous)
        guard !equivalent(previous, item) else {
            return AgentCalendarMutation(item: previous, sync: try await syncState(for: previous), didChange: false)
        }
        try agenda.saveAgendaItem(StoredAgendaItem(item, referenceDay: Calendar.current.startOfDay(for: referenceDay())))
        do {
            let state = try await synchronize(item)
            return AgentCalendarMutation(item: item, sync: state, didChange: true)
        } catch {
            try? agenda.saveAgendaItem(StoredAgendaItem(previous, referenceDay: Calendar.current.startOfDay(for: referenceDay())))
            throw error
        }
    }

    public func delete(id: String, accountID: String) async throws -> AgentCalendarMutation {
        guard let previous = try await event(id: id) else {
            return AgentCalendarMutation(item: nil, sync: .localOnly("O compromisso já não existe; a remoção é idempotente."), didChange: false)
        }
        guard previous.accountID == accountID else {
            throw AgentToolError.unavailable("O compromisso pertence a outra conta autorizada.")
        }
        try refuseParticipantMutation(of: previous)
        try agenda.removeAgendaItem(id)
        do {
            let state = try await remove(previous)
            return AgentCalendarMutation(item: nil, sync: state, didChange: true)
        } catch {
            try? agenda.saveAgendaItem(StoredAgendaItem(previous, referenceDay: Calendar.current.startOfDay(for: referenceDay())))
            throw error
        }
    }

    private func item(from draft: AgentCalendarDraft, preserving previous: AgendaItem? = nil) async throws -> AgendaItem {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, draft.endsAt > draft.startsAt else {
            throw AgentToolError.invalidArguments("Informe título e um horário de término posterior ao início.")
        }
        let account = try await account(id: draft.accountID)
        let calendar = Calendar.current
        let reference = calendar.startOfDay(for: referenceDay())
        guard calendar.isDate(draft.startsAt, inSameDayAs: draft.endsAt) else {
            throw AgentToolError.invalidArguments("Compromissos que atravessam dias ainda não são suportados. Crie um item para cada dia.")
        }
        let start = calendar.dateComponents([.hour, .minute], from: draft.startsAt)
        let end = calendar.dateComponents([.hour, .minute], from: draft.endsAt)
        let startMinute = (start.hour ?? 0) * 60 + (start.minute ?? 0)
        let endMinute = (end.hour ?? 0) * 60 + (end.minute ?? 0)
        guard endMinute > startMinute else {
            throw AgentToolError.invalidArguments("O horário de término precisa ser posterior ao início.")
        }
        let previousDetail = previous?.detail
        let detail = EventDetail(
            place: draft.place.trimmingCharacters(in: .whitespacesAndNewlines), link: previousDetail?.link,
            organizer: previousDetail?.organizer
                ?? EventPerson(name: account.displayName, address: account.address, role: "organizador · você", status: .yes),
            people: previousDetail?.people ?? [], note: previousDetail?.note ?? "Criado pelo agente",
            recurrence: previousDetail?.recurrence ?? "Evento único", notice: previousDetail?.notice ?? "Sem alerta",
            agenda: previousDetail?.agenda ?? [], thread: previousDetail?.thread ?? [],
            descricao: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let calendarID = draft.calendarID ?? previous?.calendarID
        let item = AgendaItem(
            id: draft.id, title: title, startMinute: startMinute, endMinute: endMinute,
            accountID: account.id,
            dayOffset: calendar.dateComponents([.day], from: reference, to: calendar.startOfDay(for: draft.startsAt)).day ?? 0,
            calendarUID: previous == nil ? draft.id : previous!.calendarUID,
            calendarSequence: previous?.calendarSequence,
            detail: detail, calendarID: calendarID,
            calendarTitle: draft.calendarID == nil ? previous?.calendarTitle : nil,
            calendarColorHex: draft.calendarID == nil ? previous?.calendarColorHex : nil,
            calendarSource: draft.calendarID == nil ? previous?.calendarSource : nil,
            isCancelled: previous?.isCancelled ?? false
        )
        if let calendarID,
           calendarID.hasPrefix(ConnectedCalendar.mailboxPrefix),
           calendarID != ConnectedCalendar.mailboxID(forAccountID: account.id)
        {
            throw AgentToolError.invalidArguments("O calendário de caixa selecionado pertence a outra conta.")
        }
        return previous == nil && draft.calendarID == nil && ConnectedCalendar.needsMailboxCalendar(account)
            ? item.withCalendar(.mailbox(for: account)) : item
    }

    private func account(id: String) async throws -> Account {
        guard let account = try await database.pool.read({ db in
            try AccountRecord.fetchOne(db, key: id)?.account
        }) else { throw AgentToolError.unavailable("A conta do compromisso não está disponível.") }
        return account
    }

    private func syncState(for item: AgendaItem) async throws -> AgentCalendarSyncState {
        if isLocalMailbox(item) {
            return .localOnly("A conta usa o calendário local do OkamiUNI; não há calendário externo configurado para sincronizar.")
        }
        guard calendarSync != nil else {
            return .localOnly("Nenhum adaptador de calendário externo está configurado para esta conta.")
        }
        return .synchronized
    }

    private func synchronize(_ item: AgendaItem) async throws -> AgentCalendarSyncState {
        let state = try await syncState(for: item)
        guard case .synchronized = state, let calendarSync else { return state }
        try await calendarSync.save(item, referenceDay: Calendar.current.startOfDay(for: referenceDay()))
        return state
    }

    private func remove(_ item: AgendaItem) async throws -> AgentCalendarSyncState {
        let state = try await syncState(for: item)
        guard case .synchronized = state, let calendarSync else { return state }
        try await calendarSync.remove(id: item.id, referenceDay: Calendar.current.startOfDay(for: referenceDay()))
        return state
    }

    private func isLocalMailbox(_ item: AgendaItem) -> Bool {
        item.calendarID?.hasPrefix(ConnectedCalendar.mailboxPrefix) == true
    }

    private func refuseParticipantMutation(of item: AgendaItem) throws {
        guard item.detail?.people.isEmpty != false else {
            throw AgentToolError.unavailable(
                "Este compromisso tem participantes. Atualizá-lo ou removê-lo pode enviar convites; use o fluxo de confirmação do calendário."
            )
        }
    }

    private func equivalent(_ lhs: AgendaItem, _ rhs: AgendaItem) -> Bool {
        lhs.id == rhs.id && lhs.accountID == rhs.accountID && lhs.title == rhs.title
            && lhs.startMinute == rhs.startMinute && lhs.endMinute == rhs.endMinute
            && lhs.dayOffset == rhs.dayOffset && lhs.calendarID == rhs.calendarID
            && lhs.detail?.place == rhs.detail?.place && lhs.detail?.visibleDescription == rhs.detail?.visibleDescription
    }
}
