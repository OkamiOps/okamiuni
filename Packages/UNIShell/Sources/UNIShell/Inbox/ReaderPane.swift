import SwiftUI
import UNIDesign
import UNICore

public struct ReaderPane: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let store: MailStore
    /// Abre a janela 03 (Composer) com esta mensagem citada.
    ///
    /// **Um gatilho só, desde a M3-12: o "⤢" da faixa de resposta rápida.** Ele
    /// grava o rascunho em `store.replyDraft(for:)` antes de chamar, para a
    /// janela cheia continuar de onde a faixa parou.
    ///
    /// O botão "Responder" da fila de triagem deixou de abrir janela: ele
    /// expande a faixa de baixo e põe o cursor nela — pedido do dono. A janela
    /// continua a um clique dali, e é o mesmo caminho de sempre.
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

    /// Quantas vezes alguém pediu para responder esta mensagem pelo botão do
    /// topo (ou por ⌘R). A faixa de baixo ouve o número mudar e se expande —
    /// ver `QuickReplyBand.expandRequest`.
    @State private var pedidoDeResposta = 0

    /// O mesmo retorno com "Desfazer" que a lista desenha. O leitor **posta**
    /// nele e não o desenha: apagar daqui tira a mensagem do leitor, e uma
    /// faixa presa a ele iria embora junto com o que precisava desfazer. Quem
    /// sobrevive à ação é a lista — ver `ActionReceipts`.
    @Environment(ActionReceipts.self) private var sharedReceipts: ActionReceipts?

    /// O objeto próprio de quando ninguém proveu um — o harness de renderização,
    /// uma preview. Mesmo alcance e mesma razão que `MessageList`: sem ele, o
    /// "Apagar" da barra seria um botão que não faz nada em metade dos
    /// contextos, que é o defeito que ele veio consertar.
    @State private var ownReceipts = ActionReceipts()

    private var receipts: ActionReceipts { sharedReceipts ?? ownReceipts }

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
        let conversa = store.conversation(of: message.id)

        return VStack(spacing: 0) {
            header(message)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // A conversa, quando há mais de uma mensagem: as anteriores
                    // recolhidas, esta aberta. Com uma mensagem só, o desenho é
                    // exatamente o de antes desta tarefa — o `else` é o mesmo
                    // bloco que sempre esteve aqui.
                    if let conversa, conversa.count > 1 {
                        ConversationStackView(store: store, conversa: conversa, opened: $stackState) {
                            cardsAndBody($0)
                        }
                    } else {
                        cardsAndBody(message)
                    }
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
                .uniContextMenu(
                    ContextMenus.reader(
                        message,
                        accountAddress: store.account(message.accountID)?.address ?? ""
                    ),
                    store: store,
                    intercept: { command in
                        receipts.intercept(
                            command, on: store, stamp: ActionReceipts.stamp
                        )
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // `.id` porque a faixa guarda o rascunho da mensagem que está
            // aberta: trocar de mensagem tem de trocar de rascunho, não herdar
            // o texto da anterior. O que já foi escrito não se perde — fica no
            // `MailStore`, e volta quando a mensagem voltar.
            QuickReplyBand(
                store: store, message: message, onPromote: onReply,
                expandRequest: pedidoDeResposta
            )
            .id(message.id)
        }
        // Abrir uma mensagem sem corpo **é** o pedido de busca. `id:` para que
        // trocar de mensagem cancele a busca da anterior e comece a desta: sem
        // isso, abrir cinco mensagens em sequência deixaria cinco conexões em
        // voo para escrever num leitor que já mostra outra coisa.
        //
        // Sem porta de corpo (fixtures, e todo teste que não passa uma) isto
        // não faz nada — `loadBodyIfNeeded` sai na primeira guarda.
        .task(id: message.id) {
            await store.loadBodyIfNeeded(message.id)
        }
        // Voltar a uma conversa é abri-la de novo, com a mais recente aberta.
        // Sem isto o estado ficava guardado com a chave da conversa de origem e
        // uma ida-e-volta o encontrava intacto — ver `ConversationStack.carried`.
        // Mora aqui, e não dentro da pilha, porque a conversa de **uma**
        // mensagem não desenha pilha nenhuma: a passagem por ela também tem de
        // limpar o que ficou.
        .onChange(of: conversa?.key) {
            stackState = conversa.flatMap { ConversationStack.carried(stackState, to: $0) }
        }
    }

    /// Os cartões (resumo, convite) e o corpo de **uma** mensagem — o miolo do
    /// leitor, exatamente como ele sempre foi.
    ///
    /// Virou função própria porque agora ele é desenhado em dois contextos: a
    /// mensagem sozinha, e a mensagem aberta dentro de uma pilha de conversa.
    /// Uma segunda cópia para o segundo caso divergiria da primeira no próximo
    /// conserto de espaçamento.
    @ViewBuilder
    private func cardsAndBody(_ message: Message) -> some View {
        if let summary = message.summary {
            summaryCard(summary, event: message.detectedEvent, message: message)
                .padding(.horizontal, 28)
                // Protótipo: o corpo do leitor tem `padding: 22px 28px 28px`.
                .padding(.top, 22)
                // Protótipo: `margin-bottom: 24px` no cartão de resumo.
                .padding(.bottom, 24)
        }

        if let convite = Self.convite(de: message) {
            inviteCard(convite, message: message)
                .padding(.horizontal, 28)
                .padding(.top, message.summary == nil ? 22 : 0)
                .padding(.bottom, 24)
        }

        body(message)
            .padding(.top, temCartao(message) ? 0 : 22)
            .padding(.bottom, 28)
    }

    // MARK: - A conversa empilhada

    /// Quais mensagens da conversa estão abertas — e de qual conversa esse
    /// estado é.
    ///
    /// `nil` é "ainda ninguém clicou nesta pilha", e aí vale o estado inicial
    /// (`ConversationStack.initialExpanded`). Guardar a chave junto é o que
    /// zera a pilha ao trocar de conversa **sem** um `.task` que só corre
    /// depois do primeiro desenho: a conversa nova já nasce com a mais recente
    /// aberta, no mesmo quadro.
    ///
    /// Vive aqui e não no `MailStore` porque é estado **de leitura desta
    /// janela**: duas janelas sobre a mesma conversa podem ter mensagens
    /// diferentes abertas, e nada disso precisa sobreviver a nada.
    @State private var stackState: ConversationStack.Opened?

    /// A primeira linha da mensagem recolhida.
    ///
    /// O primeiro parágrafo, e a prévia quando não há corpo baixado — que é o
    /// caso comum de uma mensagem antiga da conversa, cujo corpo só desce
    /// quando alguém a abre. `nonisolated` e `static` pelo motivo de sempre: o
    /// que a pessoa lê é comportamento, e o teste o afirma sem montar janela.
    nonisolated static func primeiraLinha(de message: Message) -> String {
        // **Sem refluxo, de propósito.** Aqui a pergunta é outra: a pilha
        // recolhida mostra uma linha, cortada no fim, e a primeira linha crua
        // já é a resposta certa para ela. Refluir aqui só emendaria mais texto
        // no que a `lineLimit(1)` corta — e mudaria o que a M3-10 fixou.
        let bruto = message.body.first ?? message.snippet
        return bruto
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
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
                triageChip(
                    label, isActive: message.bucket == bucket, accent: accentColor,
                    help: ""
                ) {
                    store.move(message, to: bucket)
                }
            }

            // **"Apagar", que faltava.** A barra oferecia Hoje · Depois ·
            // Arquivar · Responder, e a ação que o dono mais usa vivia só no
            // botão direito e no ⌫ — os dois continuam valendo, e os três agora
            // fazem exatamente a mesma coisa (`ActionReceipts.delete`).
            //
            // No idioma dos vizinhos, e não numa cor nova: o app não tem token
            // destrutivo, e inventar um vermelho aqui seria a única cor do
            // aplicativo que não sai do desenho. O que carrega o peso da ação é
            // a palavra — "Apagar", a mesma do menu, do arraste e da tela de
            // ajustes — e a faixa "Desfazer" que ela deixa na lista.
            triageChip(
                Self.apagarLabel(message), isActive: false, accent: accentColor,
                help: ContextMenus.deleteItem(message).help
            ) {
                _ = receipts.delete(message, on: store)
            }

            // "Responder" **expande a faixa de baixo** e põe o cursor nela —
            // não abre janela. Pedido do dono: a resposta começa embaixo da
            // mensagem que se está lendo, e a janela cheia continua a um clique
            // dali, no "⤢" da própria faixa, que leva o rascunho junto.
            Button { pedidoDeResposta += 1 } label: {
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

    /// O que o botão escreve — e ele diz a verdade sobre o que vai fazer.
    ///
    /// Na Lixeira, apagar não é mover para a Lixeira: é tirar de lá de vez. É a
    /// mesma decisão que `ContextMenus.deleteItem` toma no rótulo do menu, e a
    /// frase é a que `SwipeReceipt` já usa quando isso acontece ("Apagada de
    /// vez") — três superfícies, uma palavra.
    ///
    /// `nonisolated` e `static` pelo motivo de sempre: o que a pessoa lê é
    /// comportamento, e o teste o afirma sem montar janela.
    nonisolated static func apagarLabel(_ message: Message) -> String {
        message.bucket == .trash ? "Apagar de vez" : "Apagar"
    }

    /// A pastilha da fila de triagem, uma só vez.
    ///
    /// Protótipo: `height: 26px; padding: 0 12px; border-radius: var(--r2);
    /// font-size: 11.5px; font-weight: 590; box-shadow: var(--btn-shadow)`, com
    /// `accent`/`accent-soft`/`accent-ink` quando a caixa é a da mensagem e
    /// `btn-line`/`btn`/`ink` quando não é. Virou função porque "Apagar" entrou
    /// na barra e uma segunda cópia do mesmo desenho divergiria da primeira no
    /// próximo conserto de espaçamento.
    private func triageChip(
        _ label: String,
        isActive: Bool,
        accent: Color,
        help: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
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
                            isActive ? accent : theme.btnLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .shadow(theme.btnShadow)
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help(help ?? "")
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
            // Protótipo (`selAvatarStyle`): `width/height: 26px; font-size:
            // 10px; font-weight: 650`, **na fonte do painel** — o estilo não
            // troca a família. Aqui a inicial estava em `mono`/600: uma
            // tipografia que o desenho não pediu, e a única do leitor que não
            // combinava com a mesma bolinha da janela 05, que já traduz o mesmo
            // `font-weight: 650` como `sans`/`bold` (ver `MessageWindow`).
            Text(message.from.initials)
                .font(theme.sans.font(size: 10, weight: .bold))  // CSS 650
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

    // MARK: - O convite de agenda

    /// O convite desta mensagem, quando ela trouxe um `text/calendar`.
    ///
    /// `static` e `nonisolated` para o teste o afirmar sem montar a janela — a
    /// mesma regra das frases do corpo. A leitura é barata e pura
    /// (`ICalendar.parse` não toca em nada), então ela acontece no desenho em
    /// vez de virar mais um campo a manter em dia no `MailStore`.
    nonisolated static func convite(de message: Message) -> CalendarInvite? {
        guard let ics = message.calendarICS else { return nil }
        return ICalendar.parse(ics)
    }

    private func temCartao(_ message: Message) -> Bool {
        message.summary != nil || Self.convite(de: message) != nil
    }

    /// "Convite de agenda", "Convite cancelado", e o rótulo de quem foi
    /// convidado. Estáticas pelo mesmo motivo de `carregandoCorpo`: o que a
    /// pessoa lê é comportamento.
    nonisolated static let conviteTitulo = "Convite de agenda"
    nonisolated static let conviteCancelado = "Convite cancelado"

    /// Quem está no convite, numa linha só.
    ///
    /// O organizador primeiro e sem repetir: ele quase sempre também está na
    /// lista de participantes, e o cartão mostraria o nome dele duas vezes
    /// seguidas.
    nonisolated static func participantes(_ convite: CalendarInvite) -> String? {
        var nomes: [String] = []
        if let quem = convite.organizer { nomes.append(quem) }
        for quem in convite.attendees where !nomes.contains(quem) { nomes.append(quem) }
        return nomes.isEmpty ? nil : nomes.joined(separator: ", ")
    }

    /// O cartão do convite, no idioma do cartão de resumo — mesma superfície,
    /// mesma linha, mesmo raio. Duas superfícies diferentes para duas coisas
    /// que aparecem no mesmo lugar seriam duas gramáticas na mesma tela.
    private func inviteCard(_ convite: CalendarInvite, message: Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(convite.isCancelled ? Self.conviteCancelado : Self.conviteTitulo).capsLabel()

            Text(convite.summary.isEmpty ? "Compromisso" : convite.summary)
                .font(theme.serif.font(size: 15))
                .lineSpacing(8.25)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            if let inicio = convite.start {
                linhaDoCartao(quando(inicio, convite: convite))
            }
            if let onde = convite.location {
                linhaDoCartao(onde)
            }
            if let quem = Self.participantes(convite) {
                linhaDoCartao(quem)
            }

            // O botão só existe quando há o que criar: sem `DTSTART` não há
            // compromisso, e um convite cancelado não vira compromisso novo.
            if convite.detectedEvent != nil, !convite.isCancelled {
                Rectangle()
                    .fill(theme.accentLine.color)
                    .frame(height: Hairline.thickness(displayScale))
                    .padding(.top, 6)
                    .padding(.bottom, 5)
                HStack(spacing: 12) {
                    Spacer(minLength: 8)
                    if let agendaReceipt, agendaReceipt.messageID == message.id {
                        agendaConfirmation(agendaReceipt)
                    } else {
                        inviteAgendaButton(convite, for: message)
                    }
                }
            }
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

    private func linhaDoCartao(_ texto: String) -> some View {
        Text(texto)
            .font(theme.sans.font(size: 12.5))
            .foregroundStyle(theme.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A data do convite em hora **local**, que é a única que a pessoa
    /// consegue usar: o `DTSTART` pode ter chegado em UTC ou no fuso de quem
    /// convidou, e mostrar qualquer um dos dois pediria uma conta de cabeça.
    private func quando(_ inicio: Date, convite: CalendarInvite) -> String {
        if convite.isAllDay {
            return inicio.formatted(date: .complete, time: .omitted)
        }
        let comeco = inicio.formatted(date: .abbreviated, time: .shortened)
        guard let fim = convite.end, fim > inicio else { return comeco }
        return comeco + " – " + fim.formatted(date: .omitted, time: .shortened)
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
        agendaButton(
            label: isOnAgenda(message) ? "Na agenda" : "Colocar na agenda",
            apagado: isOnAgenda(message),
            help: isOnAgenda(message)
                ? "Colocar na agenda — indisponível: este compromisso já está na agenda"
                : "Cria o compromisso na agenda, a partir do que a mensagem detectou",
            action: { addEvent(event, for: message) }
        )
    }

    /// O mesmo botão, com a decisão do **convite**: colocar, atualizar, ou
    /// dizer que já está lá.
    ///
    /// "Atualizar na agenda" existe porque o "Convite atualizado" é o mesmo
    /// evento (mesmo `UID`) com uma versão nova, e a única coisa certa a fazer
    /// com ele é mexer no compromisso que já existe. Antes desta decisão, o
    /// botão dizia "Colocar" nas duas mensagens e criava dois compromissos
    /// idênticos — os dois "DreamSquad" da agenda do dono.
    private func inviteAgendaButton(_ convite: CalendarInvite, for message: Message) -> some View {
        let estado = store.agendaState(for: convite, from: message)
        return agendaButton(
            label: Self.inviteButtonLabel(estado),
            apagado: estado == .naAgenda,
            help: Self.inviteButtonHelp(estado),
            action: { addInvite(convite, for: message) }
        )
    }

    /// O que o botão do convite escreve em cada estado. `nonisolated` e
    /// `static` pelo motivo de sempre: o que a pessoa lê é comportamento, e o
    /// teste o afirma sem montar janela.
    nonisolated static func inviteButtonLabel(_ estado: InviteAgendaState) -> String {
        switch estado {
        case .ausente: "Colocar na agenda"
        case .naAgenda: "Na agenda"
        case .desatualizado: "Atualizar na agenda"
        }
    }

    nonisolated static func inviteButtonHelp(_ estado: InviteAgendaState) -> String {
        switch estado {
        case .ausente: "Cria o compromisso na agenda, a partir deste convite"
        case .naAgenda: "Colocar na agenda — indisponível: este convite já está na agenda"
        case .desatualizado: "Atualiza o compromisso que já está na agenda com o que este convite mudou"
        }
    }

    private func agendaButton(
        label: String, apagado onAgenda: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
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
        .help(help)
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

    /// O clique no botão do convite. `store.addToAgenda(_ invite:from:)` cria
    /// **ou** atualiza, e devolve `nil` quando não havia o que fazer — a mesma
    /// regra do outro caminho: um clique que não mudou nada não ganha um "✓".
    private func addInvite(_ convite: CalendarInvite, for message: Message) {
        guard let item = store.addToAgenda(convite, from: message) else { return }
        let stamp = Date.now.formatted(date: .omitted, time: .shortened)
        withAnimation(SwipeMotion.transition) {
            agendaReceipt = AgendaAddReceipt(
                messageID: message.id,
                itemID: item.id,
                note: AgendaAddReceipt.note(eventLabel: item.title, stamp: stamp)
            )
        }
    }

    private func undoAddEvent(_ receipt: AgendaAddReceipt) {
        store.removeFromAgenda(receipt.itemID)
        withAnimation(SwipeMotion.transition) { agendaReceipt = nil }
    }

    /// O corpo — ou o que está acontecendo com ele.
    ///
    /// **Nunca vazio mudo.** Era exatamente isso: uma mensagem sem corpo no
    /// banco (39 das 83 do dono) abria com a coluna do texto em branco, sem
    /// nada dizendo se a mensagem é vazia, se o app quebrou, ou se vale esperar.
    /// Agora os quatro estados são visíveis: o texto, a espera, a falha com
    /// saída, e a mensagem que de fato não tem texto.
    @ViewBuilder
    private func body(_ message: Message) -> some View {
        if message.hasHTML, let html = message.bodyHTML {
            // **O email de verdade.** O texto continua existindo (é ele que a
            // busca indexa e que a lista mostra na prévia), mas quem a pessoa
            // lê é isto. `.id` porque a permissão de carregar imagens remotas é
            // **por mensagem**: sem ele, o "Carregar" de uma valeria para a
            // seguinte, que é exatamente a permissão global que esta tela não
            // tem.
            // O remetente vai junto: é dele que a faixa oferece o "sempre", e
            // é ele que o `MailStore` já sabe se é confiável. `.id` continua
            // sendo da mensagem — o "Carregar" de uma abertura não atravessa
            // para a seguinte; o que atravessa é a confiança, que está no
            // disco e não neste `@State`.
            ReaderHTMLSection(
                html: html,
                // O texto plano da **mesma** mensagem, que já está no banco: é
                // ele que o leitor mostra enquanto o HTML não pinta, em vez da
                // coluna vazia. Ver `ReaderHTMLSection`.
                paragrafos: Self.paragrafos(de: message),
                remetente: message.from.address,
                confiavel: store.trustsSender(message.from.address),
                aoConfiar: { store.trustSender(message.from.address) },
                aoRevogar: { store.revokeSenderTrust(message.from.address) }
            )
            .id(message.id)
        } else if !message.body.isEmpty {
            ReaderPlainText(paragrafos: Self.paragrafos(de: message))
        } else {
            switch store.bodyLoad(for: message.id) {
            case .carregando:
                bodyNote(Self.carregandoCorpo)
            case .falhou(let causa):
                bodyFailure(causa, message: message)
            case .buscado:
                // Buscamos e não havia texto: um anexo sozinho. Dizer isso é
                // diferente de não dizer nada — mas **não** por cima de um
                // cartão de convite, que é a mensagem inteira ali desenhada:
                // era essa a frase que o convite de agenda ganhava no lugar do
                // evento.
                if Self.convite(de: message) == nil { bodyNote(Self.semTexto) }
            case nil:
                // Sem porta de corpo — as fixtures do Marco 1. A coluna fica
                // como sempre esteve, e nenhuma captura muda.
                EmptyView()
            }
        }
    }

    /// Os parágrafos do texto plano **como se lê**, e não como o transporte os
    /// entregou.
    ///
    /// "Não gosto de como o email fica": um texto plano quebrado à mão em 72
    /// colunas chegava aqui com uma linha por quebra, e a coluna do leitor
    /// desenhava cada uma como um bloco — a frase "Passando para confirmar
    /// nossa call amanhã, 16 de julho, às 15h, / no horário / de Brasília."
    /// partida em três. `PlainTextReflow` desfaz a quebra que é do transporte e
    /// deixa em paz a que é do autor (lista, citação, assinatura, tabela).
    ///
    /// **Mora aqui, no desenho, e não no decodificador.** As duas alternativas
    /// custam o mesmo para escrever, e só esta alcança as mensagens que **já
    /// estão** no banco: refluir na decodificação melhoraria as próximas e
    /// deixaria as antigas exatamente como o dono as vê hoje — a menos de uma
    /// varredura que reescrevesse todos os corpos e reindexasse o FTS por
    /// causa de espaçamento. Aqui, uma mensagem de 2024 fica boa na primeira
    /// abertura, e o banco não é tocado.
    ///
    /// `nonisolated` e `static` pelo motivo de sempre: o que a pessoa lê é
    /// comportamento, e o teste o afirma sem montar janela.
    nonisolated static func paragrafos(de message: Message) -> [String] {
        message.body.flatMap { PlainTextReflow.paragraphs(from: $0) }
    }

    /// A largura da coluna de leitura.
    ///
    /// Protótipo: `max-width: 64ch` no parágrafo do corpo — 64 caracteres de
    /// Newsreader a 16pt, que é o que este número resolve. Uma linha de texto
    /// corrido que atravessasse o painel inteiro obriga o olho a caçar o começo
    /// da linha seguinte, e é justamente o que um leitor de email não pode
    /// pedir.
    ///
    /// Uma constante, e não três literais: desde a M3-18 o mesmo número também
    /// entra na folha de estilo do email **sem desenho próprio** (ver
    /// `ReaderHTMLPolicy.documento`), e três cópias divergiriam na primeira vez
    /// que alguém mexesse numa.
    nonisolated static let readingWidth: CGFloat = 500

    /// "Carregando corpo…", e a frase da mensagem sem texto. Estáticas e
    /// `nonisolated` para o teste as afirmar sem montar a janela: o que a
    /// pessoa lê é comportamento, não decoração.
    nonisolated static let carregandoCorpo = "Carregando corpo…"
    nonisolated static let semTexto = "Esta mensagem não tem texto."

    private func bodyNote(_ texto: String) -> some View { ReaderNote(texto) }

    /// A falha, com a saída junto. Uma faixa que só diz "não deu" é a mesma
    /// tela vazia com mais palavras.
    private func bodyFailure(_ causa: String, message: Message) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Não foi possível baixar o corpo desta mensagem.")
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(causa)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
            ChromeButton(
                "Tentar de novo", appearance: .outlined,
                size: 11.5, height: 26, horizontalPadding: 10
            ) {
                Task { await store.retryBody(message.id) }
            }
            .help("Busca o corpo desta mensagem no servidor outra vez")
        }
        .frame(maxWidth: Self.readingWidth, alignment: .leading)
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

/// A frase em itálico que o leitor põe no lugar do corpo enquanto ele não está
/// lá: "Carregando corpo…" da M3-3, "Esta mensagem não tem texto." e, desde a
/// M3-21, o "Carregando a mensagem…" do bloco de HTML.
///
/// **Uma peça, e não três cópias da receita.** As três dizem a mesma coisa —
/// "aqui devia haver texto e por ora não há" — e um leitor em que duas delas
/// estivessem em serif e a terceira em sans seria um leitor com duas vozes. A
/// tipografia é a do corpo, um grau menor e em itálico: presente, e claramente
/// não sendo a mensagem.
struct ReaderNote: View {
    @Environment(\.theme) private var theme
    private let texto: String

    init(_ texto: String) { self.texto = texto }

    var body: some View {
        Text(texto)
            .font(theme.serif.font(size: 15))
            .italic()
            .foregroundStyle(theme.ink4.color)
            .frame(maxWidth: ReaderPane.readingWidth, alignment: .leading)
            .padding(.horizontal, 28)
    }
}

/// A mesma nota, com a roda girando ao lado.
///
/// **Pedido do dono, com estas palavras: "um spinning".** A frase sozinha é
/// discreta demais para uma espera de vinte segundos — ela se lê como legenda,
/// não como "o app está trabalhando". A roda é o que separa "está vindo" de
/// "travou", e é a peça que o macOS já tem para dizer isso.
///
/// A tipografia continua sendo a da `ReaderNote`: uma voz só no leitor.
struct ReaderSpinnerNote: View {
    @Environment(\.theme) private var theme
    private let texto: String

    init(_ texto: String) { self.texto = texto }

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text(texto)
                .font(theme.serif.font(size: 15))
                .italic()
                .foregroundStyle(theme.ink4.color)
        }
        .frame(maxWidth: ReaderPane.readingWidth, alignment: .leading)
        .padding(.horizontal, 28)
    }
}

/// A coluna de texto plano do leitor.
///
/// Era um `VStack` dentro do `ReaderPane.body(_:)`. Virou peça porque agora ela
/// é desenhada em **dois** momentos: quando a mensagem não tem HTML (sempre foi
/// assim) e enquanto o HTML ainda não pintou — o texto que já está no banco no
/// lugar dos vinte segundos de nada. Duas cópias divergiriam na primeira vez
/// que alguém mexesse no espaçamento de uma.
struct ReaderPlainText: View {
    @Environment(\.theme) private var theme
    let paragrafos: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(paragrafos.enumerated()), id: \.offset) { _, para in
                Text(para)
                    .font(theme.serif.font(size: 16))
                    .lineSpacing(10.88)
                    .foregroundStyle(theme.ink.color)
                    .frame(maxWidth: ReaderPane.readingWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
    }
}
