import Foundation

/// Limites e portas usados exclusivamente pelas ferramentas nativas de email.
///
/// Elas ficam no Core para que a conversa, o MCP e qualquer provedor de IA usem
/// exatamente a mesma superfície. Nenhuma delas recebe caminho local ou URL:
/// todo arquivo é identificado pelo trio conta, mensagem e anexo que a caixa já
/// conhece.
public enum AgentMailCapabilities {
    public static let maximumExtractedCharacters = 100_000
    public static let maximumSearchResults = 500
}

public struct AgentAttachmentContent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case text
        case pdfText
        case imageOCR
    }

    public let kind: Kind
    public let mimeType: String
    public let text: String
    public let truncated: Bool

    public init(kind: Kind, mimeType: String, text: String, truncated: Bool) {
        self.kind = kind
        self.mimeType = AttachmentName.mimeType(mimeType)
        self.text = text
        self.truncated = truncated
    }
}

/// Lê conteúdo de um anexo que já pertence a uma mensagem conhecida.
public protocol AgentAttachmentReading: Sendable {
    func readAttachment(
        accountID: String, messageID: String, attachmentID: String
    ) async throws -> AgentAttachmentContent
}

public enum AgentAttachmentReadError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedType(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let type):
            return "O tipo \(type) não permite leitura pelo agente. Use texto, PDF, PNG, JPEG, HEIC ou TIFF."
        case .unreadable(let reason):
            return reason
        }
    }
}

public enum AgentMailSearchScope: String, Sendable, Equatable {
    case localDatabase
    case localAndRemote
}

public enum AgentRemoteSearchState: Sendable, Equatable {
    case searched
    case partial(String)
    case unavailable(String)
    case failed(String)
}

public struct AgentRemoteSearchStatus: Sendable, Equatable {
    public let accountID: String
    public let state: AgentRemoteSearchState
    public let resultEstimate: Int?

    public init(accountID: String, state: AgentRemoteSearchState, resultEstimate: Int? = nil) {
        self.accountID = accountID
        self.state = state
        self.resultEstimate = resultEstimate
    }
}

public struct AgentMailSearchRequest: Sendable, Equatable {
    public let query: String
    public let accountIDs: Set<String>
    public let bucket: TriageBucket?
    public let receivedAfter: Date?
    public let receivedBefore: Date?
    public let includeRemote: Bool

    public init(
        query: String,
        accountIDs: Set<String>,
        bucket: TriageBucket? = nil,
        receivedAfter: Date? = nil,
        receivedBefore: Date? = nil,
        includeRemote: Bool = true
    ) {
        self.query = query
        self.accountIDs = accountIDs
        self.bucket = bucket
        self.receivedAfter = receivedAfter
        self.receivedBefore = receivedBefore
        self.includeRemote = includeRemote
    }
}

public struct AgentMailSearchResult: Sendable, Equatable {
    public let messages: [Message]
    public let scope: AgentMailSearchScope
    public let remote: [AgentRemoteSearchStatus]

    public init(
        messages: [Message], scope: AgentMailSearchScope,
        remote: [AgentRemoteSearchStatus] = []
    ) {
        self.messages = messages
        self.scope = scope
        self.remote = remote
    }
}

/// Busca o acervo SQLite inteiro e, quando a conta realmente oferece isso,
/// sincroniza os resultados remotos antes de devolver a resposta.
public protocol AgentMailSearching: Sendable {
    func search(_ request: AgentMailSearchRequest) async throws -> AgentMailSearchResult
}

/// A forma de calendário que a ferramenta recebe. Horários são instantes com
/// fuso explícito; o adaptador converte para o modelo `AgendaItem` do produto.
public struct AgentCalendarDraft: Sendable, Equatable {
    public let id: String
    public let accountID: String
    public let title: String
    public let startsAt: Date
    public let endsAt: Date
    public let place: String
    public let note: String
    public let calendarID: String?

    public init(
        id: String, accountID: String, title: String, startsAt: Date, endsAt: Date,
        place: String = "", note: String = "", calendarID: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.place = place
        self.note = note
        self.calendarID = calendarID
    }
}

