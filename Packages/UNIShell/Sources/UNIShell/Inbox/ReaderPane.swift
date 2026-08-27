import SwiftUI
import UNIDesign
import UNICore

public struct ReaderPane: View {
    @Environment(\.theme) private var theme
    let store: MailStore
    let onAddEvent: (DetectedEvent) -> Void

    public init(store: MailStore, onAddEvent: @escaping (DetectedEvent) -> Void) {
        self.store = store
        self.onAddEvent = onAddEvent
    }

    public var body: some View {
        Group {
            if let message = store.selectedMessage {
                content(message)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
    }

    private func content(_ message: Message) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                triageBar(message)
                subject(message)
                sender(message)

                if let summary = message.summary {
                    summaryCard(summary, event: message.detectedEvent)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)
                }

                body(message)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func triageBar(_ message: Message) -> some View {
        let account = store.account(message.accountID)
        let accentColor = account
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.accent.color

        return HStack(spacing: 6) {
            let triageButtons = [
                ("Hoje", TriageBucket.today),
                ("Depois", TriageBucket.later),
                ("Arquivar", TriageBucket.archived)
            ]

            ForEach(triageButtons, id: \.0) { label, bucket in
                let isActive = store.bucket == bucket
                Button {
                    store.select(bucket: bucket)
                } label: {
                    Text(label)
                        .font(theme.sans.font(size: 11.5, weight: .semibold))
                        .foregroundStyle(isActive ? theme.accentInk.color : theme.ink.color)
                        .frame(height: 26)
                        .padding(.horizontal, 12)
                        .background(isActive ? theme.accentSoft.color : theme.btn.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(
                                    isActive ? accentColor : theme.btnLine.color,
                                    lineWidth: 0.5
                                )
                        }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(account?.host ?? "")
                .font(theme.sans.font(size: 11))
                .foregroundStyle(theme.ink2.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(theme.btnLine.color, lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .bottom)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
        }
    }

    private func subject(_ message: Message) -> some View {
        Text(message.subject)
            .font(theme.serif.font(size: 26, weight: .medium))
            .tracking(-0.26)
            .lineSpacing(5.72)
            .foregroundStyle(theme.ink.color)
            .padding(.horizontal, 28)
            .padding(.top, 16)
    }

    private func sender(_ message: Message) -> some View {
        let account = store.account(message.accountID)
        let tint = account
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.accent.color

        return HStack(spacing: 10) {
            Text(message.from.initials)
                .font(theme.mono.font(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.16))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(tint.opacity(0.30), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(message.from.display)
                    .font(theme.sans.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(message.receivedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(theme.mono.font(size: 10.5))
                    .foregroundStyle(theme.ink4.color)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
    }

    private func summaryCard(_ summary: String, event: DetectedEvent?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resumo no dispositivo").capsLabel()
            Text(summary)
                .font(theme.serif.font(size: 15))
                .lineSpacing(8.25)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            if let event {
                Divider().overlay(theme.accentLine.color)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Usa interpolação com AttributedString para evitar deprecação
                        Text(Self.eventLabelFormatted(event.label, ink2: theme.ink2.color, ink: theme.ink.color))
                            .font(theme.sans.font(size: 12.5))
                    }
                    Spacer(minLength: 8)
                    Button { onAddEvent(event) } label: {
                        Text("Colocar na agenda")
                            .font(theme.sans.font(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.onAccent.color)
                            .frame(height: 26)
                            .padding(.horizontal, 12)
                            .background(theme.accent.color)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.accentLine.color, lineWidth: 0.5)
        }
    }

    private func body(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(message.body.enumerated()), id: \.offset) { _, para in
                Text(para)
                    .font(theme.serif.font(size: 16))
                    .lineSpacing(10.88)
                    .foregroundStyle(theme.ink.color)
                    .frame(maxWidth: 500, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(theme.isDark ? "uni-mark-dark" : "uni-mark-light")
                .resizable()
                .scaledToFit()
                .frame(height: 104)
                .opacity(0.85)
            Text("Nada aqui. Bom sinal.")
                .font(theme.serif.font(size: 16))
                .italic()
                .foregroundStyle(theme.ink4.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// Formata o rótulo do evento com cores diferentes para cada parte.
    /// "Compromisso detectado — " em ink2, seguido de título em ink (semibold).
    nonisolated private static func eventLabelFormatted(
        _ label: String,
        ink2: Color,
        ink: Color
    ) -> AttributedString {
        var result = AttributedString("Compromisso detectado — ")
        result.foregroundColor = ink2

        var titlePart = AttributedString(label)
        titlePart.foregroundColor = ink
        // Aplicar semibold via attributes
        var attributes = AttributeContainer()
        attributes.inlinePresentationIntent = .stronglyEmphasized
        titlePart.mergeAttributes(attributes)

        result.append(titlePart)
        return result
    }
}

#if os(macOS)
#Preview {
    ReaderPane(store: MailStore(source: InMemoryMailSource.fixtures), onAddEvent: { _ in })
        .environment(ThemeStore())
        .frame(width: 600, height: 600)
}
#endif
