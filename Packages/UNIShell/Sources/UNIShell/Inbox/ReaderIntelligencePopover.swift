import SwiftUI
import UNICore
import UNIDesign

/// Conversa contextual e compacta sobre o e-mail aberto.
///
/// O campo permanece disponível depois de cada resposta para que a pessoa
/// possa pedir outro formato, aprofundar um ponto ou revisar uma resposta sem
/// perder o histórico que já foi enviado ao provedor configurado.
struct ReaderIntelligencePopover: View {
    /// O painel antigo media 336pt e terminava exatamente sobre o botão que o
    /// abre. O shell usa esta largura como referência para manter a borda
    /// esquerda no mesmo lugar enquanto o painel cresce para a direita.
    nonisolated static let anchorWidth: CGFloat = 336
    nonisolated static let defaultSize = CGSize(width: 520, height: 400)
    nonisolated static let minimumSize = CGSize(width: 420, height: 300)
    nonisolated static let maximumSize = CGSize(width: 720, height: 500)
    private static let transcriptEndID = "reader-intelligence-transcript-end"

    nonisolated static func clampedSize(_ proposed: CGSize) -> CGSize {
        CGSize(
            width: min(max(proposed.width, minimumSize.width), maximumSize.width),
            height: min(max(proposed.height, minimumSize.height), maximumSize.height)
        )
    }

    nonisolated static func resizedSize(
        from origin: CGSize,
        translation: CGSize
    ) -> CGSize {
        clampedSize(CGSize(
            width: origin.width + translation.width,
            height: origin.height + translation.height
        ))
    }

    /// O overlay nasce alinhado pelo canto superior direito do botão. Este
    /// deslocamento conserva a borda esquerda do painel de 336pt e deixa o
    /// canto de redimensionamento acompanhar o cursor para a direita.
    nonisolated static func anchorOffset(for width: CGFloat) -> CGFloat {
        max(0, clampedSize(CGSize(width: width, height: defaultSize.height)).width - anchorWidth)
    }

    enum Action: String, CaseIterable, Sendable {
        case summary, keyPoints, insights, pending, reply, custom

        var title: String {
            switch self {
            case .summary: "Resumo"
            case .keyPoints: "Pontos-chave"
            case .insights: "Insights"
            case .pending: "Pendências"
            case .reply: "Gerar resposta"
            case .custom: "Pergunta livre"
            }
        }

        var question: String {
            switch self {
            case .summary:
                "Resuma esta conversa com foco no que eu preciso saber e decidir."
            case .keyPoints:
                "Liste os pontos-chave desta conversa, um item por linha, sem repetir detalhes secundários."
            case .insights:
                "Analise esta conversa e destaque insights, riscos e pontos em aberto."
            case .pending:
                "Liste pendências, responsáveis e prazos confirmados nesta conversa, um item por linha."
            case .reply:
                "Prepare uma resposta completa, natural e pronta para revisão desta conversa."
            case .custom:
                ""
            }
        }

        var suggestion: AssistantSuggestion {
            .init(id: rawValue, title: title, question: question)
        }
    }

    /// Mantido como entrada de preview e testes offscreen. A interface em
    /// produção não troca mais de tela: estes estados viram uma conversa.
    enum Phase: Equatable {
        case ready
        case loading(Action)
        case preview(Action, String)
        case failure(String)
    }

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let context: AssistantContext
    let isAvailable: Bool
    let onUseReply: (String) -> Void
    let onClose: () -> Void

    @Binding private var panelSize: CGSize
    @State private var conversation: AssistantConversation
    @State private var task: Task<Void, Never>?
    @State private var resizeOrigin: CGSize?

    init(
        context: AssistantContext,
        isAvailable: Bool,
        initialPhase: Phase = .ready,
        panelSize: Binding<CGSize> = .constant(Self.defaultSize),
        onAsk: @escaping (AssistantRequest) async throws -> String,
        onGenerateReply: @escaping () async throws -> String,
        onUseReply: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.context = context
        self.isAvailable = isAvailable
        self.onUseReply = onUseReply
        self.onClose = onClose
        _panelSize = panelSize
        _conversation = State(
            initialValue: AssistantConversation(
                context: context,
                debugState: Self.debugState(for: initialPhase)
            ) { request in
                if request.question == Action.reply.question {
                    return try await onGenerateReply()
                }
                return try await onAsk(request)
            }
        )
    }

