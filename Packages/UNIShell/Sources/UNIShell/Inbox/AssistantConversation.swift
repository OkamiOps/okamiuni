import Foundation
import Observation
import UNICore
import UNISync

/// Se um turno é conversa ou prosa de email. Um rascunho não passa pelo
/// renderizador de Markdown: asterisco ali é literal.
public enum AssistantTurnKind: String, Sendable, Hashable {
    case message
    case draft
}

public enum AssistantSpeaker: String, Sendable, Hashable {
    case user
    case assistant
}

public struct AssistantMessage: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let speaker: AssistantSpeaker
    public let text: String
    public let kind: AssistantTurnKind
    /// As propostas de ação que vieram **com** este turno (§4). Já passaram
    /// pelo validador do roteador: o que ele descartou não chega aqui, e por
    /// isso não vira cartão.
    public let proposals: [AssistantProposal]

    public init(
        id: UUID = UUID(),
        speaker: AssistantSpeaker,
        text: String,
        kind: AssistantTurnKind = .message,
        proposals: [AssistantProposal] = []
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.kind = kind
        self.proposals = proposals
    }

    /// Os cartões deste turno, na ordem em que a resposta os propôs.
    public var cards: [AssistantProposalCard] {
        AssistantProposalCard.cards(for: proposals, turnID: id.uuidString)
    }
}

/// A entrada entregue ao motor por uma fiação externa ao shell.
public struct AssistantRequest: Sendable, Hashable {
    public let context: AssistantContext
    public let question: String
    public let conversation: [AssistantMessage]

    public init(context: AssistantContext, question: String, conversation: [AssistantMessage]) {
        self.context = context
        self.question = question
        self.conversation = conversation
    }
}

/// As duas rotas que o assistente tem. Separá-las é o conserto: o
/// dashboard mandava "escreva um rascunho" por `answer()`, cujo prompt
/// pede Markdown, e o rascunho voltava com asteriscos e listas.
@MainActor
public struct AssistantEngine {
    public let supportsDraftReply: Bool
    public let answer: (AssistantRequest) async throws -> String
    public let draftReply: (AssistantRequest) async throws -> String
    /// A mesma pergunta, com as propostas de ação da §4.
    ///
    /// Rota separada, e não uma bandeira no `answer`: o painel antigo pede
    /// prosa e a gaveta pede prosa **mais** estrutura, e o roteador tem
    /// caminhos diferentes para as duas. O padrão embrulha o `answer` — quem
    /// não sabe propor devolve a resposta sem cartão nenhum, em vez de
    /// prometer um botão que não existe.
    public let answerWithProposals: (AssistantRequest) async throws -> AssistantAnswer

    public init(
        supportsDraftReply: Bool,
        answer: @escaping (AssistantRequest) async throws -> String,
        draftReply: @escaping (AssistantRequest) async throws -> String = { _ in
            throw TextAssistantError.invalidRequest(L10n.tr("Criar uma resposta requer contexto de e-mail."))
        },
        answerWithProposals: ((AssistantRequest) async throws -> AssistantAnswer)? = nil
    ) {
        self.supportsDraftReply = supportsDraftReply
        self.answer = answer
        self.draftReply = draftReply
        self.answerWithProposals = answerWithProposals
            ?? { AssistantAnswer(text: try await answer($0)) }
    }
}

public extension AssistantEngine {
    /// Motor de uma superfície sem assistente conectado: previews, harness e
    /// o app antes de escolher um provedor. Falha dizendo o que fazer, em vez
    /// de deixar botão aceso e mudo.
    static let unavailable = AssistantEngine(supportsDraftReply: false) { _ in
        throw TextAssistantError.invalidRequest(
            L10n.tr("O assistente não foi conectado a esta janela.")
        )
    }
}

/// Estado construível para previews e renderização fora da tela.
public struct AssistantPanelDebugState: Sendable, Hashable {
    public var messages: [AssistantMessage]
    public var draft: String
    public var isLoading: Bool
    public var failure: AssistantFailure?
    public var briefingText: String?

    public init(
        messages: [AssistantMessage] = [],
        draft: String = "",
        isLoading: Bool = false,
        failure: AssistantFailure? = nil,
        briefingText: String? = nil
    ) {
        self.messages = messages
        self.draft = draft
        self.isLoading = isLoading
        self.failure = failure
        self.briefingText = briefingText
    }

    public static let empty = AssistantPanelDebugState()
}

