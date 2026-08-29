import Foundation
import GRDB
import UNICore

// `FolderRole` mudou de casa na M3-17: ele mora em `UNICore.MailFolder`, junto
// com o tipo que a barra lateral desenha. `import UNICore` acima é o que o traz
// de volta para todo este pacote, sem uma linha de mudança em quem o usa.

public struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "account"

    public var id: String
    public var address: String
    public var displayName: String
    public var provider: String
    public var host: String
    public var tintLightHex: String
    public var tintDarkHex: String
    public var signature: String
    public var imapHost: String?
    public var imapPort: Int?
    public var imapSecurity: String?
    public var state: String
    public var lastSyncedAt: Date?
    public var createdAt: Date

    /// Datas gravadas como epoch UTC (`Double`), não como o texto
    /// "AAAA-MM-DD HH:MM:SS.SSS" que `.deferredToDate` (o padrão do GRDB)
    /// produziria. A coluna já é `DOUBLE` na migração — sem esta estratégia,
    /// SQLite recebe um texto que não conforma à afinidade da coluna e grava
    /// TEXT mesmo assim, e `ORDER BY receivedAt` deixa de ser ordem por
    /// tempo para virar ordem lexicográfica.
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public init(_ account: Account, createdAt: Date) {
        id = account.id
        address = account.address
        displayName = account.displayName
        provider = account.provider.rawValue
        host = account.host
        tintLightHex = account.tintLightHex
        tintDarkHex = account.tintDarkHex
        signature = account.signature
        imapHost = account.imap?.host
        imapPort = account.imap?.port
        imapSecurity = account.imap?.security.rawValue
        state = account.state.rawValue
        lastSyncedAt = account.lastSyncedAt
        self.createdAt = createdAt
    }

    /// De volta ao tipo do `UNICore`.
    ///
    /// Valor desconhecido em `provider` e `state` **não** derruba a leitura:
    /// um banco escrito por uma versão futura tem de continuar abrindo, com a
    /// conta aparecendo como IMAP ativa, em vez de a lista inteira sumir.
    /// Cair para o caso geral é a mesma regra de `.imap` ser o caso geral.
    public var account: Account {
        let endpoint: ImapEndpoint? = {
            guard let imapHost, let imapPort,
                  let bruto = imapSecurity,
                  let security = ImapEndpoint.Security(rawValue: bruto)
            else { return nil }
            return ImapEndpoint(host: imapHost, port: imapPort, security: security)
        }()
        return Account(
            id: id, address: address, displayName: displayName,
            provider: Account.Provider(rawValue: provider) ?? .imap,
            host: host, tintLightHex: tintLightHex, tintDarkHex: tintDarkHex,
            signature: signature, imap: endpoint,
            state: Account.State(rawValue: state) ?? .ativa,
            lastSyncedAt: lastSyncedAt
        )
    }
}

public struct FolderRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "folder"

    public var id: String
    public var accountID: String
    public var serverName: String
    public var role: String
    public var displayName: String

    public init(id: String, accountID: String, serverName: String, role: FolderRole, displayName: String) {
        self.id = id
        self.accountID = accountID
        self.serverName = serverName
        self.role = role.rawValue
        self.displayName = displayName
    }

    /// A pseudo-pasta do Gmail, que existe só para a chave estrangeira de
    /// `message` ter para onde apontar — os rótulos é que fazem o papel das
    /// pastas por lá. O papel é `.other` de propósito: ela guarda mensagem de
    /// **todas** as caixas, e nenhum papel a descreve (ver `InitialLoader`).
    ///
    /// Uma função só porque três lugares a escrevem — a carga inicial, o ciclo
    /// incremental e a gravação da mensagem enviada —, e um nome de servidor
    /// digitado diferente num deles daria uma segunda pasta, com as mensagens
    /// da conta partidas em duas.
    public static let gmailServerName = "GMAIL"

    public static func gmail(accountID: String) -> FolderRecord {
        FolderRecord(
            id: id(accountID: accountID, serverName: gmailServerName),
            accountID: accountID, serverName: gmailServerName,
            role: .other, displayName: "Gmail"
        )
    }

    /// O id de uma pasta é conta + nome no servidor. Determinístico de
    /// propósito: reabrir o app e listar as pastas de novo tem de encontrar as
    /// mesmas linhas, não criar linhas paralelas.
    public static func id(accountID: String, serverName: String) -> String {
        "\(accountID)/\(serverName)"
    }

    /// A pasta como a barra lateral a mostra — ou `nil` quando esta linha não é
    /// uma pasta de verdade.
    ///
    /// **A pseudo-pasta do Gmail devolve `nil`, e é por isso que esta
    /// propriedade é opcional.** Ela existe só para a chave estrangeira de
    /// `message` ter para onde apontar; ela guarda as mensagens de Hoje,
    /// Depois, Arquivado *e* Lixeira da conta, e a coluna `role` dela é
    /// `.other` justamente para declarar que não significa nada (ver
    /// `InitialLoader`). Mostrá-la na barra seria uma linha chamada "Gmail" com
    /// a conta inteira dentro, ao lado das pastas de verdade. As pastas de uma
    /// conta Gmail são os **rótulos**, e eles têm linhas próprias desde a
    /// M3-17.
    ///
    /// Esta é a volta de `role: String` para `FolderRole` que o comentário
    /// antigo deste lugar deixou marcada como dívida — paga agora, e com a
    /// decisão sobre o Gmail junto, que era a condição.
    public var folder: MailFolder? {
        guard serverName != Self.gmailServerName else { return nil }
        return MailFolder(
            id: id, accountID: accountID, serverName: serverName,
            displayName: displayName,
            // Valor desconhecido não derruba a leitura, pela mesma regra de
            // `AccountRecord.account`: um banco escrito por uma versão futura
            // continua abrindo, com a pasta aparecendo sem papel.
            role: FolderRole(rawValue: role) ?? .other
        )
    }
}

