import Foundation

/// Um e-mail que pode servir como contexto factual para o assistente local.
///
/// O conteúdo é sempre tratado como dado: ele pode conter texto arbitrário e
/// não deve alterar a política do assistente.
public struct OnDeviceAssistantEmailContext: Sendable, Hashable {
    public let subject: String
    public let sender: String
    public let recipients: [String]
    public let sentAt: Date?
    public let body: String
    /// HTML sanitizado da mensagem, quando existe. O adaptador remoto usa isto
    /// para montar o texto completo: o `text/plain` do Gmail costuma ser só a
    /// abertura, e o restante mora no HTML.
    public let html: String?

    public init(
        subject: String,
        sender: String,
        recipients: [String] = [],
        sentAt: Date? = nil,
        body: String,
        html: String? = nil
    ) {
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.sentAt = sentAt
        self.body = body
        self.html = html
    }
}

/// Uma contagem de caixa que dá ao assistente a visão do ambiente inteiro sem
/// obrigá-lo a deduzir totais a partir do recorte de e-mails detalhados.
public struct OnDeviceAssistantMailboxContext: Sendable, Hashable {
    public let name: String
    public let totalCount: Int
    public let unreadCount: Int

    public init(name: String, totalCount: Int, unreadCount: Int) {
        self.name = name
        self.totalCount = totalCount
        self.unreadCount = unreadCount
    }
}

/// Um compromisso disponível no ambiente local do app.
public struct OnDeviceAssistantAgendaContext: Sendable, Hashable {
    public let title: String
    public let date: Date
    public let startMinute: Int
    public let endMinute: Int
    public let account: String
    public let place: String?

    public init(
        title: String,
        date: Date,
        startMinute: Int,
        endMinute: Int,
        account: String,
        place: String? = nil
    ) {
        self.title = title
        self.date = date
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.account = account
        self.place = place
    }
}

/// Cabeçalho e prévia de um e-mail dentro do retrato global. O corpo integral
/// permanece reservado ao botão contextual do leitor.
public struct OnDeviceAssistantWorkspaceEmailContext: Sendable, Hashable {
    public let id: String
    public let account: String
    public let mailbox: String
    public let isRead: Bool
    public let isFlagged: Bool
    public let subject: String
    public let sender: String
    public let recipients: [String]
    public let sentAt: Date
    public let snippet: String

    public init(
        id: String,
        account: String,
        mailbox: String,
        isRead: Bool,
        isFlagged: Bool,
        subject: String,
        sender: String,
        recipients: [String],
        sentAt: Date,
        snippet: String
    ) {
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.sentAt = sentAt
        self.snippet = snippet
    }
}

public struct OnDeviceAssistantPendingContext: Sendable, Hashable {
    public let text: String
    public let account: String

    public init(text: String, account: String) {
        self.text = text
        self.account = account
    }
}

/// Retrato local do OkamiUNI usado pelo botão global: todas as caixas
/// carregadas, os e-mails disponíveis e a agenda, sem depender da mensagem
/// que por acaso esteja aberta no leitor.
public struct OnDeviceAssistantWorkspaceContext: Sendable, Hashable {
    /// Quantos e-mails prioritários recebem cabeçalho e prévia no prompt.
    /// Totais e contagens continuam cobrindo o ambiente inteiro.
    public static let detailedEmailLimit = 24

    public let accounts: [String]
    public let emailCount: Int
    public let unreadCount: Int
    public let mailboxes: [OnDeviceAssistantMailboxContext]
    public let emails: [OnDeviceAssistantWorkspaceEmailContext]
    public let agenda: [OnDeviceAssistantAgendaContext]
    public let pendingItems: [OnDeviceAssistantPendingContext]

