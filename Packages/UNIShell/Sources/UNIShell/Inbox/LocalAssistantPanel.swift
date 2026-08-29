import Foundation
import Observation
import SwiftUI
import UNIDesign

/// O pedaço de uma mensagem que acompanha uma pergunta local.
///
/// É deliberadamente pequeno: o shell apresenta o contexto para a pessoa e o
/// compositor decide qual conteúdo pode enviar ao motor. Não há referência a
/// Foundation Models aqui.
public struct LocalAssistantContext: Sendable, Hashable {
    public let subject: String
    public let sender: String?
    public let conversationLabel: String?

    public init(subject: String, sender: String? = nil, conversationLabel: String? = nil) {
        self.subject = subject
        self.sender = sender
        self.conversationLabel = conversationLabel
    }

    var title: String { subject.isEmpty ? "Email aberto" : subject }

    var detail: String {
        [sender, conversationLabel]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}

public struct LocalAssistantSuggestion: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let question: String

    public init(id: String? = nil, title: String? = nil, question: String) {
        self.id = id ?? question
        self.title = title ?? question
        self.question = question
    }

    public static let emailDefaults: [LocalAssistantSuggestion] = [
        .init(title: "Resumo", question: "Faça um resumo útil desta conversa, destacando o que importa."),
        .init(title: "Pontos-chave", question: "Liste os pontos-chave desta conversa."),
        .init(title: "Insights", question: "Analise esta conversa e identifique insights, riscos e pontos em aberto."),
        .init(title: "Pendências", question: "Liste pendências, responsáveis e prazos desta conversa."),
        .init(title: "Gerar resposta", question: "Prepare uma resposta completa, natural e pronta para revisão desta conversa."),
    ]

    public static let workspaceDefaults: [LocalAssistantSuggestion] = [
        .init(title: "Resumo geral", question: "Resuma meu ambiente: caixas, e-mails, agenda e pendências."),
        .init(title: "Prioridades", question: "Quais são minhas prioridades agora considerando e-mails e agenda?"),
        .init(title: "Não lidos", question: "Organize os e-mails não lidos mais importantes e diga por onde começar."),
        .init(title: "Agenda", question: "Resuma minha agenda e aponte conflitos, lacunas ou preparações necessárias."),
        .init(title: "Riscos e pendências", question: "Cruze e-mails, agenda e pendências e identifique riscos ou itens esquecidos."),
    ]
}

/// Define se o painel fala da mensagem aberta ou do ambiente inteiro. A
/// separação é visível e também decide o catálogo de ações rápidas.
public enum LocalAssistantMode: Sendable, Hashable {
    case email
    case workspace

    var title: String {
        switch self {
        case .email: "Inteligência do email"
        case .workspace: "Assistente do ambiente"
        }
    }

    var contextLabel: String {
        switch self {
        case .email: "CONTEXTO DO EMAIL"
        case .workspace: "AMBIENTE LOCAL"
        }
    }

    var emptyTitle: String {
        switch self {
        case .email: "Ações rápidas"
        case .workspace: "O que você quer organizar?"
        }
    }

    var emptyDetail: String {
        switch self {
        case .email: "Escolha uma ação ou escreva uma pergunta sobre este email."
        case .workspace: "Pergunte sobre suas caixas, emails, agenda e pendências."
        }
    }

    var placeholder: String {
        switch self {
        case .email: "Pergunte sobre este email…"
        case .workspace: "Pergunte sobre seu ambiente…"
        }
    }

    var accessibilitySubject: String {
        switch self {
        case .email: "o email"
        case .workspace: "o ambiente"
        }
    }

    var footer: String {
        switch self {
        case .email: "Usa a mensagem ou conversa aberta."
        case .workspace: "Usa todas as caixas e a agenda carregadas neste Mac."
        }
    }

    var suggestions: [LocalAssistantSuggestion] {
        switch self {
        case .email: LocalAssistantSuggestion.emailDefaults
        case .workspace: LocalAssistantSuggestion.workspaceDefaults
        }
    }
}

public enum LocalAssistantSpeaker: String, Sendable, Hashable {
    case user
    case assistant
}

