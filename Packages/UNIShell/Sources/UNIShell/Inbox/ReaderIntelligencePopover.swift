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
        case summary, keyPoints, insights, pending, translate, terms, reply, custom

        var title: String {
            switch self {
            case .summary: L10n.tr("Resumir")
            case .keyPoints: L10n.tr("Pontos-chave")
            case .insights: "Insights"
            case .pending: L10n.tr("Tarefas e prazos")
            case .translate: L10n.tr("Traduzir")
            case .terms: L10n.tr("Explicar termos")
            case .reply: L10n.tr("Rascunhar resposta")
            case .custom: L10n.tr("Pergunta livre")
            }
        }

        /// O ícone da lista do protótipo. Ação sem ícone é ação que a pessoa
        /// lê duas vezes antes de achar.
        var symbol: String {
            switch self {
            case .summary: "text.alignleft"
            case .keyPoints: "list.bullet"
            case .insights: "lightbulb"
            case .pending: "checklist"
            case .translate: "character.bubble"
            case .terms: "questionmark.circle"
            case .reply: "square.and.pencil"
            case .custom: "sparkles"
            }
        }

        /// A dica da direita — o idioma para quem traduz, vazio no resto.
        var hint: String {
            self == .translate ? AppLanguage.selected.resolved.nativeName : ""
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
            case .translate:
                // Pergunta livre com texto fixo: a rota é a mesma do campo de
                // baixo, e nenhum encanamento de provedor muda por causa dela.
                "Traduza este e-mail para \(AppLanguage.selected.resolved.nativeName), "
                    + "mantendo o tom e a formatação. Não resuma: traduza o texto inteiro."
            case .terms:
                "Explique, em uma linha cada, os termos técnicos, siglas e jargões "
                    + "deste e-mail que alguém de fora da área não entenderia."
            case .reply, .custom:
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

    /// A conversa é injetada: o popover não constrói motor nem guarda
    /// transcript próprio. Quem a cria é quem conhece o provedor.
    let conversation: AssistantConversation
    let isAvailable: Bool
    let onUseReply: (String) -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @Binding private var panelSize: CGSize
    @State private var resizeOrigin: CGSize?

    init(
        conversation: AssistantConversation,
        isAvailable: Bool,
        panelSize: Binding<CGSize> = .constant(Self.defaultSize),
        onUseReply: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.isAvailable = isAvailable
        self.onUseReply = onUseReply
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        _panelSize = panelSize
    }

    private var context: AssistantContext { conversation.context }

    /// O preenchimento do painel: `surface` nos temas opacos, e a cor que o
    /// `surface` do Vidro de fato pinta sobre o fundo da janela nos dois
    /// temas de vidro.
    private var painel: TokenColor {
        theme.isTranslucent ? theme.flattened(\.surface) : theme.surface
    }

    var body: some View {
        let size = Self.clampedSize(panelSize)

        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            hairline
            // O campo vem **antes** da lista, como no desenho: o menu da IA
            // começa com "Peça algo sobre este e-mail…" e as ações prontas
            // vêm por baixo dele. Era `isGlass`, e só os dois temas de vidro
            // tinham a ordem do desenho.
            composer
            hairline
            conversationArea
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // `flattened` e não `surface`: no Vidro os tokens de superfície são
        // translúcidos de propósito, e um menu translúcido deixava o email
        // aparecer por baixo da lista de ações. O protótipo pede um painel
        // praticamente opaco (`rgba(255,255,255,0.97)`); a cor **pintada** do
        // `surface` sobre o fundo da janela é exatamente ela.
        .background(painel.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 10)
        .onDisappear { conversation.cancel() }
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
                Text(L10n.tr("Inteligência do email · \(conversation.destination.label)"))
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
                    help: L10n.tr("Limpar conversa"),
                    accessibilityLabel: L10n.tr("Limpar conversa"),
                    disabled: conversation.isLoading
                ) {
                    conversation.clear()
                }
            }

            iconButton(
                "arrow.up.left.and.arrow.down.right",
                help: isExpanded ? L10n.tr("Voltar ao tamanho padrão") : L10n.tr("Expandir painel"),
                accessibilityLabel: isExpanded ? L10n.tr("Voltar ao tamanho padrão") : L10n.tr("Expandir painel")
            ) {
                toggleExpanded()
            }

            iconButton(
                "xmark",
                help: L10n.tr("Fechar"),
                accessibilityLabel: L10n.tr("Fechar inteligência do email")
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

                    if let failure = conversation.failure {
                        // A mesma faixa das outras superfícies: sem ela a
                        // recuperação (Ajustes/Reconectar) sumia da tela.
                        AssistantFailureBand(
                            failure: failure,
                            onRetry: conversation.retry,
                            onOpenSettings: onOpenSettings
                        )
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
            .background(painel.color)
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
                Text(L10n.tr("Pergunte e continue refinando"))
                    .font(theme.serif.font(size: 15.5, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                Text(L10n.tr("Peça resumo, lista, análise ou escreva sua própria instrução."))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Uma ação por linha, com ícone e dica — o desenho. A grade de
            // pastilhas que os temas opacos viam saiu junto com o resto do
            // layout antigo.
            actionList

            if !isAvailable {
                Text(L10n.tr("Conecte um provedor de IA nas Configurações para usar estas ações."))
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A lista do protótipo: ícone, rótulo e dica, uma ação por linha.
    ///
    /// Duas ações novas entram aqui e nenhum encanamento de provedor muda por
    /// causa delas — **Traduzir** e **Explicar termos** são perguntas livres
    /// com texto fixo, pela mesma rota do campo lá de cima. Traduzir vai para
    /// o idioma escolhido do app (`AppLanguage.selected`), que é a única
    /// preferência de idioma que existe para dizer a verdade sobre o destino.
    private var actionList: some View {
        VStack(spacing: 1) {
            ForEach(
                [Action.summary, .translate, .reply, .pending, .keyPoints, .terms], id: \.self
            ) { action in
                actionRow(action)
            }
        }
    }

    private func actionRow(_ action: Action) -> some View {
        let habilitada = action == .reply
            ? canInteract && conversation.canDraftReply
            : canInteract
        return Button {
            if action == .reply {
                guard habilitada else { return }
                conversation.draftReply()
            } else {
                run(action)
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accentInk.color)
                    .frame(width: 17)
                Text(action.title)
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(theme.ink.color)
                Spacer(minLength: 8)
                if !action.hint.isEmpty {
                    Text(action.hint)
                        .font(theme.sans.font(size: 11))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 9)
        .disabled(!habilitada)
        .accessibilityLabel(action.title)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("CONVERSA"))
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
                    Text(L10n.tr("VOCÊ"))
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
            .accessibilityLabel(L10n.tr("Você: \(message.text)"))
        } else {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.info.color.opacity(0.62))
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("ASSISTENTE"))
                        .font(theme.mono.font(size: 8.5, weight: .medium))
                        .tracking(theme.capsTracking(at: 8.5))
                        .foregroundStyle(theme.ink4.color)

                    // Rascunho é prosa de email: asterisco ali é literal.
                    if message.kind == .draft {
                        Text(message.text)
                            .font(theme.sans.font(size: 12))
                            .foregroundStyle(theme.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        AssistantMarkdown(text: message.text)
                    }

                    if shouldOfferReplyUse(for: message) {
                        Button(L10n.tr("Usar esta resposta no email")) {
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
            .accessibilityLabel(L10n.tr("Assistente: \(message.text)"))
        }
    }

    private var loadingBand: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.info.color)
            Text(L10n.tr("Analisando a conversa…"))
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.ink3.color)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("O assistente está respondendo"))
    }

    private var composer: some View {
        @Bindable var conversation = conversation
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(
                conversation.hasConversation
                    ? L10n.tr("Continue a conversa ou peça outro formato…")
                    : L10n.tr("Peça algo sobre este e-mail…"),
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
            .accessibilityLabel(L10n.tr("Pergunta ou instrução sobre este email"))

            Button(action: submit) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10.5, weight: .bold))
                        .accessibilityHidden(true)
                    Text(L10n.tr("Enviar"))
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
            .help(L10n.tr("Enviar pergunta"))
            .accessibilityLabel(L10n.tr("Enviar pergunta"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 28)
        .padding(.vertical, 11)
        .background(painel.color)
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
        .help(L10n.tr("Arraste para redimensionar. Duplo clique volta ao tamanho padrão."))
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L10n.tr("Redimensionar painel de inteligência"))
        .accessibilityHint(L10n.tr("Arraste o canto. Duplo clique volta ao tamanho padrão."))
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

    /// O último rascunho gerado — é ele que "Usar esta resposta" leva ao
    /// composer.
    private var lastDraft: AssistantMessage? {
        conversation.messages.last { $0.kind == .draft }
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

    private func run(_ action: Action) {
        // "Gerar resposta" não passa por aqui: rascunho tem rota própria, e
        // a pergunta desta ação é vazia de propósito.
        guard canInteract, !action.question.isEmpty else { return }
        conversation.run(action.suggestion)
    }

    private func submit() {
        guard canSend else { return }
        conversation.submit()
    }

    private func shouldOfferReplyUse(for message: AssistantMessage) -> Bool {
        message.kind == .draft && lastDraft?.id == message.id
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
                isLoading: true
            )
        case .preview(let action, let text):
            var messages: [AssistantMessage] = []
            if action != .reply, !action.question.isEmpty {
                messages.append(.init(speaker: .user, text: action.question))
            }
            messages.append(
                .init(speaker: .assistant, text: text, kind: action == .reply ? .draft : .message)
            )
            return AssistantPanelDebugState(messages: messages)
        case .failure(let message):
            return AssistantPanelDebugState(
                failure: AssistantFailure(message: message, recovery: .retry)
            )
        }
    }

}

