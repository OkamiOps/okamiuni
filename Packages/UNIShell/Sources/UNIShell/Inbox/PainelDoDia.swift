import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// O painel do dia — `design/11-painel-do-dia.dc.html`.
///
/// **Uma caixa só na tela: o "Plano de hoje".** O resto é hairline, azulejo em
/// `surface` e tipografia. Nada aqui é lista de email: a leitura é na Caixa, e
/// o duplo clique num azulejo abre a folha do leitor que já existe.
///
/// A tela desenha o `DayPlan` (puro) e o `PlanoDoDia` (puro, a linha do
/// tempo): cabeçalho com o filtro de negócios, o plano de hoje com as duas
/// trilhas, três painéis — quem espera você, os compromissos e o dinheiro com
/// os prazos — e a barra inferior, que é **estado**: nada nela executa.
///
/// **A IA nunca executa sozinha.** Aceitar o plano cria compromissos pelo
/// comando de agenda de sempre, com desfazer; enviar acontece no cartão do
/// rascunho, onde o texto inteiro está à vista.
struct PainelDoDia: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(ActionReceipts.self) private var receipts: ActionReceipts?

    let store: MailStore
    let now: Int
    let today: Date
    let drafts: [String: ReadyDraft]
    let conversation: AssistantConversation
    let isWorking: Bool
    @Binding var filter: DayPlan.Filter
    @Binding var selectedMailID: String?
    @Binding var readingMailID: String?
    let onPresented: (String) -> Void
    let onOpenMessage: (Message) -> Void
    let onOpenEvent: (AgendaItem) -> Void
    let onCommand: (ContextCommand) -> Void
    let onDiscardDraft: (String) -> Void
    let onAskAssistant: () -> Void
    let onCompose: (ComposerRoute) -> Void
    let intelligence: ComposerIntelligenceGenerator?
    let intelligencePresentation: IntelligencePresentation
    let analysisDestination: @Sendable (String?) -> AssistantDestination
    let makeAssistantConversation: ((String) -> AssistantConversation)?
    /// A análise automática está ligada (o opt-in da rota remota).
    let automaticAnalysisOn: Bool
    /// "Gerar as prontas": a pessoa pedindo, explicitamente, o que a fila de
    /// fundo não pôde escrever. Recebe os ids dos azulejos à vista.
    let onGerarProntas: ([String]) -> Void
    /// Leva a Ajustes → IA, para a frase "· Ativar" ter para onde ir.
    let onOpenAISettings: () -> Void

    /// A mensagem cujo **cartão do rascunho** está aberto — o cartão é o de
    /// sempre (`DashboardPreviewColumn`), e é lá que o Enviar envia.
    @State private var cartaoDoRascunho: String?
    /// "Ajustar": o seletor de hora que já existe.
    @State private var ajustando = false
    /// O desfazer do "Já fiz" — a promessa que saiu por último.
    @State private var promessaDesfeita: PendingItem?

    init(
        store: MailStore,
        now: Int,
        today: Date,
        drafts: [String: ReadyDraft] = [:],
        conversation: AssistantConversation,
        isWorking: Bool = false,
        filter: Binding<DayPlan.Filter> = .constant(.standard),
        selectedMailID: Binding<String?> = .constant(nil),
        readingMailID: Binding<String?> = .constant(nil),
        onPresented: @escaping (String) -> Void = { _ in },
        onOpenMessage: @escaping (Message) -> Void = { _ in },
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onCommand: @escaping (ContextCommand) -> Void = { _ in },
        onDiscardDraft: @escaping (String) -> Void = { _ in },
        onAskAssistant: @escaping () -> Void = {},
        onCompose: @escaping (ComposerRoute) -> Void = { _ in },
        intelligence: ComposerIntelligenceGenerator? = nil,
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisDestination: @escaping @Sendable (String?) -> AssistantDestination = { _ in .onThisMac },
        makeAssistantConversation: ((String) -> AssistantConversation)? = nil,
        automaticAnalysisOn: Bool = false,
        onGerarProntas: @escaping ([String]) -> Void = { _ in },
        onOpenAISettings: @escaping () -> Void = {},
        debugCartaoDoRascunho: String? = nil
    ) {
        self.store = store
        self.now = now
        self.today = today
        self.drafts = drafts
        self.conversation = conversation
        self.isWorking = isWorking
        self._filter = filter
        self._selectedMailID = selectedMailID
        self._readingMailID = readingMailID
        self.onPresented = onPresented
        self.onOpenMessage = onOpenMessage
        self.onOpenEvent = onOpenEvent
        self.onCommand = onCommand
        self.onDiscardDraft = onDiscardDraft
        self.onAskAssistant = onAskAssistant
        self.onCompose = onCompose
        self.intelligence = intelligence
        self.intelligencePresentation = intelligencePresentation
        self.analysisDestination = analysisDestination
        self.makeAssistantConversation = makeAssistantConversation
        self.automaticAnalysisOn = automaticAnalysisOn
        self.onGerarProntas = onGerarProntas
        self.onOpenAISettings = onOpenAISettings
        _cartaoDoRascunho = State(initialValue: debugCartaoDoRascunho)
    }

    // MARK: - O que a tela lê

    private var plan: DayPlan {
        DashboardPlanInput.plan(
            store: store, drafts: drafts, filter: filter, today: today, nowMinute: now
        )
    }

    private var validatedDrafts: [String: ReadyDraft] {
        DashboardPlanInput.validatedDrafts(drafts) { store.message($0) }
    }

    /// Por que a coluna "Esperando você" não tem nenhuma resposta pronta.
    ///
    /// A tela do dono tinha zero prontas, zero blocos e zero promessas, e o
    /// cabeçalho dizia só "nenhuma resposta pronta" — que é a mesma frase para
    /// "a fila ainda não chegou lá" e para "a fila está barrada e vai continuar
    /// barrada". Duas coisas diferentes precisam de duas frases, e a que
    /// explica precisa levar a algum lugar.
    private var motivoSemProntas: PainelDoDiaModelo.MotivoSemProntas {
        let destino = Self.nomeDoMotor(conversation.destination.label)
        guard intelligencePresentation.isAvailable else {
            return .motorIndisponivel(destino: destino)
        }
        // O portão é o do opt-in (`ReadyDraftCoordinator.routeIsAllowed`): a
        // rota local sempre pode; a remota só com a análise automática ligada.
        let local = intelligencePresentation.destination?.isLocal ?? false
        if !local, !automaticAnalysisOn {
            return .precisaDoOptIn(destino: destino)
        }
        return .aindaNaoEscreveu
    }

    /// "Codex · ChatGPT" → "Codex". O rótulo inteiro não cabe no meio de uma
    /// frase, e o que a pessoa reconhece é a primeira palavra.
    static func nomeDoMotor(_ label: String) -> String {
        let curto = label.split(separator: "·").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? label
        return curto.isEmpty ? label : curto
    }

    var body: some View {
        let plan = plan
        let modelo = PainelDoDiaModelo(
            plan: plan,
            drafts: validatedDrafts,
            pending: promessasFiltradas,
            agenda: store.agenda,
            messages: store.messages,
            today: today,
            nowMinute: now,
            myAddresses: Set(store.accounts.map(\.address)),
            motivoSemProntas: motivoSemProntas
        )
        return VStack(alignment: .leading, spacing: 0) {
            // O topo é fixo: o plano de hoje é a única coisa que a pessoa
            // precisa ver sem rolar, e ele não pode ser empurrado para fora.
            VStack(alignment: .leading, spacing: 0) {
                header(modelo)
                planoDeHoje(modelo)
                    .padding(.top, 16)
            }
            .padding(.top, 22)
            .padding(.horizontal, 28)

            // Os três painéis rolam. Com seis azulejos a grade já passava do
            // pé da janela, e o que saía por baixo era a barra de estado —
            // então a tela não tinha nem rolagem nem barra.
            ScrollView(.vertical) {
                painéis(modelo)
                    .padding(.top, 22)
                    .padding(.bottom, 20)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollBounceBehavior(.basedOnSize)

            // E a barra fica colada no pé, sempre: ela é estado do dia, e
            // estado que some quando o dia enche não é estado nenhum.
            barraInferior(modelo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
        .bareKeyShortcuts { key in
            let alvo = DashboardKeys.opens(
                key: key,
                selectedID: selectedMailID,
                readingID: readingMailID,
                exists: selectedMailID.flatMap { store.message($0) } != nil
            )
            guard let alvo else { return false }
            readingMailID = alvo
            return true
        }
        .overlay { readingSheet }
        .sheet(isPresented: Binding(
            get: { cartaoDoRascunho != nil }, set: { if !$0 { cartaoDoRascunho = nil } }
        )) { cartaoSheet }
        .sheet(isPresented: $ajustando) {
            NewAppointmentSheet(
                store: store,
                anchor: today,
                initialDayOffset: 0,
                initialTitle: modelo.propostos.first?.title ?? "",
                onClose: { ajustando = false }
            )
        }
        .agendaUndoBand(store: store)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Painel do dia")
    }

    // MARK: - Cabeçalho

    private func header(_ modelo: PainelDoDiaModelo) -> some View {
        let account = store.selectedAccountID.flatMap { store.account($0) }
            ?? store.accounts.first
        let hello = DashboardFocus.greeting(
            nowMinute: now,
            displayName: account?.displayName,
            address: account?.address
        )
        return HStack(alignment: .center, spacing: 16) {
            Text(hello)
                .font(theme.sans.font(size: 18, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(DashboardMetrics.headerDateLabel(today))
                .capsLabel(size: 9.5)
            filtroDeNegocios(modelo)
                .padding(.leading, 6)
            Spacer(minLength: 12)
            Text(conversation.destination.label)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink4.color)
                .lineLimit(1)
            perguntar
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hello)
    }

    /// O segmentado "Tudo · <conta> ● N": o ponto é semáforo (warn quando
    /// alguma coisa daquela conta pede você), o número é o que ela tem **na
    /// tela**, e o clique é o `DayPlan.Filter.accounts` de sempre.
    private func filtroDeNegocios(_ modelo: PainelDoDiaModelo) -> some View {
        HStack(spacing: 0) {
            segmento(
                titulo: "Tudo", ativo: filter.accounts.isEmpty,
                tint: nil, contagem: nil, ultimo: store.accounts.isEmpty
            ) { filter.accounts = [] }
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { índice, account in
                let estado = modelo.contas[account.id] ?? (total: 0, pedeVoce: false)
                segmento(
                    // `displayName` das contas de verdade nasce igual ao
                    // endereço: `marcos@okamiops.com` não cabe num segmento de
                    // 12pt, e o que identifica a conta é "Okamiops".
                    titulo: account.shortName,
                    ativo: filter.accounts.contains(account.id),
                    tint: estado.pedeVoce ? theme.warning.color : theme.success.color,
                    contagem: estado.total,
                    ultimo: índice == store.accounts.count - 1
                ) {
                    if filter.accounts.contains(account.id) {
                        filter.accounts.remove(account.id)
                    } else {
                        filter.accounts.insert(account.id)
                    }
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filtro de negócios")
    }

    private func segmento(
        titulo: String, ativo: Bool, tint: Color?, contagem: Int?, ultimo: Bool,
        acao: @escaping () -> Void
    ) -> some View {
        Button(action: acao) {
            HStack(spacing: 7) {
                if let tint {
                    Circle().fill(tint).frame(width: 7, height: 7)
                }
                Text(titulo)
                    .font(theme.sans.font(size: 12, weight: ativo ? .semibold : .medium))
                    .foregroundStyle(ativo ? theme.ink.color : theme.ink2.color)
                if let contagem {
                    Text("\(contagem)")
                        .font(theme.mono.font(size: 10))
                        .foregroundStyle(theme.ink4.color)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(ativo ? theme.btn.color : Color.clear)
            .overlay(alignment: .trailing) {
                if !ultimo {
                    Rectangle()
                        .fill(theme.btnLine.color)
                        .frame(width: Hairline.thickness(displayScale))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(titulo)
        .accessibilityAddTraits(ativo ? .isSelected : [])
    }

    private var perguntar: some View {
        Button(action: onAskAssistant) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accent.color)
                Text("Perguntar")
                    .font(theme.sans.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text("⌘J")
                    .font(theme.mono.font(size: 9.5))
                    .foregroundStyle(theme.ink4.color)
            }
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .keyboardShortcut("j", modifiers: .command)
        .accessibilityLabel("Perguntar ao assistente, comando J")
    }

    // MARK: - Plano de hoje

    private func planoDeHoje(_ modelo: PainelDoDiaModelo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text("Plano de hoje")
                    .font(theme.sans.font(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(modelo.legendaDoPlano)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                Spacer(minLength: 8)
                // Escondido, e não desabilitado: um botão cinza que não faz
                // nada é a tela pedindo que você tente clicar para descobrir.
                if !modelo.propostos.isEmpty {
                    PainelBotao(
                        titulo: "Aceitar o plano", primario: true,
                        acao: { aceitarOPlano(modelo) }
                    )
                }
                PainelBotao(titulo: "Ajustar", primario: false) { ajustando = true }
            }
            PainelLinhaDoTempo(
                blocos: modelo.blocos,
                nowMinute: now,
                onTapProposto: { _ in ajustando = true }
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plano de hoje")
    }

    /// "Aceitar o plano": os blocos propostos viram compromissos numa leva
    /// desfazível, pelo mesmo `addManualAgendaItem` do editor de agenda.
    private func aceitarOPlano(_ modelo: PainelDoDiaModelo) {
        let conta = store.selectedAccountID ?? store.accounts.first?.id ?? ""
        var criados: [String] = []
        for bloco in modelo.propostos {
            guard let item = store.addManualAgendaItem(
                title: bloco.title,
                startMinute: bloco.startMinute,
                endMinute: bloco.startMinute + bloco.minutes,
                dayOffset: 0,
                accountID: conta,
                sendInvites: false
            ) else { continue }
            criados.append(item.id)
        }
        guard !criados.isEmpty else { return }
        receipts?.agenda = SwipeReceipt(
            messageID: criados[0],
            note: PainelDoDiaModelo.reciboDoPlano(criados.count),
            undo: .batch(criados.map { .removeFromAgenda(itemID: $0) })
        )
    }

    // MARK: - Os três painéis

    private func painéis(_ modelo: PainelDoDiaModelo) -> some View {
        HStack(alignment: .top, spacing: 32) {
            esperandoVoce(modelo).frame(maxWidth: .infinity, alignment: .topLeading)
            compromissos(modelo).frame(maxWidth: .infinity, alignment: .topLeading)
            dinheiroEPrazos(modelo).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func cabecalho(
        _ titulo: String, _ contagem: Int, _ legenda: String,
        alerta: Bool = false,
        acaoDaLegenda: (() -> Void)? = nil,
        botao: (titulo: String, acao: () -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(titulo)
                .font(theme.sans.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text("\(contagem)")
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
            Spacer(minLength: 8)
            // A legenda que explica é clicável e vai para onde se resolve —
            // uma explicação sem porta é uma desculpa.
            Group {
                if let acaoDaLegenda {
                    Button(action: acaoDaLegenda) {
                        Text(legenda)
                            .font(theme.sans.font(size: 11))
                            .foregroundStyle(theme.accentInk.color)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(legenda)
                } else {
                    Text(legenda)
                        .font(theme.sans.font(size: 11))
                        .foregroundStyle(alerta ? theme.warning.color : theme.ink4.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .help(legenda)
                }
            }
            if let botao {
                PainelBotao(titulo: botao.titulo, primario: false, altura: 22, acao: botao.acao)
            }
        }
        .padding(.bottom, 10)
        .hairline(theme.line, edges: .bottom)
    }

    private func esperandoVoce(_ modelo: PainelDoDiaModelo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cabecalho(
                "Esperando você", modelo.espera.count, modelo.legendaDaEspera,
                // "Ativar" e "Entrar" levam a Ajustes → IA; "ainda não
                // escreveu" não leva a lugar nenhum, o botão é que resolve.
                acaoDaLegenda: precisaDeAjustes(modelo) ? onOpenAISettings : nil,
                // O botão é ação **explícita** da pessoa — a mesma natureza do
                // "Gerar resposta" do leitor —, e por isso não depende do
                // opt-in da fila de fundo.
                botao: modelo.motivoSemProntas != nil && !modelo.espera.isEmpty
                    ? (
                        // O botão diz para onde o conteúdo vai — a regra do app
                        // em toda superfície que sai deste Mac.
                        titulo: isWorking
                            ? "Gerando…"
                            : "Gerar as prontas · \(Self.nomeDoMotor(conversation.destination.label))",
                        acao: { onGerarProntas(modelo.espera.map(\.id)) }
                    )
                    : nil
            )
            grade(modelo.espera.enumerated().map { índice, espera in
                AnyView(PainelAzulejo(
                    iniciais: espera.iniciais,
                    tint: accountTint(espera.accountID).color,
                    nome: espera.nome,
                    numero: espera.numero,
                    sufixo: espera.sufixo,
                    palavra: espera.palavra,
                    alerta: espera.alerta,
                    porque: espera.porque,
                    acaoPrimaria: espera.temRascunho ? "Enviar a pronta" : "Ver",
                    destacada: índice == 0 && espera.pedeGente && espera.temRascunho,
                    onPrimary: {
                        selectedMailID = espera.id
                        if espera.temRascunho {
                            cartaoDoRascunho = espera.id
                        } else {
                            readingMailID = espera.id
                        }
                    },
                    onSelect: { selectedMailID = espera.id },
                    onOpen: {
                        selectedMailID = espera.id
                        readingMailID = espera.id
                    }
                ))
            } + [AnyView(PainelAzulejoVazado(frase: modelo.foraDaLista))])
        }
    }

    /// A legenda leva a Ajustes só quando o que falta é ajuste.
    private func precisaDeAjustes(_ modelo: PainelDoDiaModelo) -> Bool {
        switch modelo.motivoSemProntas {
        case .precisaDoOptIn, .motorIndisponivel: true
        case .aindaNaoEscreveu, nil: false
        }
    }

    private func compromissos(_ modelo: PainelDoDiaModelo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cabecalho("Compromissos", modelo.promessas.count, modelo.legendaDosCompromissos)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Você deve").capsLabel(size: 9.5)
                if let desfeita = promessaDesfeita {
                    Button {
                        store.restorePendingItem(desfeita)
                        promessaDesfeita = nil
                    } label: {
                        Text("Desfazer")
                            .font(theme.sans.font(size: 11, weight: .semibold))
                            .foregroundStyle(theme.accentInk.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)
            grade(modelo.promessas.map { promessa in
                AnyView(PainelAzulejo(
                    iniciais: promessa.iniciais,
                    tint: accountTint(promessa.item.accountID).color,
                    nome: promessa.titulo,
                    numero: promessa.quando,
                    palavra: "vence",
                    alerta: promessa.alerta,
                    porque: promessa.porque,
                    acaoPrimaria: promessa.rotuloDaReserva,
                    destacada: promessa.alerta,
                    acaoSecundaria: "Já fiz",
                    onPrimary: { reservar(promessa) },
                    onSecondary: {
                        promessaDesfeita = store.dismissPendingItem(promessa.item.id)
                    }
                ))
            })
            .padding(.top, 8)
            Text("Devem a você").capsLabel(size: 9.5).padding(.top, 16)
            PainelAzulejoVazado(frase: "Lido dos seus enviados · na próxima versão")
                .padding(.top, 8)
        }
    }

    /// Azulejos dois por fileira, como a grade do mockup.
    private func grade(_ azulejos: [AnyView]) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            alignment: .leading, spacing: 8
        ) {
            ForEach(Array(azulejos.enumerated()), id: \.offset) { _, azulejo in
                azulejo
            }
        }
        .padding(.top, 10)
    }

    private func dinheiroEPrazos(_ modelo: PainelDoDiaModelo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cabecalho("Dinheiro e prazos", modelo.dinheiro.count, "próximos 7 dias")
            ForEach(modelo.dinheiro) { linha in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(linha.titulo)
                            .font(theme.sans.font(size: 13.5, weight: .semibold))
                            .foregroundStyle(theme.ink.color)
                            .lineLimit(1)
                        Text(linha.quando)
                            .capsLabel(size: 9.5)
                            .foregroundStyle(
                                linha.urgente ? theme.warning.color : theme.ink4.color
                            )
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let valor = linha.valor {
                        Text(valor)
                            .font(theme.mono.font(size: 20, weight: .semibold))
                            .foregroundStyle(
                                linha.urgente ? theme.warning.color : theme.ink.color
                            )
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hairline(theme.line2, edges: .bottom)
                .contentShape(Rectangle())
                .onTapGesture { onCommand(.revealMessage(messageID: linha.id)) }
            }
            if modelo.dinheiro.isEmpty {
                Text("Nenhum prazo no radar.")
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink4.color)
                    .padding(.top, 13)
            }
        }
    }

    // MARK: - Barra inferior (estado, nunca ação)

    private func barraInferior(_ modelo: PainelDoDiaModelo) -> some View {
        HStack(spacing: 16) {
            Text("Hoje").capsLabel(size: 9.5)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.line2.color).frame(width: 160, height: 3)
                Capsule()
                    .fill(theme.accent.color)
                    .frame(width: 160 * modelo.progresso, height: 3)
            }
            Text(modelo.progressoEscrito)
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(modelo.composicao)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("em jogo").capsLabel(size: 9.5)
            if modelo.emJogo.isEmpty {
                Text(DashboardMetrics.updateLabel(nowMinute: now, isBusy: isWorking))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink4.color)
            } else {
                ForEach(modelo.emJogo, id: \.rotulo) { parte in
                    HStack(spacing: 5) {
                        Text(parte.rotulo)
                            .font(theme.sans.font(size: 12.5))
                            .foregroundStyle(theme.ink2.color)
                        Text(parte.valor)
                            .font(theme.mono.font(size: 12.5, weight: .semibold))
                            .foregroundStyle(
                                parte.aReceber ? theme.success.color : theme.ink.color
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Progresso do dia")
    }

    // MARK: - Ações

    /// "Reservar 15h": a promessa vira compromisso pelo caminho de agenda de
    /// sempre, com o desfazer da faixa.
    private func reservar(_ promessa: PainelDoDiaModelo.Promessa) {
        guard let minuto = promessa.folga else { return }
        let conta = store.selectedAccountID ?? store.accounts.first?.id ?? ""
        guard let item = store.addManualAgendaItem(
            title: promessa.titulo,
            startMinute: minuto,
            endMinute: minuto + PlanoDoDia.minutosDaPromessa,
            dayOffset: 0,
            accountID: conta,
            sendInvites: false
        ) else { return }
        receipts?.agenda = SwipeReceipt(
            messageID: item.id,
            note: "Reservado — \(item.title)",
            undo: .removeFromAgenda(itemID: item.id)
        )
    }

    /// As promessas do recorte, já filtradas pela conta escolhida.
    private var promessasFiltradas: [PendingItem] {
        let contas = filter.accounts
        return store.pendingItems.filter {
            contas.isEmpty || contas.contains($0.accountID)
        }
    }

    // MARK: - Folhas

    @ViewBuilder
    private var readingSheet: some View {
        if let id = readingMailID {
            DashboardMailSheet(
                store: store,
                messageID: id,
                onClose: { readingMailID = nil },
                onOpenInMailbox: { message in
                    readingMailID = nil
                    onOpenMessage(message)
                },
                onDraft: { message in
                    readingMailID = nil
                    selectedMailID = message.id
                    conversation.draftReply()
                },
                onPresented: onPresented,
                onCompose: onCompose,
                intelligence: intelligence,
                intelligencePresentation: intelligencePresentation,
                analysisDestination: analysisDestination,
                makeAssistantConversation: makeAssistantConversation
            )
        }
    }

    /// O cartão do rascunho — o **mesmo** da prévia do 08, agora numa folha.
    /// O Enviar é lá dentro, com o texto inteiro à vista.
    @ViewBuilder
    private var cartaoSheet: some View {
        if let id = cartaoDoRascunho, let message = store.message(id) {
            VStack(alignment: .leading, spacing: 0) {
                DashboardPreviewColumn(
                    store: store,
                    item: DashboardFocus.MailItem(message: message, reason: .today),
                    today: today,
                    readyDraft: validatedDrafts[id],
                    conversation: conversation,
                    onSendDraft: { message, texto in
                        if DashboardSend.send(
                            draft: texto, for: message, in: store, theme: theme
                        ) {
                            onDiscardDraft(message.id)
                        }
                        cartaoDoRascunho = nil
                    },
                    onEditDraft: { message, texto in
                        store.setReplyDraft(
                            ReplyDraft(to: [message.from], text: texto, savedAt: Date()),
                            for: message.id
                        )
                        cartaoDoRascunho = nil
                        onCommand(.reply(messageID: message.id))
                    },
                    onDiscardDraft: { message in
                        onDiscardDraft(message.id)
                        cartaoDoRascunho = nil
                    },
                    onCommand: onCommand
                )
                HStack {
                    Spacer(minLength: 0)
                    PainelBotao(titulo: "Fechar", primario: false) {
                        cartaoDoRascunho = nil
                    }
                }
                .padding(.top, 12)
            }
            .padding(20)
            .frame(width: 460, height: 560, alignment: .topLeading)
            .background(theme.paper.color)
        }
    }

    // MARK: - Peças

    private func accountTint(_ accountID: String) -> TokenColor {
        guard let account = store.account(accountID) else { return theme.ink3 }
        let hex = theme.isDark ? account.tintDarkHex : account.tintLightHex
        return TokenColor(css: hex) ?? theme.ink3
    }
}
