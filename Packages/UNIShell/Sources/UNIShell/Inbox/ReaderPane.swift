import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// Onde o leitor está desenhado — e o que muda por causa disso.
///
/// O leitor nasceu para a Caixa, e por isso lia a mensagem da **seleção** do
/// store e nunca precisava avisar ninguém quando arquivar tirava a conversa da
/// lista: quem sobrevive à ação é a lista, que fica logo ao lado. A folha do
/// dashboard tem as duas necessidades invertidas — mostra uma mensagem que não
/// é a seleção da Caixa, e precisa fechar quando essa mensagem sai das
/// prioridades. As duas diferenças cabem em dois campos; uma segunda cópia do
/// leitor não caberia em manutenção nenhuma.
struct ReaderPresentation {
    /// A mensagem a mostrar, quando não é a seleção da Caixa.
    var messageID: String?
    /// A mensagem aberta saiu da lista (arquivada, apagada, movida). A Caixa
    /// não faz nada; a folha se fecha.
    var onMessageLeft: (() -> Void)?

    /// O painel de sempre, dentro da Caixa.
    ///
    /// Calculado, e não `static let`: o tipo guarda um fechamento e não é
    /// `Sendable`, e um global armazenado de tipo não-`Sendable` é erro sob
    /// concorrência estrita.
    static var pane: ReaderPresentation { ReaderPresentation() }

    /// A folha do dashboard: mensagem própria, e fechamento ao sair da lista.
    static func sheet(
        messageID: String,
        onMessageLeft: @escaping () -> Void
    ) -> ReaderPresentation {
        ReaderPresentation(messageID: messageID, onMessageLeft: onMessageLeft)
    }
}

