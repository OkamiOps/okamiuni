import Foundation
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
    let briefing: AssistantConversation
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
    /// Presente só com a coluna de contexto recolhida: o `sidebar.left` que a
    /// traz de volta, na ponta esquerda do cabeçalho do Painel.
    var onExpandSidebar: (() -> Void)?

    /// A mensagem cujo **cartão do rascunho** está aberto — o cartão é o de
    /// sempre (`DashboardPreviewColumn`), e é lá que o Enviar envia.
    @State private var cartaoDoRascunho: String?
    /// A solicitação que está esperando o turno `.draft`. Ela prende o texto
    /// à mensagem em que a pessoa começou, mesmo se trocar a seleção enquanto
    /// o provedor ainda estiver escrevendo.
    @State private var rascunhoEmGeracao: DashboardDraftHandoff?
    /// Rascunhos já recebidos nesta sessão, indexados pela mensagem de origem.
    /// O registro durável mora em `MailStore`; este mapa só mantém o cartão
    /// aberto e não permite que um turno global vaze para outro email.
    @State private var rascunhosGerados: [String: DashboardGeneratedDraft] = [:]
    @State private var errosDeRascunho: [String: String] = [:]
    /// A mesma ação não pode entrar duas vezes na fila enquanto a folha ainda
    /// está fechando. Em falha o id é removido para permitir uma nova tentativa.
    @State private var enviosDeRascunhoIniciados: Set<String> = []
    /// A conversa de um pedido do dashboard. Quando a fábrica existe, ela
    /// nasce com o `messageID` fixo, em vez de seguir a seleção mutável do
    /// dashboard.
    @State private var conversaDoRascunho: AssistantConversation?
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
        briefing: AssistantConversation? = nil,
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
        onExpandSidebar: (() -> Void)? = nil,
        debugCartaoDoRascunho: String? = nil
    ) {
        self.store = store
        self.now = now
        self.today = today
        self.drafts = drafts
        self.conversation = conversation
        self.briefing = briefing ?? conversation
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
        self.onExpandSidebar = onExpandSidebar
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
        Self.motivoSemProntas(
            destino: Self.nomeDoMotor(conversation.destination.label),
            motorDisponivel: intelligencePresentation.isAvailable,
            rotaLocal: intelligencePresentation.destination?.isLocal ?? false,
            automaticAnalysisOn: automaticAnalysisOn
        )
    }

    /// `static` e visível ao pacote para o teste ler a decisão sem montar a
    /// view. O portão é o do opt-in (`ReadyDraftCoordinator.routeIsAllowed`):
    /// a rota local sempre pode; a remota só com a análise automática ligada —
    /// que, desde o ruling de 2026-09-03, já vem ligada com um provedor
    /// remoto configurado, e por isso "· Ativar" some da tela dele.
    static func motivoSemProntas(
        destino: String,
        motorDisponivel: Bool,
        rotaLocal: Bool,
        automaticAnalysisOn: Bool
    ) -> PainelDoDiaModelo.MotivoSemProntas {
        guard motorDisponivel else { return .motorIndisponivel(destino: destino) }
        if !rotaLocal, !automaticAnalysisOn {
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
            agenda: store.dashboardAgenda(accountIDs: filter.accounts),
            messages: store.messages,
            today: today,
            nowMinute: now,
            myAddresses: Set(store.accounts.map(\.address)),
            motivoSemProntas: motivoSemProntas
        )
        // Um corpo só, para os 28 temas: o desenho do protótipo. Quem pinta o
        // fundo é o painel que envolve o Painel — vidro nos dois temas que o
        // declaram, caixa opaca de tokens nos outros 26.
        return corpoVidro(modelo)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        // Ver a nota em `CalendarScreen`: a folha de compromisso pende do topo.
        .topHangingSheet(isPresented: ajustando, onDismiss: { ajustando = false }) {
            NewAppointmentSheet(
                store: store,
                anchor: today,
                initialDayOffset: 0,
                initialTitle: modelo.propostos.first?.title ?? "",
                onClose: { ajustando = false }
            )
        }
        .agendaUndoBand(store: store)
        .task(id: briefingInputKey) {
            guard intelligencePresentation.isAvailable else { return }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            briefing.refreshBriefingIfNeeded(inputKey: briefingInputKey)
        }
        .onChange(of: filter.accounts) { _, _ in briefing.invalidateBriefing() }
        .onChange(of: store.selectedAccountID) { _, _ in briefing.invalidateBriefing() }
        .onChange(of: briefing.destination) { _, _ in briefing.invalidateBriefing() }
        .onChange(of: mensagensDoRascunho) { _, mensagens in
            receberRascunhoGerado(em: mensagens)
        }
        .onChange(of: falhaDoRascunho) { _, falha in
            receberFalhaDoRascunho(falha)
        }
        .onDisappear { briefing.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Painel do dia"))
    }

    // MARK: - O corpo Vidro

    /// Um painel só, na ordem do protótipo: cabeçalho, "Comece por aqui", a
    /// linha do tempo, uma hairline e "Depois disso" em três frentes.
    ///
    /// O que saiu daqui saiu porque já existe em outro lugar: os chips de
    /// negócio estão na coluna de contexto, o assistente está no trilho e no
    /// ⌘J, e a barra de estado do pé era a repetição escrita do que o anel de
    /// progresso e os três azulejos mostram.
    private func corpoVidro(_ modelo: PainelDoDiaModelo) -> some View {
        let account = store.selectedAccountID.flatMap { store.account($0) }
            ?? store.accounts.first
        let frentes = frentesDeVidro(modelo)
        return VStack(alignment: .leading, spacing: 24) {
            PainelVidroCabecalho(
                data: DashboardMetrics.headerDateLabel(today),
                saudacao: DashboardFocus.greeting(
                    nowMinute: now,
                    displayName: account?.displayName,
                    address: account?.address
                ),
                progresso: modelo.progresso,
                progressoEscrito: modelo.progressoEscrito,
                onExpandSidebar: onExpandSidebar,
                onAskAssistant: onAskAssistant
            )

            destaqueDeVidro(modelo)

            PainelLinhaDoTempo(
                blocos: modelo.blocos,
                nowMinute: now,
                onTapCompromisso: { bloco in
                    if let item = store.agenda.first(where: { $0.id == bloco.id }) {
                        onOpenEvent(item)
                    }
                },
                onTapProposto: { _ in ajustando = true },
                temLink: { bloco in
                    store.agenda.first { $0.id == bloco.id }?.detail?.hasLink ?? false
                },
                // "Aceitar o plano", de volta ao Painel (15/10/2026). Ele
                // mora na trilha "Você" porque é dela que ele fala: os blocos
                // tracejados ali são a proposta, e aceitar é transformá-los em
                // compromisso. Sem proposta o botão não existe.
                aceitarPropostos: modelo.propostos.isEmpty
                    ? nil
                    : (contagem: modelo.propostos.count, acao: { aceitarOPlano(modelo) })
            )

            if !frentes.isEmpty {
                Rectangle()
                    .fill(theme.line.color)
                    .frame(height: Hairline.thickness(displayScale))

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(L10n.tr("Depois disso"))
                            .font(theme.sans.font(size: 17, weight: .semibold))
                            .foregroundStyle(theme.ink.color)
                        Text(frentes.count == 1
                             ? L10n.tr("o resto do dia, numa frente só")
                             : L10n.tr("o resto do dia, em \(frentes.count) frentes"))
                            .font(theme.sans.font(size: 13))
                            .foregroundStyle(theme.ink3.color)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(frentes) { frente in
                            PainelVidroAzulejoDaFrente(frente: frente)
                        }
                        // A grade é sempre de três colunas: uma frente sozinha
                        // não estica na largura toda, fica no terço dela.
                        ForEach(0..<max(0, 3 - frentes.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(L10n.tr("Nada mais esperando você hoje."))
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(theme.ink3.color)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 24)
    }

    /// "Comece por aqui": o primeiro que espera, ou o próximo compromisso, ou
    /// uma linha calma. Nunca um cartão vazio.
    @ViewBuilder
    private func destaqueDeVidro(_ modelo: PainelDoDiaModelo) -> some View {
        if let espera = modelo.espera.first {
            let mensagem = store.message(espera.id)
            PainelVidroDestaque(
                iniciais: espera.iniciais,
                tint: accountTint(espera.accountID).color,
                rotulo: L10n.tr("Comece por aqui"),
                titulo: mensagem.map { PainelDoDiaModelo.titulo(de: $0.subject) } ?? espera.nome,
                porque: espera.porque,
                numero: "\(espera.numero)\(espera.sufixo)",
                legenda: espera.alerta ? L10n.tr("até o prazo") : espera.palavra,
                acao: espera.temRascunho
                    ? L10n.tr("Revisar e enviar")
                    : L10n.tr("Abrir e responder"),
                executar: { abrirEspera(espera) }
            )
        } else if let evento = proximoCompromisso {
            PainelVidroDestaque(
                iniciais: PainelDoDiaModelo.iniciais(de: evento.title),
                tint: accountTint(evento.accountID).color,
                rotulo: evento.startMinute <= now
                    ? L10n.tr("Em andamento")
                    : L10n.tr("Comece por aqui"),
                titulo: evento.title,
                porque: "\(hora(evento.startMinute)) – \(hora(evento.endMinute))",
                numero: minutosAte(evento.startMinute),
                legenda: evento.startMinute <= now
                    ? L10n.tr("já começou")
                    : L10n.tr("até começar"),
                acao: L10n.tr("Abrir compromisso"),
                executar: { onOpenEvent(evento) }
            )
        } else {
            Text(L10n.tr("Nenhuma reunião restante hoje, e ninguém esperando resposta."))
                .font(theme.sans.font(size: 14))
                .foregroundStyle(theme.ink3.color)
        }
    }

    /// "2h" ou "35m" até o compromisso começar.
    private func minutosAte(_ minuto: Int) -> String {
        let falta = max(0, minuto - now)
        return falta >= 60 ? "\(falta / 60)h" : "\(falta)m"
    }

    /// As três frentes do "Depois disso". Uma frente sem dado nenhum **não
    /// entra**: um azulejo escrito "0" é a tela ocupando espaço para dizer
    /// que não tem nada a dizer.
    private func frentesDeVidro(_ modelo: PainelDoDiaModelo) -> [PainelVidroFrente] {
        var frentes: [PainelVidroFrente] = []

        if !modelo.espera.isEmpty {
            let prontas = modelo.espera.filter(\.temRascunho)
            let primeira = prontas.first ?? modelo.espera[0]
            frentes.append(PainelVidroFrente(
                id: "responder",
                titulo: L10n.tr("Responder"),
                icone: "arrowshape.turn.up.left",
                cor: theme.accentInk.color,
                numero: "\(prontas.isEmpty ? modelo.espera.count : prontas.count)",
                unidade: prontas.isEmpty
                    ? L10n.tr("esperando você")
                    : L10n.tr("respostas prontas"),
                avatares: modelo.espera.prefix(3).map {
                    PainelVidroFrente.Avatar(
                        id: $0.id, iniciais: $0.iniciais,
                        tint: accountTint($0.accountID).color
                    )
                },
                linhas: modelo.espera.prefix(3).map {
                    PainelVidroFrente.Linha(
                        id: $0.id, quem: $0.nome, oQue: $0.palavra,
                        quando: "\($0.numero)\($0.sufixo)", urgente: $0.alerta
                    )
                },
                acao: prontas.isEmpty
                    ? L10n.tr("Ver a primeira")
                    : L10n.tr("Revisar as \(prontas.count)"),
                acaoPrimaria: true,
                executar: { abrirEspera(primeira) }
            ))
        }

        if !modelo.promessas.isEmpty {
            let reservavel = modelo.promessas.first { $0.rotuloDaReserva != nil }
            frentes.append(PainelVidroFrente(
                id: "prometeu",
                titulo: L10n.tr("Você prometeu"),
                icone: "checkmark.circle",
                cor: theme.nowLine.color,
                numero: "\(modelo.promessas.count)",
                unidade: L10n.tr("promessas abertas"),
                avatares: modelo.promessas.prefix(3).map {
                    PainelVidroFrente.Avatar(
                        id: $0.id, iniciais: $0.iniciais,
                        tint: accountTint($0.item.accountID).color
                    )
                },
                linhas: modelo.promessas.prefix(3).map {
                    PainelVidroFrente.Linha(
                        id: $0.id, quem: $0.titulo, oQue: "",
                        quando: $0.quando, urgente: $0.alerta
                    )
                },
                acao: reservavel?.rotuloDaReserva,
                acaoPrimaria: false,
                executar: { if let reservavel { reservar(reservavel) } }
            ))
        }

        if !modelo.dinheiro.isEmpty {
            let destaque = modelo.frenteDeDinheiro
            frentes.append(PainelVidroFrente(
                id: "dinheiro",
                titulo: L10n.tr("Dinheiro"),
                icone: "dollarsign.circle",
                cor: theme.success.color,
                numero: destaque?.numero ?? "\(modelo.dinheiro.count)",
                unidade: destaque?.unidade ?? L10n.tr("prazos no radar"),
                avatares: [],
                linhas: modelo.dinheiro.prefix(3).map {
                    PainelVidroFrente.Linha(
                        id: $0.id, quem: $0.titulo,
                        oQue: $0.aReceber ? L10n.tr("a receber") : L10n.tr("a pagar"),
                        quando: Self.quandoCurto($0.quando), urgente: $0.urgente
                    )
                },
                acao: L10n.tr("Ver contas"),
                acaoPrimaria: false,
                executar: {
                    if let primeira = modelo.dinheiro.first {
                        onCommand(.revealMessage(messageID: primeira.id))
                    }
                }
            ))
        }

        return frentes
    }

    /// "vence 05/09 · vantion" → "05/09"; "vence hoje · vantion" → "hoje".
    ///
    /// A coluna da direita do azulejo é mono e estreita: a conta e o verbo
    /// cabem na linha de cima, e o que precisa estar à direita é a data.
    static func quandoCurto(_ texto: String) -> String {
        let semConta = texto.split(separator: "·").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? texto
        for verbo in [L10n.tr("vence "), L10n.tr("venceu ")] where semConta.hasPrefix(verbo) {
            return String(semConta.dropFirst(verbo.count))
        }
        return semConta
    }

    /// O mesmo caminho do azulejo clássico: com rascunho abre o cartão, sem
    /// rascunho abre a leitura. Nada é enviado por conta própria.
    private func abrirEspera(_ espera: PainelDoDiaModelo.Espera) {
        selectedMailID = espera.id
        if espera.temRascunho {
            cartaoDoRascunho = espera.id
        } else {
            readingMailID = espera.id
        }
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
                titulo: L10n.tr("Tudo"), ativo: filter.accounts.isEmpty,
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
        .accessibilityLabel(L10n.tr("Filtro de negócios"))
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
                Text(L10n.tr("Perguntar"))
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
        .accessibilityLabel(L10n.tr("Perguntar ao assistente, comando J"))
    }

    // MARK: - Plano de hoje

    private func planoDeHoje(_ modelo: PainelDoDiaModelo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(L10n.tr("Plano de hoje"))
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
                        titulo: L10n.tr("Aceitar o plano"), primario: true,
                        acao: { aceitarOPlano(modelo) }
                    )
                }
                PainelBotao(titulo: L10n.tr("Ajustar"), primario: false) { ajustando = true }
            }
            if let evento = proximoCompromisso {
                proximoCompromissoRow(evento)
                    .padding(.vertical, 10)
            } else {
                Text(L10n.tr("Nenhuma reunião restante hoje. Seu tempo está livre para as prioridades abaixo."))
                    .font(theme.sans.font(size: 12)).foregroundStyle(theme.ink3.color)
                    .padding(.vertical, 8)
            }
            PainelLinhaDoTempo(
                blocos: modelo.blocos,
                nowMinute: now,
                onTapCompromisso: { bloco in
                    if let item = store.agenda.first(where: { $0.id == bloco.id }) {
                        onOpenEvent(item)
                    }
                },
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
        .accessibilityLabel(L10n.tr("Plano de hoje"))
    }

    private var proximoCompromisso: AgendaItem? {
        store.dashboardAgenda(accountIDs: filter.accounts)
            .filter { !$0.isCancelled && $0.dayOffset == 0 && $0.endMinute > now }
            .sorted { $0.startMinute < $1.startMinute }.first
    }

    private func proximoCompromissoRow(_ evento: AgendaItem) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(evento.startMinute <= now ? L10n.tr("Em andamento") : L10n.tr("Próximo compromisso"))
                    .capsLabel(size: 9.5).foregroundStyle(theme.accentInk.color)
                Text(evento.title)
                    .font(theme.sans.font(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text("\(hora(evento.startMinute)) – \(hora(evento.endMinute))")
                .font(theme.mono.font(size: 13)).foregroundStyle(theme.ink2.color)
            PainelBotao(titulo: L10n.tr("Abrir compromisso"), primario: true, altura: 32) {
                onOpenEvent(evento)
            }.accessibilityIdentifier("dashboard-proximo-compromisso")
        }
        .accessibilityElement(children: .contain)
    }

    private func hora(_ minuto: Int) -> String {
        String(format: "%02d:%02d", minuto / 60, minuto % 60)
    }

    private var briefingInputKey: String {
        let focus = store.dashboardFocus(nowMinute: now, now: today, accountIDs: filter.accounts)
        let emails = focus.mail.map { item in
            let m = item.message
            return "\(m.id)|\(m.subject)|\(m.snippet)|\(m.isFlagged)|\(m.isRead)|\(String(describing: m.triage))"
        }.joined(separator: "\n")
        let eventos = store.dashboardAgenda(accountIDs: filter.accounts).filter {
            !$0.isCancelled && (0...7).contains($0.dayOffset) && ($0.dayOffset > 0 || $0.endMinute > now)
        }.map { "\($0.id)|\($0.title)|\($0.dayOffset)|\($0.startMinute)|\($0.endMinute)|\($0.detail?.place ?? "")" }.joined(separator: "\n")
        let pendencias = focus.pending.map { "\($0.id)|\($0.text)|\(String(describing: $0.dueDate))" }.joined(separator: "\n")
        return "\(today)|\(now / 15)|\(filter.accounts.sorted())|\(store.selectedAccountID ?? "")|\(briefing.destination)|\(intelligencePresentation)|\(emails)|\(eventos)|\(pendencias)"
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
            VStack(alignment: .leading, spacing: 24) {
                orientacaoIA
                if !modelo.promessas.isEmpty { compromissos(modelo) }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
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
                L10n.tr("Precisa de você"), modelo.espera.count, L10n.tr("Recentes e sinalizados"),
                // "Ativar" e "Entrar" levam a Ajustes → IA; "ainda não
                // escreveu" não leva a lugar nenhum, o botão é que resolve.
                acaoDaLegenda: nil,
                // O botão é ação **explícita** da pessoa — a mesma natureza do
                // "Gerar resposta" do leitor —, e por isso não depende do
                // opt-in da fila de fundo.
                botao: modelo.motivoSemProntas != nil && !modelo.espera.isEmpty
                    ? (
                        // O botão diz para onde o conteúdo vai — a regra do app
                        // em toda superfície que sai deste Mac.
                        titulo: isWorking
                            ? L10n.tr("Gerando…")
                            : L10n.tr("Gerar · \(Self.nomeDoMotor(conversation.destination.label))"),
                        acao: { onGerarProntas(modelo.espera.map(\.id)) }
                    )
                    : nil
            )
            grade(modelo.espera.enumerated().map { índice, espera in
                AnyView(PainelAzulejo(
                    iniciais: espera.iniciais,
                    tint: accountTint(espera.accountID).color,
                    nome: espera.nome,
                    numero: espera.sufixo == "h" ? espera.numero : "",
                    sufixo: espera.sufixo == "h" ? "h" : "",
                    palavra: espera.palavra,
                    alerta: espera.sufixo == "h" && espera.alerta,
                    porque: espera.porque,
                    detalhe: "\(espera.recebida) · \(store.account(espera.accountID)?.shortName ?? espera.accountID)",
                    acaoPrimaria: espera.temRascunho ? L10n.tr("Revisar resposta") : L10n.tr("Ver"),
                    destacada: índice == 0 && espera.pedeGente && espera.temRascunho,
                    acaoSecundaria: L10n.tr("Arquivar"),
                    onPrimary: {
                        selectedMailID = espera.id
                        if espera.temRascunho {
                            cartaoDoRascunho = espera.id
                        } else {
                            readingMailID = espera.id
                        }
                    },
                    onSecondary: { onCommand(.move(messageID: espera.id, to: .archived)) },
                    onSelect: { selectedMailID = espera.id },
                    onOpen: {
                        selectedMailID = espera.id
                        readingMailID = espera.id
                    }
                ))
            })
            if modelo.espera.isEmpty {
                Text(L10n.tr("Nenhum pedido recente de resposta. Mensagens antigas continuam disponíveis na Caixa."))
                    .font(theme.sans.font(size: 12)).foregroundStyle(theme.ink3.color)
                    .padding(.top, 16)
            }
        }
    }

    private var orientacaoIA: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("Próximas ações")).font(theme.sans.font(size: 14, weight: .semibold))
                Spacer()
                Text(briefing.destination.label).font(theme.sans.font(size: 11)).foregroundStyle(theme.ink3.color)
            }.padding(.bottom, 10).hairline(theme.line, edges: .bottom)
            if briefing.isLoading {
                ProgressView(L10n.tr("Atualizando suas prioridades…")).controlSize(.small)
            }
            if let failure = briefing.failure {
                Text(failure.message).font(theme.sans.font(size: 12)).foregroundStyle(theme.warning.color)
            }
            if let text = briefing.briefingText {
                if briefing.isLoading || briefing.failure != nil {
                    Text(L10n.tr("Última análise disponível"))
                        .capsLabel(size: 9.5).foregroundStyle(theme.ink4.color)
                }
                AssistantMarkdown(text: text, style: .compact)
            } else if !intelligencePresentation.isAvailable {
                Text(intelligencePresentation.detail)
                    .font(theme.sans.font(size: 13)).foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if intelligencePresentation.isAvailable {
                Text(L10n.tr("Atualiza automaticamente com as mudanças do dia."))
                    .font(theme.sans.font(size: 11)).foregroundStyle(theme.ink4.color)
                PainelBotao(titulo: briefing.failure == nil ? L10n.tr("Atualizar prioridades") : L10n.tr("Tentar novamente"), primario: false) {
                    briefing.briefing()
                }.disabled(briefing.isLoading)
            } else {
                PainelBotao(titulo: L10n.tr("Conectar IA"), primario: false, acao: onOpenAISettings)
            }
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
            cabecalho(L10n.tr("Compromissos"), modelo.promessas.count, modelo.legendaDosCompromissos)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.tr("Você deve")).capsLabel(size: 9.5)
                if let desfeita = promessaDesfeita {
                    Button {
                        store.restorePendingItem(desfeita)
                        promessaDesfeita = nil
                    } label: {
                        Text(L10n.tr("Desfazer"))
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
                    palavra: L10n.tr("vence"),
                    alerta: promessa.alerta,
                    porque: promessa.porque,
                    acaoPrimaria: promessa.rotuloDaReserva,
                    destacada: promessa.alerta,
                    acaoSecundaria: L10n.tr("Já fiz"),
                    onPrimary: { reservar(promessa) },
                    onSecondary: {
                        promessaDesfeita = store.dismissPendingItem(promessa.item.id)
                    }
                ))
            })
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
            cabecalho(L10n.tr("Dinheiro e prazos"), modelo.dinheiro.count, L10n.tr("datas recentes e próximas"))
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
                Text(L10n.tr("Nenhum prazo no radar."))
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink4.color)
                    .padding(.top, 13)
            }
        }
    }

    // MARK: - Barra inferior (estado, nunca ação)

    private func barraInferior(_ modelo: PainelDoDiaModelo) -> some View {
        HStack(spacing: 16) {
            Text(L10n.tr("Hoje")).capsLabel(size: 9.5)
            Text(modelo.composicao)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(L10n.tr("em jogo")).capsLabel(size: 9.5)
            if modelo.emJogo.isEmpty {
                Text(isWorking ? L10n.tr("Atualizando…") : L10n.tr("Reflete a caixa sincronizada"))
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
        .accessibilityLabel(L10n.tr("Progresso do dia"))
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
            note: L10n.tr("Reservado — \(item.title)"),
            undo: .removeFromAgenda(itemID: item.id)
        )
    }

    /// As promessas do recorte, já filtradas pela conta escolhida.
    private var promessasFiltradas: [PendingItem] {
        let contas = filter.accounts
        let hoje = Calendar.current.startOfDay(for: today)
        let limite = Calendar.current.date(byAdding: .day, value: 8, to: hoje) ?? hoje
        return store.visiblePendingItems.filter {
            (contas.isEmpty || contas.contains($0.accountID))
                && ($0.dueDate == nil || ($0.dueDate! >= hoje && $0.dueDate! < limite))
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
                    iniciarRevisaoDoRascunho(para: message)
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
                    generatedDraft: rascunhosGerados[id],
                    conversation: conversation,
                    isGeneratingDraft: rascunhoEmGeracao?.sourceMessageID == id
                        && (conversaDoRascunho?.isLoading ?? false),
                    isSendingDraft: enviosDeRascunhoIniciados.contains(id),
                    draftError: errosDeRascunho[id],
                    onGenerateDraft: iniciarRevisaoDoRascunho,
                    onSendDraft: { message, texto in
                        guard enviosDeRascunhoIniciados.insert(message.id).inserted else { return }
                        if DashboardSend.send(
                            draft: texto, for: message, in: store, theme: theme
                        ) {
                            onDiscardDraft(message.id)
                            if let idDoRascunho = rascunhosGerados[message.id]?.persistedDraftID {
                                store.discardDraft(id: idDoRascunho)
                            }
                            rascunhosGerados.removeValue(forKey: message.id)
                            errosDeRascunho.removeValue(forKey: message.id)
                            cartaoDoRascunho = nil
                        } else {
                            enviosDeRascunhoIniciados.remove(message.id)
                            errosDeRascunho[message.id] = L10n.tr(
                                "Não foi possível enviar a resposta. Revise a fila de saída e tente novamente."
                            )
                        }
                    },
                    onEditDraft: { message, texto in
                        cartaoDoRascunho = nil
                        if let idDoRascunho = rascunhosGerados[message.id]?.persistedDraftID {
                            onCompose(.draft(messageID: idDoRascunho))
                        } else {
                            store.setReplyDraft(
                                ReplyDraft(to: [message.from], text: texto, savedAt: Date()),
                                for: message.id
                            )
                            onCommand(.reply(messageID: message.id))
                        }
                    },
                    onDiscardDraft: { message in
                        onDiscardDraft(message.id)
                        if let idDoRascunho = rascunhosGerados[message.id]?.persistedDraftID {
                            store.discardDraft(id: idDoRascunho)
                        }
                        rascunhosGerados.removeValue(forKey: message.id)
                        errosDeRascunho.removeValue(forKey: message.id)
                        enviosDeRascunhoIniciados.remove(message.id)
                        cartaoDoRascunho = nil
                    },
                    onCommand: onCommand
                )
                HStack {
                    Spacer(minLength: 0)
                    PainelBotao(titulo: L10n.tr("Fechar"), primario: false) {
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

    private var mensagensDoRascunho: [AssistantMessage] {
        conversaDoRascunho?.messages ?? []
    }

    private var falhaDoRascunho: AssistantFailure? {
        conversaDoRascunho?.failure
    }

    /// Fecha a leitura e abre o cartão imediatamente. A conversa que gera o
    /// texto é criada para este `messageID`, para o contexto não acompanhar a
    /// seleção caso a pessoa continue navegando no dashboard enquanto espera.
    private func iniciarRevisaoDoRascunho(para message: Message) {
        let conversa = makeAssistantConversation?(message.id) ?? conversation
        guard conversa.canDraftReply, !conversa.isLoading else { return }

        let handoff = DashboardDraftHandoff(sourceMessageID: message.id)
        selectedMailID = message.id
        readingMailID = nil
        cartaoDoRascunho = message.id
        rascunhoEmGeracao = handoff
        errosDeRascunho.removeValue(forKey: message.id)
        enviosDeRascunhoIniciados.remove(message.id)
        conversaDoRascunho = conversa

        guard conversa.draftReply(requestID: handoff.requestID) != nil else {
            rascunhoEmGeracao = nil
            errosDeRascunho[message.id] = L10n.tr(
                "Não foi possível gerar a resposta. Tente novamente."
            )
            return
        }
    }

    private func receberRascunhoGerado(em mensagens: [AssistantMessage]) {
        guard let handoff = rascunhoEmGeracao,
              let turno = mensagens.last(where: { $0.requestID == handoff.requestID }),
              let mensagem = store.message(handoff.sourceMessageID)
        else { return }

        defer { rascunhoEmGeracao = nil }
        do {
            let salvo = try MailAgentTools(store: store).saveReplyDraft(
                messageID: mensagem.id,
                text: turno.text,
                requestID: handoff.requestID.uuidString
            )
            guard let rascunho = handoff.generatedDraft(
                from: turno, persistedDraftID: salvo.id
            ) else { return }
            rascunhosGerados[mensagem.id] = rascunho
            errosDeRascunho.removeValue(forKey: mensagem.id)
        } catch {
            // A resposta já foi produzida; não a escondemos só porque o disco
            // falhou. Ela fica no cartão e pode ser promovida ao composer.
            if let rascunho = handoff.generatedDraft(from: turno, persistedDraftID: nil) {
                rascunhosGerados[mensagem.id] = rascunho
            }
            errosDeRascunho[mensagem.id] = L10n.tr(
                "Não foi possível salvar o rascunho. O texto continua disponível para revisão."
            )
        }
    }

    private func receberFalhaDoRascunho(_ falha: AssistantFailure?) {
        guard let handoff = rascunhoEmGeracao, let falha else { return }
        rascunhoEmGeracao = nil
        errosDeRascunho[handoff.sourceMessageID] = falha.message
        cartaoDoRascunho = handoff.sourceMessageID
    }

    // MARK: - Peças

    private func accountTint(_ accountID: String) -> TokenColor {
        guard let account = store.account(accountID) else { return theme.ink3 }
        let hex = theme.isDark ? account.tintDarkHex : account.tintLightHex
        return TokenColor(css: hex) ?? theme.ink3
    }
}

/// A ponte curta entre o clique em uma mensagem e o turno assíncrono que a IA
/// devolve. O `requestID` pertence ao clique; o `sourceMessageID`, à mensagem
/// cuja resposta será revisada. Os dois são necessários porque a conversa do
/// dashboard sobrevive à mudança de seleção.
struct DashboardDraftHandoff: Hashable {
    let sourceMessageID: String
    let requestID: UUID

    init(sourceMessageID: String, requestID: UUID = UUID()) {
        self.sourceMessageID = sourceMessageID
        self.requestID = requestID
    }

    func generatedDraft(
        from turn: AssistantMessage,
        persistedDraftID: String?
    ) -> DashboardGeneratedDraft? {
        guard turn.kind == .draft, turn.requestID == requestID else { return nil }
        return DashboardGeneratedDraft(
            sourceMessageID: sourceMessageID,
            persistedDraftID: persistedDraftID,
            text: turn.text
        )
    }
}

/// Texto gerado exclusivamente para uma mensagem do dashboard. A cópia do
/// texto fica aqui só enquanto o cartão está aberto; `persistedDraftID` aponta
/// para o rascunho real no `MailStore`, que o Composer sabe reabrir.
struct DashboardGeneratedDraft: Hashable {
    let sourceMessageID: String
    let persistedDraftID: String?
    let text: String
}