public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "message"

    public var id: String
    public var accountID: String
    public var folderID: String
    public var serverID: String?
    public var uidValidity: Int64?
    public var fromName: String
    public var fromAddress: String
    public var toJSON: String
    public var ccJSON: String
    public var subject: String
    public var snippet: String
    public var receivedAt: Date
    public var dayOffset: Int
    public var isRead: Bool
    public var isFlagged: Bool
    public var bucket: String
    /// As etiquetas do protótipo ("Precisa resposta", "Lead"...). Sem esta
    /// coluna a linha reaberta do banco perde os chips — eles renderizam de
    /// `Message.tags`, e `message(body:)` cravava `[]`.
    public var tagsJSON: String
    /// O resumo gerado no dispositivo. `nil` até existir — é o mesmo "nulo
    /// até existir" que `Message.summary` já documenta.
    public var summary: String?
    /// O compromisso que o app achou dentro do corpo, se achou algum.
    public var detectedEventJSON: String?
    /// As sugestões de resposta de um toque. Sem esta coluna, a faixa de
    /// sugestões da mensagem reaberta vem sempre vazia, mensagem nenhuma
    /// tendo sugestão nenhuma — o cartão de resumo do leitor depende disto.
    public var replyHintsJSON: String
    /// O `Message-ID` do RFC 5322, sem `<>`, da v4. `nil` nas linhas gravadas
    /// antes dela e em toda mensagem que não nasceu de um servidor.
    public var rfcMessageID: String?
    /// A corrente da conversa como JSON, da raiz para cá — ver
    /// `Message.references`.
    public var referencesJSON: String
    /// A chave da conversa, derivada por `ThreadKey` na gravação e **indexada**.
    /// `nil` só existiria numa linha escrita fora de todos os caminhos de hoje;
    /// a migração v4 preencheu as antigas.
    public var threadKey: String?
    /// Em que pastas do provedor esta mensagem está, como JSON de ids de pasta
    /// — a coluna da v8.
    ///
    /// **Vazio é o caso normal, e significa "onde `folderID` diz".** Numa conta
    /// IMAP a mensagem mora numa pasta e ponto: a coluna ficaria repetindo o
    /// `folderID` em toda linha do banco. Ela existe pelo Gmail, onde pasta é
    /// rótulo e uma mensagem tem vários — "Faturas" e "Clientes" ao mesmo
    /// tempo, que nenhuma coluna única representa.
    public var folderMembershipJSON: String

    /// Datas gravadas como epoch UTC (`Double`) — ver
    /// `AccountRecord.databaseDateEncodingStrategy`. `ORDER BY receivedAt
    /// DESC` (a lista "Tudo") depende de a coluna ser numérica de verdade.
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public init(_ message: Message, folderID: String) {
        id = message.id
        accountID = message.accountID
        self.folderID = folderID
        serverID = message.serverID
        uidValidity = message.uidValidity
        fromName = message.from.name
        fromAddress = message.from.address
        toJSON = Self.encode(message.to)
        ccJSON = Self.encode(message.cc)
        subject = message.subject
        snippet = message.snippet
        receivedAt = message.receivedAt
        dayOffset = message.dayOffset
        isRead = message.isRead
        isFlagged = message.isFlagged
        bucket = message.bucket.rawValue
        tagsJSON = Self.encodeTags(message.tags)
        summary = message.summary
        detectedEventJSON = Self.encodeDetectedEvent(message.detectedEvent)
        replyHintsJSON = Self.encodeStrings(message.replyHints)
        rfcMessageID = message.rfcMessageID
        referencesJSON = Self.encodeStrings(message.references)
        threadKey = message.threadKey
        // Só o que **acrescenta** informação é gravado: a pertinência de uma
        // mensagem que está só na própria pasta já está dita por `folderID`.
        folderMembershipJSON = message.folderIDs == [folderID]
            ? "[]"
            : Self.encodeStrings(message.folderIDs)
    }

    /// O corpo vem de fora porque mora noutra tabela: a lista mostra centenas
    /// de linhas e não precisa de nenhum corpo, e carregar todos por tabela
    /// única faria a abertura pagar por texto que ninguém vai ler.
    public func message(
        body: [String], bodyHTML: String? = nil, calendarICS: String? = nil,
        attachments: [MailAttachment] = []
    ) -> Message {
        Message(
            id: id, accountID: accountID,
            from: Contact(name: fromName, address: fromAddress),
            receivedAt: receivedAt,
            subject: subject, snippet: snippet, body: body,
            tags: Self.decodeTags(tagsJSON), bucket: TriageBucket(rawValue: bucket) ?? .archived,
            isRead: isRead, summary: summary, detectedEvent: Self.decodeDetectedEvent(detectedEventJSON),
            dayOffset: dayOffset, replyHints: Self.decodeStrings(replyHintsJSON),
            to: Self.decode(toJSON), cc: Self.decode(ccJSON),
            isFlagged: isFlagged,
            serverID: serverID, uidValidity: uidValidity,
            bodyHTML: bodyHTML, calendarICS: calendarICS,
            rfcMessageID: rfcMessageID,
            references: Self.decodeStrings(referencesJSON),
            threadKey: threadKey,
            folderIDs: Self.folderIDs(membership: folderMembershipJSON, folderID: folderID),
            attachments: attachments
        )
    }

    /// As pastas da mensagem, resolvidas: a lista gravada quando há uma, e a
    /// pasta única quando não. Uma função, e não duas leituras espalhadas, para
    /// o "vazio quer dizer `folderID`" ter um lugar só.
    static func folderIDs(membership: String, folderID: String) -> [String] {
        let lista = decodeStrings(membership)
        return lista.isEmpty ? [folderID] : lista
    }

    /// Um contato serializado, para `to`/`cc` caberem numa coluna.
    private struct Wire: Codable { var name: String; var address: String }

    private static func encode(_ contacts: [Contact]) -> String {
        let fio = contacts.map { Wire(name: $0.name, address: $0.address) }
        guard let dados = try? JSONEncoder().encode(fio),
              let texto = String(data: dados, encoding: .utf8) else { return "[]" }
        return texto
    }

    private static func decode(_ json: String) -> [Contact] {
        guard let dados = json.data(using: .utf8),
              let fio = try? JSONDecoder().decode([Wire].self, from: dados) else { return [] }
        return fio.map { Contact(name: $0.name, address: $0.address) }
    }

    private static func encodeStrings(_ items: [String]) -> String {
        guard let dados = try? JSONEncoder().encode(items),
              let texto = String(data: dados, encoding: .utf8) else { return "[]" }
        return texto
    }

    private static func decodeStrings(_ json: String) -> [String] {
        guard let dados = json.data(using: .utf8),
              let lista = try? JSONDecoder().decode([String].self, from: dados) else { return [] }
        return lista
    }

    /// Uma etiqueta serializada.
    private struct TagWire: Codable { var name: String; var tintHex: String? }

    private static func encodeTags(_ tags: [Tag]) -> String {
        let fio = tags.map { TagWire(name: $0.name, tintHex: $0.tintHex) }
        guard let dados = try? JSONEncoder().encode(fio),
              let texto = String(data: dados, encoding: .utf8) else { return "[]" }
        return texto
    }

    private static func decodeTags(_ json: String) -> [Tag] {
        guard let dados = json.data(using: .utf8),
              let fio = try? JSONDecoder().decode([TagWire].self, from: dados) else { return [] }
        return fio.map { Tag(name: $0.name, tintHex: $0.tintHex) }
    }

    /// Um evento detectado serializado. `start` como epoch UTC, pela mesma
    /// regra das colunas de data — ver `databaseDateEncodingStrategy`.
    private struct DetectedEventWire: Codable { var label: String; var start: Double; var duration: Double }

    private static func encodeDetectedEvent(_ event: DetectedEvent?) -> String? {
        guard let event else { return nil }
        let fio = DetectedEventWire(
            label: event.label, start: event.start.timeIntervalSince1970, duration: event.duration
        )
        guard let dados = try? JSONEncoder().encode(fio),
              let texto = String(data: dados, encoding: .utf8) else { return nil }
        return texto
    }

    private static func decodeDetectedEvent(_ json: String?) -> DetectedEvent? {
        guard let json,
              let dados = json.data(using: .utf8),
              let fio = try? JSONDecoder().decode(DetectedEventWire.self, from: dados) else { return nil }
        return DetectedEvent(
            label: fio.label, start: Date(timeIntervalSince1970: fio.start), duration: fio.duration
        )
    }
}