public struct LocalAssistantMessage: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let speaker: LocalAssistantSpeaker
    public let text: String

    public init(id: UUID = UUID(), speaker: LocalAssistantSpeaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

/// A entrada entregue ao motor por uma fiação externa ao shell.
public struct LocalAssistantRequest: Sendable, Hashable {
    public let context: LocalAssistantContext
    public let question: String
    public let conversation: [LocalAssistantMessage]

    public init(context: LocalAssistantContext, question: String, conversation: [LocalAssistantMessage]) {
        self.context = context
        self.question = question
        self.conversation = conversation
    }
}

/// Estado construível para previews e renderização fora da tela. Ele elimina a
/// necessidade de disparar uma pergunta de verdade só para conferir a UI.
public struct LocalAssistantPanelDebugState: Sendable, Hashable {
    public var messages: [LocalAssistantMessage]
    public var draft: String
    public var isLoading: Bool
    public var errorMessage: String?
    public var lastQuestion: String?

    public init(
        messages: [LocalAssistantMessage] = [],
        draft: String = "",
        isLoading: Bool = false,
        errorMessage: String? = nil,
        lastQuestion: String? = nil
    ) {
        self.messages = messages
        self.draft = draft
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.lastQuestion = lastQuestion
    }

    public static let empty = LocalAssistantPanelDebugState()
}

/// Estado observável da conversa. Mantê-lo no shell torna a transição
/// pergunta → carregando → resposta/erro testável sem acoplar a View a um
/// motor concreto.
@MainActor
@Observable
public final class LocalAssistantConversation {
    public private(set) var messages: [LocalAssistantMessage]
    public var draft: String
    public private(set) var isLoading: Bool
    public private(set) var errorMessage: String?

    private let context: LocalAssistantContext
    private let onAsk: (LocalAssistantRequest) async throws -> String
    private var lastQuestion: String?

    public init(
        context: LocalAssistantContext,
        debugState: LocalAssistantPanelDebugState = .empty,
        onAsk: @escaping (LocalAssistantRequest) async throws -> String
    ) {
        self.context = context
        self.messages = debugState.messages
        self.draft = debugState.draft
        self.isLoading = debugState.isLoading
        self.errorMessage = debugState.errorMessage
        self.lastQuestion = debugState.lastQuestion
        self.onAsk = onAsk
    }

    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canRetry: Bool {
        lastQuestion != nil && !isLoading
    }

    public var hasConversation: Bool { !messages.isEmpty }

    /// Uma ação rápida é realmente de um toque: entra no mesmo fluxo de
    /// pergunta, carregamento, resposta e retry do campo livre.
    public func run(_ suggestion: LocalAssistantSuggestion) async {
        guard !isLoading else { return }
        draft = suggestion.question
        await submit()
    }

    public func clear() {
        guard !isLoading else { return }
        messages.removeAll()
        draft = ""
        errorMessage = nil
        lastQuestion = nil
    }

    public func submit() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }

        messages.append(.init(speaker: .user, text: question))
        draft = ""
        lastQuestion = question
        await ask(question)
    }

    public func retry() async {
        guard let lastQuestion, !isLoading else { return }
        await ask(lastQuestion)
    }

    private func ask(_ question: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await onAsk(
                .init(context: context, question: question, conversation: messages)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !response.isEmpty else {
                errorMessage = LocalAssistantCopy.emptyResponse
                return
            }
            messages.append(.init(speaker: .assistant, text: response))
        } catch is CancellationError {
            // Fechar uma janela não deve deixar a conversa marcada como falha.
        } catch {
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            // O estado pode mudar entre abrir o painel e fazer a pergunta
            // (Apple Intelligence desligada, modelo ainda preparando). Quando o
            // motor explica o motivo, a pessoa precisa vê-lo; a frase genérica
            // só cobre erros sem descrição aproveitável.
            errorMessage = description.isEmpty ? LocalAssistantCopy.requestFailed : description
        }
    }
}

/// Painel de perguntas sobre a mensagem aberta ou sobre o ambiente local.
///
/// A resposta é uma closure assíncrona injetada pelo app. Por isso esta peça
/// pode ser renderizada e testada sem acesso ao Foundation Models, sem rede e
/// sem saber como o conteúdo da mensagem foi obtido.
public struct LocalAssistantPanel: View {
    public static let defaultWidth: CGFloat = 360

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var conversation: LocalAssistantConversation

    private let mode: LocalAssistantMode
    private let context: LocalAssistantContext
    private let suggestions: [LocalAssistantSuggestion]
    private let onClose: () -> Void
    private let width: CGFloat

