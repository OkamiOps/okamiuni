import SwiftUI
import UNIDesign
import UNICore

public struct ReaderPane: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let store: MailStore
    /// Abre a janela 03 (Composer) com esta mensagem citada.
    ///
    /// Dois gatilhos chamam este mesmo fechamento: o botão "Responder" da fila
    /// de triagem e o "⤢" da faixa de resposta rápida. O do "⤢" grava o
    /// rascunho em `store.replyDraft(for:)` **antes** de chamar, para a janela
    /// cheia continuar de onde a faixa parou.
    let onReply: (Message) -> Void

    /// O retorno de "Colocar na agenda": qual mensagem, qual item criado, e a
    /// nota que a confirmação mostra. `nil` a maior parte do tempo — só existe
    /// enquanto a confirmação está na tela.
    ///
    /// Mora aqui, e não como fechamento para fora (como `onReply`), porque
    /// "Colocar na agenda" não abre janela nem precisa de nada que só o
    /// `InboxScreen` tenha: é uma mutação de `store`, do mesmo jeito que a
    /// fila de triagem chama `store.move(_:to:)` direto, sem passar por um
    /// closure.
    @State private var agendaReceipt: AgendaAddReceipt?

    public init(
        store: MailStore,
        onReply: @escaping (Message) -> Void = { _ in }
    ) {
        self.store = store
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
        // O retorno de "Colocar na agenda" some sozinho, mas nunca **antes**
        // de dar tempo de "Desfazer" — mesma vida útil e mesma reinicialização
        // por `id` que o retorno de arraste da lista já usa
        // (`MessageList.receiptLifetime`): uma segunda confirmação troca a
        // faixa e reinicia a contagem em vez de herdar o resto do relógio da
        // primeira.
        .task(id: agendaReceipt?.id) {
            guard agendaReceipt != nil else { return }
            try? await Task.sleep(for: MessageList.receiptLifetime)
            guard !Task.isCancelled else { return }
            agendaReceipt = nil
        }
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
                        summaryCard(summary, event: message.detectedEvent, message: message)
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
                // Botão direito no corpo. Fica no bloco que rola, não no
                // cabeçalho: lá em cima cada botão da fila de triagem já tem
                // o seu alvo, e um menu por cima deles roubaria o clique.
                //
                // `contentShape` porque a coluna do texto mede 500pt e o
                // painel mede mais: sem ela o clique fora do parágrafo cai no
                // fundo e não acha menu nenhum.
                .contentShape(Rectangle())
                .uniContextMenu(ContextMenus.reader(message), store: store)
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
                                    lineWidth: Hairline.thickness(displayScale)
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
                        .strokeBorder(
                            tint.opacity(0.30),
                            lineWidth: Hairline.thickness(displayScale)
                        )
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

    private func summaryCard(_ summary: String, event: DetectedEvent?, message: Message) -> some View {
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
                    .frame(height: Hairline.thickness(displayScale))
                    .padding(.top, 6)   // 8 do spacing + 6 = os 14 do margin-top
                    .padding(.bottom, 5)  // 5 + 8 do spacing = os 13 do padding-top
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Usa interpolação com AttributedString para evitar deprecação
                        Text(Self.eventLabelFormatted(event.label, ink2: theme.ink2.color, ink: theme.ink.color))
                            .font(theme.sans.font(size: 12.5))
                    }
                    Spacer(minLength: 8)
                    if let agendaReceipt, agendaReceipt.messageID == message.id {
                        agendaConfirmation(agendaReceipt)
                    } else {
                        addToAgendaButton(event, for: message)
                    }
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
                .strokeBorder(theme.accentLine.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    // MARK: - Colocar na agenda

    /// O compromisso desta mensagem já está em `store.agenda` — não só "o
    /// clique aconteceu nesta sessão", mas o estado de fato. É contra isto, e
    /// não contra `agendaReceipt`, que o botão decide se ainda tem o que
    /// fazer: a confirmação some sozinha depois de
    /// `MessageList.receiptLifetime`, mas o compromisso continua lá, e um
    /// terceiro clique — depois da confirmação já ter sumido — não pode
    /// voltar a parecer um botão comum.
    private func isOnAgenda(_ message: Message) -> Bool {
        let id = DetectedEventConversion.agendaID(forMessageID: message.id)
        return store.agenda.contains { $0.id == id }
    }

    /// "Colocar na agenda". Protótipo: botão de acento, raio 8 literal,
    /// `box-shadow: 0 1px 2px rgba(0,0,0,0.18)`.
    ///
    /// **A decisão do segundo clique**, e de qualquer clique depois dele:
    /// desabilitado, com o rótulo trocado para "Na agenda" e o `help`
    /// dizendo por quê — a mesma dupla que `SwipeActionColumn.isNoOp` usa
    /// para uma ação que não faria nada. Um botão que continuasse com a
    /// mesma cara e recusasse em silêncio seria o próprio defeito que esta
    /// tarefa veio consertar, só que adiado para o segundo clique.
    private func addToAgendaButton(_ event: DetectedEvent, for message: Message) -> some View {
        let onAgenda = isOnAgenda(message)
        return Button { addEvent(event, for: message) } label: {
            Text(onAgenda ? "Na agenda" : "Colocar na agenda")
                .font(theme.sans.font(size: 11.5, weight: .semibold))
                .foregroundStyle(onAgenda ? theme.ink4.color : theme.onAccent.color)
                .frame(height: 26)
                .padding(.horizontal, 12)
                .background(onAgenda ? theme.surface3.color : theme.accent.color)
                // Raio 8 literal no protótipo, não `var(--r2)`.
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if onAgenda {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
                    }
                }
                // `box-shadow: 0 1px 2px rgba(0,0,0,0.18)` — o blur do CSS
                // vale o dobro do raio do SwiftUI. Some junto com o acento:
                // um botão apagado não pede a mesma sombra de um botão vivo.
                .shadow(color: onAgenda ? .clear : .black.opacity(0.18), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(onAgenda)
        // Raio 8 literal, o mesmo do `clipShape` acima.
        .focusRing(cornerRadius: 8, tint: \.onAccent)
        .fixedSize()
        .help(onAgenda
              ? "Colocar na agenda — indisponível: este compromisso já está na agenda"
              : "Cria o compromisso na agenda, a partir do que a mensagem detectou")
    }

    /// O retorno de "Colocar na agenda", no idioma da faixa de resposta
    /// (`QuickReplyBand.closedCard`, "Retomar") e do arraste da lista
    /// (`SwipeUndoBand`, "Desfazer"): "✓ nota" com um botão que desfaz.
    private func agendaConfirmation(_ receipt: AgendaAddReceipt) -> some View {
        HStack(spacing: 8) {
            Text("✓")
                .font(theme.sans.font(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.accentInk.color)
            Text(receipt.note)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
            ChromeButton(
                "Desfazer", appearance: .outlined,
                size: 11.5, height: 26, horizontalPadding: 10
            ) {
                undoAddEvent(receipt)
            }
            .help("Desfazer: \(receipt.note)")
        }
    }

    /// O que o clique faz de verdade: `store.addToAgenda` decide se há
    /// compromisso novo (devolve o item) ou se é repetição (devolve `nil`,
    /// primeira e única guarda contra duplicar). Só no primeiro caso nasce
    /// uma confirmação — um clique que não fez nada não ganha um "✓".
    private func addEvent(_ event: DetectedEvent, for message: Message) {
        guard let item = store.addToAgenda(event, from: message) else { return }
        let stamp = Date.now.formatted(date: .omitted, time: .shortened)
        withAnimation(SwipeMotion.transition) {
            agendaReceipt = AgendaAddReceipt(
                messageID: message.id,
                itemID: item.id,
                note: AgendaAddReceipt.note(eventLabel: event.label, stamp: stamp)
            )
        }
    }

    private func undoAddEvent(_ receipt: AgendaAddReceipt) {
        store.removeFromAgenda(receipt.itemID)
        withAnimation(SwipeMotion.transition) { agendaReceipt = nil }
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
    ReaderPane(store: MailStore(source: InMemoryMailSource.fixtures))
        .environment(ThemeStore())
        .frame(width: 600, height: 600)
}
#endif