public struct MessageBodyRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "message_body"

    /// O `rowid` físico da linha — `nil` até o `insert` de verdade, que o
    /// preenche via `didInsert`. Ele é a chave primária da tabela desde a
    /// rodada de conserto 1: `content_rowid='rowid'` do FTS5 externo precisa
    /// de um rowid que sobreviva a um `VACUUM`, e só o rowid declarado como
    /// chave primária sobrevive. `messageID` continua único (é por ele que o
    /// app busca), mas deixou de ser a chave física.
    public var rowid: Int64?
    public var messageID: String
    /// Os parágrafos, como JSON — é assim que `Message.body` é modelado.
    public var paragraphs: String
    /// Os mesmos parágrafos, juntos por quebra de linha. **É esta coluna que o
    /// FTS5 indexa**: indexar o JSON faria os colchetes e as aspas entrarem no
    /// índice e a busca por `"` casar com tudo.
    public var plain: String
    /// O HTML sanitizado da mensagem, da v3.
    ///
    /// Três valores, três significados — ver o comentário da migração v3.
    /// `nil` é "nunca decodificado com o decodificador que conhece HTML" e é o
    /// que faz o leitor rebuscar uma vez; `""` é "decodificado, e a mensagem
    /// não tem HTML"; o resto é o HTML.
    public var html: String?
    /// O `text/calendar` cru do convite, quando a mensagem trouxe um.
    public var calendarICS: String?

    public init(
        messageID: String, paragraphs: [String],
        html: String? = nil, calendarICS: String? = nil
    ) {
        self.rowid = nil
        self.messageID = messageID
        let dados = (try? JSONEncoder().encode(paragraphs)) ?? Data("[]".utf8)
        self.paragraphs = String(data: dados, encoding: .utf8) ?? "[]"
        plain = paragraphs.joined(separator: "\n")
        self.html = html
        self.calendarICS = calendarICS
    }

    public var body: [String] {
        guard let dados = paragraphs.data(using: .utf8),
              let lista = try? JSONDecoder().decode([String].self, from: dados) else { return [] }
        return lista
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        rowid = inserted.rowID
    }
}

