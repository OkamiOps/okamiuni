import SwiftUI
import UNIDesign
import UNIShell
import UNICore
import UNISync

@main
struct OkamiUNIApp: App {
    @State private var themes = ThemeStore()

    /// O mundo do `UNISync`: banco, diretor e a fonte que a UI vai ler.
    ///
    /// Montado uma vez, no `init`, porque a escolha é a mesma para o app
    /// inteiro e não pode mudar a cada redesenho. Quem decide o que ela é mora
    /// no `UNISync` — `AppComposition` —, e não aqui: este alvo não tem testes,
    /// e a decisão "banco ou fixtures" é a mais consequente do Marco 2. Daqui
    /// para baixo só há fiação.
    private let composition: AppComposition
    /// De onde vem o "agora" e o "hoje" da agenda. Decidido uma vez, no `init`,
    /// porque o `MailStore` precisa do **mesmo** hoje que as telas de agenda:
    /// o `dayOffset` de um compromisso é contado contra ele, e dois "hojes"
    /// diferentes poriam o compromisso criado num dia da grade e desenhado
    /// noutro.
    private let agendaClock: AgendaClock
    @State private var mailStore: MailStore
    /// A janela de Contas do usuário. Nula só quando o `UNISync` não subiu —
    /// e nesse caso a cena diz o que houve, ver `ContasIndisponiveis`.
    @State private var accountsModel: AccountsModel?
    /// Quais ações o arraste lateral da linha revela de cada lado. Persistido
    /// em `UserDefaults` como o tema — ver `SwipeSettingsStore`.
    @State private var swipes = SwipeSettingsStore()
    /// Serviço padrão e credenciais de API. O editor e Ajustes → Agenda leem
    /// a mesma instância; a fábrica cria a sala nova a cada compromisso.
    @State private var meetingRooms: MeetingRoomSettingsStore
    @State private var meetingFactory: MeetingRoomFactory
    /// Regras globais, persistidas fora das contas para continuarem valendo
    /// quando a pessoa alternar entre caixas. A mesma instância entra no
    /// `MailStore`, que aplica as regras em mensagens novas, e na janela de
    /// Configurações, que as edita.
    @State private var emailRules: EmailRuleStore
    /// O modelo de Contas **do ensaio**, e só dele: banco temporário, cofre em
    /// memória, sem OAuth. Nulo sem `--ensaiar-contas`, que é o caso de todo
    /// mundo — ver `AccountsRehearsal.makeModel()`.
    ///
    /// **A cena `uni.accounts` é da Task 18.** Enquanto ela não existe, o
    /// ensaio precisa de uma janela de Contas para dirigir, e a bandeira a
    /// empresta da janela principal: com `--ensaiar-contas` a cena principal
    /// desenha `AccountsWindow` no lugar do `InboxScreen`, ensaia e encerra o
    /// app sozinha. Nada disto é registro definitivo — é o menor empréstimo que
    /// deixa o instrumento rodar antes da tarefa que registra a cena de
    /// verdade, e sai daqui quando ela chegar.
    @State private var accountsRehearsalModel = AccountsRehearsal.makeModel()
    /// A sessão do assistente: a gaveta da janela principal e a janela
    /// destacada dividem esta — é o que faz a conversa ser a mesma nas duas.
    /// Mora no app porque uma cena não alcança o `@State` de outra.
    @State private var assistantSession = AssistantSession()

    private var composerIntelligence: ComposerIntelligenceGenerator {
        AssistantBridge.composerGenerator(using: composition.textAssistant)
    }

