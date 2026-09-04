import Foundation

/// Um e-mail que pode servir como contexto factual para o assistente.
///
/// O conteúdo é sempre tratado como dado: ele pode conter texto arbitrário e
/// não deve alterar a política do assistente.
public struct AssistantEmailContext: Sendable, Hashable {
    /// O id da mensagem no app, quando este contexto veio de uma.
    ///
    /// Existe por causa do validador da §4: uma proposta só pode citar
    /// mensagem que estava **neste** contexto, e sem o id não há como afirmar
    /// isso — o validador teria de recusar tudo ou confiar em tudo. `nil` para
    /// um contexto montado à mão (teste, prévia), e nesse caso nenhuma ação
    /// sobre mensagem sobrevive, que é o lado seguro.
    public let messageID: String?
    /// A mensagem já tem compromisso detectado e **persistido**.
    ///
    /// `addToAgenda` depende disto: pôr na agenda um compromisso que o modelo
    /// inventou na hora do clique seria a IA decidindo data sozinha.
    public let hasDetectedEvent: Bool
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
        html: String? = nil,
        messageID: String? = nil,
        hasDetectedEvent: Bool = false
    ) {
        self.messageID = messageID
        self.hasDetectedEvent = hasDetectedEvent
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
public struct AssistantMailboxContext: Sendable, Hashable {
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
public struct AssistantAgendaContext: Sendable, Hashable {
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
public struct AssistantWorkspaceEmailContext: Sendable, Hashable {
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

public struct AssistantPendingContext: Sendable, Hashable {
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
public struct AssistantWorkspaceContext: Sendable, Hashable {
    /// Quantos e-mails prioritários recebem cabeçalho e prévia no prompt.
    /// Totais e contagens continuam cobrindo o ambiente inteiro.
    public static let detailedEmailLimit = 24

    public let accounts: [String]
    public let emailCount: Int
    public let unreadCount: Int
    public let mailboxes: [AssistantMailboxContext]
    public let emails: [AssistantWorkspaceEmailContext]
    public let agenda: [AssistantAgendaContext]
    public let pendingItems: [AssistantPendingContext]

    public init(
        accounts: [String],
        emailCount: Int,
        unreadCount: Int,
        mailboxes: [AssistantMailboxContext],
        emails: [AssistantWorkspaceEmailContext],
        agenda: [AssistantAgendaContext],
        pendingItems: [AssistantPendingContext] = []
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

public extension AssistantMailContext {
    /// Os ids das mensagens **deste** contexto — o universo em que uma
    /// proposta pode agir. Ver `AssistantProposalValidator`.
    var messageIDs: Set<String> {
        switch self {
        case let .email(email):
            Set([email.messageID].compactMap { $0 })
        case let .conversation(emails):
            Set(emails.compactMap(\.messageID))
        case let .workspace(workspace):
            Set(workspace.emails.map(\.id))
        }
    }

    /// Quais deles já têm compromisso detectado e persistido.
    ///
    /// O retrato global fica de fora de propósito: ele carrega cabeçalho e
    /// prévia, não o compromisso — e afirmar que existe um sem ter lido a
    /// mensagem seria a mesma invenção que o validador existe para barrar.
    var messageIDsWithEvent: Set<String> {
        switch self {
        case let .email(email):
            Set(email.hasDetectedEvent ? [email.messageID].compactMap { $0 } : [])
        case let .conversation(emails):
            Set(emails.filter(\.hasDetectedEvent).compactMap(\.messageID))
        case .workspace:
            []
        }
    }
}

/// O que uma pergunta devolve quando o assistente pode propor ações.
public struct AssistantAnswer: Sendable, Hashable {
    /// A prosa, já sem o bloco de ações.
    public let text: String
    /// As propostas que sobreviveram ao parser **e** ao validador.
    public let proposals: [AssistantProposal]

    public init(text: String, proposals: [AssistantProposal] = []) {
        self.text = text
        self.proposals = proposals
    }
}

/// O contexto de e-mail disponível para uma pergunta factual.
///
/// Um `.email` representa a leitura atual. Um `.conversation` preserva a
/// ordem dos e-mails de uma conversa, do mais antigo para o mais recente.
public enum AssistantMailContext: Sendable, Hashable {
    case email(AssistantEmailContext)
    case conversation([AssistantEmailContext])
    /// O nome histórico do tipo é mantido para não quebrar os consumidores de
    /// escrita, mas perguntas globais podem receber o ambiente local completo.
    case workspace(AssistantWorkspaceContext)
}

/// A origem de cada turno da conversa com o assistente.
public enum AssistantTurnRole: String, Sendable, Hashable {
    case user
    case assistant
}

/// Um turno anterior da conversa com o assistente.
///
/// O histórico é somente contexto de linguagem; não é uma fonte factual mais
/// confiável do que os e-mails originais.
public struct AssistantTurn: Sendable, Hashable {
    public let role: AssistantTurnRole
    public let text: String

    public init(role: AssistantTurnRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// O contexto completo de uma pergunta ao assistente.
public struct AssistantConversationSnapshot: Sendable, Hashable {
    public let mailContext: AssistantMailContext
    public let turns: [AssistantTurn]

    public init(
        mailContext: AssistantMailContext,
        turns: [AssistantTurn] = []
    ) {
        self.mailContext = mailContext
        self.turns = turns
    }
}

/// Transformações de escrita disponíveis sem expor detalhes do modelo à UI.
public enum WritingAction: Sendable, Hashable {
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
public enum TextAssistantError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(AppleIntelligenceAvailability)
    case invalidRequest(String)
    case emptyResponse
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(.available):
            return L10n.tr("O assistente não está disponível neste momento.")
        case .unavailable(.deviceNotEligible):
            return L10n.tr("Este dispositivo não é elegível para a Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return L10n.tr("A Apple Intelligence está desativada neste dispositivo.")
        case .unavailable(.modelNotReady):
            return L10n.tr("O modelo da Apple Intelligence ainda não está pronto.")
        case let .invalidRequest(message):
            return message
        case .emptyResponse:
            return L10n.tr("O assistente devolveu uma resposta vazia.")
        case let .generationFailed(message):
            return message
        }
    }
}

/// A porta assíncrona para perguntas sobre e-mail e transformações de escrita.
///
/// Implementações vivem fora de UNICore para que este pacote permaneça puro,
/// usando somente Foundation e Observation.
public protocol TextAssisting: Sendable {
    var modelVersion: String { get }

    func availability() async -> AppleIntelligenceAvailability
    func answer(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> String
    func transform(
        _ text: String,
        using action: WritingAction,
        context: AssistantMailContext?
    ) async throws -> String
    /// A mesma pergunta, com as propostas de ação da §4 quando houver ação a
    /// propor.
    ///
    /// Está aqui, e não só no `AssistantRouter`, porque a superfície que
    /// pergunta segura `any TextAssisting` — e sem este requisito a gaveta
    /// teria de conhecer o roteador concreto de UNISync para pedir propostas.
    /// O padrão abaixo é o honesto para quem não sabe propor: a resposta em
    /// texto, sem cartão nenhum.
    func answerWithProposals(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> AssistantAnswer
}

public extension TextAssisting {
    func answerWithProposals(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> AssistantAnswer {
        AssistantAnswer(text: try await answer(question: question, in: conversation))
    }
}

public extension TextAssisting {
    /// Conveniência para as transformações que não precisam ler o e-mail.
    func transform(
        _ text: String,
        using action: WritingAction
    ) async throws -> String {
        try await transform(text, using: action, context: nil)
    }
}