public extension AssistantDestination {
    /// Enquanto nenhum provedor foi escolhido não há rota que descrever, e
    /// prometer "local" seria mentira. O rodapé manda a pessoa aos Ajustes.
    ///
    /// O rótulo dizia "Provedor configurado" — exatamente o contrário do que
    /// este valor significa, e era o que o dashboard escrevia debaixo do campo
    /// numa instalação sem provedor nenhum. A rota em si sempre esteve certa
    /// (`InboxScreen.assistantDestination` deriva de `AssistantSettings` e só
    /// cai aqui na ausência dela); o defeito era só a frase.
    static let unconfigured = AssistantDestination(
        label: L10n.tr("Sem provedor"),
        detail: L10n.tr("Escolha o provedor nos Ajustes."),
        isLocal: false
    )
}

/// A única dona de transcript, `isLoading`, `failure` e `task`.
///
/// Painel, dashboard, janela de mensagem e popover do leitor recebem uma
/// instância por injeção. Antes havia duas máquinas de estado com regras
/// diferentes para a mesma pergunta, e nenhuma delas cancelava nada.
@MainActor
@Observable
public final class AssistantConversation {
    /// Vale em toda superfície. Antes o painel mandava tudo e o dashboard
    /// mandava 16 — a mesma conversa custava preços diferentes. É
    /// `nonisolated` porque a ponte monta o histórico fora do MainActor.
    public nonisolated static let maximumHistoryTurns = 16

    public static let summaryQuestion =
        "Faça um resumo útil desta conversa, destacando o que importa."

    /// A pergunta fixa do briefing (spec §2.5). É constante para o
    /// resultado ser comparável entre dias e provedores.
    public static let briefingQuestion = """
        Faça um briefing do meu dia em até 120 palavras: o que exige \
        resposta hoje, os compromissos de hoje em ordem, e o que pode \
        esperar. Cite remetentes e horários.
        """

    public private(set) var messages: [AssistantMessage]
    public var draft: String
    public private(set) var isLoading: Bool
    public private(set) var failure: AssistantFailure?
    /// Sessão, não persiste, e é independente do transcript. O nome não é
    /// `briefing` porque o método com esse nome já ocupa o identificador.
    public private(set) var briefingText: String?

    public let scope: AssistantScope
    public let context: AssistantContext

    /// **Lido na hora de desenhar, nunca congelado na construção.**
    ///
    /// Ajustes é outra janela, e o dashboard guarda esta conversa em `@State`
    /// pela sessão inteira. Com um valor fixo aqui, trocar de provedor deixava
    /// o rodapé e o "Lendo o contexto neste Mac…" prometendo local enquanto o
    /// pedido saía para a xAI — o defeito da spec §1.2, de volta pelo cache.
    public var destination: AssistantDestination { destinationProvider() }

    /// Pelo mesmo motivo: o botão de erro precisa nomear a assinatura de
    /// **agora**, não a que estava escolhida quando a tela abriu.
    private var provider: AssistantProviderOAuthKind? { providerProvider() }

    private let destinationProvider: @Sendable () -> AssistantDestination
    private let providerProvider: @Sendable () -> AssistantProviderOAuthKind?
    private let engine: AssistantEngine
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var lastAction: Action?

    enum Action: Equatable {
        case ask(String)
        case draftReply
        case briefing
    }

    /// A conveniência para quem tem um destino fixo de verdade: previews,
    /// harnesses e o popover do leitor, que nasce e morre num clique.
    public convenience init(
        scope: AssistantScope,
        context: AssistantContext,
        destination: AssistantDestination,
        engine: AssistantEngine,
        provider: AssistantProviderOAuthKind? = nil,
        debugState: AssistantPanelDebugState = .empty
    ) {
        self.init(
            scope: scope,
            context: context,
            destination: { destination },
            engine: engine,
            provider: { provider },
            debugState: debugState
        )
    }

    public init(
        scope: AssistantScope,
        context: AssistantContext,
        destination: @escaping @Sendable () -> AssistantDestination,
        engine: AssistantEngine,
        provider: @escaping @Sendable () -> AssistantProviderOAuthKind? = { nil },
        debugState: AssistantPanelDebugState = .empty
    ) {
        self.scope = scope
        self.context = context
        self.destinationProvider = destination
        self.engine = engine
        self.providerProvider = provider
        self.messages = debugState.messages
        self.draft = debugState.draft
        self.isLoading = debugState.isLoading
        self.failure = debugState.failure
        self.briefingText = debugState.briefingText
    }

    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    /// Rascunho só existe com email ou conversa em contexto. Com o
    /// ambiente inteiro o botão não aparece — em vez de aparecer mudo.
    public var canDraftReply: Bool {
        engine.supportsDraftReply && scope == .email
    }