/// A parte local de um anexo recebido. `data` é nulo para Gmail até a pessoa
/// pedir para salvar; IMAP a preenche quando já recebeu a fonte MIME completa.
public struct MessageAttachmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "message_attachment"

    public var id: String
    public var messageID: String
    public var filename: String
    public var mimeType: String
    public var byteCount: Int
    public var remoteID: String?
    public var data: Data?

    public init(
        id: String, messageID: String, filename: String, mimeType: String,
        byteCount: Int, remoteID: String? = nil, data: Data? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.filename = AttachmentName.sanitize(filename)
        self.mimeType = AttachmentName.mimeType(mimeType)
        self.byteCount = max(0, byteCount)
        self.remoteID = remoteID
        self.data = data
    }

    public var attachment: MailAttachment {
        MailAttachment(id: id, filename: filename, mimeType: mimeType, byteCount: byteCount)
    }
}

public struct AgendaItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "agenda_item"

    public var id: String
    public var accountID: String
    public var title: String
    public var startMinute: Int
    public var endMinute: Int
    /// Continua `Int`, e não uma `Date`, pelo mesmo motivo que
    /// `AgendaItem.dayOffset` é: um deslocamento em dias não atravessa fuso.
    public var dayOffset: Int

    public init(_ item: AgendaItem) {
        id = item.id
        accountID = item.accountID
        title = item.title
        startMinute = item.startMinute
        endMinute = item.endMinute
        dayOffset = item.dayOffset
    }

    public var item: AgendaItem {
        AgendaItem(
            id: id, title: title,
            startMinute: startMinute, endMinute: endMinute,
            accountID: accountID, dayOffset: dayOffset
        )
    }
}

public struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "sync_state"

    public var accountID: String
    /// Vazio para o estado da conta inteira (o `historyId` do Gmail); o id da
    /// pasta para o estado por pasta (o par `UIDVALIDITY`/maior UID do IMAP).
    public var folderID: String
    public var historyID: String?
    public var uidValidity: Int64?
    public var highestUID: Int64?
    public var syncedAt: Date?

    /// Datas gravadas como epoch UTC (`Double`) — ver
    /// `AccountRecord.databaseDateEncodingStrategy`.
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public init(
        accountID: String, folderID: String,
        historyID: String? = nil, uidValidity: Int64? = nil,
        highestUID: Int64? = nil, syncedAt: Date? = nil
    ) {
        self.accountID = accountID
        self.folderID = folderID
        self.historyID = historyID
        self.uidValidity = uidValidity
        self.highestUID = highestUID
        self.syncedAt = syncedAt
    }
}
