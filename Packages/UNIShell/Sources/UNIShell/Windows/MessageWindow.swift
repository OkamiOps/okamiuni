import SwiftUI
import UNIDesign
import UNICore

/// A tela **05 Email em janela** (linhas 743–787 do protótipo, 800×600).
///
/// Abre com duplo clique numa mensagem da lista. É o leitor sem os painéis
/// em volta: assunto grande, remetente, marcas, resumo no dispositivo e corpo.
public struct MessageWindow: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let store: MailStore
    let messageID: String
    let textAssistant: (any OnDeviceTextAssisting)?
    let intelligencePresentation: IntelligencePresentation
    @State private var assistantOpen = false

    public init(
        store: MailStore,
        messageID: String,
        textAssistant: (any OnDeviceTextAssisting)? = nil,
        intelligencePresentation: IntelligencePresentation = .available
    ) {
        self.store = store
        self.messageID = messageID
        self.textAssistant = textAssistant
        self.intelligencePresentation = intelligencePresentation
    }

    private var message: Message? {
        store.messages.first { $0.id == messageID }
    }

    private var account: Account? {
        message.flatMap { store.account($0.accountID) }
    }

    private var tint: Color {
        account.flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color } ?? theme.accent.color
    }

    public var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                WindowTitleBar(title: message?.subject ?? "Mensagem") {
                    TintChip(label: account?.host ?? "", tint: tint, emphasized: true)
                }

                if let message {
                    header(message)
                    body(message)
                    footer(message)
                } else {
                    missing
                }
            }

            if assistantOpen, let message {
                LocalAssistantPanel(
                    context: localContext(for: message),
                    onAsk: askAssistant,
                    onClose: closeAssistant
                )
                .id(store.conversation(of: message.id)?.key ?? message.id)
                .padding(12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
        .task { if store.messages.isEmpty { await store.load() } }
    }

    /// Protótipo: `padding: 20px 26px 16px; border-bottom: 0.5px solid var(--line2)`.
    private func header(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(message.subject)
                .font(theme.serif.font(size: 27, weight: .medium))
                .tracking(-0.01 * 27)      // letter-spacing: -0.01em
                .lineSpacing(0.2 * 27)     // line-height: 1.2
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Text(message.from.initials)
                    .font(theme.sans.font(size: 12, weight: .bold))  // CSS 650
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.16))
                    .clipShape(Circle())
                    .overlay {
                        Circle().strokeBorder(
                            tint.opacity(0.30),
                            lineWidth: Hairline.thickness(displayScale)
                        )
                    }

                VStack(alignment: .leading, spacing: 0) {
                    Text(message.from.name)
                        .font(theme.sans.font(size: 13, weight: .semibold))  // 590
                        .foregroundStyle(theme.ink.color)
                    Text(message.from.address)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text(message.receivedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(theme.mono.font(size: 11))
                    .foregroundStyle(theme.ink4.color)
                    .fixedSize()
            }
            .padding(.top, 14)

            if !message.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(message.tags) { tag in
                        TintChip(
                            label: tag.name,
                            tint: tag.tintHex.flatMap { TokenColor(css: $0)?.color } ?? theme.ink3.color
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .hairline(theme.line2, edges: .bottom)
    }

    /// Protótipo: `padding: 22px 26px 28px`, resumo com `margin-bottom: 22px`.
    private func body(_ message: Message) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let summary = message.summary {
                    summaryCard(summary)
                        .padding(.bottom, 22)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(message.body.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(theme.serif.font(size: 16.5))
                            .lineSpacing(0.7 * 16.5)   // line-height: 1.7
                            .foregroundStyle(theme.ink.color)
                            // `max-width: 66ch` — no serifado de 16.5 dá ~520pt.
                            .frame(maxWidth: 520, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 28)
        }
        .frame(maxHeight: .infinity)
    }

    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resumo no dispositivo").capsLabel(size: 9.5)
            Text(summary)
                .font(theme.serif.font(size: 15))
                .lineSpacing(0.55 * 15)   // line-height: 1.55
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.accentLine.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    /// Protótipo: `padding: 12px 20px 14px; background: var(--surface2)`.
    private func footer(_ message: Message) -> some View {
        HStack(spacing: 8) {
            ChromeButton(
                "Responder aqui", appearance: .accent, size: 13, weight: .semibold,
                horizontalPadding: 16
            ) {
                openWindow(id: UNIWindow.composer, value: message.id)
                dismiss()
            }
            ChromeButton("Perguntar", appearance: .outlined) {
                withAnimation(.easeInOut(duration: 0.18)) { assistantOpen = true }
            }
            .disabled(!intelligencePresentation.isAvailable)
            .help(
                intelligencePresentation.isAvailable
                    ? "Abre ações rápidas e perguntas sobre este email."
                    : intelligencePresentation.detail
            )
            ChromeButton("Arquivar", appearance: .outlined) {
                store.move(message, to: .archived)
                dismiss()
            }
            Spacer(minLength: 8)
            ChromeButton("Fechar janela", appearance: .outlined) { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .top)
    }

    private var missing: some View {
        Text("Esta mensagem não está mais na caixa.")
            .font(theme.serif.font(size: 16))
            .italic()
            .foregroundStyle(theme.ink4.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func localContext(for message: Message) -> LocalAssistantContext {
        let count = store.conversation(of: message.id)?.count ?? 1
        return LocalAssistantContext(
            subject: message.subject,
            sender: message.from.display,
            conversationLabel: count > 1 ? "\(count) mensagens" : nil
        )
    }

    private func closeAssistant() {
        withAnimation(.easeInOut(duration: 0.18)) { assistantOpen = false }
    }

    private func askAssistant(_ request: LocalAssistantRequest) async throws -> String {
        guard let textAssistant else {
            throw OnDeviceTextAssistantError.invalidRequest(
                "O assistente local não foi conectado a esta janela."
            )
        }

        let ids = store.conversation(of: messageID)?.messageIDs ?? [messageID]
        for id in ids { await store.loadBodyIfNeeded(id) }

        guard let current = store.messages.first(where: { $0.id == messageID }) else {
            throw OnDeviceTextAssistantError.invalidRequest(
                "O email selecionado não está mais disponível."
            )
        }
        let mailContext: OnDeviceAssistantMailContext
        if let conversation = store.conversation(of: current.id), conversation.count > 1 {
            mailContext = .init(conversation: conversation)
        } else {
            mailContext = .init(message: current)
        }
        return try await OnDeviceAssistantBridge.answer(
            request,
            mailContext: mailContext,
            using: textAssistant
        )
    }
}

#if os(macOS)
#Preview("05 Email em janela") {
    MessageWindow(store: MailStore(source: InMemoryMailSource.fixtures), messageID: "m1")
        .environment(ThemeStore())
        .frame(width: 800, height: 600)
}
#endif