public enum AgentCalendarSyncState: Sendable, Equatable {
    case synchronized
    /// A conta só tem o calendário local do OkamiUNI; não há um servidor
    /// externo configurado para ela receber esta alteração.
    case localOnly(String)
}

public struct AgentCalendarMutation: Sendable, Equatable {
    public let item: AgendaItem?
    public let sync: AgentCalendarSyncState
    public let didChange: Bool

    public init(item: AgendaItem?, sync: AgentCalendarSyncState, didChange: Bool) {
        self.item = item
        self.sync = sync
        self.didChange = didChange
    }
}

/// Porta de calendário idempotente. Ela persiste a projeção local e usa o
/// `CalendarSyncing` existente quando há um calendário externo configurado.
public protocol AgentCalendarManaging: Sendable {
    func event(id: String) async throws -> AgendaItem?
    func search(query: String, accountIDs: Set<String>) async throws -> [AgendaItem]
    func create(_ draft: AgentCalendarDraft) async throws -> AgentCalendarMutation
    func update(_ draft: AgentCalendarDraft) async throws -> AgentCalendarMutation
    func delete(id: String, accountID: String) async throws -> AgentCalendarMutation
}

/// Sanitização deliberadamente conservadora para HTML que o agente salva em um
/// rascunho. Mantém layout e `cid:` existentes; remove conteúdo executável e
/// esquemas que podem carregar arquivo local ou script.
public enum AgentDraftHTML {
    public static let maximumByteCount = 200_000

    public static func sanitize(_ html: String) throws -> String {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              html.utf8.count <= maximumByteCount
        else { throw AgentToolError.invalidArguments("O HTML do rascunho está vazio ou grande demais.") }

        var result = html.unicodeScalars.filter {
            $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\t" || $0 == "\r"
        }.map(String.init).joined()
        result = replacing(
            result,
            pattern: #"<(script|iframe|object|embed|applet|frame|frameset|base|link|meta)\b[^>]*>.*?</\1\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators], with: ""
        )
        result = replacing(
            result,
            pattern: #"<(script|iframe|object|embed|applet|frame|frameset|base|link|meta)\b[^>]*?/?>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators], with: ""
        )
        result = replacing(
            result,
            pattern: #"\s+on[a-z0-9_-]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            options: [.caseInsensitive], with: ""
        )
        result = replacing(
            result,
            pattern: #"\s+(?:href|src|action|formaction|background|srcset)\s*=\s*(?:\"\s*(?:javascript|vbscript|file)\s*:[^\"]*\"|'\s*(?:javascript|vbscript|file)\s*:[^']*'|(?:javascript|vbscript|file)\s*:[^\s>]+)"#,
            options: [.caseInsensitive], with: ""
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AgentToolError.invalidArguments("O HTML não contém conteúdo seguro para salvar.") }
        return result
    }

    /// Conserva o metadado que a janela do compositor usa para reabrir a
    /// assinatura já materializada. O HTML visual da assinatura pertence ao
    /// fragmento que o agente recebeu; se ele o omitir, a atualização é
    /// rejeitada para não apagar algo que o usuário não consegue reconstruir.
    public static func preservingSignature(from old: String?, in replacement: String) throws -> String {
        guard let old, let marker = signatureMarker(in: old) else { return replacement }
        guard replacement.contains(marker) else {
            throw AgentToolError.invalidArguments(
                "Este rascunho contém uma assinatura. Inclua o HTML atual e o metadado da assinatura ao atualizar."
            )
        }
        return replacement
    }

    private static func signatureMarker(in html: String) -> String? {
        guard let start = html.range(of: "<!--okamiuni-signature:")?.lowerBound,
              let end = html.range(of: "-->", range: start..<html.endIndex)?.upperBound
        else { return nil }
        return String(html[start..<end])
    }

    private static func replacing(
        _ source: String, pattern: String, options: NSRegularExpression.Options, with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return source }
        return regex.stringByReplacingMatches(
            in: source, range: NSRange(source.startIndex..., in: source), withTemplate: replacement
        )
    }
}