    var body: some View {
        let size = Self.clampedSize(panelSize)

        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            hairline
            conversationArea
            composer
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 10)
        .onDisappear { task?.cancel() }
        .accessibilityIdentifier("reader-intelligence-popover")
    }

    private var header: some View {
        HStack(spacing: 8) {
            // O painel é roteável: pode estar usando Codex, Grok,
            // LiteLLM, CLI ou o modelo local. Um símbolo exclusivo da Apple
            // afirmaria uma origem que esta view não conhece.
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.info.color)
                .frame(width: 24, height: 24)
                .background(
                    theme.info.color.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: theme.radiusSmall)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Inteligência do email")
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(context.title)
                    .font(theme.sans.font(size: 10.5))
                    .foregroundStyle(theme.ink4.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if conversation.hasConversation {
                iconButton(
                    "arrow.counterclockwise",
                    help: "Limpar conversa",
                    accessibilityLabel: "Limpar conversa",
                    disabled: conversation.isLoading
                ) {
                    conversation.clear()
                }
            }

            iconButton(
                "arrow.up.left.and.arrow.down.right",
                help: isExpanded ? "Voltar ao tamanho padrão" : "Expandir painel",
                accessibilityLabel: isExpanded ? "Voltar ao tamanho padrão" : "Expandir painel"
            ) {
                toggleExpanded()
            }

            iconButton(
                "xmark",
                help: "Fechar",
                accessibilityLabel: "Fechar inteligência do email"
            ) {
                onClose()
            }
        }
    }

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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

                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptEndID)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.color)
            .onChange(of: conversation.messages.count) {
                scrollToEnd(using: proxy)
            }
            .onChange(of: conversation.isLoading) {
                scrollToEnd(using: proxy)
            }
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Pergunte e continue refinando")
                    .font(theme.serif.font(size: 15.5, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                Text("Peça resumo, lista, análise ou escreva sua própria instrução.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionGrid
            replyButton

            if !isAvailable {
                Text("Conecte um provedor de IA nas Configurações para usar estas ações.")
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
            spacing: 6
        ) {
            ForEach([Action.summary, .keyPoints, .insights, .pending], id: \.self) { action in
                panelButton(action.title, enabled: canInteract) {
                    run(action)
                }
            }
        }
    }

    private var replyButton: some View {
        panelButton(Action.reply.title, enabled: canInteract, emphasized: true) {
            run(.reply)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CONVERSA")
                .font(theme.mono.font(size: 8.5, weight: .medium))
                .tracking(theme.capsTracking(at: 8.5))
                .foregroundStyle(theme.ink4.color)

            ForEach(conversation.messages) { message in
                messageBubble(message)
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: AssistantMessage) -> some View {
        if message.speaker == .user {
            HStack {
                Spacer(minLength: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("VOCÊ")
                        .font(theme.mono.font(size: 8.5, weight: .medium))
                        .tracking(theme.capsTracking(at: 8.5))
                        .foregroundStyle(theme.info.color)
                    Text(message.text)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(theme.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(theme.infoSoft.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            theme.infoLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Você: \(message.text)")
        } else {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.info.color.opacity(0.62))
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: 7) {
                    Text("ASSISTENTE")
                        .font(theme.mono.font(size: 8.5, weight: .medium))
                        .tracking(theme.capsTracking(at: 8.5))
                        .foregroundStyle(theme.ink4.color)

                    ReaderAssistantMarkdown(text: message.text)

                    if shouldOfferReplyUse(for: message) {
                        Button("Usar esta resposta no email") {
                            onUseReply(message.text)
                            onClose()
                        }
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.onEnter.color)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(theme.enter.color, in: RoundedRectangle(cornerRadius: 7))
                        .focusRing(cornerRadius: 7, tint: \.onEnter)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Assistente: \(message.text)")
        }
    }

    private var loadingBand: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.info.color)
            Text(isReplyConversation ? "Redigindo e considerando a conversa…" : "Analisando a conversa…")
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.ink3.color)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("O assistente está respondendo")
    }

    private func errorBand(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.danger.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(error)
                    .font(theme.sans.font(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)

                if conversation.canRetry {
                    Button("Tentar de novo") {
                        task = Task { await conversation.retry() }
                    }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.info.color)
                    .focusRing(cornerRadius: theme.radiusSmall)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                conversation.hasConversation
                    ? "Continue a conversa ou peça outro formato…"
                    : "Pergunte sobre este email…",
                text: $conversation.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(theme.sans.font(size: 12))
            .foregroundStyle(theme.ink.color)
            .lineLimit(1...3)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.surface2.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
            }
            .onSubmit { submit() }
            .disabled(!isAvailable || conversation.isLoading)
            .accessibilityLabel("Pergunta ou instrução sobre este email")

            Button(action: submit) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10.5, weight: .bold))
                        .accessibilityHidden(true)
                    Text("Enviar")
                        .font(theme.sans.font(size: 11, weight: .semibold))
                }
                .foregroundStyle(theme.onEnter.color)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(theme.enter.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall, tint: \.onEnter)
            .disabled(!canSend)
            .help("Enviar pergunta")
            .accessibilityLabel("Enviar pergunta")
        }
        .padding(.leading, 14)
        .padding(.trailing, 28)
        .padding(.vertical, 11)
        .background(theme.surface.color)
        .overlay(alignment: .top) { hairline }
    }

    private var resizeHandle: some View {
        ZStack {
            Color.clear
            Path { path in
                path.move(to: CGPoint(x: 9, y: 23))
                path.addLine(to: CGPoint(x: 23, y: 9))
                path.move(to: CGPoint(x: 15, y: 23))
                path.addLine(to: CGPoint(x: 23, y: 15))
                path.move(to: CGPoint(x: 20, y: 23))
                path.addLine(to: CGPoint(x: 23, y: 20))
            }
            .stroke(
                theme.ink4.color.opacity(0.62),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .pointerStyle(.frameResize(position: .bottomTrailing))
        .onTapGesture(count: 2) { panelSize = Self.defaultSize }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let origin = resizeOrigin ?? Self.clampedSize(panelSize)
                    if resizeOrigin == nil { resizeOrigin = origin }
                    panelSize = Self.resizedSize(
                        from: origin,
                        translation: value.translation
                    )
                }
                .onEnded { _ in resizeOrigin = nil }
        )
        .help("Arraste para redimensionar. Duplo clique volta ao tamanho padrão.")
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Redimensionar painel de inteligência")
        .accessibilityHint("Arraste o canto. Duplo clique volta ao tamanho padrão.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                panelSize = Self.resizedSize(
                    from: panelSize,
                    translation: CGSize(width: 40, height: 30)
                )
            case .decrement:
                panelSize = Self.resizedSize(
                    from: panelSize,
                    translation: CGSize(width: -40, height: -30)
                )
            @unknown default:
                break
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.line.color)
            .frame(height: Hairline.thickness(displayScale))
    }

    private var isExpanded: Bool {
        let size = Self.clampedSize(panelSize)
        return abs(size.width - Self.maximumSize.width) < 1
            && abs(size.height - Self.maximumSize.height) < 1
    }

    private var canInteract: Bool {
        isAvailable && !conversation.isLoading
    }

    private var canSend: Bool {
        canInteract && conversation.canSend
    }

    private var isReplyConversation: Bool {
        conversation.messages.contains {
            $0.speaker == .user && $0.text == Action.reply.question
        }
    }

    private func toggleExpanded() {
        panelSize = isExpanded ? Self.defaultSize : Self.maximumSize
    }

    private func iconButton(
        _ systemName: String,
        help: String,
        accessibilityLabel: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(theme.surface3.color, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.ink3.color)
        .focusRing(cornerRadius: 7)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func panelButton(
        _ title: String,
        enabled: Bool,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: 11, weight: .medium))
                .foregroundStyle(emphasized ? theme.info.color : theme.ink2.color)
                .frame(maxWidth: .infinity)
                .frame(height: 29)
                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            emphasized ? theme.infoLine.color : theme.line2.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 8)
        .disabled(!enabled)
    }

    private func run(_ action: Action) {
        guard canInteract, !action.question.isEmpty else { return }
        task = Task {
            await conversation.run(action.suggestion)
        }
    }

    private func submit() {
        guard canSend else { return }
        task = Task {
            await conversation.submit()
        }
    }

    private func shouldOfferReplyUse(for message: AssistantMessage) -> Bool {
        guard isReplyConversation, message.speaker == .assistant else { return false }
        return conversation.messages.last(where: { $0.speaker == .assistant })?.id == message.id
    }

    private func scrollToEnd(using proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(Self.transcriptEndID, anchor: .bottom)
        }
    }

    static func debugState(for phase: Phase) -> AssistantPanelDebugState {
        switch phase {
        case .ready:
            return .empty
        case .loading(let action):
            return AssistantPanelDebugState(
                messages: action.question.isEmpty
                    ? []
                    : [.init(speaker: .user, text: action.question)],
                isLoading: true,
                lastQuestion: action.question.isEmpty ? nil : action.question
            )
        case .preview(let action, let text):
            var messages: [AssistantMessage] = []
            if !action.question.isEmpty {
                messages.append(.init(speaker: .user, text: action.question))
            }
            messages.append(.init(speaker: .assistant, text: text))
            return AssistantPanelDebugState(messages: messages)
        case .failure(let message):
            return AssistantPanelDebugState(errorMessage: message)
        }
    }

}

