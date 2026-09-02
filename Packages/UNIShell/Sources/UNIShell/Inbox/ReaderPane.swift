import SwiftUI
import UNIDesign
import UNICore

/// Acesso contextual à IA no próprio cabeçalho do e-mail. Separado apenas
/// para o clique real do controle ser verificável fora da tela.
struct ReaderAssistantButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let presentation: IntelligencePresentation
    let action: () -> Void

    private var help: String {
        presentation.isAvailable
            ? "Abre resumo, pontos-chave, insights, pendências e geração de resposta para este email."
            : presentation.detail
    }

    private var statusColor: Color {
        theme.info.color
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(presentation.isAvailable ? statusColor : theme.ink4.color)
                .frame(width: 28, height: 28)
                .background(presentation.isAvailable ? statusColor.opacity(0.12) : theme.surface3.color)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            presentation.isAvailable ? statusColor.opacity(0.38) : theme.line.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 14)
        .disabled(!presentation.isAvailable)
        .help(help)
        .accessibilityLabel("Ações de inteligência deste email")
        .accessibilityValue(presentation.isAvailable ? "Disponível" : "Indisponível")
        .accessibilityHint(help)
    }
}

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
    /// Abre a janela 03 na intenção pedida — responder, responder a todos,
    /// encaminhar ou continuar rascunho. O ícone Responder da barra **não**
    /// passa por aqui: ele expande a faixa de baixo.
    let onCompose: (ComposerRoute) -> Void
    /// Mesmo motor da janela cheia, reaproveitado na resposta rápida.
    let intelligence: ComposerIntelligenceGenerator?
    /// Estado real do modelo local e ação que abre o painel contextual do
    /// leitor. O botão fica junto da caixa porque é uma ação sobre este e-mail,
    /// não uma configuração global.
    let intelligencePresentation: IntelligencePresentation
    let onOpenAssistant: () -> Void
    let onAskAssistant: ((String, LocalAssistantRequest) async throws -> String)?
    /// A mensagem visível deve saltar a fila de resumos históricos. O app
    /// injeta a coordenação real; previews e testes podem deixar a porta vazia.
    let onMessagePresented: (String) -> Void
    /// Informa ao shell quando o popover transborda o leitor. O layout de
    /// três colunas precisa elevar o painel inteiro e suspender as calhas de
    /// redimensionamento enquanto essa superfície estiver aberta.
    let onEmailAssistantOpenChange: (Bool) -> Void
    /// Porta exclusiva do harness offscreen: mantém o painel contextual aberto
    /// sem automatizar a interface da sessão.
    let debugEmailAssistantOpen: Bool
    /// Força o TL;DR aberto — o harness que prova o cartão de compromisso.
    let debugResumoAberto: Bool
    /// Destino injetável do anexo: evita painel do sistema no harness e deixa
    /// a ação testável sem automação da área de trabalho.
    let attachmentSaver: (any AttachmentSaving)?

    /// O retorno de "Colocar na agenda": qual mensagem, qual item criado, e a
    /// nota que a confirmação mostra. `nil` a maior parte do tempo — só existe
    /// enquanto a confirmação está na tela.
    ///
    /// Mora aqui, e não como fechamento para fora (como `onCompose`), porque
    /// "Colocar na agenda" não abre janela nem precisa de nada que só o
    /// `InboxScreen` tenha: é uma mutação de `store`, do mesmo jeito que a
    /// fila de triagem chama `store.move(_:to:)` direto, sem passar por um
    /// closure.
    @State private var agendaReceipt: AgendaAddReceipt?

    /// Quantas vezes alguém pediu para responder esta mensagem pelo botão do
    /// topo (ou por ⌘R). A faixa de baixo ouve o número mudar e se expande —
    /// ver `QuickReplyBand.expandRequest`.
    @State private var pedidoDeResposta = 0
    @State private var folderPickerOpen = false
    @State private var quickReplyRevision = 0
    @State private var emailAssistantOpen = false
    @State private var emailAssistantPanelSize = ReaderIntelligencePopover.defaultSize
    @State private var assistantAnchor: CGPoint = .zero

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
    @State private var attachmentError: String?
    @State private var savingAttachmentID: String?
    /// A primeira pintura mostra o leitor (testes e abertura). Trocar de
    /// caixa (Tudo) espera a lista pintar — senão a WebView trava o clique.
    @State private var readerDidAppear = false
    @State private var readerReadyRecorte: String?
    /// Convite aberto ou recolhido, por mensagem. Sem entrada: aberto se
    /// ainda não respondeu, recolhido depois de Aceitar/Talvez/Recusar.
    @State private var conviteAbertoPorID: [String: Bool] = [:]
    /// Resumo de IA aberto ou recolhido. Sem entrada: recolhido — o email
    /// cabe na tela; quem quiser o TL;DR expande.
    @State private var resumoAbertoPorID: [String: Bool] = [:]
    /// Cabeçalho compacto vs. expandido, por mensagem. Sem entrada: compacto.
    /// O clique na linha revela email do remetente, destinatários e o assunto
    /// inteiro — o que a faixa de uma linha esconde.
    @State private var cabecalhoAbertoPorID: [String: Bool] = [:]

    private var receipts: ActionReceipts { sharedReceipts ?? ownReceipts }

    public init(
        store: MailStore,
        onCompose: @escaping (ComposerRoute) -> Void = { _ in },
        attachmentSaver: (any AttachmentSaving)? = NativeAttachmentSaver(),
        intelligence: ComposerIntelligenceGenerator? = nil,
        intelligencePresentation: IntelligencePresentation = .available,
        onOpenAssistant: @escaping () -> Void = {},
        onAskAssistant: ((String, LocalAssistantRequest) async throws -> String)? = nil,
        onMessagePresented: @escaping (String) -> Void = { _ in },
        onEmailAssistantOpenChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            store: store,
            debugEmailAssistantOpen: false,
            debugResumoAberto: false,
            onCompose: onCompose,
            attachmentSaver: attachmentSaver,
            intelligence: intelligence,
            intelligencePresentation: intelligencePresentation,
            onOpenAssistant: onOpenAssistant,
            onAskAssistant: onAskAssistant,
            onMessagePresented: onMessagePresented,
            onEmailAssistantOpenChange: onEmailAssistantOpenChange
        )
    }

    init(
        store: MailStore,
        debugEmailAssistantOpen: Bool,
        debugResumoAberto: Bool = false,
        onCompose: @escaping (ComposerRoute) -> Void = { _ in },
        attachmentSaver: (any AttachmentSaving)? = nil,
        intelligence: ComposerIntelligenceGenerator? = nil,
        intelligencePresentation: IntelligencePresentation = .available,
        onOpenAssistant: @escaping () -> Void = {},
        onAskAssistant: ((String, LocalAssistantRequest) async throws -> String)? = nil,
        onMessagePresented: @escaping (String) -> Void = { _ in },
        onEmailAssistantOpenChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.store = store
        self.onCompose = onCompose
        self.attachmentSaver = attachmentSaver
        self.intelligence = intelligence
        self.intelligencePresentation = intelligencePresentation
        self.onOpenAssistant = onOpenAssistant
        self.onAskAssistant = onAskAssistant
        self.onMessagePresented = onMessagePresented
        self.onEmailAssistantOpenChange = onEmailAssistantOpenChange
        self.debugEmailAssistantOpen = debugEmailAssistantOpen
        self.debugResumoAberto = debugResumoAberto
        _emailAssistantOpen = State(initialValue: debugEmailAssistantOpen)
    }

    public var body: some View {
        let recorte = [
            store.bucket.rawValue,
            store.selectedAccountID ?? "",
            store.selectedFolderID ?? "",
        ].joined(separator: "|")
        let showReader = readerReadyRecorte == recorte
            || (!readerDidAppear && readerReadyRecorte == nil)
        Group {
            if showReader, let message = store.selectedMessage {
                content(message)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
        .onAppear {
            readerDidAppear = true
            if readerReadyRecorte == nil { readerReadyRecorte = recorte }
        }
        .onChange(of: recorte) { _, novo in
            readerReadyRecorte = nil
            Task { @MainActor in
                await Task.yield()
                readerReadyRecorte = novo
            }
        }
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

            // A divisória dados/corpo é irmã, não overlay do cabeçalho. Como
            // overlay ela atravessava o painel da IA na borda de baixo — o
            // mesmo defeito da faixa da conta, que já saiu do overlay.
            Rectangle()
                .fill(theme.line2.color)
                .frame(height: Hairline.thickness(displayScale))

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
                        accountAddress: store.account(message.accountID)?.address ?? "",
                        provider: store.account(message.accountID)?.provider,
                        folders: store.folders(of: message.accountID),
                        selectedFolderID: store.selectedFolderID,
                        currentBucket: store.bucket
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
            if message.bucket != .drafts {
                QuickReplyBand(
                    store: store, message: message,
                    onPromote: { onCompose(.reply(messageID: $0.id)) },
                    expandRequest: pedidoDeResposta,
                    intelligence: intelligence
                )
                .id("\(message.id)-\(quickReplyRevision)")
            }
        }
        .coordinateSpace(.named(Self.assistantAnchorSpace))
        .onPreferenceChange(ReaderAssistantAnchorKey.self) { point in
            if point != assistantAnchor { assistantAnchor = point }
        }
        .overlay(alignment: .topLeading) {
            if emailAssistantOpen, assistantAnchor != .zero {
                emailAssistantPopover(message)
                    .offset(
                        x: assistantAnchor.x - ReaderIntelligencePopover.clampedSize(
                            emailAssistantPanelSize
                        ).width,
                        y: assistantAnchor.y + 34
                    )
            }
        }
        // Abrir uma mensagem sem corpo **é** o pedido de busca. `id:` para que
        // trocar de mensagem cancele a busca da anterior e comece a desta: sem
        // isso, abrir cinco mensagens em sequência deixaria cinco conexões em
        // voo para escrever num leitor que já mostra outra coisa.
        //
        // Sem porta de corpo (fixtures, e todo teste que não passa uma) isto
        // não faz nada — `loadBodyIfNeeded` sai na primeira guarda.
        .task(id: message.id) {
            setEmailAssistantOpen(debugEmailAssistantOpen)
            messageDidAppear(message.id)
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

    /// Mantém a chamada isolada e diretamente testável sem precisar simular
    /// seleção ou depender da duração de uma inferência real.
    func messageDidAppear(_ messageID: String) {
        onMessagePresented(messageID)
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
                .padding(.top, 22)
                .padding(.bottom, Self.convite(de: message) != nil ? 8 : 16)
        }

        if let convite = Self.convite(de: message) {
            inviteCard(convite, message: message)
                .padding(.horizontal, 28)
                .padding(.top, message.summary == nil ? 22 : 8)
                .padding(.bottom, 16)
        }

        body(message)
            .padding(.top, temCartao(message) ? 0 : 16)
            .padding(.bottom, 28)
    }

    private func save(_ attachment: MailAttachment, from message: Message) {
        guard let attachmentSaver else {
            attachmentError = "Salvar anexo indisponível nesta janela."
            return
        }
        savingAttachmentID = attachment.id
        attachmentError = nil
        Task {
            defer { savingAttachmentID = nil }
            do {
                let fetched = try await store.fetchAttachment(attachment, from: message)
                try await attachmentSaver.save(fetched)
            } catch let error as AttachmentError {
                attachmentError = error.localizedDescription
            } catch {
                attachmentError = "Não foi possível baixar ou salvar o anexo."
            }
        }
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

    /// Fila de triagem em cima; remetente, assunto, hora e anexos numa linha
    /// só. O corpo passa a ser o centro da coluna — o bloco de 22pt de assunto
    /// mais o avatar de 26pt empurravam o email para fora da primeira tela.
    private func header(_ message: Message) -> some View {
        let accentColor = accountTint(message)

        return VStack(alignment: .leading, spacing: 0) {
            triageBar(message)
                // O painel da IA é overlay do botão, irmão **anterior** do
                // assunto. Sem isto o VStack pinta o título por cima e o
                // clique cai no texto, não no modal.
                .zIndex(emailAssistantOpen ? 2 : 0)
            identityBlock(message)
                .padding(.top, 28)
                .allowsHitTesting(!emailAssistantOpen)
            if let attachmentError {
                Text(attachmentError)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.danger.color)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        // A faixa da conta é fundo do cabeçalho, não overlay. Como overlay ela
        // atravessava o popover que nasce dentro deste conteúdo e desenhava a
        // linha verde/azul por cima do modal.
        .background {
            ZStack(alignment: .leading) {
                theme.surface.color
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)
            }
        }
    }

    /// Remetente · assunto numa linha. O clique expande: email, destinatários
    /// e o assunto inteiro. Os anexos ficam **fora** do botão para o clique
    /// no clipe continuar baixando, e não abrir o cabeçalho.
    private func identityBlock(_ message: Message) -> some View {
        let aberto = cabecalhoEstaAberto(message)
        return VStack(alignment: .leading, spacing: aberto ? 10 : 0) {
            if aberto {
                identityExpanded(message)
                if !message.attachments.isEmpty {
                    attachmentChips(message)
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        abrirCabecalho(message)
                    } label: {
                        identityCollapsed(message)
                    }
                    .buttonStyle(.plain)
                    .help(Self.expandirCabecalho)
                    .accessibilityLabel(Self.expandirCabecalho)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue("Recolhido")

                    if !message.attachments.isEmpty {
                        attachmentChips(message)
                    }
                }
            }
        }
    }

    private func abrirCabecalho(_ message: Message) {
        withAnimation(.easeOut(duration: 0.15)) {
            cabecalhoAbertoPorID[message.id] = true
        }
    }

    private func recolherCabecalho(_ message: Message) {
        withAnimation(.easeOut(duration: 0.15)) {
            cabecalhoAbertoPorID[message.id] = false
        }
    }

    private func cabecalhoEstaAberto(_ message: Message) -> Bool {
        cabecalhoAbertoPorID[message.id] ?? false
    }

    private func identityCollapsed(_ message: Message) -> some View {
        let tint = accountTint(message)
        return HStack(alignment: .center, spacing: 8) {
            senderAvatar(message.from.initials, tint: tint, size: 20, font: 9)
            Text(Self.identityCaption(name: message.from.name, subject: message.subject))
                .font(theme.sans.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            identityStamp(message)
            identityChevron(aberto: false)
        }
        .contentShape(Rectangle())
    }

    private func identityExpanded(_ message: Message) -> some View {
        let tint = accountTint(message)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                senderAvatar(message.from.initials, tint: tint, size: 26, font: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.from.name.isEmpty ? message.from.address : message.from.name)
                        .font(theme.sans.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                    if !message.from.address.isEmpty, !message.from.name.isEmpty {
                        Text(message.from.address)
                            .font(theme.sans.font(size: 12))
                            .foregroundStyle(theme.ink3.color)
                            .textSelection(.enabled)
                    }
                    if let para = Self.destinatarios(message) {
                        Text(para)
                            .font(theme.sans.font(size: 12))
                            .foregroundStyle(theme.ink3.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                identityStamp(message)
                Button {
                    recolherCabecalho(message)
                } label: {
                    identityChevron(aberto: true)
                }
                .buttonStyle(.plain)
                .help(Self.recolherCabecalho)
                .accessibilityLabel(Self.recolherCabecalho)
            }
            Text(message.subject)
                .font(theme.serif.font(size: 17, weight: .semibold))
                .tracking(-0.01 * 17)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .contentShape(Rectangle())
    }

    private func senderAvatar(_ initials: String, tint: Color, size: CGFloat, font: CGFloat) -> some View {
        Text(initials)
            .font(theme.sans.font(size: font, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(
                        tint.opacity(0.30),
                        lineWidth: Hairline.thickness(displayScale)
                    )
            )
    }

    private func identityStamp(_ message: Message) -> some View {
        Text(message.receivedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
            .font(theme.mono.font(size: 10.5))
            .foregroundStyle(theme.ink4.color)
            .fixedSize()
    }

    private func identityChevron(aberto: Bool) -> some View {
        Image(systemName: aberto ? "chevron.up" : "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.ink3.color)
            .frame(width: 18, height: 18)
    }

    /// "Marina Duarte · Revisão do contrato"
    nonisolated static func identityCaption(name: String, subject: String) -> String {
        let quem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let oQue = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if quem.isEmpty { return oQue }
        if oQue.isEmpty { return quem }
        return "\(quem) · \(oQue)"
    }

    nonisolated static let expandirCabecalho = "Mostra o email do remetente e o assunto completo"
    nonisolated static let recolherCabecalho = "Recolhe remetente e assunto"

    /// "Para Ana, Bruno · Cc Carla"
    nonisolated static func destinatarios(_ message: Message) -> String? {
        func nomes(_ lista: [Contact]) -> String {
            lista.map { $0.name.isEmpty ? $0.address : $0.name }.joined(separator: ", ")
        }
        let para = nomes(message.to)
        let cc = nomes(message.cc)
        switch (para.isEmpty, cc.isEmpty) {
        case (true, true): return nil
        case (false, true): return "Para \(para)"
        case (true, false): return "Cc \(cc)"
        case (false, false): return "Para \(para) · Cc \(cc)"
        }
    }

    private func attachmentChips(_ message: Message) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(message.attachments.prefix(2))) { attachment in
                Button {
                    save(attachment, from: message)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9, weight: .semibold))
                        Text(attachment.filename)
                            .lineLimit(1)
                    }
                    .font(theme.sans.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.ink2.color)
                    .frame(height: 22)
                    .padding(.horizontal, 8)
                    .background(theme.surface3.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.radiusSmall)
                            .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
                    }
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .disabled(savingAttachmentID == attachment.id)
                .help(savingAttachmentID == attachment.id
                    ? "Baixando \(attachment.filename)…"
                    : "Baixar \(attachment.filename) (\(attachment.mimeType), \(attachment.sizeLabel))")
            }
            if message.attachments.count > 2 {
                Text("+\(message.attachments.count - 2)")
                    .font(theme.sans.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.ink3.color)
                    .help(message.attachments.dropFirst(2).map(\.filename).joined(separator: " · "))
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func accountTint(_ message: Message) -> Color {
        store.account(message.accountID)
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.accent.color
    }

    private func triageBar(_ message: Message) -> some View {
        let account = store.account(message.accountID)
        let accentColor = accountTint(message)
        let markers = Self.appliedMarkers(for: message, in: store.folders)
        let buckets: [(String, TriageBucket)] = [
            ("Hoje", .today),
            ("Depois", .later),
            ("Arquivar", .archived),
        ]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                TintChip(label: account?.host ?? "", tint: accentColor, emphasized: true)
                ForEach(Array(markers.prefix(1))) { marker in
                    TintChip(
                        label: Self.markerChipLabel(marker.displayName),
                        tint: theme.ink3.color
                    )
                    .help("Marcador aplicado: \(marker.displayName)")
                }
                if markers.count > 1 {
                    TintChip(label: "+\(markers.count - 1)", tint: theme.ink3.color)
                        .help(markers.dropFirst().map(\.displayName).joined(separator: " · "))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if message.bucket == .drafts {
                    triageAction(
                        "Editar rascunho",
                        symbol: "square.and.pencil",
                        help: "Continua o que já estava escrito",
                        tone: .primary
                    ) {
                        onCompose(ComposerRoute.editor(for: message))
                    }
                    .keyboardShortcut("r", modifiers: .command)

                    triageAction(
                        "Apagar",
                        symbol: SwipeAction.trash.symbol(for: message),
                        help: "Joga o rascunho fora",
                        tone: .danger,
                        showsLabel: false
                    ) {
                        _ = receipts.delete(message, on: store)
                    }
                } else {
                    bucketSegment(buckets, current: message.bucket) { bucket in
                        store.move(message, to: bucket)
                    }

                    triageAction(
                        Self.apagarLabel(message),
                        symbol: SwipeAction.trash.symbol(for: message),
                        help: ContextMenus.deleteItem(message).help,
                        tone: .danger,
                        showsLabel: false
                    ) {
                        _ = receipts.delete(message, on: store)
                    }

                    moveFolderButton(for: message)

                    composeIconRow(for: message)
                }

                Spacer(minLength: 16)

                ReaderAssistantButton(
                    presentation: intelligencePresentation,
                    action: {
                        setEmailAssistantOpen(!emailAssistantOpen)
                        onOpenAssistant()
                    }
                )
                .background {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .named(Self.assistantAnchorSpace))
                        Color.clear.preference(
                            key: ReaderAssistantAnchorKey.self,
                            value: CGPoint(x: frame.maxX, y: frame.minY)
                        )
                    }
                }
            }
            .zIndex(emailAssistantOpen ? 90 : 0)
        }
    }

    /// Destinos da conversa num **trilho só**. Cada rótulo tem largura própria
    /// (`.fixedSize`) — espremer o HStack pai quebrava "Hoje" no meio.
    private func bucketSegment(
        _ buckets: [(String, TriageBucket)],
        current: TriageBucket,
        action: @escaping (TriageBucket) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { index, item in
                let (label, bucket) = item
                let ativo = current == bucket
                if index > 0 {
                    Rectangle()
                        .fill(theme.line.color)
                        .frame(width: Hairline.thickness(displayScale), height: 14)
                }
                Button { action(bucket) } label: {
                    Text(label)
                        .font(theme.sans.font(size: 11.5, weight: ativo ? .semibold : .medium))
                        .foregroundStyle(ativo ? theme.accentInk.color : theme.ink2.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(ativo ? theme.accentSoft.color : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: 6)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .background(theme.surface2.color)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    @ViewBuilder
    private func emailAssistantPopover(_ message: Message) -> some View {
        ReaderIntelligencePopover(
            context: assistantContext(message),
            isAvailable: intelligencePresentation.isAvailable
                && onAskAssistant != nil
                && intelligence != nil,
            panelSize: $emailAssistantPanelSize,
            onAsk: { request in
                guard let onAskAssistant else {
                    throw TextAssistantError.invalidRequest(
                        "O assistente local não foi conectado a esta janela."
                    )
                }
                return try await onAskAssistant(message.id, request)
            },
            onGenerateReply: { try await generateReply(for: message.id) },
            onUseReply: { useGeneratedReply($0, for: message) },
            onClose: { setEmailAssistantOpen(false) }
        )
    }

    private func assistantContext(_ message: Message) -> LocalAssistantContext {
        let count = store.conversation(of: message.id)?.count ?? 1
        return LocalAssistantContext(
            subject: message.subject,
            sender: message.from.display,
            conversationLabel: count > 1 ? "\(count) mensagens" : nil
        )
    }

    nonisolated static func appliedMarkers(
        for message: Message,
        in folders: [MailFolder]
    ) -> [MailFolder] {
        folders.filter {
            $0.accountID == message.accountID
                && $0.role == .other
                && message.folderIDs.contains($0.id)
        }
    }

    nonisolated static func markerChipLabel(_ displayName: String) -> String {
        let leaf = displayName
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? displayName
        guard leaf.count > 18 else { return leaf }
        return String(leaf.prefix(17)) + "…"
    }

    private func setEmailAssistantOpen(_ open: Bool) {
        emailAssistantOpen = open
        onEmailAssistantOpenChange(open)
    }

    private func generateReply(for messageID: String) async throws -> String {
        guard let intelligence else {
            throw TextAssistantError.invalidRequest(
                "A inteligência de escrita não foi conectada a esta janela."
            )
        }
        let ids = store.conversation(of: messageID)?.messageIDs ?? [messageID]
        for id in ids { await store.loadBodyIfNeeded(id) }

        guard let message = store.message(messageID),
              let context = store.assistantMailContext(for: messageID)
        else {
            throw TextAssistantError.invalidRequest(
                "O email selecionado não está mais disponível."
            )
        }
        let request = ComposerIntelligenceRequest(
            action: .createReply,
            target: .draft,
            source: store.replyDraft(for: messageID)?.text ?? "",
            sourceMessage: message,
            sourceContext: context
        )
        return try await ComposerIntelligence.generate(request, using: intelligence).result
    }

    private func useGeneratedReply(_ text: String, for message: Message) {
        var draft = store.replyDraft(for: message.id)
            ?? ReplyDraft(to: [message.from], body: AttributedString())
        draft.body = AttributedString(text)
        draft.sentAt = nil
        store.setReplyDraft(draft, for: message.id)
        quickReplyRevision += 1
        pedidoDeResposta += 1
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

    /// A ação continua reversível fora da Lixeira, mas não pode parecer igual a
    /// "Arquivar": magenta suave deixa explícito que ela tira a conversa da
    /// caixa atual sem transformar uma ida para a Lixeira em botão alarmista.
    ///
    /// Estes três tokens vivem juntos porque a cor é semântica da ação, não do
    /// tema/conta que recebeu a mensagem. O teste renderiza a pastilha com a
    /// paleta real para impedir que ela volte a ser um botão neutro.
    nonisolated static func apagarPalette(isDark: Bool) -> ReaderDangerPalette {
        if isDark {
            ReaderDangerPalette(
                ink: TokenColor(css: "#FE39D1")!,
                fill: TokenColor(css: "#3A0828")!,
                line: TokenColor(css: "#C41A8A")!
            )
        } else {
            ReaderDangerPalette(
                ink: TokenColor(css: "#A3135A")!,
                fill: TokenColor(css: "#FDE7F2")!,
                line: TokenColor(css: "#E580B5")!
            )
        }
    }

    /// Três ícones no lugar do antigo "Responder" com texto: responder,
    /// responder a todos, encaminhar. Hover pinta o acento; o rótulo vive no
    /// `help`.
    private func composeIconRow(for message: Message) -> some View {
        let conta = store.account(message.accountID)?.address ?? ""
        let podeTodos = ComposerSeed.replyAllExtras(message, accountAddress: conta) > 0
        return HStack(spacing: 4) {
            ReaderChromeIcon(
                symbol: "arrowshape.turn.up.left.fill",
                label: "Responder",
                help: "Responder a este email"
            ) {
                pedidoDeResposta += 1
            }
            .keyboardShortcut("r", modifiers: .command)

            ReaderChromeIcon(
                symbol: "arrowshape.turn.up.left.2.fill",
                label: "Responder a todos",
                help: podeTodos
                    ? "Responder ao remetente e a todos que estavam na mensagem"
                    : "Não há mais ninguém além do remetente para incluir",
                enabled: podeTodos
            ) {
                onCompose(.replyAll(messageID: message.id))
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            ReaderChromeIcon(
                symbol: "arrowshape.turn.up.right.fill",
                label: "Encaminhar",
                help: "Encaminhar este email"
            ) {
                onCompose(.forward(messageID: message.id))
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }

    /// Ação solta da barra: Apagar (só o ícone) e Editar rascunho.
    private func triageAction(
        _ label: String,
        symbol: String,
        help: String?,
        tone: TriageChipTone,
        showsLabel: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let danger = Self.apagarPalette(isDark: theme.isDark)
        let isDanger = tone == .danger
        let isPrimary = tone == .primary
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                if showsLabel {
                    Text(label)
                        .font(theme.sans.font(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(
                isDanger ? danger.ink.color
                    : (isPrimary ? theme.accentInk.color : theme.ink.color)
            )
            .padding(.horizontal, showsLabel ? 11 : 0)
            .frame(width: showsLabel ? nil : 28, height: 28)
            .fixedSize(horizontal: showsLabel, vertical: true)
            .background(
                isDanger ? danger.fill.color
                    : (isPrimary ? theme.accentSoft.color : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isDanger ? danger.line.color
                            : (isPrimary ? theme.accentLine.color : Color.clear),
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 7, tint: \.accent)
        .help(help ?? "")
        .accessibilityLabel(label)
    }

    /// Pasta com seta. Abre o painel nosso — o `Menu` do sistema estourava
    /// a tela com a lista de marcadores do Gmail.
    private func moveFolderButton(for message: Message) -> some View {
        let entries = Self.folderMenuEntries(for: message, store: store)
        return Button {
            folderPickerOpen.toggle()
        } label: {
            MoveToFolderGlyph()
                .foregroundStyle(folderPickerOpen ? theme.accentInk.color : theme.ink2.color)
                .frame(width: 28, height: 28)
                .background(folderPickerOpen ? theme.accentSoft.color : theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            folderPickerOpen ? theme.accent.color : theme.btnLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Mover para pasta ou marcador")
        .accessibilityLabel("Mover para pasta ou marcador")
        .popover(isPresented: $folderPickerOpen, arrowEdge: .bottom) {
            MoveFolderPanel(
                groups: MoveFolderPanel.groups(from: entries),
                onPick: { command in
                    runFolderCommand(command)
                    folderPickerOpen = false
                }
            )
        }
        .onChange(of: message.id) { _, _ in folderPickerOpen = false }
    }

    private func runFolderCommand(_ command: ContextCommand) {
        if receipts.intercept(command, on: store, stamp: ActionReceipts.stamp) { return }
        StoreCommand.run(command, on: store)
    }

    /// A lista que o menu da barra oferece — a mesma regra do menu de contexto.
    static func folderMenuEntries(for message: Message, store: MailStore) -> [ContextMenuEntry] {
        ContextMenus.folderSubmenus(
            message,
            provider: store.account(message.accountID)?.provider,
            folders: store.folders(of: message.accountID),
            selectedFolderID: store.selectedFolderID,
            currentBucket: store.bucket
        )
    }

    @ViewBuilder
    private func summaryCard(_ summary: String, event: DetectedEvent?, message: Message) -> some View {
        let aberto = resumoEstaAberto(message)
        let miolo = summaryCardBody(summary, event: event, message: message, aberto: aberto)
        if aberto {
            miolo
                .onTapGesture { toggleResumo(message, aberto: true) }
                .accessibilityAction(named: Text(Self.recolherResumo)) {
                    toggleResumo(message, aberto: true)
                }
        } else {
            Button {
                toggleResumo(message, aberto: false)
            } label: {
                miolo
            }
            .buttonStyle(.plain)
            .help("Mostra o resumo gerado neste Mac")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("TL;DR. \(summary)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Self.mostrarResumo)
        }
    }

    private func summaryCardBody(
        _ summary: String, event: DetectedEvent?, message: Message, aberto: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: aberto ? 8 : 0) {
            if aberto {
                summaryCardAberto(summary, event: event, message: message)
            } else {
                summaryCardRecolhido(summary)
            }
        }
        .padding(.vertical, aberto ? 15 : 8)
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.infoSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.infoLine.color, lineWidth: Hairline.thickness(displayScale))
        }
        .contentShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
    }

    private func resumoEstaAberto(_ message: Message) -> Bool {
        if debugResumoAberto { return true }
        return resumoAbertoPorID[message.id] ?? Self.resumoComecaAberto
    }

    private func summaryCardAberto(
        _ summary: String, event: DetectedEvent?, message: Message
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("TL;DR · neste Mac").capsLabel()
                Spacer(minLength: 0)
                if intelligencePresentation.usesConfiguredProvider,
                   onAskAssistant != nil {
                    Button("Usar IA configurada") {
                        setEmailAssistantOpen(true)
                        onOpenAssistant()
                    }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.info.color)
                    .help("Abre o painel para resumir com o provedor e o modelo escolhidos em Configurações.")
                }
                resumoChevron(aberto: true)
            }
            .contentShape(Rectangle())
            .help("Recolhe o resumo para ler o email")
            Text(summary)
                .font(theme.serif.font(size: 15))
                .lineSpacing(8.25)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let event, Self.convite(de: message) == nil {
                // Com `text/calendar` o cartão do convite já diz o compromisso.
                // "Compromisso detectado" em cima dele era a mesma reunião
                // duas vezes, e empurrava o email para fora da tela.
                Rectangle()
                    .fill(theme.infoLine.color)
                    .frame(height: Hairline.thickness(displayScale))
                    .padding(.top, 6)
                    .padding(.bottom, 5)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.eventLabelFormatted(event.label, ink2: theme.ink2.color, ink: theme.ink.color))
                            .font(theme.sans.font(size: 12.5))
                            .textSelection(.enabled)
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
    }

    private func summaryCardRecolhido(_ summary: String) -> some View {
        HStack(spacing: 8) {
            Text("TL;DR · neste Mac").capsLabel()
            Text(summary)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            resumoChevron(aberto: false)
        }
    }

    private func toggleResumo(_ message: Message, aberto: Bool) {
        resumoAbertoPorID[message.id] = !aberto
    }

    private func resumoChevron(aberto: Bool) -> some View {
        Image(systemName: aberto ? "chevron.up" : "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.ink3.color)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
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
    nonisolated static let conviteCanceladoFora = "Este compromisso não está na sua agenda."
    nonisolated static let conviteCanceladoNaAgenda = "Na agenda como cancelado."
    nonisolated static let conviteNaAgenda = "Na agenda"
    nonisolated static let removerDaAgenda = "Remover da agenda"
    nonisolated static let recolherConvite = "Recolher"
    nonisolated static let mostrarConvite = "Detalhes"
    nonisolated static let recolherResumo = "Recolher resumo"
    nonisolated static let mostrarResumo = "Mostrar resumo"
    /// O TL;DR nasce recolhido: uma linha, e quem quiser o texto expande.
    nonisolated static let resumoComecaAberto = false

    /// Aberto enquanto não respondeu; recolhido depois de Aceitar/Talvez/
    /// Recusar, para o email caber na tela. Cancelado fica aberto.
    nonisolated static func conviteComecaAberto(responded: Bool, cancelled: Bool) -> Bool {
        cancelled || !responded
    }

    /// Quem está no convite, numa linha só.
    ///
    /// O organizador primeiro e sem repetir: ele quase sempre também está na
    /// lista de participantes, e o cartão mostraria o nome dele duas vezes
    /// seguidas.
    nonisolated static func participantes(_ convite: CalendarInvite) -> String? {
        let nomes = listaDeParticipantes(convite)
        return nomes.isEmpty ? nil : nomes.joined(separator: ", ")
    }

    nonisolated static func listaDeParticipantes(_ convite: CalendarInvite) -> [String] {
        var nomes: [String] = []
        if let quem = convite.organizer { nomes.append(quem) }
        for quem in convite.attendees where !nomes.contains(quem) { nomes.append(quem) }
        return nomes
    }

    /// A lista inteira empurrava o email para fora. Três nomes e o resto
    /// vira "e mais N".
    nonisolated static func participantesResumo(_ convite: CalendarInvite, limite: Int = 3) -> String? {
        let nomes = listaDeParticipantes(convite)
        guard !nomes.isEmpty else { return nil }
        if nomes.count <= limite { return nomes.joined(separator: ", ") }
        let visiveis = nomes.prefix(limite).joined(separator: ", ")
        return "\(visiveis) e mais \(nomes.count - limite)"
    }

    /// O cartão do convite, no idioma do cartão de resumo — mesma superfície,
    /// mesma linha, mesmo raio. Depois da resposta ele **recolhe**: uma linha
    /// com o estado e as duas decisões que ainda restam. Recolher à mão
    /// também vale, para ler o email antes de decidir.
    private func inviteCard(_ convite: CalendarInvite, message: Message) -> some View {
        let selected = store.inviteRSVPState(for: convite, from: message)
        let aberto = conviteEstaAberto(
            message, responded: selected != nil, cancelled: convite.isCancelled
        )

        return VStack(alignment: .leading, spacing: aberto ? 8 : 0) {
            if aberto {
                inviteCardAberto(convite, message: message, selected: selected)
            } else {
                inviteCardRecolhido(convite, message: message, selected: selected)
            }
        }
        .padding(.vertical, aberto ? 15 : 8)
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.infoSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.infoLine.color, lineWidth: Hairline.thickness(displayScale))
        }
        .task(id: message.id) {
            store.syncInviteWithAgenda(convite, from: message)
        }
    }

    private func conviteEstaAberto(
        _ message: Message, responded: Bool, cancelled: Bool
    ) -> Bool {
        conviteAbertoPorID[message.id] ?? Self.conviteComecaAberto(
            responded: responded, cancelled: cancelled
        )
    }

    private func inviteCardAberto(
        _ convite: CalendarInvite, message: Message, selected: InviteRSVPResponse?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(convite.isCancelled ? Self.conviteCancelado : Self.conviteTitulo).capsLabel()
                Spacer(minLength: 8)
                if !convite.isCancelled {
                    conviteToggle(message, aberto: true)
                }
            }

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
            if let quem = Self.participantesResumo(convite) {
                linhaDoCartao(quem)
            }

            if convite.isCancelled {
                linhaDoCartao("Este convite foi cancelado pelo organizador.")
                if store.cancelledAgendaItem(for: convite, from: message)?.isCancelled == true {
                    linhaDoCartao(Self.conviteCanceladoNaAgenda)
                } else if store.cancelledAgendaItem(for: convite, from: message) == nil {
                    linhaDoCartao(Self.conviteCanceladoFora)
                }
            } else {
                inviteRSVPControls(convite, for: message, selected: selected)
            }

            if let agendaReceipt, agendaReceipt.messageID == message.id {
                inviteAgendaRow { agendaConfirmation(agendaReceipt) }
            } else if convite.detectedEvent != nil, !convite.isCancelled {
                inviteAgendaRow { inviteAgendaButton(convite, for: message) }
            }
        }
    }

    private func inviteCardRecolhido(
        _ convite: CalendarInvite, message: Message, selected: InviteRSVPResponse?
    ) -> some View {
        let titulo = convite.summary.isEmpty ? "Compromisso" : convite.summary
        let naAgenda = store.agendaState(for: convite, from: message) != .ausente
        return HStack(spacing: 8) {
            if let selected {
                Text(selected.label)
                    .font(theme.sans.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(rsvpFill(selected))
            }
            Text(titulo)
                .font(theme.sans.font(size: 12.5, weight: .medium))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
            if naAgenda {
                Text(Self.conviteNaAgenda)
                    .font(theme.sans.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if !convite.isCancelled, selected == nil {
                ForEach(InviteRSVPResponse.allCases, id: \.self) { response in
                    inviteRSVPButton(
                        response, convite: convite, message: message,
                        selected: selected,
                        unavailable: store.inviteRSVPUnavailableReason(for: convite, from: message)
                    )
                }
            }
            conviteToggle(message, aberto: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            [selected?.label, titulo, naAgenda ? Self.conviteNaAgenda : nil]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
    }

    private func conviteToggle(_ message: Message, aberto: Bool) -> some View {
        Button {
            conviteAbertoPorID[message.id] = !aberto
        } label: {
            Image(systemName: aberto ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(aberto ? "Recolhe o convite para ler o email" : "Mostra os detalhes do convite")
        .accessibilityLabel(aberto ? Self.recolherConvite : Self.mostrarConvite)
    }

    private func inviteAgendaRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.infoLine.color)
                .frame(height: Hairline.thickness(displayScale))
                .padding(.top, 6)
                .padding(.bottom, 5)
            HStack(spacing: 12) {
                Spacer(minLength: 8)
                content()
            }
        }
    }

    private func linhaDoCartao(_ texto: String) -> some View {
        Text(texto)
            .font(theme.sans.font(size: 12.5))
            .foregroundStyle(theme.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// As três decisões iTIP vivem no próprio cartão do convite. Depois de
    /// responder, o botão escolhido vira o rótulo e só as outras duas
    /// continuam — Aceitar sobe Recusar, Talvez deixa Aceitar e Recusar.
    private func inviteRSVPControls(
        _ convite: CalendarInvite, for message: Message, selected: InviteRSVPResponse?
    ) -> some View {
        let unavailable = store.inviteRSVPUnavailableReason(for: convite, from: message)
        let respostas = selected?.otherResponses ?? Array(InviteRSVPResponse.allCases)

        return VStack(alignment: .leading, spacing: 7) {
            Text(selected.map { "Resposta na fila: \($0.label)" } ?? "Responder ao convite")
                .font(theme.sans.font(size: 11.5, weight: .semibold))
                .foregroundStyle(selected == nil ? theme.ink2.color : theme.accentInk.color)

            HStack(spacing: 6) {
                ForEach(respostas, id: \.self) { response in
                    inviteRSVPButton(
                        response, convite: convite, message: message,
                        selected: selected, unavailable: unavailable
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if let unavailable {
                Text(unavailable.message)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func inviteRSVPButton(
        _ response: InviteRSVPResponse,
        convite: CalendarInvite,
        message: Message,
        selected: InviteRSVPResponse?,
        unavailable: InviteRSVPUnavailableReason?
    ) -> some View {
        let isSelected = selected == response
        let disabled = isSelected || unavailable != nil
        let help: String
        if isSelected {
            help = "\(response.label) — esta resposta já está na fila de saída"
        } else if let unavailable {
            help = unavailable.message
        } else {
            help = "\(response.actionLabel) e enviar ao organizador pela fila de saída"
        }

        let fill = rsvpFill(response)
        let ink = rsvpInk(response)
        return Button {
            aplicarRSVP(response, convite: convite, message: message)
        } label: {
            Text(response.actionLabel)
                .font(theme.sans.font(size: 11.5, weight: .semibold))
                .foregroundStyle(isSelected ? theme.ink4.color : ink)
                .frame(height: 26)
                .padding(.horizontal, 10)
                .background(isSelected ? theme.surface3.color : fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected ? theme.line.color : fill,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !isSelected ? 0.45 : 1)
        .focusRing(cornerRadius: 8, tint: rsvpFocus(response))
        .help(help)
    }

    /// Recolhe o cartão só quando a resposta entrou na fila. Um clique que
    /// não enviou nada deixava o convite fechado e os botões iguais — parecia
    /// que o RSVP tinha morrido.
    private func aplicarRSVP(
        _ response: InviteRSVPResponse,
        convite: CalendarInvite?,
        message: Message
    ) {
        guard let convite else { return }
        switch store.respondToInvite(convite, from: message, response: response) {
        case .queued, .alreadyQueued:
            conviteAbertoPorID[message.id] = false
        case .unavailable, .failed:
            conviteAbertoPorID[message.id] = true
        }
    }

    private func rsvpFill(_ response: InviteRSVPResponse) -> Color {
        switch response {
        case .accepted: theme.enter.color
        case .tentative: theme.accent.color
        case .declined: theme.remove.color
        }
    }

    private func rsvpInk(_ response: InviteRSVPResponse) -> Color {
        switch response {
        case .accepted: theme.onEnter.color
        case .tentative: theme.onAccent.color
        case .declined: theme.onRemove.color
        }
    }

    private func rsvpFocus(_ response: InviteRSVPResponse) -> KeyPath<Theme, TokenColor> {
        switch response {
        case .accepted: \.onEnter
        case .tentative: \.onAccent
        case .declined: \.onRemove
        }
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
        guard let event = message.detectedEvent else {
            let id = DetectedEventConversion.agendaID(forMessageID: message.id)
            return store.agenda.contains { $0.id == id }
        }
        return store.existingAgendaItem(for: event, from: message) != nil
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

    private func inviteCancelButton(_ convite: CalendarInvite, for message: Message) -> some View {
        ChromeButton(
            Self.removerDaAgenda,
            appearance: .remove,
            size: 11.5,
            height: 26,
            horizontalPadding: 12
        ) {
            removeCancelledInvite(convite, for: message)
        }
        .help("Tira da agenda o compromisso que este cancelamento anuncia")
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
                .foregroundStyle(onAgenda ? theme.ink4.color : theme.onEnter.color)
                .frame(height: 26)
                .padding(.horizontal, 12)
                .background(onAgenda ? theme.surface3.color : theme.enter.color)
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
        .focusRing(cornerRadius: 8, tint: \.onEnter)
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
                .foregroundStyle(theme.info.color)
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

    private func removeCancelledInvite(_ convite: CalendarInvite, for message: Message) {
        guard let item = store.removeCancelledInvite(convite, from: message) else { return }
        let stamp = Date.now.formatted(date: .omitted, time: .shortened)
        withAnimation(SwipeMotion.transition) {
            agendaReceipt = AgendaAddReceipt(
                messageID: message.id,
                itemID: item.id,
                note: AgendaAddReceipt.removedNote(eventLabel: item.title, stamp: stamp)
            )
        }
    }

    private func undoAddEvent(_ receipt: AgendaAddReceipt) {
        if store.agenda.contains(where: { $0.id == receipt.itemID }) {
            store.removeFromAgenda(receipt.itemID)
        } else {
            store.restoreToAgenda(receipt.itemID)
        }
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
                aoRevogar: { store.revokeSenderTrust(message.from.address) },
                aoRSVP: { aplicarRSVP($0, convite: Self.convite(de: message), message: message) }
            )
            .id(message.id)
        } else if !message.body.isEmpty {
            ReaderPlainText(paragrafos: Self.paragrafos(de: message))
        } else {
            switch store.bodyLoad(for: message.id) {
            case .carregando:
                ReaderSpinnerNote(Self.carregandoCorpo)
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

    /// O espaço em que o sparkle reporta o canto dele para o painel da IA
    /// nascer **fora** do cabeçalho — senão a hairline de baixo corta o modal.
    nonisolated static let assistantAnchorSpace = "reader-assistant-anchor"

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

/// A intenção visual da pastilha de triagem. O tipo separado impede que a
/// ação perigosa receba por acidente os mesmos tokens neutros da triagem.
private enum TriageChipTone {
    case normal
    case danger
    case primary
}

/// O canto superior direito do sparkle, no espaço da coluna do leitor.
///
/// O painel da IA não pode nascer overlay do cabeçalho: a hairline de baixo
/// do cabeçalho é overlay **posterior** e corta o modal ao meio. O sparkle
/// só reporta onde está; quem desenha o painel é a coluna inteira.
private struct ReaderAssistantAnchorKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Ícone 28×28 da barra do leitor: quieto, acende no hover.
private struct ReaderChromeIcon: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var hovering = false

    let symbol: String
    let label: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        let aceso = hovering && enabled
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    enabled
                        ? (aceso ? theme.accentInk.color : theme.ink2.color)
                        : theme.ink4.color
                )
                .frame(width: 28, height: 28)
                .background(aceso ? theme.accentSoft.color : theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            aceso ? theme.accent.color : theme.btnLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
    }
}

/// Pasta com seta para dentro — o "Mover para" da barra, no desenho que o
/// dono mandou: um folder e a seta caindo nele.
private struct MoveToFolderGlyph: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .semibold))
                .offset(x: -1, y: -1)
            Image(systemName: "arrow.down.left")
                .font(.system(size: 6.5, weight: .bold))
                .offset(x: 4, y: 3)
        }
        .frame(width: 16, height: 14)
        .accessibilityHidden(true)
    }
}

/// Tokens da ação destrutiva do leitor. Não entram em `Theme`: são semântica
/// local de uma ação, enquanto o tema continua responsável pela identidade da
/// conta e pelos controles normais.
struct ReaderDangerPalette: Sendable, Hashable {
    let ink: TokenColor
    let fill: TokenColor
    let line: TokenColor
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
                    .foregroundStyle(theme.ink2.color)
                    .frame(maxWidth: ReaderPane.readingWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 28)
    }
}