    public var canRetry: Bool { lastAction != nil && !isLoading }

    /// Que trabalho está no ar agora, para a barra fina do chrome poder
    /// nomeá-lo ("Perguntando ao Codex · ChatGPT"). `nil` em repouso.
    ///
    /// A dependência que o SwiftUI observa é `isLoading` — `lastAction` é
    /// `@ObservationIgnored` e é escrito **antes** dele —, então a barra
    /// acende e apaga no mesmo quadro em que a conversa muda de estado.
    public var workKind: AssistantWorkKind? {
        guard isLoading else { return nil }
        switch lastAction {
        case .ask: return .question
        case .draftReply: return .draft
        case .briefing: return .briefing
        case nil: return .question
        }
    }
    public var hasConversation: Bool { !messages.isEmpty }

    public func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        ask(question)
    }

    /// Uma sugestão sabe por qual rota sai. Toda "gerar resposta" da
    /// interface termina em `draftReply()`, nunca em `ask()`.
    public func run(_ suggestion: AssistantSuggestion) {
        switch suggestion.kind {
        case .question: ask(suggestion.question)
        case .draftReply: draftReply()
        }
    }

    public func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        start(.ask(question))
    }

    public func summarize() { ask(Self.summaryQuestion) }

    public func draftReply() {
        guard canDraftReply else { return }
        start(.draftReply)
    }

    public func briefing() { start(.briefing) }

    /// Fechar a superfície chama isto. Cancelamento não é falha: quem
    /// fechou a janela não precisa ver "não foi possível responder".
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
    }

    public func clear() {
        cancel()
        messages.removeAll()
        draft = ""
        failure = nil
        briefingText = nil
        lastAction = nil
    }

    public func retry() {
        guard let lastAction, !isLoading else { return }
        start(lastAction, appendingUserTurn: false)
    }

    private func start(_ action: Action, appendingUserTurn: Bool = true) {
        guard !isLoading else { return }
        lastAction = action
        failure = nil

        if case let .ask(question) = action, appendingUserTurn {
            messages.append(.init(speaker: .user, text: question))
        }

        isLoading = true
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.perform(action)
            // Um pedido cancelado já devolveu a máquina ao repouso em
            // `cancel()`; publicar aqui apagaria o pedido que veio depois.
            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.currentTask = nil
        }
    }

    private func perform(_ action: Action) async {
        let request = AssistantRequest(
            context: context,
            question: question(for: action),
            conversation: Array(messages.suffix(Self.maximumHistoryTurns + 1))
        )
        do {
            let text: String
            var propostas: [AssistantProposal] = []
            switch action {
            case .ask:
                // A gaveta e o painel dividem esta máquina, e o pedido é o
                // mesmo: quem não sabe propor devolve `proposals` vazio pelo
                // padrão do motor, e o painel antigo continua desenhando só
                // a prosa.
                let resposta = try await engine.answerWithProposals(request)
                text = resposta.text
                propostas = resposta.proposals
            case .briefing:
                text = try await engine.answer(request)
            case .draftReply:
                text = try await engine.draftReply(request)
            }
            guard !Task.isCancelled else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                failure = AssistantFailure(TextAssistantError.emptyResponse, provider: provider)
                return
            }
            switch action {
            case .ask:
                messages.append(
                    .init(speaker: .assistant, text: trimmed, proposals: propostas)
                )
            case .draftReply:
                messages.append(.init(speaker: .assistant, text: trimmed, kind: .draft))
            case .briefing:
                briefingText = trimmed
            }
        } catch is CancellationError {
            // Fechar a superfície não marca a conversa como falha.
        } catch {
            guard !Task.isCancelled else { return }
            failure = AssistantFailure(error, provider: provider)
        }
    }

    private func question(for action: Action) -> String {
        switch action {
        case let .ask(question): question
        case .briefing: Self.briefingQuestion
        // O rascunho parte do texto que já existe no composer; a ponte
        // resolve o rascunho atual e o entrega aqui. Vazio é legítimo.
        case .draftReply: ""
        }
    }
}

#if DEBUG
public extension AssistantConversation {
    /// Espera o pedido em voo terminar. Existe para o teste não precisar
    /// de `Task.sleep`, que é o que transforma suíte em loteria.
    func waitForIdle() async { await currentTask?.value }
}
#endif
