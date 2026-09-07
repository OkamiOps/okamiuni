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
    let intelligencePresentation: IntelligencePresentation
    let analysisDestination: @Sendable (String?) -> AssistantDestination
    let onMessagePresented: (String) -> Void

    public init(
        store: MailStore,
        messageID: String,
        textAssistant: (any TextAssisting)? = nil,
        assistantSettings: AssistantSettingsStore? = nil,
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        onMessagePresented: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.messageID = messageID
        self.textAssistant = textAssistant
        self.assistantSettings = assistantSettings
        self.intelligencePresentation = intelligencePresentation
        self.analysisDestination = analysisDestination
        self.onMessagePresented = onMessagePresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: store.message(messageID)?.subject ?? L10n.tr("Mensagem")) { EmptyView() }
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
        .background(theme.surface.color)
        .task(id: messageID) {
            if store.messages.isEmpty { await store.load() }
            await store.loadBodyIfNeeded(messageID)
        }
    }

    private func makeAssistantConversation(messageID id: String) -> AssistantConversation {
        let settings = assistantSettings?.snapshot()
        let message = store.message(id)
        let engine: AssistantEngine = textAssistant.map { assistant in
            AssistantBridge.engine(
                using: assistant,
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
