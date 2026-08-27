import SwiftUI
import UNIDesign
import UNICore

public struct ReaderPane: View {
    @Environment(\.theme) private var theme
    let store: MailStore
    let onAddEvent: (DetectedEvent) -> Void
    /// Abre a janela 03 (Composer) com esta mensagem citada.
    ///
    /// Dois gatilhos chamam este mesmo fechamento: o botão "Responder" da fila
    /// de triagem e o "⤢" da faixa de resposta rápida. O do "⤢" grava o
    /// rascunho em `store.replyDraft(for:)` **antes** de chamar, para a janela
    /// cheia continuar de onde a faixa parou.
    let onReply: (Message) -> Void

    public init(
        store: MailStore,
        onAddEvent: @escaping (DetectedEvent) -> Void,
        onReply: @escaping (Message) -> Void = { _ in }
    ) {
        self.store = store
        self.onAddEvent = onAddEvent
        self.onReply = onReply
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

    /// Protótipo: três blocos empilhados, e só o do meio rola — cabeçalho
    /// `flex: none`, corpo `flex: 1; overflow-y: auto`, faixa de resposta
    /// `flex: none`. O cabeçalho estava dentro da rolagem aqui, e embaixo do
    /// corpo sobrava exatamente o vazio que a faixa ocupa.
    private func content(_ message: Message) -> some View {
        VStack(spacing: 0) {
            header(message)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let summary = message.summary {
                        summaryCard(summary, event: message.detectedEvent)
                            .padding(.horizontal, 28)
                            // Protótipo: o corpo do leitor tem `padding: 22px 28px 28px`.
                            .padding(.top, 22)
                            // Protótipo: `margin-bottom: 24px` no cartão de resumo.
                            .padding(.bottom, 24)
                    }

                    body(message)
                        .padding(.top, message.summary == nil ? 22 : 0)
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // `.id` porque a faixa guarda o rascunho da mensagem que está
            // aberta: trocar de mensagem tem de trocar de rascunho, não herdar
            // o texto da anterior. O que já foi escrito não se perde — fica no
            // `MailStore`, e volta quando a mensagem voltar.
            QuickReplyBand(store: store, message: message, onPromote: onReply)
                .id(message.id)
        }
    }

    /// Protótipo: um bloco só — `padding: 16px 28px 16px;
    /// border-bottom: 0.5px solid var(--line2); border-left: 3px solid selColor` —
    /// com a fila de triagem, o assunto e o remetente dentro dele. Aqui isso
    /// estava partido em três, com a barra colorida e a divisória cercando só a
    /// fila de triagem e um fundo `surface2` que o protótipo não tem.
    private func header(_ message: Message) -> some View {
        let accentColor = accountTint(message)

        return VStack(alignment: .leading, spacing: 0) {
            triageBar(message)
                .padding(.bottom, 12)  // protótipo: margin-bottom: 12px
            subject(message)
            sender(message)
                .padding(.top, 10)  // protótipo: margin-top: 10px
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(theme.surface.color)
        .hairline(theme.line2, edges: .bottom)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
        }
    }

    private func accountTint(_ message: Message) -> Color {
        store.account(message.accountID)
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.accent.color
    }

    private func triageBar(_ message: Message) -> some View {
        let account = store.account(message.accountID)
        let accentColor = accountTint(message)

        return HStack(spacing: 7) {  // protótipo: gap: 7px
            let triageButtons = [
                ("Hoje", TriageBucket.today),
                ("Depois", TriageBucket.later),
                ("Arquivar", TriageBucket.archived)
            ]

            // Protótipo: `on` é a caixa **da mensagem**, e clicar move a
            // mensagem — não troca a visão da lista.
            ForEach(triageButtons, id: \.0) { label, bucket in
                let isActive = message.bucket == bucket
                Button {
                    store.move(message, to: bucket)
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
                        .shadow(theme.btnShadow)
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
            }

            // O gancho para a janela 03. Fica junto da fila de triagem porque é
            // a mesma decisão: o que fazer com esta mensagem agora.
            Button { onReply(message) } label: {
                Text("Responder")
                    .font(theme.sans.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.onAccent.color)
                    .frame(height: 26)
                    .padding(.horizontal, 12)
                    .background(theme.accent.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                    .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
            .keyboardShortcut("r", modifiers: .command)

            Spacer(minLength: 8)

            // Protótipo: `selChipStyle: this.chip(selAcc.c, true)` — o mesmo
            // chip da barra lateral e da lista, na cor da conta.
            TintChip(label: account?.host ?? "", tint: accentColor, emphasized: true)
        }
    }

    private func subject(_ message: Message) -> some View {
        Text(message.subject)
            .font(theme.serif.font(size: 26, weight: .medium))
            .tracking(-0.01 * 26)   // letter-spacing: -0.01em a 26pt = -0.26pt
            .lineSpacing(0.22 * 26)  // line-height: 1.22 × 26 − 26 = 5.72
            .foregroundStyle(theme.ink.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sender(_ message: Message) -> some View {
        let tint = accountTint(message)

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

            // Protótipo: nome e email na **mesma linha** (nome em `ink`/590,
            // email em `ink3`), com o carimbo empurrado para a direita por
            // `margin-left: auto`. Aqui o carimbo estava embaixo do nome.
            Text(Self.senderLine(
                name: message.from.name,
                address: message.from.address,
                ink: theme.ink.color,
                ink3: theme.ink3.color
            ))
            .font(theme.sans.font(size: 12.5))
            .lineLimit(1)

            Spacer(minLength: 10)

            Text(message.receivedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                .font(theme.mono.font(size: 10.5))
                .foregroundStyle(theme.ink4.color)
                .fixedSize()
        }
    }

    /// "Marina Duarte · marina@clientepremium.com" com o nome em `ink` e o
    /// endereço em `ink3`, como o protótipo faz com dois `<span>`.
    nonisolated static func senderLine(
        name: String,
        address: String,
        ink: Color,
        ink3: Color
    ) -> AttributedString {
        var line = AttributedString(name)
        line.foregroundColor = ink
        var strong = AttributeContainer()
        strong.inlinePresentationIntent = .stronglyEmphasized
        line.mergeAttributes(strong)

        guard !address.isEmpty else { return line }
        var tail = AttributedString(" · \(address)")
        tail.foregroundColor = ink3
        line.append(tail)
        return line
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
                // Protótipo: `margin-top: 14px; padding-top: 13px;
                // border-top: 0.5px solid var(--accent-line)`. O `spacing: 8`
                // do VStack já responde por 8 dos 14.
                Rectangle()
                    .fill(theme.accentLine.color)
                    .frame(height: Hairline.thickness)
                    .padding(.top, 6)   // 8 do spacing + 6 = os 14 do margin-top
                    .padding(.bottom, 5)  // 5 + 8 do spacing = os 13 do padding-top
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
                            // Raio 8 literal no protótipo, não `var(--r2)`.
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            // `box-shadow: 0 1px 2px rgba(0,0,0,0.18)` — o blur
                            // do CSS vale o dobro do raio do SwiftUI.
                            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    // Raio 8 literal, o mesmo do `clipShape` acima.
                    .focusRing(cornerRadius: 8, tint: \.onAccent)
                    .fixedSize()
                }
            }
        }
        // Protótipo: `padding: 15px 17px`.
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
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