    public init(
        mode: LocalAssistantMode = .email,
        context: LocalAssistantContext,
        suggestions: [LocalAssistantSuggestion]? = nil,
        width: CGFloat = LocalAssistantPanel.defaultWidth,
        debugState: LocalAssistantPanelDebugState = .empty,
        onAsk: @escaping (LocalAssistantRequest) async throws -> String,
        onClose: @escaping () -> Void
    ) {
        self.mode = mode
        self.context = context
        self.suggestions = suggestions ?? mode.suggestions
        self.width = width
        self.onClose = onClose
        _conversation = State(
            initialValue: LocalAssistantConversation(
                context: context,
                debugState: debugState,
                onAsk: onAsk
            )
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            contextBand
            DividerLine(theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if conversation.hasConversation {
                        transcript
                    } else {
                        emptyConversation
                    }

                    if let error = conversation.errorMessage {
                        errorBand(error)
                    }

                    if conversation.isLoading {
                        loadingBand
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)

            composer
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface2.color)
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .accessibilityIdentifier("local-assistant-panel")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 21, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.accent.color)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(theme.serif.font(size: 18, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("PROCESSADO NESTE MAC")
                    .font(theme.mono.font(size: 9, weight: .medium))
                    .tracking(theme.capsTracking(at: 9))
                    .foregroundStyle(theme.ink4.color)
            }
            // Reserva fixa para que a presença de uma barra de rolagem no
            // transcript não possa expulsar título nem botões da moldura.
            .frame(width: 190, alignment: .leading)
            Spacer(minLength: 0)

            if conversation.hasConversation {
                Button(action: conversation.clear) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(theme.ink3.color)
                        .background(theme.surface3.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                    .buttonStyle(.plain)
                    .focusRing(cornerRadius: theme.radiusSmall)
                    .disabled(conversation.isLoading)
                    .help("Limpar esta conversa")
                    .accessibilityLabel("Limpar conversa")
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(theme.ink3.color)
                    .background(theme.surface3.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .help("Fechar painel de perguntas")
            .accessibilityLabel("Fechar perguntas sobre \(mode.accessibilitySubject)")
        }
        .padding(16)
    }

    private var contextBand: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mode.contextLabel)
                .font(theme.mono.font(size: 9, weight: .medium))
                .tracking(theme.capsTracking(at: 9))
                .foregroundStyle(theme.ink4.color)
            Text(context.title)
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(2)
            if !context.detail.isEmpty {
                Text(context.detail)
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.surface3.color)
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.emptyTitle)
                .font(theme.serif.font(size: 16, weight: .medium))
                .foregroundStyle(theme.ink.color)
            Text(mode.emptyDetail)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(suggestions) { suggestion in
                    suggestionButton(suggestion)
                }
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONVERSA")
                .font(theme.mono.font(size: 9, weight: .medium))
                .tracking(theme.capsTracking(at: 9))
                .foregroundStyle(theme.ink4.color)

            ForEach(conversation.messages) { message in
                messageBubble(message)
            }
        }
    }

    private func suggestionButton(_ suggestion: LocalAssistantSuggestion) -> some View {
        Button { Task { await conversation.run(suggestion) } } label: {
            HStack(spacing: 10) {
                Text(suggestion.title)
                    .font(theme.sans.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink2.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.ink4.color)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 34)
            .background(theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .disabled(conversation.isLoading)
        .help("Usar a pergunta: \(suggestion.question)")
    }

    private func messageBubble(_ message: LocalAssistantMessage) -> some View {
        HStack {
            if message.speaker == .user { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.speaker == .user ? "VOCÊ" : "ASSISTENTE")
                    .font(theme.mono.font(size: 8.5, weight: .medium))
                    .tracking(theme.capsTracking(at: 8.5))
                    .foregroundStyle(message.speaker == .user ? theme.accentInk.color : theme.ink4.color)
                Text(message.text)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 274, alignment: .leading)
            .padding(10)
            .background(message.speaker == .user ? theme.accentSoft.color : theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        (message.speaker == .user ? theme.accentLine : theme.line2).color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
            if message.speaker == .assistant { Spacer(minLength: 36) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.speaker == .user ? "Você" : "Assistente"): \(message.text)")
    }

    private func errorBand(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
                    .accessibilityHidden(true)
                Text(error)
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink2.color)
            }
            Text("Tente novamente ou reformule a pergunta.")
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
            if conversation.canRetry {
                ChromeButton(
                    "Tentar de novo", appearance: .outlined,
                    size: 11.5, height: 27, horizontalPadding: 10
                ) {
                    Task { await conversation.retry() }
                }
                .help("Tenta responder a última pergunta novamente")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(theme.surface3.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
        }
        .accessibilityElement(children: .combine)
    }

    private var loadingBand: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.accent.color)
            Text("Lendo o contexto local…")
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.ink3.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Respondendo à pergunta")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(mode.placeholder, text: $conversation.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(theme.surface.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.radiusSmall)
                            .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
                    }
                    .onSubmit { submit() }
                    .accessibilityLabel("Pergunta sobre \(mode.accessibilitySubject)")

                Button(action: submit) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .accessibilityHidden(true)
                        Text("Enviar")
                            .font(theme.sans.font(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(theme.onAccent.color)
                    .frame(height: 32)
                    .padding(.horizontal, 10)
                    .background(theme.accent.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
                .disabled(!conversation.canSend || conversation.isLoading)
                .help("Enviar pergunta")
                .accessibilityLabel("Enviar pergunta")
            }

            Text(mode.footer)
                .font(theme.sans.font(size: 10.5))
                .foregroundStyle(theme.ink4.color)
        }
        .padding(16)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .top)
    }

    private func submit() {
        Task { await conversation.submit() }
    }
}

private enum LocalAssistantCopy {
    static let requestFailed = "Não foi possível responder agora."
    static let emptyResponse = "Não foi possível formar uma resposta."
}

private struct DividerLine: View {
    let color: TokenColor
    @Environment(\.displayScale) private var displayScale

    init(_ color: TokenColor) {
        self.color = color
    }

    var body: some View {
        Rectangle()
            .fill(color.color)
            .frame(height: Hairline.thickness(displayScale))
    }
}
