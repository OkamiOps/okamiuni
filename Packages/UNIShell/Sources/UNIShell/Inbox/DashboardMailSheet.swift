import SwiftUI
import UNIDesign
import UNICore

/// Leitura do e-mail por cima do Dashboard. A Caixa continua sendo o lugar
/// do detalhe; daqui a pessoa lê, gera rascunho e volta.
struct DashboardMailSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let messageID: String
    let onClose: () -> Void
    let onOpenInMailbox: (Message) -> Void
    let onDraft: (Message) -> Void
    let onPresented: (String) -> Void

    private var message: Message? { store.message(messageID) }

    var body: some View {
        ZStack {
            theme.paper.color.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityLabel("Fechar email")

            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(theme.line2.color)
                    .frame(height: Hairline.thickness(displayScale))
                ScrollView {
                    bodyBlock
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .frame(maxWidth: 720, maxHeight: 640)
            .background(
                sheetFill.color,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
            }
            .shadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.14), radius: 28, y: 12)
            .padding(28)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.map { "Email: \($0.subject)" } ?? "Email")
        .task(id: messageID) {
            onPresented(messageID)
            await store.loadBodyIfNeeded(messageID)
        }
    }

    private var header: some View {
        let message = self.message
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message?.from.display ?? "Remetente")
                        .font(theme.sans.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.ink2.color)
                        .lineLimit(1)
                    Text(message?.subject ?? "Sem assunto")
                        .font(theme.sans.font(size: 18, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.ink3.color)
                        .frame(width: 28, height: 28)
                        .background(theme.surface3.color, in: Circle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: 14)
                .help("Fechar")
                .accessibilityLabel("Fechar email")
            }
            if let message {
                Text(stamp(message.receivedAt))
                    .font(theme.mono.font(size: 11))
                    .foregroundStyle(theme.ink4.color)
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var bodyBlock: some View {
        if let message {
            if message.hasHTML, let html = message.bodyHTML, !html.isEmpty {
                ReaderHTMLSection(
                    html: html,
                    paragrafos: ReaderPane.paragrafos(de: message),
                    remetente: message.from.address,
                    confiavel: store.trustsSender(message.from.address),
                    aoConfiar: { store.trustSender(message.from.address) },
                    aoRevogar: { store.revokeSenderTrust(message.from.address) }
                )
                .id(message.id)
            } else if !message.body.isEmpty {
                ReaderPlainText(paragrafos: ReaderPane.paragrafos(de: message))
            } else {
                switch store.bodyLoad(for: message.id) {
                case .carregando, nil:
                    ReaderSpinnerNote(ReaderPane.carregandoCorpo)
                        .padding(.horizontal, 28)
                case .falhou:
                    Text("Não deu para carregar o corpo. Abra na Caixa.")
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(theme.ink3.color)
                        .padding(.horizontal, 28)
                case .buscado:
                    Text(message.snippet)
                        .font(theme.serif.font(size: 16))
                        .foregroundStyle(theme.ink2.color)
                        .padding(.horizontal, 28)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message {
                Button("Abrir na Caixa") { onOpenInMailbox(message) }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.link.color)
                    .focusRing(cornerRadius: theme.radiusSmall)
            }
            Spacer(minLength: 8)
            if let message {
                Button {
                    onDraft(message)
                } label: {
                    Text("Gerar rascunho")
                        .font(theme.sans.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.onAccent.color)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(theme.accent.color, in: Capsule())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: 15, tint: \.onAccent)
                .help("Pede um rascunho com o corpo deste email")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.line2.color)
                .frame(height: Hairline.thickness(displayScale))
        }
    }

    private var sheetFill: TokenColor {
        theme.surface.contrastRatio(with: theme.paper) >= 1.18
            ? theme.surface
            : theme.surface3
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