public struct ReaderPane: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let store: MailStore
    /// Painel da Caixa ou folha do dashboard — ver `ReaderPresentation`.
    let presentation: ReaderPresentation
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
    /// De onde o resumo **desta** mensagem veio, pela versão do motor
    /// gravada com ele. A legenda do TL;DR sai daqui — o cartão é feito pela
    /// fila, não pelo assistente interativo — e não pode seguir a rota atual:
    /// o histórico anterior ao opt-in continua tendo sido resumido neste Mac.
    let analysisDestination: @Sendable (String?) -> AssistantDestination
    let onOpenAssistant: () -> Void
    /// Fábrica da conversa do popover, injetada pelo shell: é ele que
    /// conhece o provedor configurado e o motor. Nula = sem assistente.
    let makeAssistantConversation: ((String) -> AssistantConversation)?
    /// A mensagem visível deve saltar a fila de resumos históricos. O app
    /// injeta a coordenação real; previews e testes podem deixar a porta vazia.
    let onMessagePresented: (String) -> Void
    /// Informa ao shell quando o popover transborda o leitor. O layout de
    /// três colunas precisa elevar o painel inteiro e suspender as calhas de
    /// redimensionamento enquanto essa superfície estiver aberta.
    let onEmailAssistantOpenChange: (Bool) -> Void
    /// "Próximo: <compromisso> em N min", pronto, ou `nil` quando não há nada
    /// mais hoje. Ver `AgendaSummary.nextEventCapsule`: é o que substitui a
    /// quarta coluna da Caixa no shell Vidro.
    let nextEvent: String?
    /// Porta exclusiva do harness offscreen: mantém o painel contextual aberto
    /// sem automatizar a interface da sessão.
    let debugEmailAssistantOpen: Bool
    /// Força o TL;DR aberto — o harness que prova o cartão de compromisso.
    let debugResumoAberto: Bool
    /// Trata o rascunho guardado como se a IA o tivesse escrito. Porta
    /// exclusiva do harness: a barra de resposta com o rascunho da IA é um
    /// desenho a conferir, e sintetizar uma ida ao provedor fora da tela não
    /// é verificação de aparência.
    var debugIADraft = false
    /// Os passos que o motor já deu nesta ida — a lista de ✓ e o brilho do
    /// passo atual. Vem da `AssistantSession`, que é quem ouve o `onActivity`.
    var assistantSteps: [String] = []
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
    /// O tom do rascunho da IA que está na barra de resposta.
    @State private var inkTone: AssistantDraftTone = .direto
    /// O seletor de tom, aberto pela barra **ou** pelo menu do ✦ IA.
    @State private var tonePickerOpen = false
    /// De qual mensagem é o rascunho que a IA escreveu nesta sessão. `nil`
    /// quando o que está guardado foi escrito à mão: a barra só se diz "da
    /// IA" quando foi a IA que a escreveu.
    @State private var iaDraftMessageID: String?
    /// A conversa do popover: nasce ao abrir, é cancelada ao fechar. Uma só
    /// máquina de estado, a mesma do painel e do dashboard.
    @State private var readerConversation: AssistantConversation?

    /// O mesmo retorno com "Desfazer" que a lista desenha. O leitor **posta**
    /// nele e não o desenha: apagar daqui tira a mensagem do leitor, e uma
    /// faixa presa a ele iria embora junto com o que precisava desfazer. Quem
    /// sobrevive à ação é a lista — ver `ActionReceipts`.
    /// A faixa de erro do popover precisa poder abrir Configurações — é a
    /// mesma porta do menu do app.
    @Environment(\.openWindow) private var openWindow
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
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        onOpenAssistant: @escaping () -> Void = {},
        makeAssistantConversation: ((String) -> AssistantConversation)? = nil,
        onMessagePresented: @escaping (String) -> Void = { _ in },
        onEmailAssistantOpenChange: @escaping (Bool) -> Void = { _ in },
        nextEvent: String? = nil
    ) {
        self.init(
            store: store,
            debugEmailAssistantOpen: false,
            debugResumoAberto: false,
            presentation: .pane,
            onCompose: onCompose,
            attachmentSaver: attachmentSaver,
            intelligence: intelligence,
            intelligencePresentation: intelligencePresentation,
            analysisDestination: analysisDestination,
            onOpenAssistant: onOpenAssistant,
            makeAssistantConversation: makeAssistantConversation,
            onMessagePresented: onMessagePresented,
            onEmailAssistantOpenChange: onEmailAssistantOpenChange,
            nextEvent: nextEvent
        )
    }

    init(
        store: MailStore,
        debugEmailAssistantOpen: Bool,
        debugResumoAberto: Bool = false,
        presentation: ReaderPresentation = .pane,
        onCompose: @escaping (ComposerRoute) -> Void = { _ in },
        attachmentSaver: (any AttachmentSaving)? = nil,
        intelligence: ComposerIntelligenceGenerator? = nil,
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        onOpenAssistant: @escaping () -> Void = {},
        makeAssistantConversation: ((String) -> AssistantConversation)? = nil,
        onMessagePresented: @escaping (String) -> Void = { _ in },
        onEmailAssistantOpenChange: @escaping (Bool) -> Void = { _ in },
        nextEvent: String? = nil
    ) {
        self.store = store
        self.nextEvent = nextEvent
        self.presentation = presentation
        self.onCompose = onCompose
        self.attachmentSaver = attachmentSaver
        self.intelligence = intelligence
        self.intelligencePresentation = intelligencePresentation
        self.analysisDestination = analysisDestination
        self.onOpenAssistant = onOpenAssistant
        self.makeAssistantConversation = makeAssistantConversation
        self.onMessagePresented = onMessagePresented
        self.onEmailAssistantOpenChange = onEmailAssistantOpenChange
        self.debugEmailAssistantOpen = debugEmailAssistantOpen
        self.debugResumoAberto = debugResumoAberto
        _emailAssistantOpen = State(initialValue: debugEmailAssistantOpen)
        // A porta do harness abre a superfície sem passar pela ação: a
        // conversa precisa existir já na primeira pintura.
        _readerConversation = State(
            initialValue: debugEmailAssistantOpen
                ? (presentation.messageID ?? store.selectedMessageID)
                    .flatMap { makeAssistantConversation?($0) }
                : nil
        )
    }

    /// Os passos do motor, ligados depois da construção.
    ///
    /// Modificador, e não parâmetro de `init`: as duas inicializações do
    /// leitor já têm catorze argumentos, e quem passa isto é uma linha só do
    /// `InboxScreen`.
    func assistantSteps(_ steps: [String]) -> Self {
        var copia = self
        copia.assistantSteps = steps
        return copia
    }

    /// A mensagem que o leitor mostra: a da folha, quando há folha; a seleção
    /// da Caixa no resto do tempo.
    private var mensagemVisivel: Message? {
        if let id = presentation.messageID { return store.message(id) }
        return store.selectedMessage
    }

    /// Arquivar, apagar ou mover tira a mensagem da lista de onde ela veio.
    /// Na Caixa não há o que fazer — a lista ao lado sobrevive e mostra o
    /// retorno com "Desfazer". Na folha do dashboard, a mensagem que a folha
    /// existia para mostrar deixou de estar lá: ela se fecha.
    private func mensagemSaiuDaLista() {
        presentation.onMessageLeft?()
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
            if showReader, let message = mensagemVisivel {
                content(message)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **O preenchimento é o do painel** (`readerFill`), e ele é um só, nos
        // 28 temas: pintar `surface` aqui poria uma segunda folha por baixo.
        // Era `isGlass`, de quando só o Vidro tinha painel; hoje
        // `resolvedPanel` dá um a todo tema (`glassPanel(_:kind:)`).
        // A pergunta antes de abrir link vale para o leitor inteiro: o HTML da
        // `WebView` e o texto desenhado passam os dois por aqui. Pendurada no
        // topo do painel para o cartão ter a largura dele, e não a da coluna.
        .linkConfirmation()
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
            // **Um cabeçalho só, nos 28 temas.** A linha fica sob a barra de
            // ferramentas, como no desenho: o cabeçalho e o corpo são o mesmo
            // papel, e um fio entre eles partiria o leitor em dois.
            //
            // Havia dois — este e uma barra de triagem com pastilhas, que só
            // os 26 opacos viam. O dono: os temas clássicos perdem o vidro e
            // mantêm o desenho. O que muda de tema para tema é material, não
            // estrutura.
            readerToolbar(message)
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
            readerHeader(message)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // A conversa, quando há mais de uma mensagem: as anteriores
                    // recolhidas, esta aberta. Com uma mensagem só, o desenho é
                    // exatamente o de antes desta tarefa — o `else` é o mesmo
                    // bloco que sempre esteve aqui.
                    if let conversa, conversa.count > 1 {
                        ConversationStackView(store: store, conversa: conversa, opened: $stackState) {
                            cardsAndBody($0, inStack: true)
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
            .avisaQueRola(L10n.tr("O email continua abaixo. Role para ver o resto."))

            // `.id` porque a faixa guarda o rascunho da mensagem que está
            // aberta: trocar de mensagem tem de trocar de rascunho, não herdar
            // o texto da anterior. O que já foi escrito não se perde — fica no
            // `MailStore`, e volta quando a mensagem voltar.
            if message.bucket != .drafts {
                QuickReplyBand(
                    store: store, message: message,
                    onPromote: { onCompose(.reply(messageID: $0.id)) },
                    expandRequest: pedidoDeResposta,
                    intelligence: intelligence,
                    iaDraft: iaDraft(for: message)
                )
                .id("\(message.id)-\(quickReplyRevision)")
            }
        }
        // **Nenhum painel por cima do e-mail.** O ✦ IA abre um menu de ações
        // (ver `ReaderInkMenu`) e o resultado é escrito no próprio e-mail ou
        // vai para a barra de resposta — é a direção Tinta. O painel
        // flutuante que cobria o texto saiu daqui.
        //
        // O rascunho que a IA devolve é adotado pela barra de resposta assim
        // que chega: é lá que ele mora no desenho, e não num cartão à parte.
        .onChange(of: readerConversation?.messages.count ?? 0) { _, _ in
            guard let ultima = readerConversation?.messages.last,
                  ultima.speaker == .assistant, ultima.kind == .draft else { return }
            adoptIADraft(ultima.text, for: message)
        }
        // Abrir uma mensagem sem corpo **é** o pedido de busca. `id:` para que
        // trocar de mensagem cancele a busca da anterior e comece a desta: sem
        // isso, abrir cinco mensagens em sequência deixaria cinco conexões em
        // voo para escrever num leitor que já mostra outra coisa.
        //
        // Sem porta de corpo (fixtures, e todo teste que não passa uma) isto
        // não faz nada — `loadBodyIfNeeded` sai na primeira guarda.
        .task(id: message.id) {
            setEmailAssistantOpen(debugEmailAssistantOpen, for: message.id)
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
    private func cardsAndBody(_ message: Message, inStack: Bool = false) -> some View {
        // A ordem é a do desenho `IA-Tinta`: a tinta da IA logo abaixo do
        // assunto, depois o remetente, depois o e-mail. Quem abre a mensagem
        // decide se vai ler o resto **depois** de saber o que ela pede dele —
        // e por isso a tinta vem antes do avatar, não depois.
        if temTinta(message) {
            inkSection(message)
                .padding(.horizontal, 28)
                .padding(.top, TintaMetrics.flowGap)
        }

        // O remetente saiu do cabeçalho fixo e entrou no fluxo, que é onde o
        // desenho o põe. Dentro de uma pilha de conversa a linha de cada
        // mensagem já é o remetente dela, e repeti-la seria o nome duas vezes
        // seguidas.
        if !inStack {
            identityRow(message)
                .padding(.horizontal, 28)
                .padding(.top, TintaMetrics.flowGap)
        }

        if let convite = Self.convite(de: message) {
            inviteCard(convite, message: message)
                .padding(.horizontal, 28)
                .padding(.top, TintaMetrics.flowGap)
                .padding(.bottom, 16)
        }

        body(message)
            .padding(.top, TintaMetrics.flowGap)
            .padding(.bottom, 28)
    }

    /// Há tinta para escrever nesta mensagem? Resumo guardado, resposta ao
    /// vivo, tarefa com lastro ou um pedido em voo. Sem nada disso o leitor
    /// não escreve versalete nenhum — um "RESUMO E TAREFAS" sobre o vazio é
    /// pior do que silêncio.
    private func temTinta(_ message: Message) -> Bool {
        guard resumoEstaAberto(message) else { return false }
        if readerConversation?.isLoading == true { return true }
        if inkProse(message) != nil { return true }
        return !inkTasks(message).isEmpty
    }

    /// A prosa da IA: a última resposta ao vivo desta sessão, ou o resumo que
    /// a fila já gravou na mensagem.
    private func inkProse(_ message: Message) -> String? {
        if let ultima = readerConversation?.messages.last(
            where: { $0.speaker == .assistant && $0.kind == .message }
        ) {
            return ultima.text
        }
        return message.summary
    }

    /// As tarefas que a IA escreve em linha.
    ///
    /// **Duas fontes, as duas com lastro**: o pedido que a análise já
    /// persistida afirmou (com prazo e evidência) e o compromisso detectado na
    /// mensagem. Nada é lido do texto na hora de desenhar.
    private func inkTasks(_ message: Message) -> [ReaderInkTask] {
        var tarefas: [ReaderInkTask] = []
        if let pedido = PedidoDoEmail.de(triagem: message.triage, agora: Date()) {
            tarefas.append(ReaderInkTask(
                id: "pedido",
                text: pedido.chamada,
                deadline: pedido.prazo,
                urgent: pedido.urgente,
                action: podeRascunhar ? L10n.tr("Rascunhar") : nil,
                run: podeRascunhar ? { pedirRascunho(for: message, tone: .direto) } : nil
            ))
        }
        // Com `text/calendar` o cartão do convite já diz o compromisso: a
        // tarefa seria a mesma reunião duas vezes.
        if let evento = message.detectedEvent, Self.convite(de: message) == nil,
           !isOnAgenda(message) {
            tarefas.append(ReaderInkTask(
                id: "evento",
                text: evento.label,
                action: L10n.tr("Criar evento"),
                run: { addEvent(evento, for: message) }
            ))
        }
        return tarefas
    }

    /// A tinta inteira — ver `ReaderInkSection`.
    private func inkSection(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: TintaMetrics.blockGap) {
            ReaderInkSection(
                prose: inkProse(message),
                provenance: Self.inkProvenance(
                    for: analysisDestination(message.summaryModelVersion)
                ),
                tasks: inkTasks(message),
                isWorking: readerConversation?.isLoading == true,
                steps: assistantSteps,
                onHide: { toggleResumo(message, aberto: true) }
            )
            if let falha = readerConversation?.failure {
                AssistantFailureBand(
                    failure: falha,
                    onRetry: { readerConversation?.retry() },
                    onOpenSettings: { openWindow(id: UNIWindow.accounts) }
                )
            }
            if let receipt = agendaReceipt, receipt.messageID == message.id {
                agendaConfirmation(receipt)
            }
        }
    }

    /// "neste Mac", "Codex · ChatGPT" — a procedência que a nota da tinta
    /// escreve. A mesma condição da legenda antiga do TL;DR.
    static func inkProvenance(for destination: AssistantDestination) -> String {
        destination.isLocal ? L10n.tr("neste Mac") : destination.label
    }

    private func save(_ attachment: MailAttachment, from message: Message) {
        guard let attachmentSaver else {
            attachmentError = L10n.tr("Salvar anexo indisponível nesta janela.")
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
                attachmentError = L10n.tr("Não foi possível baixar ou salvar o anexo.")
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

    /// A cápsula do próximo compromisso, no alto do leitor.
    private func nextEventCapsule(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(theme.sans.font(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(theme.accentInk.color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(theme.accentSoft.color)
        .clipShape(Capsule())
        .accessibilityIdentifier("reader-next-event")
        .accessibilityLabel(label)
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

    /// "Marina Duarte · Revisão do contrato"
    nonisolated static func identityCaption(name: String, subject: String) -> String {
        let quem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let oQue = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if quem.isEmpty { return oQue }
        if oQue.isEmpty { return quem }
        return "\(quem) · \(oQue)"
    }

    nonisolated static var expandirCabecalho: String { L10n.tr("Mostra o email do remetente e o assunto completo") }
    nonisolated static var recolherCabecalho: String { L10n.tr("Recolhe remetente e assunto") }

    /// "Para Ana, Bruno · Cc Carla"
    nonisolated static func destinatarios(_ message: Message) -> String? {
        func nomes(_ lista: [Contact]) -> String {
            lista.map { $0.name.isEmpty ? $0.address : $0.name }.joined(separator: ", ")
        }
        let para = nomes(message.to)
        let cc = nomes(message.cc)
        switch (para.isEmpty, cc.isEmpty) {
        case (true, true): return nil
        case (false, true): return L10n.tr("Para \(para)")
        case (true, false): return L10n.tr("Cc \(cc)")
        case (false, false): return L10n.tr("Para \(para) · Cc \(cc)")
        }
    }

    private func attachmentChips(_ message: Message) -> some View {
        ScrollView(.horizontal) {
          HStack(spacing: 5) {
            ForEach(message.attachments) { attachment in
                Button {
                    save(attachment, from: message)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9, weight: .semibold))
                        Text(attachment.filename)
                            .lineLimit(1)
                            .frame(maxWidth: 240)
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
                    ? L10n.tr("Baixando \(attachment.filename)…")
                    : L10n.tr("Baixar \(attachment.filename) (\(attachment.mimeType), \(attachment.sizeLabel))"))
            }
          }
          .padding(.bottom, 8)
        }
        .frame(height: 38)
    }

    private func accountTint(_ message: Message) -> Color {
        store.account(message.accountID)
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.accent.color
    }

    // MARK: - A barra e o cabeçalho do leitor

    /// A barra do protótipo: o botão de acento da IA na ponta esquerda, um
    /// fio, os ícones de ação, e as setas de anterior/próxima na direita.
    ///
    /// **O atalho não é ⌘E.** O protótipo escreve ⌘E ao lado do botão, mas ⌘E
    /// já é "Arquivar" no menu Mensagem — o atalho do Mail e do Gmail, que
    /// este app reivindicou de propósito no menu principal (ver
    /// `MessageCommands`). Dois donos para a mesma tecla significa que o menu
    /// principal ganha e o botão fica mudo. O que a IA deste e-mail ganha é
    /// ⌥⌘J, irmão do ⌘J que abre a gaveta do ambiente inteiro — e o botão
    /// escreve o atalho que de fato existe.
    private func readerToolbar(_ message: Message) -> some View {
        HStack(spacing: 2) {
            inkPill(message)

            Rectangle()
                .fill(theme.line.color)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 5)

            glassIcon("arrowshape.turn.up.left", L10n.tr("Responder"), L10n.tr("Responder a este email")) {
                pedidoDeResposta += 1
            }
            .keyboardShortcut("r", modifiers: .command)

            glassIcon("arrowshape.turn.up.right", L10n.tr("Encaminhar"), L10n.tr("Encaminhar este email")) {
                onCompose(.forward(messageID: message.id))
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            glassIcon("archivebox", L10n.tr("Arquivar"), L10n.tr("Tira da caixa e guarda")) {
                store.move(message, to: .archived)
                mensagemSaiuDaLista()
            }

            glassIcon("clock", L10n.tr("Depois"), L10n.tr("Adia esta mensagem para Depois")) {
                store.move(message, to: .later)
                mensagemSaiuDaLista()
            }

            glassFolderButton(for: message)

            glassIcon(
                SwipeAction.trash.symbol(for: message),
                Self.apagarLabel(message),
                ContextMenus.deleteItem(message).help ?? ""
            ) {
                _ = receipts.delete(message, on: store)
                mensagemSaiuDaLista()
            }

            // "Responder a todos" não ganha um sétimo ícone: ele continua no
            // menu de contexto da mensagem e no ⇧⌘R, que este botão invisível
            // é quem põe no `performKeyEquivalent` da janela.
            Button(L10n.tr("Responder a todos")) {
                onCompose(.replyAll(messageID: message.id))
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .hidden()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            Spacer(minLength: 8)

            glassIcon("chevron.up", L10n.tr("Mensagem anterior"), L10n.tr("Abre a conversa acima na lista")) {
                _ = store.selectAdjacentConversation(offset: -1)
            }
            glassIcon("chevron.down", L10n.tr("Próxima mensagem"), L10n.tr("Abre a conversa abaixo na lista")) {
                _ = store.selectAdjacentConversation(offset: 1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .zIndex(emailAssistantOpen ? 90 : 0)
    }

    /// Ícone quieto da barra de vidro: sem moldura e sem fundo, como no
    /// protótipo — o acento só aparece no hover.
    private func glassIcon(
        _ symbol: String, _ label: String, _ help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 9)
        .help(help)
        .accessibilityLabel(label)
    }

    /// O "Mover para pasta" da barra de vidro — o mesmo painel do botão
    /// clássico, sem a moldura dele.
    private func glassFolderButton(for message: Message) -> some View {
        let entries = Self.folderMenuEntries(for: message, store: store)
        return Button { folderPickerOpen.toggle() } label: {
            MoveToFolderGlyph()
                .foregroundStyle((folderPickerOpen ? theme.accentInk : theme.ink2).color)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 9)
        .help(L10n.tr("Mover para pasta ou marcador"))
        .accessibilityLabel(L10n.tr("Mover para pasta ou marcador"))
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

    /// **"✦ IA ⌥⌘J" — a porta de entrada, a mesma nos 28 temas.**
    ///
    /// Era duas: esta pastilha no cabeçalho de vidro e um ícone redondo na
    /// barra de triagem dos 26 opacos. O desenho aprovado (`IA-Tinta`) tem uma
    /// pastilha, e o que muda de tema para tema é o que sempre muda — a cor do
    /// acento e a superfície. Aceso em acento cheio enquanto o menu está
    /// aberto; apagado e desabilitado sem provedor, com o motivo no `help`.
    private func inkPill(_ message: Message) -> some View {
        let aberto = emailAssistantOpen
        let disponivel = intelligencePresentation.isAvailable
        return Button {
            setEmailAssistantOpen(!emailAssistantOpen, for: message.id)
            onOpenAssistant()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Text(L10n.tr("IA"))
                    .font(theme.sans.font(size: 12.5, weight: .semibold))
                Text("⌥⌘J")
                    .font(theme.mono.font(size: 10))
                    .opacity(0.75)
            }
            .foregroundStyle(
                (!disponivel ? theme.ink4 : (aberto ? theme.onAccent : theme.accentInk)).color
            )
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                (!disponivel ? theme.surface3 : (aberto ? theme.accent : theme.accentSoft)).color
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 10)
        .disabled(!disponivel)
        .keyboardShortcut("j", modifiers: [.command, .option])
        .help(
            intelligencePresentation.isAvailable
                ? L10n.tr("IA neste e-mail (⌥⌘J)")
                : intelligencePresentation.detail
        )
        .accessibilityLabel(L10n.tr("IA neste e-mail"))
        .accessibilityValue(aberto ? L10n.tr("Aberto") : L10n.tr("Fechado"))
        .popover(isPresented: inkMenuBinding(for: message), arrowEdge: .bottom) {
            inkMenu(for: message)
        }
    }

    /// O menu do ✦ IA, com cada entrada ligada ao que o app de fato sabe
    /// fazer. Entrada sem ação é entrada desabilitada, com o motivo no `help`
    /// — nunca um botão mudo.
    private func inkMenu(for message: Message) -> some View {
        ReaderInkMenu(
            isEnabled: { entrada in
                switch entrada {
                case .rascunhar: return podeRascunhar
                case .tom: return podeRascunhar && iaDraftMessageID == message.id
                case .evento: return message.detectedEvent != nil && !isOnAgenda(message)
                default: return podeRascunhar
                }
            },
            run: { entrada in
                setEmailAssistantOpen(false)
                switch entrada {
                case .rascunhar:
                    pedirRascunho(for: message, tone: .direto)
                case .tom:
                    tonePickerOpen = true
                case .evento:
                    if let evento = message.detectedEvent { addEvent(evento, for: message) }
                default:
                    if let pergunta = entrada.question { perguntar(pergunta, for: message) }
                }
            }
        )
    }

    private func inkMenuBinding(for message: Message) -> Binding<Bool> {
        Binding(
            get: { emailAssistantOpen },
            set: { setEmailAssistantOpen($0, for: message.id) }
        )
    }

    /// Há motor de IA ligado a este leitor?
    private var podeRascunhar: Bool {
        intelligencePresentation.isAvailable && makeAssistantConversation != nil
    }

    private func ensureConversation(for messageID: String) {
        if readerConversation == nil {
            readerConversation = makeAssistantConversation?(messageID)
        }
    }

    /// Uma pergunta do menu, pela mesma rota do campo do assistente. A
    /// resposta volta para **dentro do e-mail**.
    private func perguntar(_ question: String, for message: Message) {
        ensureConversation(for: message.id)
        resumoAbertoPorID[message.id] = true
        readerConversation?.ask(question)
    }

    private func pedirRascunho(for message: Message, tone: AssistantDraftTone) {
        ensureConversation(for: message.id)
        inkTone = tone
        readerConversation?.draftReply(tone: tone)
    }

    /// O rascunho da IA entra na barra de resposta, recolhida: é ali que ele
    /// morava antes de existir painel nenhum.
    private func adoptIADraft(_ text: String, for message: Message) {
        var draft = store.replyDraft(for: message.id)
            ?? ReplyDraft(to: [message.from], body: AttributedString())
        draft.body = AttributedString(text)
        draft.sentAt = nil
        store.setReplyDraft(draft, for: message.id)
        iaDraftMessageID = message.id
        // A faixa relê o rascunho guardado ao trocar de `id`.
        quickReplyRevision += 1
    }

    private func descartarIADraft(_ message: Message) {
        store.setReplyDraft(nil, for: message.id)
        iaDraftMessageID = nil
        quickReplyRevision += 1
    }

    /// O rascunho da IA desta mensagem, para a barra de resposta desenhá-lo.
    private func iaDraft(for message: Message) -> QuickReplyIADraft? {
        guard debugIADraft || iaDraftMessageID == message.id else { return nil }
        let texto = store.replyDraft(for: message.id)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !texto.isEmpty else { return nil }
        return QuickReplyIADraft(
            text: texto,
            tone: inkTone,
            tonePickerOpen: Binding(get: { tonePickerOpen }, set: { tonePickerOpen = $0 }),
            onTone: podeRascunhar ? { pedirRascunho(for: message, tone: $0) } : nil,
            onDiscard: { descartarIADraft(message) }
        )
    }

    /// O cabeçalho do protótipo: a linha fina da conta e da pasta, o assunto
    /// grande, e o remetente com avatar, endereço e hora.
    ///
    /// Sem a faixa opaca de `surface` que o cabeçalho clássico pinta: no Vidro
    /// o leitor é **um** preenchimento só, o do painel.
    private func readerHeader(_ message: Message) -> some View {
        let tint = accountTint(message)
        let count = store.conversation(of: message.id)?.count ?? 1
        return VStack(alignment: .leading, spacing: 14) {
            if let nextEvent {
                nextEventCapsule(nextEvent)
            }
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(Self.glassOrigin(
                    account: store.account(message.accountID)?.address ?? "",
                    folder: store.selectedFolderID.flatMap { id in
                        store.folders(of: message.accountID).first { $0.id == id }?.displayName
                    } ?? store.bucket.label
                ))
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
                .layoutPriority(-1)

                // **Os marcadores aplicados continuam visíveis.** Eles
                // moravam na fila de triagem, que saiu com o cabeçalho
                // antigo; aqui ficam na linha da procedência, que é a linha
                // de onde esta mensagem veio — e um marcador do Gmail é
                // exatamente isso.
                let marcadores = Self.appliedMarkers(for: message, in: store.folders)
                ForEach(Array(marcadores.prefix(1))) { marcador in
                    TintChip(
                        label: Self.markerChipLabel(marcador.displayName),
                        tint: theme.ink3.color
                    )
                    .help(L10n.tr("Marcador aplicado: \(marcador.displayName)"))
                }
                if marcadores.count > 1 {
                    TintChip(label: "+\(marcadores.count - 1)", tint: theme.ink3.color)
                        .help(marcadores.dropFirst().map(\.displayName).joined(separator: " · "))
                }

                Spacer(minLength: 8)
                Text(MessageList.messageCountLabel(count))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
            }

            Text(message.subject)
                .font(theme.serif.font(size: 24, weight: .bold))
                .tracking(-0.02 * 24)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if !message.attachments.isEmpty {
                attachmentChips(message)
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.danger.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .allowsHitTesting(!emailAssistantOpen)
    }

    /// O remetente como o desenho `IA-Tinta` o escreve: avatar de 36, nome em
    /// 14,5 semibold, "marina@cliente.com · para você" em 12,5, e a hora em
    /// mono de 12 na ponta direita.
    ///
    /// Mora no fluxo de leitura, abaixo da tinta da IA — ver `cardsAndBody`.
    private func identityRow(_ message: Message) -> some View {
        let tint = accountTint(message)
        return HStack(alignment: .center, spacing: 12) {
            senderAvatar(message.from.initials, tint: tint, size: 36, font: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.from.name.isEmpty ? message.from.address : message.from.name)
                    .font(theme.sans.font(size: 14.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Text(Self.glassSenderCaption(message))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            identityStamp(message)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "ricardo@empresa.com · Caixa de entrada"
    nonisolated static func glassOrigin(account: String, folder: String) -> String {
        let conta = account.trimmingCharacters(in: .whitespaces)
        if conta.isEmpty { return folder }
        return "\(conta) · \(folder)"
    }

    /// "marina@cliente.com · para você"
    nonisolated static func glassSenderCaption(_ message: Message) -> String {
        let endereço = message.from.address.trimmingCharacters(in: .whitespaces)
        let para = destinatarios(message)
        switch (endereço.isEmpty, para) {
        case (true, nil): return ""
        case (true, let para?): return para
        case (false, nil): return endereço
        case (false, let para?): return "\(endereço) · \(para)"
        }
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

    private func setEmailAssistantOpen(_ open: Bool, for messageID: String? = nil) {
        if open {
            if readerConversation == nil,
               let id = messageID ?? presentation.messageID ?? store.selectedMessageID {
                readerConversation = makeAssistantConversation?(id)
            }
        } else {
            readerConversation?.cancel()
            readerConversation = nil
        }
        emailAssistantOpen = open
        onEmailAssistantOpenChange(open)
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
        message.bucket == .trash ? L10n.tr("Apagar de vez") : L10n.tr("Apagar")
    }

    private func runFolderCommand(_ command: ContextCommand) {
        defer { mensagemSaiuDaLista() }
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

    /// "neste Mac" só quando é verdade. Com o opt-in remoto ligado, a legenda
    /// nomeia o destino que de fato leu a mensagem.
    static func summaryCaption(for destination: AssistantDestination) -> String {
        destination.isLocal ? L10n.tr("TL;DR · neste Mac") : "TL;DR · \(destination.label)"
    }

    /// A mesma condição da legenda. A dica do cartão recolhido afirmava
    /// "neste Mac" sem olhar para o destino, vinte linhas acima da função que
    /// olha — e era ela que a pessoa lia ao passar o mouse.
    static func summaryHelp(for destination: AssistantDestination) -> String {
        destination.isLocal
            ? L10n.tr("Mostra o resumo gerado neste Mac")
            : L10n.tr("Mostra o resumo gerado por \(destination.label)")
    }

    /// **Um desenho só para os 28 temas.** A tinta nasce escrita em todos:
    /// não havia razão para o vidro ler a frase inteira e os 26 opacos
    /// receberem uma linha dobrada, e o `isGlass` que decidia isto aqui
    /// voltou a ser o que ele deve ser — tratamento de superfície, não layout.
    private func resumoEstaAberto(_ message: Message) -> Bool {
        if debugResumoAberto { return true }
        return resumoAbertoPorID[message.id] ?? Self.resumoComecaAberto
    }

    /// "OCULTAR" / "Mostrar resumo": a escolha é por mensagem e não
    /// sobrevive a nada — é estado de leitura desta janela.
    private func toggleResumo(_ message: Message, aberto: Bool) {
        resumoAbertoPorID[message.id] = !aberto
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

    /// "Convite de agenda", "Convite cancelado", e o rótulo de quem foi
    /// convidado. Estáticas pelo mesmo motivo de `carregandoCorpo`: o que a
    /// pessoa lê é comportamento.
    nonisolated static var conviteTitulo: String { L10n.tr("Convite de agenda") }
    nonisolated static var conviteCancelado: String { L10n.tr("Convite cancelado") }
    nonisolated static var conviteCanceladoFora: String { L10n.tr("Este compromisso não está na sua agenda.") }
    nonisolated static var conviteCanceladoNaAgenda: String { L10n.tr("Na agenda como cancelado.") }
    nonisolated static var conviteNaAgenda: String { L10n.tr("Na agenda") }
    nonisolated static var removerDaAgenda: String { L10n.tr("Remover da agenda") }
    nonisolated static var recolherConvite: String { L10n.tr("Recolher") }
    nonisolated static var mostrarConvite: String { L10n.tr("Detalhes") }
    nonisolated static var recolherResumo: String { L10n.tr("Recolher resumo") }
    nonisolated static var mostrarResumo: String { L10n.tr("Mostrar resumo") }
    /// **A tinta nasce escrita.** Na direção Tinta o que a IA diz não é uma
    /// gaveta a abrir: é texto no fluxo, entre o assunto e o remetente, com um
    /// "OCULTAR" para quem não quiser. Era `false` quando aquilo era um cartão
    /// dobrado — e um cartão que começa dobrado é uma frase que ninguém lê.
    nonisolated static let resumoComecaAberto = true

    /// O que a faixa escreve depois do resumo: "Precisa resposta" e
    /// "Prazo: qui 15h", nesta ordem, quando existirem.
    ///
    /// Só estes dois. Intenção e urgência são o que **ordena** o dashboard,
    /// não o que a pessoa precisa ler ao abrir a mensagem — escrever "Lead ·
    /// urgência alta" no cartão seria mostrar o mecanismo do ranking em vez
    /// de um fato sobre o email.
    ///
    /// `nonisolated static` para o teste ler a cópia sem montar a janela.
    nonisolated static func triageChips(
        for triage: MessageTriage?,
        timeZone: TimeZone = .current
    ) -> [String] {
        guard let triage else { return [] }
        var chips: [String] = []
        if triage.needsReply { chips.append(L10n.tr("Precisa resposta")) }
        if let deadline = triage.deadline {
            chips.append(L10n.tr("Prazo: \(deadlineLabel(deadline.date, timeZone: timeZone))"))
        }
        return chips
    }

    /// "qui 15h" — dia curto e hora, no fuso de quem lê. O minuto só aparece
    /// quando existe: "qui 15h00" seria ruído em nove de cada dez prazos.
    nonisolated static func deadlineLabel(_ date: Date, timeZone: TimeZone) -> String {
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = timeZone
        let partes = calendario.dateComponents([.hour, .minute], from: date)
        let hora = partes.hour ?? 0
        let minuto = partes.minute ?? 0
        let formatador = DateFormatter()
        formatador.locale = L10n.locale
        formatador.timeZone = timeZone
        formatador.setLocalizedDateFormatFromTemplate("EEE")
        let dia = formatador.string(from: date)
            .replacingOccurrences(of: ".", with: "")
            .lowercased()
        return minuto == 0 ? L10n.tr("\(dia) \(hora)h") : L10n.tr("\(dia) \(hora)h\(String(format: "%02d", minuto))")
    }

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
        return L10n.tr("\(visiveis) e mais \(nomes.count - limite)")
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

            Text(convite.summary.isEmpty ? L10n.tr("Compromisso") : convite.summary)
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
                linhaDoCartao(L10n.tr("Este convite foi cancelado pelo organizador."))
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
        let titulo = convite.summary.isEmpty ? L10n.tr("Compromisso") : convite.summary
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
        .help(aberto ? L10n.tr("Recolhe o convite para ler o email") : L10n.tr("Mostra os detalhes do convite"))
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
            Text(selected.map { L10n.tr("Resposta na fila: \($0.label)") } ?? L10n.tr("Responder ao convite"))
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
            help = L10n.tr("\(response.label) — esta resposta já está na fila de saída")
        } else if let unavailable {
            help = unavailable.message
        } else {
            help = L10n.tr("\(response.actionLabel) e enviar ao organizador pela fila de saída")
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
            label: isOnAgenda(message) ? L10n.tr("Na agenda") : L10n.tr("Colocar na agenda"),
            apagado: isOnAgenda(message),
            help: isOnAgenda(message)
                ? L10n.tr("Colocar na agenda — indisponível: este compromisso já está na agenda")
                : L10n.tr("Cria o compromisso na agenda, a partir do que a mensagem detectou"),
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
        .help(L10n.tr("Tira da agenda o compromisso que este cancelamento anuncia"))
    }

    /// O que o botão do convite escreve em cada estado. `nonisolated` e
    /// `static` pelo motivo de sempre: o que a pessoa lê é comportamento, e o
    /// teste o afirma sem montar janela.
    nonisolated static func inviteButtonLabel(_ estado: InviteAgendaState) -> String {
        switch estado {
        case .ausente: L10n.tr("Colocar na agenda")
        case .naAgenda: L10n.tr("Na agenda")
        case .desatualizado: L10n.tr("Atualizar na agenda")
        }
    }

    nonisolated static func inviteButtonHelp(_ estado: InviteAgendaState) -> String {
        switch estado {
        case .ausente: L10n.tr("Cria o compromisso na agenda, a partir deste convite")
        case .naAgenda: L10n.tr("Colocar na agenda — indisponível: este convite já está na agenda")
        case .desatualizado: L10n.tr("Atualiza o compromisso que já está na agenda com o que este convite mudou")
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
                L10n.tr("Desfazer"), appearance: .outlined,
                size: 11.5, height: 26, horizontalPadding: 10
            ) {
                undoAddEvent(receipt)
            }
            .help(L10n.tr("Desfazer: \(receipt.note)"))
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
    nonisolated static var carregandoCorpo: String { L10n.tr("Carregando corpo…") }
    nonisolated static var semTexto: String { L10n.tr("Esta mensagem não tem texto.") }

    private func bodyNote(_ texto: String) -> some View { ReaderNote(texto) }

    /// A falha, com a saída junto. Uma faixa que só diz "não deu" é a mesma
    /// tela vazia com mais palavras.
    private func bodyFailure(_ causa: String, message: Message) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Não foi possível baixar o corpo desta mensagem."))
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(causa)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
            ChromeButton(
                L10n.tr("Tentar de novo"), appearance: .outlined,
                size: 11.5, height: 26, horizontalPadding: 10
            ) {
                Task { await store.retryBody(message.id) }
            }
            .help(L10n.tr("Busca o corpo desta mensagem no servidor outra vez"))
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
            Text(L10n.tr("Nada aqui. Bom sinal."))
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
        var result = AttributedString(L10n.tr("Compromisso detectado — "))
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

/// Ícone 28×28 da barra do leitor: quieto, acende no hover.
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