    init() {
        FontRegistry.registerBundledFonts()
        // O banco do contêiner, o diretor e a fonte. Nada aqui pode impedir o
        // app de abrir: banco que não abre devolve as fixtures e o erro, e o
        // erro aparece na janela de Contas em vez de virar tela cinza.
        let composicao = AppComposition.make()
        composition = composicao
        // `.live` quando o banco abriu — é aí que a fonte pode ser real e o
        // relógio da máquina é o que vale. `.fixed` quando não (a janela de
        // Contas já cobre esse caso), e aí o "agora" congelado é o do Marco 1.
        let relogio: AgendaClock = composicao.database != nil
            ? .live : .fixed(Fixtures.nowMinute)
        agendaClock = relogio
        let regras = EmailRuleStore(defaults: .standard)
        _emailRules = State(initialValue: regras)
        let rooms = MeetingRoomSettingsStore()
        _meetingRooms = State(initialValue: rooms)
        _meetingFactory = State(initialValue: MeetingRoomFactory(
            google: composicao.googleAuth, rooms: rooms
        ))
        let store = MailStore(
            source: composicao.source, commandPort: composicao.commandPort,
            bodyPort: composicao.bodyPort, attachmentPort: composicao.attachmentPort,
            sendPort: composicao.sendPort,
            draftPort: composicao.draftPort,
            inviteRSVPPort: composicao.inviteRSVPPort,
            contactPort: composicao.contactPort,
            emailRules: regras,
            agendaPort: composicao.agendaPort,
            calendarSync: composicao.calendarSync,
            trustPort: composicao.trustPort,
            // A porta da regra "nunca é prioridade" (Tarefa 2): é por ela que
            // "Arquivar e aprender" persiste e que a regra sobrevive à
            // reabertura.
            senderRulePort: composicao.senderRulePort,
            agendaReferenceDay: { relogio.today },
            calendarDefaults: .standard
        )
        _mailStore = State(initialValue: store)
        // A ressalva 1 da Tarefa 2: a fila de rascunho antecipado só enxerga
        // a agenda do banco. Com esta troca ela passa a olhar a agenda que o
        // `MailStore` de fato mostra — EventKit incluído — antes de propor
        // horário. A closure é chamada fora da main; o salto é síncrono e
        // curto (uma leitura de array).
        if let filaDeRascunho = composicao.readyDraftQueue {
            let agendaDoStore: @Sendable () -> [AgendaItem] = {
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { store.agenda }
                }
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { store.agenda }
                }
            }
            Task { await filaDeRascunho.useAgenda(agendaDoStore) }
        }
        if let diretor = composicao.director {
            // A fila junto: é por ela que o "Tentar de novo" de uma fila parada
            // chega ao executor daquela conta.
            _accountsModel = State(initialValue: AccountsModel(
                director: diretor, outbox: composicao.outbox, sync: composicao.sync
            ))
        }
        if let erro = composicao.configError {
            // Falha de configuração nunca some: vai para o log estruturado
            // (dentro do `AppComposition`) e para o stderr, e a janela de
            // Contas a mostra para quem pode consertá-la.
            fputs("[OkamiUNI] \(erro.mensagem)\n", stderr)
        }
        // A faixa de resposta lê o rascunho uma vez, na primeira montagem.
        // Semear depois disso não a alcança — foi o que fez duas capturas
        // saírem byte a byte idênticas. Aqui é antes de qualquer janela.
        // O ensaio de teclado precisa do mesmo estado: sem destinatário nem
        // texto na faixa, o "Enviar" nasce desabilitado e o ⌘⏎ não teria como
        // provar nada.
        if WindowCapture.fromProcess != nil || KeyboardRehearsal.fromProcess != nil {
            WindowCapture.seedForCapture(mailStore)
        }
    }

    /// A pausa da fila, quando existe. O modelo observa o banco; ela aparece
    /// sozinha, sem a pessoa reabrir a janela.
    private var pausaDaAnalise: AnalysisPauseState? {
        guard let fila = composition.analysisQueue,
              let motivo = fila.state.reason
        else { return nil }
        return AnalysisPauseState(reason: motivo) {
            Task { await fila.retry() }
        }
    }

    /// De onde o resumo de uma mensagem veio, pela versão do motor gravada
    /// com ele. O snapshot é lido na hora da legenda porque o rótulo do
    /// provedor pode mudar; a proveniência, não.
    private var destinoDaAnalise: @Sendable (String?) -> AssistantDestination {
        let settings = composition.assistantSettings
        return { versao in
            settings.snapshot().automaticAnalysisDestination(forSummaryModelVersion: versao)
        }
    }

    /// O conteúdo da cena principal.
    ///
    /// Uma cena só, dois conteúdos, e a bandeira decide. Sem `--ensaiar-contas`
    /// — o caso de todo mundo — é o `InboxScreen` de sempre, com as portas de
    /// depuração penduradas nele. Com a bandeira, é a janela de Contas que o
    /// ensaio dirige e fotografa antes de encerrar o app: a cena `uni.accounts`
    /// é da Task 18, e até ela chegar o ensaio pega a janela principal
    /// emprestada em vez de registrar por conta própria uma cena que teria de
    /// ser desfeita depois.
    @ViewBuilder
    private var cenaPrincipal: some View {
        if let accountsRehearsalModel {
            AccountsWindow(model: accountsRehearsalModel)
                .rehearseAccountsIfRequested(
                    AccountsRehearsal.fromProcess, model: accountsRehearsalModel
                )
        } else {
            LeituraDoAssistente(model: composition.assistantAvailability) { apresentacao in
                InboxScreen(
                    store: mailStore,
                    clock: agendaClock,
                    intelligencePresentation: apresentacao,
                    analysisPause: pausaDaAnalise,
                    analysisDestination: destinoDaAnalise,
                    textAssistant: composition.textAssistant,
                    assistantSettings: composition.assistantSettings,
                    onMessagePresented: prioritizeMessageSummary,
                    accountsModel: accountsModel,
                    analysisQueue: composition.analysisQueue,
                    backlogAnalysis: composition.backlogAnalysis,
                    readyDrafts: composition.readyDrafts,
                    assistantSession: assistantSession
                )
            }
                // Porta de depuração: `open -g --args --nova-mensagem` abre a
                // janela auxiliar pelo mesmo `openWindow` do menu, sem trazer o
                // app à frente e sem sintetizar tecla nenhuma. Sem a bandeira,
                // isto não faz nada.
                .modifier(LaunchWindowOpener())
                // `--capturar=/caminho.png`: fotografa a própria janela e
                // encerra. Sem a bandeira, não faz nada.
                .captureWindowIfRequested(WindowCapture.fromProcess, store: mailStore)
                // `--ensaiar-arraste`: arrasta a primeira linha com eventos
                // sintetizados dentro do processo e fotografa cada fase. Sem a
                // bandeira, não faz nada.
                .rehearseSwipeIfRequested(SwipeRehearsal.fromProcess)
                // `--ensaiar-teclado`: sintetiza ⌘R, ⌘N, ⌘⏎ e as setas do menu
                // de contexto dentro do processo e afere o efeito de cada uma.
                .rehearseKeyboardIfRequested(KeyboardRehearsal.fromProcess, store: mailStore)
                // `--ensaiar-barra`: dois cliques na área vazia da barra de
                // título e a moldura da janela antes e depois.
                .rehearseTitleBarIfRequested(TitleBarRehearsal.fromProcess)
                // `--ensaiar-semaforos`: abre a 03 e a 04 e mede a moldura de
                // verdade dos botões do sistema contra o cabeçalho de cada
                // janela. Sem a bandeira, não faz nada.
                .rehearseTrafficLightsIfRequested(
                    TrafficLightRehearsal.fromProcess, store: mailStore
                )
        }
    }

    var body: some Scene {
        WindowGroup("OkamiUNI") {
            cenaPrincipal
                .environment(themes)
                .environment(swipes)
                .environment(meetingRooms)
                .environment(meetingFactory)
                .theme(themes.theme)
                .barraColadaNoTopo()
                // 860 é o piso da faixa mais estreita da Task R: trilha de
                // 62 + lista de 320 ainda deixam 478pt para o leitor.
                //
                // A altura da *janela* não chega a 600: ela é sempre
                // `minHeight + 32`, e os 32 são a barra de título que a
                // `.hiddenTitleBar` continua reservando no quadro da janela
                // mesmo com o conteúdo desenhando por baixo dela. Medido:
                // minHeight 100 dá janela de 132, minHeight 700 dava 732.
                // Nenhum conteúdo impõe altura — com minHeight 100 o shell
                // inteiro comprime até 100. Então 600 aqui é 600 de conteúdo,
                // 632 de janela.
                .frame(minWidth: 860, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 916)
        .commands {
            // ⌘N abre a 06. O botão "Escrever" da barra do topo chama o mesmo
            // caminho — ele mora no `WindowChrome`, que é de outra tarefa.
            CommandGroup(replacing: .newItem) { NewMessageCommand() }
            // O menu Mensagem, e a casa dos atalhos que agem sobre a mensagem
            // selecionada. Eles precisam estar **no menu principal**: é ele que
            // `NSApplication.sendEvent` consulta antes da janela, e ⌘E já é
            // "Use Selection for Find" lá. Ver `MessageCommands`.
            MessageCommands(store: mailStore, assistantSession: assistantSession)
            // "Configurações…" no lugar do item de Ajustes que o macOS
            // reserva — é a mesma janela do Marco 2, batizada com o nome que
            // o dono do projeto pediu, e o par do item de contexto que a
            // linha da conta na lateral já oferece. `.replacing`, e não
            // `.after`: esta cena **é** as Configurações do app, não um item
            // ao lado delas — duas entradas ali confundiriam o que abre com
            // ⌘,.
            CommandGroup(replacing: .appSettings) { AccountsCommand() }
        }

        // As quatro janelas da Task U. Cenas de verdade, não folhas: o protótipo
        // as chama de "em janela" e desenha sombra e raio próprios, que numa
        // cena o macOS desenha por nós. `WindowGroup(id:for:)` ainda dá o que
        // uma `NSWindow` à mão custaria: tamanho declarado, ⌘W, Janela ▸ e uma
        // janela por valor (dois compositores para duas mensagens diferentes,
        // e a mesma janela de volta quando o valor se repete).
        //
        // O valor é sempre `String` porque `WindowGroup(for:)` exige
        // `Codable & Hashable` — e porque a janela deve reler do `MailStore`,
        // não carregar uma cópia congelada da mensagem.

        // O valor da cena carrega a **intenção** junto do id — responder ou
        // responder a todos —, e é `ComposerRoute` quem a lê. Um valor antigo,
        // sem prefixo, continua sendo uma resposta simples: nenhuma janela
        // restaurada muda de significado.
        WindowGroup(id: UNIWindow.composer, for: String.self) { $route in
            ComposerWindow(
                store: mailStore,
                mode: .init(ComposerRoute.parse(route ?? "")),
                intelligence: composerIntelligence
            )
                .themed(themes)
                .barraColadaNoTopo()
                .frame(minWidth: 620, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.composer)

        WindowGroup(id: UNIWindow.newMessage, for: String.self) { $accountID in
            ComposerWindow(
                store: mailStore,
                mode: .new(accountID: accountID),
                intelligence: composerIntelligence
            )
                .themed(themes)
                .barraColadaNoTopo()
                .frame(minWidth: 620, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.newMessage)

        WindowGroup(id: UNIWindow.message, for: String.self) { $messageID in
            LeituraDoAssistente(model: composition.assistantAvailability) { apresentacao in
                MessageWindow(
                    store: mailStore,
                    messageID: messageID ?? "",
                    textAssistant: composition.textAssistant,
                    assistantSettings: composition.assistantSettings,
                    intelligencePresentation: apresentacao,
                    analysisDestination: destinoDaAnalise,
                    onMessagePresented: prioritizeMessageSummary
                )
            }
                .themed(themes)
                .barraColadaNoTopo()
                .frame(minWidth: 520, minHeight: 380)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.message)

        WindowGroup(id: UNIWindow.event, for: String.self) { $itemID in
            EventWindow(store: mailStore, itemID: itemID ?? "")
                .themed(themes)
                .barraColadaNoTopo()
                .frame(minWidth: 460, minHeight: 380)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.event)

        // 10 Assistente destacado. `Window`, e não `WindowGroup`: é **uma** por
        // app, como as Configurações — duas janelas da mesma conversa seriam
        // duas telas discordando sobre o que já foi executado. Ela entra no
        // menu Janela por ser cena, e ⌘W a fecha sem apagar a conversa.
        Window("Assistente", id: UNIWindow.assistant) {
            AssistantWindow(session: assistantSession)
                .themed(themes)
                .barraColadaNoTopo()
                .frame(minWidth: 380, minHeight: 320)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.assistant)

        // A janela de Configurações do Marco 2 — "Contas" até o primeiro
        // teste com contas reais. `Window`, e não `WindowGroup`: ela é uma
        // só — abri-la de novo traz a que já está aberta, que é o que o menu
        // do app e o item de contexto da linha da conta esperam. É esta a
        // cena que `UNIWindow.accounts` nomeia (o id interno não mudou, só o
        // título) e é o registro definitivo dela: a Task 16 já mandava
        // abri-la e a Task 17 a tomou emprestada da janela principal
        // enquanto ela não existia. A lista de contas é a primeira seção do
        // corpo — ver `AccountsWindow`.
        Window("Configurações", id: UNIWindow.accounts) {
            Group {
                if let accountsModel {
                    AccountsWindow(
                        model: accountsModel,
                        initialSection: .general,
                        assistantSettings: composition.assistantSettings,
                        assistantCredentials: composition.assistantCredentials,
                        textAssistant: composition.textAssistant,
                        liteLLMOAuthAuthorizer: composition.liteLLMOAuth,
                        providerOAuthAuthorizer: composition.assistantProviderOAuth,
                        backlogAnalysis: composition.backlogAnalysis,
                        emailRules: emailRules,
                        themes: themes,
                        swipes: swipes,
                        mailStore: mailStore,
                        meetingRooms: meetingRooms
                    )
                } else {
                    // Sem diretor não há o que gerenciar — e dizer isso é
                    // melhor do que uma janela vazia.
                    ContasIndisponiveis(erro: composition.configError)
                }
            }
            .themed(themes)
            .barraColadaNoTopo()
            .frame(minWidth: 820, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.accounts)
    }

    /// A leitura atual tem prioridade sobre o reprocessamento histórico. A
    /// coordenação continua serial para não disputar o modelo local nem gerar
    /// análises duplicadas; a mensagem aberta entra logo depois da inferência
    /// que já estiver em andamento.
    private func prioritizeMessageSummary(_ messageID: String) {
        guard let intelligence = composition.intelligence else { return }
        Task { await intelligence.prioritize(messageID: messageID) }
    }
}

/// Lê a disponibilidade do assistente **dentro do corpo de uma `View`**.
///
/// Não é rodeio: o fecho de conteúdo de uma `WindowGroup` e a propriedade
/// `cenaPrincipal` são avaliados fora de um corpo de `View`, e uma leitura
/// feita ali não entra no rastreio do `@Observable` — a barra ficaria com a
/// primeira medida para sempre. Dentro deste corpo, ler `model.availability`
/// registra a dependência, e o `refresh()` seguinte redesenha quem consome.
///
/// O `.task` é o outro motivo de existir: cada superfície que lê a
/// disponibilidade também paga a primeira medida, e o modelo coalesce as
/// chamadas — abrir três janelas de mensagem não sobe três sondas.
private struct LeituraDoAssistente<Content: View>: View {
    let model: AssistantAvailabilityModel
    @ViewBuilder let content: (IntelligencePresentation) -> Content

    var body: some View {
        content(IntelligencePresentation(model.availability))
            .task { await model.refresh() }
    }
}

/// Abre a janela auxiliar pedida na linha de comando, uma vez só.
///
/// `openWindow` é chave de ambiente e precisa de um `View` para ser lida — daí
/// o modificador em vez de uma chamada dentro do `App`.
private struct LaunchWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var done = false

    func body(content: Content) -> some View {
        content.task {
            guard !done, let request = LaunchWindowRequest.fromProcess else { return }
            done = true
            openWindow(id: request.windowID, value: request.value)
        }
    }
}

extension View {
    /// A barra custom desta janela **é** a barra de título: ela encosta no topo
    /// e os semáforos nativos moram dentro dela.
    ///
    /// Sem isto o SwiftUI empurra o conteúdo para baixo da área segura — os
    /// 32pt que a `.hiddenTitleBar` continua reservando no quadro — e sobra uma
    /// faixa vazia entre os botões do sistema e o que a barra desenha.
    ///
    /// **É o defeito da M3-22.** Só a janela principal chamava isto; as cinco
    /// auxiliares desenhavam a barra 32pt abaixo do topo enquanto o alinhador
    /// punha os semáforos em 22 — medido pelo `--ensaiar-semaforos` na 03 e na
    /// 04: `diferença = -32`, ou seja, os botões do sistema 32 pontos **acima**
    /// da linha do cabeçalho. Era exatamente o que o dono via na janela de
    /// responder e na de compromisso.
    ///
    /// A M3-21 não pegou porque mediu por bitmap do conteúdo, onde os semáforos
    /// não aparecem — eles não são desenhados pelo AppKit do conteúdo.
    fileprivate func barraColadaNoTopo() -> some View {
        ignoresSafeArea(.container, edges: .top)
    }

    /// O tema atravessa para as janelas novas: o `ThemeStore` no ambiente (para
    /// quem troca de tema) e o `Theme` resolvido (para quem só desenha).
    /// As duas coisas, sempre — só o `.theme(...)` deixaria o seletor mudo, e
    /// só o `.environment(...)` deixaria a janela no tema padrão.
    fileprivate func themed(_ themes: ThemeStore) -> some View {
        environment(themes).theme(themes.theme)
    }
}

/// ⌘N. Vive num `View` porque `openWindow` é uma chave de ambiente, e um `App`
/// não tem ambiente para lê-la.
private struct NewMessageCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Nova mensagem") {
            openWindow(id: UNIWindow.newMessage, value: "")
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

/// ⌘, abre a janela de Configurações. Vive num `View` porque `openWindow` é
/// chave de ambiente, como `NewMessageCommand`.
///
/// ⌘, e não mais ⇧⌘A: era ⇧⌘A porque ⌘, era "Ajustes" no macOS inteiro, e
/// roubar o atalho de um item que o sistema espera deixaria esse item sem
/// tecla. Isso valia enquanto a janela se chamava "Contas" — uma coisa entre
/// outras que o app tinha. Virando "Configurações", ela **é** o que ⌘, é
/// para: não há mais item nenhum do sistema para colidir, porque esta janela
/// é o item.
private struct AccountsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Configurações…") { openWindow(id: UNIWindow.accounts) }
            .keyboardShortcut(",", modifiers: .command)
    }
}

/// O que a cena de Contas mostra quando o `UNISync` não subiu.
///
/// Existe porque a alternativa é pior: sem diretor, `AccountsWindow` não pode
/// ser construída, e uma cena registrada que abre vazia faz a pessoa achar que
/// não tem conta nenhuma quando o que houve foi o banco não abrir.
private struct ContasIndisponiveis: View {
    @Environment(\.theme) private var theme
    let erro: SyncError?

    var body: some View {
        VStack(spacing: 10) {
            Text("Contas indisponíveis")
                .font(theme.sans.font(size: 14, weight: .medium))
                .foregroundStyle(theme.ink.color)
            Text(erro?.mensagem ?? "O banco local não pôde ser aberto.")
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.paper.color)
    }
}
