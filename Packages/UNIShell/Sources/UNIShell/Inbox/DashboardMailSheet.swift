import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// Leitura do e-mail por cima do Dashboard — **o leitor da Caixa dentro de uma
/// folha**, e não um segundo leitor.
///
/// ## Por que deixou de ter corpo próprio
///
/// A primeira versão desenhava aqui um cabeçalho (com o remetente escrito duas
/// vezes), o corpo, e um rodapé com duas ações. Tudo o que a Caixa oferece —
/// triagem, apagar, mover para pasta, responder, responder a todos,
/// encaminhar, TL;DR, anexos, convite, pilha de conversa, "Como enviado / Como
/// o tema", resposta rápida — não existia; e embaixo do corpo sobrava o vazio
/// do que não estava lá. Reescrever qualquer uma dessas peças aqui seria a
/// segunda cópia que diverge da primeira no conserto seguinte, e é por isso que
/// agora a folha é só a moldura: `ReaderPane` inteiro, com as portas de sempre
/// (`ActionReceipts` → `StoreCommand` → `MailCommandPort`), e nenhum caminho de
/// execução paralelo ao da Caixa.
///
/// O que a folha acrescenta são as duas saídas que só fazem sentido aqui:
/// "Abrir na Caixa" e "Gerar rascunho" (que fala com a conversa do dashboard,
/// por `draftReply()`). Fechar a folha é o ✕, o clique no fundo, e o Esc — que
/// continua no `EscapeCancel` do `InboxScreen`, com a precedência que
/// `MenuKeyActionTests` tranca.
struct DashboardMailSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let messageID: String
    let onClose: () -> Void
    let onOpenInMailbox: (Message) -> Void
    let onDraft: (Message) -> Void
    let onPresented: (String) -> Void
    /// A janela 03, igualzinho à Caixa: responder a todos, encaminhar, e o "⤢"
    /// da faixa de resposta rápida.
    let onCompose: (ComposerRoute) -> Void
    let intelligence: ComposerIntelligenceGenerator?
    let intelligencePresentation: IntelligencePresentation
    /// A legenda do TL;DR sai daqui — o mesmo destino que a Caixa mostra, pela
    /// versão do motor gravada com o resumo.
    let analysisDestination: @Sendable (String?) -> AssistantDestination
    let makeAssistantConversation: ((String) -> AssistantConversation)?

    init(
        store: MailStore,
        messageID: String,
        onClose: @escaping () -> Void,
        onOpenInMailbox: @escaping (Message) -> Void,
        onDraft: @escaping (Message) -> Void,
        onPresented: @escaping (String) -> Void = { _ in },
        onCompose: @escaping (ComposerRoute) -> Void = { _ in },
        intelligence: ComposerIntelligenceGenerator? = nil,
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        makeAssistantConversation: ((String) -> AssistantConversation)? = nil
    ) {
        self.store = store
        self.messageID = messageID
        self.onClose = onClose
        self.onOpenInMailbox = onOpenInMailbox
        self.onDraft = onDraft
        self.onPresented = onPresented
        self.onCompose = onCompose
        self.intelligence = intelligence
        self.intelligencePresentation = intelligencePresentation
        self.analysisDestination = analysisDestination
        self.makeAssistantConversation = makeAssistantConversation
    }

    /// A folha não passa de 880×760: mais que isso vira a janela inteira e
    /// deixa de parecer uma leitura por cima do briefing.
    static let maxWidth: CGFloat = 880
    static let maxHeight: CGFloat = 760

    private var message: Message? { store.message(messageID) }

    var body: some View {
        ZStack {
            theme.paper.color.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityLabel(L10n.tr("Fechar email"))

            VStack(spacing: 0) {
                sheetBar
                Rectangle()
                    .fill(theme.line2.color)
                    .frame(height: Hairline.thickness(displayScale))
                reader
            }
            .frame(maxWidth: Self.maxWidth, maxHeight: Self.maxHeight)
            // O idioma de painel sobreposto do projeto — `surface`,
            // `radiusLarge`, hairline em `line` e a sombra do tema. Sem folga:
            // o leitor traz os recuos dele.
            .menuPanelChrome(padding: 0)
            .padding(28)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.map { L10n.tr("Email: \($0.subject)") } ?? L10n.tr("Email"))
    }

    /// O leitor da Caixa, apontado para a mensagem da folha e avisado de que,
    /// quando ela sair da lista de prioridades, a folha fecha.
    private var reader: some View {
        ReaderPane(
            store: store,
            debugEmailAssistantOpen: false,
            presentation: .sheet(messageID: messageID, onMessageLeft: onClose),
            onCompose: onCompose,
            attachmentSaver: NativeAttachmentSaver(),
            intelligence: intelligence,
            intelligencePresentation: intelligencePresentation,
            analysisDestination: analysisDestination,
            makeAssistantConversation: makeAssistantConversation,
            onMessagePresented: onPresented
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A barra da folha: as duas saídas que a Caixa não tem, e o ✕.
    ///
    /// Fica **em cima** do leitor, e não num rodapé: o leitor termina na faixa
    /// de resposta rápida, e uma barra depois dela empurraria o corpo para
    /// cima para reabrir o vazio que esta tarefa veio fechar.
    private var sheetBar: some View {
        HStack(spacing: 10) {
            if let message {
                Button(L10n.tr("Abrir na Caixa")) { onOpenInMailbox(message) }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.link.color)
                    .focusRing(cornerRadius: theme.radiusSmall)
                    .help(L10n.tr("Mostra este email na Caixa, com a lista ao lado"))
            }
            Spacer(minLength: 8)
            if let message {
                Button {
                    onDraft(message)
                } label: {
                    Text(L10n.tr("Gerar rascunho"))
                        .font(theme.sans.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.onAccent.color)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(theme.accent.color, in: Capsule())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: 14, tint: \.onAccent)
                .help(L10n.tr("Pede um rascunho com o corpo deste email"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: 28, height: 28)
                    .background(theme.surface3.color, in: Circle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: 14)
            .help(L10n.tr("Fechar"))
            .accessibilityLabel(L10n.tr("Fechar email"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(theme.surface.color)
    }
}
