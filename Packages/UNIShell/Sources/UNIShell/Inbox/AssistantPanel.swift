import Foundation
import Observation
import SwiftUI
import UNIDesign
import UNISync

/// O pedaço de uma mensagem que acompanha uma pergunta local.
///
/// É deliberadamente pequeno: o shell apresenta o contexto para a pessoa e o
/// compositor decide qual conteúdo pode enviar ao motor. Não há referência a
/// Foundation Models aqui.
public struct AssistantContext: Sendable, Hashable {
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

public struct AssistantSuggestion: Identifiable, Sendable, Hashable {
    /// Qual das duas rotas do motor a sugestão usa. Sem isto, "Gerar
    /// resposta" saía por `answer()` — o prompt que pede Markdown — e o
    /// rascunho voltava com asteriscos.
    public enum Kind: Sendable, Hashable {
        case question
        case draftReply
    }

    public let id: String
    public let title: String
    public let question: String
    public let kind: Kind

    public init(
        id: String? = nil,
        title: String? = nil,
        question: String,
        kind: Kind = .question
    ) {
        self.id = id ?? question
        self.title = title ?? question
        self.question = question
        self.kind = kind
    }

    public static let emailDefaults: [AssistantSuggestion] = [
        .init(title: "Resumo", question: "Faça um resumo útil desta conversa, destacando o que importa."),
        .init(title: "Pontos-chave", question: "Liste os pontos-chave desta conversa."),
        .init(title: "Insights", question: "Analise esta conversa e identifique insights, riscos e pontos em aberto."),
        .init(title: "Pendências", question: "Liste pendências, responsáveis e prazos desta conversa."),
        .init(id: "draft-reply", title: "Gerar resposta", question: "", kind: .draftReply),
    ]

    public static let workspaceDefaults: [AssistantSuggestion] = [
        .init(title: "Resumo geral", question: "Resuma meu ambiente: caixas, e-mails, agenda e pendências."),
        .init(title: "Prioridades", question: "Quais são minhas prioridades agora considerando e-mails e agenda?"),
        .init(title: "Não lidos", question: "Organize os e-mails não lidos mais importantes e diga por onde começar."),
        .init(title: "Agenda", question: "Resuma minha agenda e aponte conflitos, lacunas ou preparações necessárias."),
        .init(title: "Riscos e pendências", question: "Cruze e-mails, agenda e pendências e identifique riscos ou itens esquecidos."),
    ]
}

/// Define se o painel fala da mensagem aberta ou do ambiente inteiro. A
/// separação é visível e também decide o catálogo de ações rápidas.
public enum AssistantScope: Sendable, Hashable {
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

    var suggestions: [AssistantSuggestion] {
        switch self {
        case .email: AssistantSuggestion.emailDefaults
        case .workspace: AssistantSuggestion.workspaceDefaults
        }
    }

    /// A cópia que aparece enquanto a pergunta está a caminho. Depende do
    /// destino, não do escopo: prometer "local" com um provedor remoto
    /// selecionado foi o que motivou a spec 1.2.
    func loadingLabel(for destination: AssistantDestination) -> String {
        destination.isLocal
            ? "Lendo o contexto neste Mac…"
            : "Falando com \(destination.label)…"
    }
}

/// Painel de perguntas sobre a mensagem aberta ou sobre o ambiente local.
///
/// A resposta é uma closure assíncrona injetada pelo app. Por isso esta peça
/// pode ser renderizada e testada sem acesso ao Foundation Models, sem rede e
/// sem saber como o conteúdo da mensagem foi obtido.
public struct AssistantPanel: View {
    public static let defaultWidth: CGFloat = 360

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    private let conversation: AssistantConversation
    /// Visível para o teste: é a lista depois do filtro de rota.
    let visibleSuggestions: [AssistantSuggestion]
    private let onClose: () -> Void
    private let onOpenSettings: () -> Void
    private let width: CGFloat

    public init(
        conversation: AssistantConversation,
        suggestions: [AssistantSuggestion]? = nil,
        width: CGFloat = AssistantPanel.defaultWidth,
        onOpenSettings: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.conversation = conversation
        // Sugestão de rascunho num motor que não redige seria botão mudo.
        self.visibleSuggestions = (suggestions ?? conversation.scope.suggestions).filter {
            $0.kind == .question || conversation.canDraftReply
        }
        self.width = width
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
    }

    /// Atalhos de leitura: o escopo e o contexto são da conversa, que é a
    /// única dona do estado. O painel não guarda cópia de nenhum dos dois.
    private var mode: AssistantScope { conversation.scope }
    private var context: AssistantContext { conversation.context }

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

                    if let failure = conversation.failure {
                        AssistantFailureBand(
                            failure: failure,
                            onRetry: conversation.retry,
                            onOpenSettings: onOpenSettings
                        )
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
        .accessibilityIdentifier("assistant-panel")
        .onDisappear { conversation.cancel() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 21, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.info.color)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(theme.serif.font(size: 18, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(conversation.destination.label.uppercased())
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
                ForEach(visibleSuggestions) { suggestion in
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

    private func suggestionButton(_ suggestion: AssistantSuggestion) -> some View {
        Button { conversation.run(suggestion) } label: {
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

    private func messageBubble(_ message: AssistantMessage) -> some View {
        HStack {
            if message.speaker == .user { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.speaker == .user ? "VOCÊ" : "ASSISTENTE")
                    .font(theme.mono.font(size: 8.5, weight: .medium))
                    .tracking(theme.capsTracking(at: 8.5))
                    .foregroundStyle(message.speaker == .user ? theme.info.color : theme.ink4.color)
                // Turno de rascunho é prosa de email: asterisco e hífen ali são
                // literais que a pessoa vai colar no composer.
                if message.kind == .draft || message.speaker == .user {
                    Text(message.text)
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle(theme.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    AssistantMarkdown(text: message.text)
                }
            }
            .frame(maxWidth: 274, alignment: .leading)
            .padding(10)
            .background(message.speaker == .user ? theme.infoSoft.color : theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        (message.speaker == .user ? theme.infoLine : theme.line2).color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
            if message.speaker == .assistant { Spacer(minLength: 36) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.speaker == .user ? "Você" : "Assistente"): \(message.text)")
    }

    private var loadingBand: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.info.color)
            Text(mode.loadingLabel(for: conversation.destination))
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.ink3.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Respondendo à pergunta")
    }

    /// A conversa é injetada, não é `@State`: a ligação do campo precisa
    /// ser feita à mão em vez de sair do cifrão.
    private var draftBinding: Binding<String> {
        Binding(get: { conversation.draft }, set: { conversation.draft = $0 })
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(mode.placeholder, text: draftBinding, axis: .vertical)
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
                    .onSubmit { conversation.submit() }
                    .accessibilityLabel("Pergunta sobre \(mode.accessibilitySubject)")

                Button(action: conversation.submit) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .accessibilityHidden(true)
                        Text("Enviar")
                            .font(theme.sans.font(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(theme.onEnter.color)
                    .frame(height: 32)
                    .padding(.horizontal, 10)
                    .background(theme.enter.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall, tint: \.onEnter)
                .disabled(!conversation.canSend)
                .help("Enviar pergunta")
                .accessibilityLabel("Enviar pergunta")
            }

            Text(conversation.destination.detail)
                .font(theme.sans.font(size: 10.5))
                .foregroundStyle(theme.ink4.color)
        }
        .padding(16)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .top)
    }

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
