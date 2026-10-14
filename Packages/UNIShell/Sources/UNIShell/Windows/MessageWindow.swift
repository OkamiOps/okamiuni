import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// A janela destacada compartilha corpo, anexos e ações com a Caixa e o dashboard.
public struct MessageWindow: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let store: MailStore
    let messageID: String
    let textAssistant: (any TextAssisting)?
    let assistantSettings: AssistantSettingsStore?
    let agentServices: AgentApplicationServices
    let intelligencePresentation: IntelligencePresentation
    let analysisDestination: @Sendable (String?) -> AssistantDestination
    let onMessagePresented: (String) -> Void

    public init(
        store: MailStore,
        messageID: String,
        textAssistant: (any TextAssisting)? = nil,
        assistantSettings: AssistantSettingsStore? = nil,
        agentServices: AgentApplicationServices = .init(),
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        onMessagePresented: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.messageID = messageID
        self.textAssistant = textAssistant
        self.assistantSettings = assistantSettings
        self.agentServices = agentServices
        self.intelligencePresentation = intelligencePresentation
        self.analysisDestination = analysisDestination
        self.onMessagePresented = onMessagePresented
    }

    /// A janela da mensagem: **chrome e medida**, e o leitor inteiro por
    /// dentro.
    ///
    /// Protótipo: `ModalJanelas.dc.html`, bloco "MENSAGEM EM JANELA" — 880×720,
    /// raio de janela, a barra de 44 com os semáforos na linha da plataforma e,
    /// na ponta direita dela, **onde a mensagem mora**: "na Caixa de entrada ·
    /// ricardo@empresa.com". Essa linha é a única coisa que a janela solta não
    /// herda da Caixa de graça — sem ela, a mensagem aberta fora da lista
    /// perde a caixa e a conta de vista.
    ///
    /// O que está **dentro** é o `ReaderPane`, o mesmo da Caixa, e o desenho
    /// dele é de outra tarefa: a barra de ferramentas, o cartão da IA e o
    /// corpo não são tocados aqui. É por isso que o desenho mostra uma barra
    /// só, com os semáforos e as ferramentas juntos, e aqui há duas — a nossa,
    /// com os semáforos e o lugar, e a do leitor logo abaixo.
    public var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: store.message(messageID)?.subject ?? L10n.tr("Mensagem")) {
                if let lugar = ondeMora {
                    Text(lugar)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ReaderPane(
                store: store,
                debugEmailAssistantOpen: false,
                presentation: .sheet(messageID: messageID, onMessageLeft: { dismiss() }),
                onCompose: { openWindow(id: UNIWindow.composer, value: $0.value) },
                attachmentSaver: NativeAttachmentSaver(),
                intelligence: textAssistant.map { AssistantBridge.composerGenerator(using: $0) },
                intelligencePresentation: intelligencePresentation,
                analysisDestination: analysisDestination,
                makeAssistantConversation: { id in makeAssistantConversation(messageID: id) },
                onMessagePresented: onMessagePresented
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `glassWindow`: o fundo de uma janela **solta**, que no Vidro é
        // fechado o bastante para texto longo e nos 26 opacos é `surface`,
        // que é o que a janela sempre pintou. Mesmo token do compositor.
        .background(theme.glassWindow.color)
        .task(id: messageID) {
            if store.messages.isEmpty { await store.load() }
            await store.loadBodyIfNeeded(messageID)
        }
    }

    /// "na Caixa de entrada · ricardo@empresa.com" — a caixa e a conta desta
    /// mensagem, como o desenho as escreve. Nulo quando a mensagem já não está
    /// no banco: a barra fica só com o assunto em vez de afirmar um lugar.
    private var ondeMora: String? {
        guard let message = store.message(messageID) else { return nil }
        let caixa = message.bucket.label
        guard let conta = store.account(message.accountID)?.address else {
            return L10n.tr("na \(caixa)")
        }
        return L10n.tr("na \(caixa) · \(conta)")
    }

    private func makeAssistantConversation(messageID id: String) -> AssistantConversation {
        let settings = assistantSettings?.snapshot()
        let message = store.message(id)
        let engine: AssistantEngine = textAssistant.map { assistant in
            AssistantBridge.engine(
                using: WorkspaceAgentAssistant(
                    base: assistant,
                    settings: { assistantSettings?.snapshot() ?? .default },
                    makeTools: { agentServices.tools(store: store, open: { messageID in
                        openWindow(id: UNIWindow.message, value: messageID)
                    }) }
                ),
                supportsDraftReply: true,
                mailContext: {
                    let ids = store.conversation(of: id)?.messageIDs ?? [id]
                    for messageID in ids { await store.loadBodyIfNeeded(messageID) }
                    guard let context = store.assistantMailContext(for: id) else {
                        throw TextAssistantError.invalidRequest(L10n.tr("O email selecionado não está mais disponível."))
                    }
                    return context
                },
                currentDraft: { store.replyDraft(for: id)?.text ?? "" }
            )
        } ?? .unavailable
        return AssistantConversation(
            scope: .email,
            context: AssistantContext(subject: message?.subject ?? "", sender: message?.from.display),
            destination: settings.map(AssistantDestination.init(settings:)) ?? .unconfigured,
            engine: engine,
            provider: settings.flatMap { $0.provider == .providerOAuth ? $0.providerOAuth.kind : nil }
        )
    }
}