/// Blocos simples de Markdown voltados ao que o assistente produz no leitor.
/// SwiftUI achata listas quando um documento inteiro é entregue a um único
/// Text; separar os blocos conserva bullets, numeração e respiro entre ideias.
struct ReaderAssistantMarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph(String)
        case heading(String)
        case bullet(String)
        case numbered(marker: String, text: String)
    }

    let id: Int
    let kind: Kind

    nonisolated static func parse(_ text: String) -> [Self] {
        var kinds: [Kind] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            kinds.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = headingText(in: line) {
                flushParagraph()
                kinds.append(.heading(heading))
            } else if let item = unorderedItem(in: line) {
                flushParagraph()
                kinds.append(.bullet(item))
            } else if let item = orderedItem(in: line) {
                flushParagraph()
                kinds.append(.numbered(marker: item.marker, text: item.text))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()

        return kinds.enumerated().map { index, kind in
            Self(id: index, kind: kind)
        }
    }

    private nonisolated static func headingText(in line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 3 else { return nil }
        let remainder = line.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        let text = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private nonisolated static func unorderedItem(in line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let item = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
        return nil
    }

    private nonisolated static func orderedItem(in line: String) -> (marker: String, text: String)? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let marker = String(line[..<separator])
        guard marker.count >= 2,
              marker.last == "." || marker.last == ")",
              Int(marker.dropLast()) != nil
        else {
            return nil
        }
        let item = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : (marker, item)
    }
}

private struct ReaderAssistantMarkdown: View {
    @Environment(\.theme) private var theme

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(ReaderAssistantMarkdownBlock.parse(text)) { block in
                blockView(block.kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ kind: ReaderAssistantMarkdownBlock.Kind) -> some View {
        switch kind {
        case .paragraph(let text):
            richText(text)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink2.color)
                .lineSpacing(2.5)
        case .heading(let text):
            richText(text)
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .padding(.top, 2)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(theme.info.color)
                    .frame(width: 4, height: 4)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center]
                    }
                richText(text)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .numbered(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(theme.mono.font(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.info.color)
                    .frame(minWidth: 18, alignment: .trailing)
                richText(text)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func richText(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value)) ?? AttributedString(value))
    }
}