    public init(
        accounts: [String],
        emailCount: Int,
        unreadCount: Int,
        mailboxes: [OnDeviceAssistantMailboxContext],
        emails: [OnDeviceAssistantWorkspaceEmailContext],
        agenda: [OnDeviceAssistantAgendaContext],
        pendingItems: [OnDeviceAssistantPendingContext] = []
    ) {
        self.accounts = accounts
        self.emailCount = emailCount
        self.unreadCount = unreadCount
        self.mailboxes = mailboxes
        self.emails = emails
        self.agenda = agenda
        self.pendingItems = pendingItems
    }
}

/// O contexto de e-mail disponível para uma pergunta factual.
///
/// Um `.email` representa a leitura atual. Um `.conversation` preserva a
/// ordem dos e-mails de uma conversa, do mais antigo para o mais recente.
public enum OnDeviceAssistantMailContext: Sendable, Hashable {
    case email(OnDeviceAssistantEmailContext)
    case conversation([OnDeviceAssistantEmailContext])
    /// O nome histórico do tipo é mantido para não quebrar os consumidores de
    /// escrita, mas perguntas globais podem receber o ambiente local completo.
    case workspace(OnDeviceAssistantWorkspaceContext)
}

/// A origem de cada turno da conversa com o assistente.
public enum OnDeviceAssistantTurnRole: String, Sendable, Hashable {
    case user
    case assistant
}

/// Um turno anterior da conversa com o assistente local.
///
/// O histórico é somente contexto de linguagem; não é uma fonte factual mais
/// confiável do que os e-mails originais.
public struct OnDeviceAssistantTurn: Sendable, Hashable {
    public let role: OnDeviceAssistantTurnRole
    public let text: String

    public init(role: OnDeviceAssistantTurnRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// O contexto completo de uma pergunta ao assistente local.
public struct OnDeviceAssistantConversation: Sendable, Hashable {
    public let mailContext: OnDeviceAssistantMailContext
    public let turns: [OnDeviceAssistantTurn]

    public init(
        mailContext: OnDeviceAssistantMailContext,
        turns: [OnDeviceAssistantTurn] = []
    ) {
        self.mailContext = mailContext
        self.turns = turns
    }
}

/// Transformações de escrita disponíveis sem expor detalhes do modelo à UI.
public enum OnDeviceWritingAction: Sendable, Hashable {
    case summarize
    case rewriteForClarity
    case shorten
    case formalize
    case makeFriendly
    case correctPortuguese
    /// Cria uma resposta a partir do contexto de e-mail. Diferentemente das
    /// demais ações, pode receber um rascunho atual vazio.
    case draftReply
    case customInstruction(String)
}

/// Falhas que a interface pode apresentar sem importar FoundationModels.
public enum OnDeviceTextAssistantError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(OnDeviceMessageAnalysisAvailability)
    case invalidRequest(String)
    case emptyResponse
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(.available):
            return "O assistente local não está disponível neste momento."
        case .unavailable(.deviceNotEligible):
            return "Este dispositivo não é elegível para o assistente local."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "A Apple Intelligence está desativada neste dispositivo."
        case .unavailable(.modelNotReady):
            return "O modelo local ainda não está pronto."
        case let .invalidRequest(message):
            return message
        case .emptyResponse:
            return "O assistente local devolveu uma resposta vazia."
        case let .generationFailed(message):
            return message
        }
    }
}

/// A porta assíncrona para perguntas sobre e-mail e transformações de escrita.
///
/// Implementações vivem fora de UNICore para que este pacote permaneça puro,
/// usando somente Foundation e Observation.
public protocol OnDeviceTextAssisting: Sendable {
    var modelVersion: String { get }

    func availability() async -> OnDeviceMessageAnalysisAvailability
    func answer(
        question: String,
        in conversation: OnDeviceAssistantConversation
    ) async throws -> String
    func transform(
        _ text: String,
        using action: OnDeviceWritingAction,
        context: OnDeviceAssistantMailContext?
    ) async throws -> String
}

public extension OnDeviceTextAssisting {
    /// Conveniência para as transformações que não precisam ler o e-mail.
    func transform(
        _ text: String,
        using action: OnDeviceWritingAction
    ) async throws -> String {
        try await transform(text, using: action, context: nil)
    }
}
