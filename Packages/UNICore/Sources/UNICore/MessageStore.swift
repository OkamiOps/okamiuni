import Foundation
import Observation

/// De onde as mensagens vêm. No Marco 1 só existe a implementação em memória;
/// no Marco 2, Gmail, Graph e IMAP passam a conformar a este mesmo protocolo
/// e a UI não muda.
public protocol MailSource: Sendable {
    func accounts() async throws -> [Account]
    func messages() async throws -> [Message]
    func agenda() async throws -> [AgendaItem]
    func pendingItems() async throws -> [PendingItem]
    /// As pastas do provedor, de todas as contas. **Requisito com implementação
    /// padrão** pela mesma razão de despacho de `snapshots()` logo abaixo — e
    /// a padrão é a lista vazia, que é o que faz o app sem conta (as fixtures)
    /// continuar sem seção de pastas nenhuma.
    func folders() async throws -> [MailFolder]

    // As três abaixo são **requisitos com implementação padrão**, e não
    // membros só de extensão. A diferença é despacho: o `MailStore` guarda
    // um `any MailSource`, e um membro que existe apenas na extensão do
    // protocolo é resolvido estaticamente — a fonte do banco sobrescreveria
    // `snapshots()` e a chamada continuaria caindo na padrão, entregando um
    // retrato só e nunca acordando a lista. Declarados aqui, o despacho passa
    // pela tabela de testemunhas e a sobrescrita vale. Ter padrão na extensão
    // é o que faz `InMemoryMailSource` continuar conformando sem uma linha.
    func snapshot() async throws -> MailSnapshot
    func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error>
    func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>?
}

/// Tudo o que a UI precisa, num valor só.
///
/// Existe porque a fonte deixou de ser um puxão e virou uma assinatura: com
/// quatro chamadas separadas, o `MailStore` teria de sincronizar quatro
/// sequências e decidir o que fazer quando três chegam e uma não. Um valor só
/// é atômico por construção.
public struct MailSnapshot: Sendable, Hashable {
    public let accounts: [Account]
    public let messages: [Message]
    public let agenda: [AgendaItem]
    public let pendingItems: [PendingItem]
    /// As pastas do provedor. Aditivo (`[]`), e a lista vazia é o retrato do
    /// app sem conta: as fixtures não têm servidor nenhum, e por isso a seção
    /// CAIXAS continua exatamente como o Marco 1 a desenhava.
    public let folders: [MailFolder]

    public init(
        accounts: [Account], messages: [Message],
        agenda: [AgendaItem], pendingItems: [PendingItem],
        folders: [MailFolder] = []
    ) {
        self.accounts = accounts
        self.messages = messages
        self.agenda = agenda
        self.pendingItems = pendingItems
        self.folders = folders
    }
}

extension MailSource {
    /// Um retrato, agora.
    public func snapshot() async throws -> MailSnapshot {
        MailSnapshot(
            accounts: try await accounts(),
            messages: try await messages(),
            agenda: try await agenda(),
            pendingItems: try await pendingItems(),
            folders: try await folders()
        )
    }

    /// Sem pastas: a fonte em memória não fala com servidor nenhum.
    public func folders() async throws -> [MailFolder] { [] }

    /// A sequência de retratos.
    ///
    /// **A implementação padrão entrega um e termina** — é isso que faz
    /// `InMemoryMailSource` e todos os testes do Marco 1 continuarem valendo
    /// sem uma linha de mudança. Quem observa de verdade (o banco) sobrescreve.
    public func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            let tarefa = Task {
                do {
                    continuation.yield(try await snapshot())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Quem para de consumir para o trabalho junto: sem isto, fechar a
            // janela deixaria o retrato sendo montado para ninguém.
            continuation.onTermination = { _ in tarefa.cancel() }
        }
    }

    /// Os ids das mensagens cujo **corpo** casa com o termo.
    ///
    /// `nil` significa "esta fonte não sabe procurar no corpo" — e não "não
    /// achou nada". A diferença importa: com `nil`, o `MailStore` fica com a
    /// busca do Marco 1 (remetente, assunto, prévia) em vez de esvaziar a
    /// lista achando que a fonte respondeu.
    public func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? { nil }
}

public struct InMemoryMailSource: MailSource {
    private let _accounts: [Account]
    private let _messages: [Message]
    private let _agenda: [AgendaItem]
    private let _pendingItems: [PendingItem]

    private let _folders: [MailFolder]

    public init(
        accounts: [Account], messages: [Message], agenda: [AgendaItem],
        pendingItems: [PendingItem] = [],
        folders: [MailFolder] = []
    ) {
        self._accounts = accounts
        self._messages = messages
        self._agenda = agenda
        self._pendingItems = pendingItems
        self._folders = folders
    }

    /// A agenda entra pelo **mês inteiro**, não só por hoje nem só pela semana.
    ///
    /// Uma lista só é o que faz a janela 04 achar qualquer compromisso pelo
    /// `id`, inclusive o de quarta. Quem mostra um recorte filtra por
    /// `dayOffset`: a trilha diária pede 0, a grade da semana agrupa sete, a
    /// grade do mês agrupa quarenta e dois. `Fixtures.month` contém
    /// `Fixtures.week`, que contém `Fixtures.agenda`, então a terça é a mesma
    /// nos quatro lugares.
    public static var fixtures: InMemoryMailSource {
        InMemoryMailSource(
            accounts: Fixtures.accounts,
            messages: Fixtures.messages,
            agenda: Fixtures.month,
            pendingItems: Fixtures.pendingItems
        )
    }

    public func accounts() async throws -> [Account] { _accounts }
    public func messages() async throws -> [Message] { _messages }
    public func agenda() async throws -> [AgendaItem] { _agenda }
    public func pendingItems() async throws -> [PendingItem] { _pendingItems }
    public func folders() async throws -> [MailFolder] { _folders }
}

/// Executa as projeções SQLite sem prender o ator principal.
///
/// Uma fila serial é importante aqui: várias ações rápidas sobre a mesma
/// mensagem precisam chegar ao outbox exatamente na ordem em que aconteceram.
/// `Task.detached` por operação tiraria o disco da UI, mas poderia inverter
/// ler -> não ler -> ler sob carga.
private final class MailCommandDispatcher: @unchecked Sendable {
    private let port: any MailCommandPort
    private let queue = DispatchQueue(
        label: "com.okamiops.okamiuni.mail-commands",
        qos: .userInitiated
    )

    init(port: any MailCommandPort) {
        self.port = port
    }

    func enqueue(
        _ operation: @escaping @Sendable (any MailCommandPort) throws -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [port] in
            do {
                try operation(port)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Barreira assíncrona usada pelos testes para observar uma fila vazia sem
    /// introduzir sleeps nem expor a implementação à interface.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

/// Cache da agenda visível. Classe, e não struct no `MailStore`, para as
/// escritas do getter não acordarem o Observation a cada quadro da grade.
private final class AgendaProjectionCache {
    var fingerprint = 0
    var hidden: Set<String> = []
    var concealed: Set<String> = []
    var selectedAccount: String?
    var calendar: [AgendaItem] = []
    var visible: [AgendaItem] = []
}

@MainActor
@Observable
public final class MailStore {
    private struct VisibleCacheKey: Equatable, Hashable {
        let messagesRevision: UInt
        let bodyHitsRevision: UInt
        let bucket: String
        /// Início do dia local do relógio injetado. Sem ele, a lista de Hoje
        /// que já foi cacheada continuaria desenhando ontem depois da meia-noite.
        let referenceDayStart: Date
        let accountID: String?
        let folderID: String?
        let category: String?
        let query: String
        let searchEverywhere: Bool
    }

    /// Recorte da lista **sem** o carimbo do retrato. A página de Tudo tem
    /// de sobreviver a uma ida a Hoje; a revisão entra no carimbo ao lado,
    /// não nesta chave, senão cada mutação deixaria páginas velhas no dicionário.
    private struct RecortePageKey: Hashable {
        let bucket: String
        let referenceDayStart: Date
        let accountID: String?
        let folderID: String?
        let category: String?
        let query: String
        let searchEverywhere: Bool

        init(_ visible: VisibleCacheKey) {
            bucket = visible.bucket
            referenceDayStart = visible.referenceDayStart
            accountID = visible.accountID
            folderID = visible.folderID
            category = visible.category
            query = visible.query
            searchEverywhere = visible.searchEverywhere
        }
    }

    /// Campos baratos da caixa, paralelos a `messages`. Tudo não pode copiar
    /// `bodyHTML` só para saber bucket, data e chave da conversa.
    private struct MessageListIndex {
        let revision: UInt
        let dates: [Date]
        let buckets: [TriageBucket]
        let accountIDs: [String]
        let conversationKeys: [String]
        let folderIDs: [[String]]
        let ids: [String]
        let isRead: [Bool]
        let idIndex: [String: Int]
        let ranked: [Int]
    }

    // Estes dois carimbos precisam ser observáveis: num cache hit os getters
    // abaixo não percorrem `messages`/`bodyHits`, então são eles que mantêm a
    // dependência da View viva até a próxima mutação.
    private var messagesRevision: UInt = 0
    private var bodyHitsRevision: UInt = 0
    @ObservationIgnored private var visibleMessagesCache: (key: VisibleCacheKey, value: [Message])?
    @ObservationIgnored private var visibleConversationsCache: (key: VisibleCacheKey, value: [Conversation])?
    @ObservationIgnored private var countsCacheRevision: UInt = .max
    @ObservationIgnored private var unreadCountCache: [CountCacheKey: Int] = [:]
    @ObservationIgnored private var bucketCountCache: [CountCacheKey: Int] = [:]
    @ObservationIgnored private var foldersByAccountCache: [String: [MailFolder]] = [:]
    @ObservationIgnored private var conversationPagesStamp: (messages: UInt, bodyHits: UInt) = (.max, .max)
    @ObservationIgnored private var conversationPages: [RecortePageKey: (limit: Int, page: ConversationPage)] = [:]
    @ObservationIgnored private var listIndexCache: MessageListIndex?
    @ObservationIgnored private var accountCountCache: [String: Int] = [:]
    @ObservationIgnored private var dashboardFocusCache: (key: DashboardFocusCacheKey, value: DashboardFocus)?

    private struct DashboardFocusCacheKey: Equatable {
        var messagesRevision: UInt
        var accountID: String?
        var nowMinute: Int
        var agendaFingerprint: Int
        var pendingCount: Int
    }
    @ObservationIgnored private var bodyStore: [String: LoadedBody] = [:]
    @ObservationIgnored private var rebuildIndexOnNextDidSet = true
    /// O leitor observa isto, não `messages`: gravar HTML na lista
    /// invalidava o cache de Tudo e o segundo clique reconstruía a caixa.
    private var bodiesRevision: UInt = 0

    private struct LoadedBody {
        var body: [String]
        var bodyHTML: String?
        var calendarICS: String?
        var attachments: [MailAttachment]
    }
    /// Quantas vezes a página foi montada de verdade. O teste da ida e volta
    /// a Tudo lê isto: o clique seguinte não pode voltar a varrer a caixa.
    @ObservationIgnored var conversationPageBuildCount = 0

    private struct CountCacheKey: Hashable {
        let bucket: String
        let accountID: String?
        let dayStart: Date
    }

    public private(set) var accounts: [Account] = []
    public private(set) var messages: [Message] = [] {
        didSet {
            messagesRevision &+= 1
            if rebuildIndexOnNextDidSet || listIndexCache?.ids.count != messages.count {
                listIndexCache = makeListIndex()
                rebuildIndexOnNextDidSet = false
            }
        }
    }
    public private(set) var agenda: [AgendaItem] = []
    public private(set) var pendingItems: [PendingItem] = []

    /// A coalescência da agenda é cara se repetida a cada quadro. A caixa é
    /// uma classe para o Observation não enxergar as escritas do cache.
    private let agendaProjection = AgendaProjectionCache()

    /// `nil` preserva o mundo sem calendário conectado (fixtures e testes do
    /// Marco 1). Quando há uma porta real, a aba Agenda mostra um estado que a
    /// pessoa consegue agir, em vez de parecer vazia por algum motivo oculto.
    public private(set) var calendarAvailability: CalendarAvailability?
    /// Calendários do macOS (Todoist, iCloud, Gmail…) visíveis na lateral da
    /// Agenda. Vazio sem autorização ou sem porta.
    public private(set) var connectedCalendars: [ConnectedCalendar] = []
    /// Calendários que a pessoa desligou na lateral. Os novos nascem ligados.
    public private(set) var hiddenCalendarIDs: Set<String> = []
    /// Origens recolhidas na lateral (Todoist, iCloud…). Os novos grupos
    /// nascem abertos.
    public private(set) var collapsedCalendarSources: Set<String> = []
    /// Calendários tirados da lista pelo clique direito. Continuam no EventKit;
    /// só não ocupam a lateral nem a trilha recolhida.
    public private(set) var concealedCalendarIDs: Set<String> = []
    /// Compromissos que um `METHOD:CANCEL` marcou. Continuam no dia, como o
    /// Google Agenda — só mudam de desenho.
    private var cancelledAgendaKeys: Set<String> = []

    /// As pastas do provedor, como o último retrato as trouxe — **sem**
    /// contador. Quem quer a lista de uma conta pronta para desenhar chama
    /// `folders(of:)`, que ordena e conta.
    ///
    /// Vazia sem conta conectada, sempre: as fixtures não têm servidor.
    public private(set) var folders: [MailFolder] = []

    /// Quantas vezes `reveal(_:)` de fato revelou alguma coisa.
    ///
    /// Existe porque "ir para o email de origem" também é pedido de **fora** da
    /// janela principal — o botão "Email" da janela 04 mora noutra cena e não
    /// alcança o `@State` da `InboxScreen`, que é quem sabe trocar para a aba
    /// Email. Selecionar a mensagem sem trocar de aba deixaria o clique sem
    /// retorno visível quando a janela principal está na aba Agenda: a
    /// definição de botão mudo.
    ///
    /// É um contador, e não um `messageID?`, porque revelar duas vezes a
    /// **mesma** mensagem tem de acordar quem observa nas duas.
    /// `id` desconhecido não incrementa: `reveal` sai antes.
    public private(set) var revealCount = 0

    public private(set) var bucket: TriageBucket = .today
    /// Categoria aberta dentro de Hoje. `nil` é "Todos" e, fora de Hoje,
    /// este filtro é sempre ignorado.
    public private(set) var categoryFilter: MailCategory?
    public private(set) var selectedMessageID: String?
    public private(set) var selectedAccountID: String?

    /// As conversas marcadas na lista, para ação em lote.
    ///
    /// **Não** é a seleção do leitor: o clique na linha continua abrindo. A
    /// marca é um conjunto paralelo, da lista inteira — Hoje, Depois,
    /// Arquivado, Lixeira, pasta do provedor. Trocar de recorte descarta o
    /// que saiu da visão.
    public private(set) var checkedConversationKeys: Set<String> = []

    /// A pasta do provedor aberta, quando há uma.
    ///
    /// **É uma dimensão paralela à caixa do Fluxo, não um substituto dela.**
    /// O Fluxo é triagem ("o que ainda preciso decidir"); a pasta é o mapa do
    /// servidor ("onde isto está guardado lá"). Os dois filtros valem ao mesmo
    /// tempo, e é por isso que abrir uma pasta não mexe em `bucket`.
    public private(set) var selectedFolderID: String?

    /// Que contas estão com as pastas abertas na barra lateral.
    ///
    /// **Nenhuma, ao nascer** — recolhida é como a barra sempre foi, e é o que
    /// mantém a tela do Marco 1 idêntica. O estado é da sessão de propósito: é
    /// o mesmo idioma das seções da janela de compromisso (`EventSections`) e
    /// da faixa de resposta do leitor.
    public private(set) var expandedAccountIDs: Set<String> = []

    public var query: String = "" {
        didSet {
            if oldValue != query {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchEverywhere = false
                }
                pruneChecked()
            }
        }
    }

    /// A busca sai da caixa aberta e cobre pastas, Arquivar, Enviadas…
    /// Só vale com termo; apagar o campo desliga. Padrão falso: Hoje continua
    /// sendo Hoje até a pessoa pedir Tudo.
    public var searchEverywhere: Bool = false {
        didSet { if oldValue != searchEverywhere { pruneChecked() } }
    }

    /// Tem termo **e** a pessoa pediu Tudo. É o predicado que a lista lê.
    public var searchesEverywhereNow: Bool {
        searchEverywhere && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }
    public private(set) var loadError: String?

    /// Os ids que a fonte achou pelo **corpo**, para a busca corrente.
    ///
    /// Vive aqui e não em `matches` porque procurar no corpo é `async` (é
    /// consulta ao índice do banco) e `visibleMessages` é síncrono — a lista
    /// não pode esperar disco a cada redesenho.
    private var bodyHits: Set<String> = [] {
        didSet { bodyHitsRevision &+= 1 }
    }

    private let source: MailSource

    /// Para onde as seis mutações do Marco 3 são enviadas, quando há para
    /// onde enviar. `nil` é o caso das fixtures e de todo teste que não passa
    /// uma — o comportamento fica **idêntico** ao do Marco 1: só memória.
    ///
    /// Falha aqui nunca some silenciosa e nunca desfaz a mutação local — ela
    /// vira `loadError`, pelo mesmo `report(_:)` que a carga usa. A mutação
    /// otimista na lista continua valendo mesmo se a porta falhar: é UI que
    /// nunca espera rede, o mesmo princípio do Marco 2 aplicado à escrita.
    @ObservationIgnored private let commandDispatcher: MailCommandDispatcher?

    /// Regras criadas em Configurações. O primeiro retrato só estabelece a
    /// linha de base: filtros novos não devem reprocessar toda a caixa já
    /// sincronizada. A partir dele, cada id visto uma vez não volta a disparar
    /// mesmo que a mensagem mude de caixa e reapareça em outro retrato.
    @ObservationIgnored private let emailRules: EmailRuleStore?
    @ObservationIgnored private var messageIDsSeenByRules: Set<String>?

    /// A projeção de uma regra é otimista, como as demais ações do leitor.
    /// Enquanto o banco ainda não publicou a confirmação, um retrato antigo
    /// não pode desfazer visualmente a ação nem fazê-la ser enfileirada outra
    /// vez. O mapa vive só nesta sessão; a fonte continua sendo a verdade
    /// depois que refletir a mudança.
    @ObservationIgnored private var pendingRuleActions: [String: Set<EmailRuleAction>] = [:]
    /// O mesmo anteparo para o destino concreto da regra. A representação é o
    /// próprio `SwipeMoveDestination`, para Gmail e IMAP seguirem exatamente o
    /// caminho já provado pelos gestos — não uma segunda interpretação de
    /// "mover" que poderia divergir no servidor.
    @ObservationIgnored private var pendingRuleMoveDestinations: [String: SwipeMoveDestination] = [:]

    /// Quem busca o corpo que o banco não tem. `nil` nas fixtures e em todo
    /// teste que não passa uma — e nesse caso `loadBodyIfNeeded` não faz nada,
    /// que é o comportamento do Marco 1 intacto.
    private let bodyPort: BodyFetching?

    /// Busca de bytes de anexos sob demanda. Separada do corpo porque um PDF
    /// não deve atravessar a mesma espera nem o mesmo estado do leitor.
    private let attachmentPort: AttachmentFetching?

    /// Para onde vai o "Enviar" do composer. `nil` nas fixtures e em todo
    /// teste que não passa uma — e nesse caso a janela continua fechando sem
    /// mandar nada, que é o Marco 1 intacto. `canSend` é o que deixa a janela
    /// dizer a verdade sobre isso em vez de fingir que enviou.
    private let sendPort: MailSendPort?

    /// Para onde o "Salvar rascunho" grava. `nil` nas fixtures — e nesse
    /// caso o rascunho vive só nesta sessão, como o resto do Marco 1.
    private let draftPort: MailDraftPort?

    /// A extensão da mesma fila que grava uma resposta RSVP junto da mensagem
    /// iTIP. Nula nos previews/fixtures; nesses casos ainda é possível testar
    /// com `sendPort`, mas o app conectado usa esta porta para sobreviver ao
    /// reinício sem deixar o cartão oferecer a mesma resposta outra vez.
    private let inviteRSVPPort: InviteRSVPCommandPort?

    /// O estado que o cartão lê. A chave inclui conta e UID (ou a mensagem
    /// sem UID), porque o mesmo evento pode chegar em duas caixas distintas.
    private var inviteRSVPStates: [String: InviteRSVPState] = [:]

    /// De onde vem o catálogo real de contatos. `nil` nas fixtures e em todo
    /// teste que não passa uma — e nesse caso `contactPool` fica em
    /// `Fixtures.contacts`, que é o comportamento de sempre.
    private let contactPort: ContactDirectoryPort?

    /// Os contatos que o campo de destinatário oferece. `Fixtures.contacts`
    /// até a primeira sincronização; a lista real do banco depois — ver
    /// `refreshContactPoolIfNeeded()`.
    ///
    /// **Sem conta conectada, é sempre `Fixtures.contacts`** — a regra do
    /// app inteiro. É por isso que o valor inicial já é o catálogo de
    /// exemplo, e não uma lista vazia: um teste que nunca chama `load()` nem
    /// `observe()` (a maioria da suíte de hoje) continua vendo exatamente o
    /// que via antes desta tarefa.
    public private(set) var contactPool: [DirectoryContact] = Fixtures.contacts

    /// O conjunto de contas na última vez que `contactPool` foi montado.
    /// `nil` até a primeira chamada — é o que faz `refreshContactPoolIfNeeded`
    /// rodar ao menos uma vez mesmo quando a lista de contas continua vazia
    /// (o caso das fixtures, cujo `contactPool` já nasce correto mas cujo
    /// carimbo precisa existir para a próxima comparação fazer sentido).
    private var contactPoolAccountIDs: Set<String>?

    /// Protege contra a resposta de uma consulta de contatos que ficou presa
    /// atrás de uma troca de conta mais recente — o mesmo carimbo que
    /// `refreshBodyMatches()` usa para o termo de busca, aqui sobre o
    /// conjunto de contas em vez do texto digitado.
    private var contactPoolGeneration = 0

    /// Onde os compromissos que a pessoa criou sobrevivem ao fechar o app.
    /// `nil` nas fixtures e em todo teste que não passa uma — e nesse caso a
    /// agenda é de sessão, como no Marco 1. Ver `AgendaPersisting`.
    private let agendaPort: (any AgendaPersisting)?

    /// A agenda do sistema e, quando configurado, CalDAV. Ela não substitui a
    /// fonte de email: soma seus compromissos ao retrato que já alimenta as
    /// quatro superfícies de agenda.
    private let calendarSync: (any CalendarSyncing)?

    /// A parte do retrato que vem de `MailSource`; mantê-la separada permite
    /// que uma observação do banco não apague o resultado que acabou de chegar
    /// do EventKit/CalDAV entre dois retratos.
    private var sourceAgenda: [AgendaItem] = []
    private var synchronizedAgenda: [AgendaItem] = []

    /// De quem as imagens remotas carregam sozinhas. `nil` nas fixtures e em
    /// todo teste que não passa uma — e nesse caso ninguém é confiável, que é
    /// o comportamento da M3-8, intacto. Ver `SenderTrusting`.
    private let trustPort: (any SenderTrusting)?

    /// A lista lida do disco, em memória, para a pergunta "este remetente é
    /// confiável?" não custar uma consulta a cada desenho do leitor. Ela muda
    /// só por ação de quem está aqui, e essas ações a atualizam na hora.
    private var trustedSenderAddresses: Set<String> = []

    /// Contra que dia o `dayOffset` da agenda é contado.
    ///
    /// `Fixtures.today` por padrão, que é o mundo congelado do Marco 1 e o que
    /// mantém capturas e retratos idênticos. O app com banco passa o relógio da
    /// máquina, o mesmo que `AgendaClock.live` dá às telas de agenda — os dois
    /// **têm** de concordar, senão um compromisso criado hoje aparece no dia
    /// errado da grade.
    private let agendaReferenceDay: @Sendable () -> Date
    private let calendarDefaults: UserDefaults?
    private static let hiddenCalendarsKey = "uni.hiddenCalendarIDs"
    private static let collapsedCalendarSourcesKey = "uni.collapsedCalendarSources"
    private static let concealedCalendarsKey = "uni.concealedCalendarIDs"
    private static let cancelledAgendaKeysKey = "uni.cancelledAgendaKeys"

    /// Nome da seção da lateral onde ficam os calendários ocultados pelo
    /// clique direito. Não é origem do EventKit.
    public static let concealedCalendarsSection = "Ocultos"

    /// O dia de calendário de um item da agenda — o "hoje" injetado mais o
    /// deslocamento do item. É o que a janela de compromisso mostra como
    /// data: sem isto ela desenhava a âncora das fixtures ("Terça, 25 de
    /// agosto") para qualquer evento, em qualquer dia real.
    public func agendaDate(for item: AgendaItem) -> Date {
        Calendar.current.date(
            byAdding: .day, value: item.dayOffset, to: agendaReferenceDay()
        ) ?? agendaReferenceDay()
    }

    /// Os compromissos vindos do disco, já traduzidos para o "hoje" desta
    /// abertura. Eles entram em `agenda` junto com o que a fonte der, e ganham
    /// dela no `id`: um compromisso que a pessoa criou não pode ser apagado
    /// pelo retrato seguinte.
    private var persistedAgenda: [AgendaItem] = []

    public init(
        source: MailSource,
        commandPort: MailCommandPort? = nil,
        bodyPort: BodyFetching? = nil,
        attachmentPort: AttachmentFetching? = nil,
        sendPort: MailSendPort? = nil,
        draftPort: MailDraftPort? = nil,
        inviteRSVPPort: InviteRSVPCommandPort? = nil,
        contactPort: ContactDirectoryPort? = nil,
        emailRules: EmailRuleStore? = nil,
        agendaPort: (any AgendaPersisting)? = nil,
        calendarSync: (any CalendarSyncing)? = nil,
        trustPort: (any SenderTrusting)? = nil,
        agendaReferenceDay: @escaping @Sendable () -> Date = { Fixtures.today },
        calendarDefaults: UserDefaults? = nil
    ) {
        self.source = source
        self.commandDispatcher = commandPort.map(MailCommandDispatcher.init(port:))
        self.bodyPort = bodyPort
        self.attachmentPort = attachmentPort
        self.sendPort = sendPort
        self.draftPort = draftPort
        self.inviteRSVPPort = inviteRSVPPort
        self.contactPort = contactPort
        self.emailRules = emailRules
        self.agendaPort = agendaPort
        self.calendarSync = calendarSync
        self.trustPort = trustPort
        self.agendaReferenceDay = agendaReferenceDay
        self.calendarDefaults = calendarDefaults
        if let stored = calendarDefaults?.stringArray(forKey: Self.hiddenCalendarsKey) {
            hiddenCalendarIDs = Set(stored)
        }
        if let stored = calendarDefaults?.stringArray(forKey: Self.collapsedCalendarSourcesKey) {
            collapsedCalendarSources = Set(stored)
        }
        if let stored = calendarDefaults?.stringArray(forKey: Self.concealedCalendarsKey) {
            concealedCalendarIDs = Set(stored)
        }
        if let stored = calendarDefaults?.stringArray(forKey: Self.cancelledAgendaKeysKey) {
            cancelledAgendaKeys = Set(stored)
        }
        // Uma leitura de uma tabela de dezenas de linhas, na montagem. Adiá-la
        // faria o primeiro email aberto mostrar a faixa de bloqueio antes de a
        // lista chegar — e piscar depois.
        if let trustPort {
            trustedSenderAddresses = (try? trustPort.trustedSenders()) ?? []
        }
        if let inviteRSVPPort {
            do {
                inviteRSVPStates = Dictionary(
                    uniqueKeysWithValues: try inviteRSVPPort.savedInviteRSVPStates().map {
                        (Self.inviteRSVPStateKey($0), $0)
                    }
                )
            } catch {
                report(error)
            }
        }
    }

    /// Baixa somente o arquivo solicitado. Sem porta (fixtures/harness) a
    /// falha tem mensagem explícita, em vez de um botão que não faz nada.
    public func fetchAttachment(
        _ attachment: MailAttachment, from message: Message
    ) async throws -> FetchedAttachment {
        guard let attachmentPort else { throw AttachmentError.unavailable }
        return try await attachmentPort.fetchAttachment(
            accountID: message.accountID, messageID: message.id, attachmentID: attachment.id
        )
    }

    // MARK: - Os remetentes de quem as imagens carregam sozinhas

    /// Este remetente já foi confiado?
    ///
    /// Casa por **endereço exato**, normalizado dos dois lados — ver
    /// `SenderTrust` para por que não é por domínio. Sem porta, é sempre
    /// `false`: o bloqueio da M3-8, intacto.
    public func trustsSender(_ address: String) -> Bool {
        trustedSenderAddresses.contains(SenderTrust.normalize(address))
    }

    /// "Sempre carregar deste remetente." Grava e passa a valer no mesmo
    /// quadro — era essa a distância entre clicar e a imagem aparecer.
    public func trustSender(_ address: String) {
        guard let trustPort else { return }
        let normalizado = SenderTrust.normalize(address)
        guard !normalizado.isEmpty else { return }
        trustedSenderAddresses.insert(normalizado)
        do {
            try trustPort.trustSender(normalizado)
        } catch {
            report(error)
        }
    }

    /// O "Rever" da faixa: desfaz a confiança, no disco e na tela. Sem ele a
    /// decisão seria de mão única, e uma decisão de mão única sobre privacidade
    /// é um beco.
    public func revokeSenderTrust(_ address: String) {
        guard let trustPort else { return }
        let normalizado = SenderTrust.normalize(address)
        trustedSenderAddresses.remove(normalizado)
        do {
            try trustPort.revokeSenderTrust(normalizado)
        } catch {
            report(error)
        }
    }

    /// Há por onde enviar de verdade?
    ///
    /// A janela pergunta antes de prometer: sem porta, "Enviar" não envia, e um
    /// botão que fecha a janela como se tivesse enviado é a versão mais cara do
    /// botão mudo — a pessoa acha que mandou.
    public var canSend: Bool { sendPort != nil }

    /// Enfileira a mensagem. Devolve se ela de fato entrou na fila.
    ///
    /// Falha não é engolida (vira `loadError`, como toda falha de porta) e
    /// **não** é fatal para o rascunho: quem chama só fecha a janela quando
    /// isto devolve `true`, senão o texto da pessoa some junto com o erro.
    @discardableResult
    public func send(_ message: OutgoingMessage) -> Bool {
        guard let sendPort else { return false }
        do {
            try sendPort.send(message)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Grava (ou atualiza) um rascunho na caixa Rascunhos.
    ///
    /// Sem porta, fica só na memória desta sessão — o botão ainda funciona,
    /// a linha aparece na barra, e fecha o app some. Com banco, a mesma
    /// linha sobrevive ao reinício. Falha de disco devolve `false` e deixa
    /// o texto na janela: gravar não pode apagar o que a pessoa escreveu.
    @discardableResult
    public func saveDraft(_ message: Message) -> Bool {
        let rascunho = message.withBucket(.drafts).withRead(true)
        rebuildIndexOnNextDidSet = true
        if let index = messages.firstIndex(where: { $0.id == rascunho.id }) {
            messages[index] = rascunho
        } else {
            messages.insert(rascunho, at: 0)
        }
        bodyStore[rascunho.id] = LoadedBody(
            body: rascunho.body,
            bodyHTML: rascunho.bodyHTML,
            calendarICS: rascunho.calendarICS,
            attachments: rascunho.attachments
        )
        guard let draftPort else { return true }
        do {
            try draftPort.saveDraft(rascunho)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Tira o rascunho da caixa — depois de enviar, ou se a pessoa descartar.
    public func discardDraft(id: String) {
        guard messages.contains(where: { $0.id == id && $0.bucket == .drafts }) else { return }
        rebuildIndexOnNextDidSet = true
        messages.removeAll { $0.id == id }
        bodyStore.removeValue(forKey: id)
        guard let draftPort else { return }
        do {
            try draftPort.deleteDraft(id: id)
        } catch {
            report(error)
        }
    }

    // MARK: - Respostas RSVP/iTIP

    /// A resposta já gravada para este convite, se houver. O cartão usa isto
    /// para exibir a decisão real e apagar somente o botão repetido — mudar de
    /// ideia continua possível e gera um novo `METHOD:REPLY`.
    public func inviteRSVPState(for invite: CalendarInvite, from message: Message) -> InviteRSVPResponse? {
        let key = InviteRSVP.eventKey(for: invite, message: message)
        return inviteRSVPStates[Self.inviteRSVPStateKey(accountID: message.accountID, eventKey: key)]?.response
    }

    /// A explicação que a interface mostra quando não há como montar uma
    /// resposta honesta. Não depende da conta atualmente selecionada: a
    /// identidade sempre é a da mensagem que trouxe o convite.
    public func inviteRSVPUnavailableReason(
        for invite: CalendarInvite, from message: Message
    ) -> InviteRSVPUnavailableReason? {
        InviteRSVP.unavailableReason(
            for: invite,
            account: account(message.accountID),
            canQueue: inviteRSVPPort != nil || sendPort != nil
        )
    }

    /// Enfileira a resposta pelo mesmo outbox do composer. Quando há banco, o
    /// estado e a operação entram na **mesma transação**; em fixture, a porta
    /// de envio falsa mantém a ação testável e o estado dura a sessão.
    @discardableResult
    public func respondToInvite(
        _ invite: CalendarInvite,
        from message: Message,
        response: InviteRSVPResponse,
        now: Date = Date()
    ) -> InviteRSVPResult {
        if let reason = inviteRSVPUnavailableReason(for: invite, from: message) {
            return .unavailable(reason)
        }
        if inviteRSVPState(for: invite, from: message) == response {
            if response.placesOnAgenda {
                _ = addToAgenda(invite, from: message)
            } else {
                removeDeclinedInvite(invite, from: message)
            }
            return .alreadyQueued(response)
        }
        guard let account = account(message.accountID),
              let outgoing = InviteRSVP.message(
                response: response, invite: invite, original: message, account: account, now: now
              )
        else {
            // A guarda acima cobre os dados de convite; este ramo existe para
            // o caso de uma fonte trocar a conta durante o clique.
            return .unavailable(.accountMissing)
        }

        let state = InviteRSVPState(
            accountID: account.id,
            eventKey: InviteRSVP.eventKey(for: invite, message: message),
            response: response
        )
        do {
            if let inviteRSVPPort {
                try inviteRSVPPort.queueInviteRSVP(outgoing, state: state)
            } else if let sendPort {
                try sendPort.send(outgoing)
            } else {
                return .unavailable(.sendQueueMissing)
            }
            inviteRSVPStates[Self.inviteRSVPStateKey(state)] = state
            if response.placesOnAgenda {
                _ = addToAgenda(invite, from: message)
            } else {
                removeDeclinedInvite(invite, from: message)
            }
            return .queued(response)
        } catch {
            report(error)
            return .failed
        }
    }

    /// Aceitar/Talvez já gravados, sem o compromisso: o cartão pergunta isto
    /// ao abrir a mensagem. Sem isto, quem aceitou antes desta regra via
    /// "Colocar na agenda" num convite que já tinha resposta.
    public func ensureAgendaForRSVP(_ invite: CalendarInvite, from message: Message) {
        guard let response = inviteRSVPState(for: invite, from: message),
              response.placesOnAgenda
        else { return }
        _ = addToAgenda(invite, from: message)
    }

    /// Recusar tira o compromisso **nascido deste email**. Cópias do EventKit
    /// ficam: o Google Agenda só as some depois de processar o DECLINED.
    func removeDeclinedInvite(_ invite: CalendarInvite, from message: Message) {
        let id = DetectedEventConversion.agendaID(forMessageID: message.id)
        var alvos: [AgendaItem] = []
        if let existente = InviteAgenda.existing(
            for: invite, id: id, accountID: message.accountID, in: agenda
        ), DetectedEventConversion.isFromEmail(existente.id) {
            alvos.append(existente)
        }
        if let proposto = proposedItem(for: invite, from: message, id: id) {
            alvos.append(contentsOf: agenda.filter {
                DetectedEventConversion.isFromEmail($0.id) && InviteAgenda.sameMeeting($0, proposto)
            })
        }
        var vistos = Set<String>()
        for item in alvos where vistos.insert(item.id).inserted {
            removeFromAgenda(item.id)
        }
    }

    /// Abriu o convite: Aceitar/Talvez grava; um SEQUENCE novo atualiza o
    /// compromisso que já está lá, sem um segundo cartão pedindo clique.
    public func syncInviteWithAgenda(_ invite: CalendarInvite, from message: Message) {
        if invite.isCancelled {
            _ = applyCancelledInvite(invite, from: message)
            return
        }
        if let response = inviteRSVPState(for: invite, from: message) {
            if response.placesOnAgenda {
                _ = addToAgenda(invite, from: message)
            } else {
                removeDeclinedInvite(invite, from: message)
            }
            return
        }
        if agendaState(for: invite, from: message) == .desatualizado {
            _ = addToAgenda(invite, from: message)
        }
    }

    private static func inviteRSVPStateKey(_ state: InviteRSVPState) -> String {
        inviteRSVPStateKey(accountID: state.accountID, eventKey: state.eventKey)
    }

    private static func inviteRSVPStateKey(accountID: String, eventKey: String) -> String {
        "\(accountID)\u{1F}\(eventKey)"
    }

    /// Manda a mutação para a porta, se houver uma. Erro vira `loadError` —
    /// nunca é engolido — mas nunca desfaz o que já mudou em memória.
    private func send(
        _ operation: @escaping @Sendable (any MailCommandPort) throws -> Void
    ) {
        commandDispatcher?.enqueue(operation) { [weak self] message in
            Task { @MainActor [weak self] in
                self?.loadError = message
            }
        }
    }

    /// Permite que testes de integração esperem as projeções pendentes sem
    /// transformar as ações públicas em APIs assíncronas.
    func waitForPendingCommands() async {
        await commandDispatcher?.waitUntilIdle()
    }

    public func load() async {
        await refreshCalendar()
        reloadPersistedAgenda()
        do {
            // O retrato é buscado inteiro antes de qualquer propriedade mudar.
            // Isto garante atomicidade: ou as quatro listas chegam, ou nenhuma
            // propriedade muda.
            apply(try await source.snapshot())
        } catch {
            // Em erro, nenhuma propriedade muda; o estado anterior continua válido.
            report(error)
        }
        await refreshContactPoolIfNeeded()
    }

    /// Assina a fonte e aplica cada retrato que chegar.
    ///
    /// É o que substitui `load()` quando a fonte é o banco: uma carga inicial
    /// que grava enquanto baixa acorda a lista sozinha, sem ninguém pedir
    /// "recarregar". Fontes que não observam entregam um retrato e terminam,
    /// então chamar isto nelas é exatamente `load()`.
    public func observe() async {
        await refreshCalendar()
        reloadPersistedAgenda()
        do {
            for try await snapshot in source.snapshots() {
                apply(snapshot)
                await refreshContactPoolIfNeeded()
            }
        } catch {
            // O que já foi aplicado fica: a lista não pode esvaziar porque a
            // observação caiu. O erro aparece, com ação, na janela de Contas.
            report(error)
        }
    }

    /// Remonta `contactPool` quando o conjunto de contas mudou desde a última
    /// vez — a primeira conta a entrar, a última a sair, ou uma troca de
    /// conta no meio. Comparar o **conjunto**, e não a contagem, é o que
    /// impede um retrato que troca uma conta pela outra (mesmo total) de
    /// passar batido.
    ///
    /// Fora de `apply(_:)` de propósito: `apply` é síncrona (a lista de
    /// mensagens não pode esperar disco a cada retrato) e isto é uma consulta
    /// ao banco.
    private func refreshContactPoolIfNeeded() async {
        let atuais = Set(accounts.map(\.id))
        guard contactPoolAccountIDs != atuais else { return }
        contactPoolAccountIDs = atuais
        await refreshContactPool()
    }

    /// A consulta em si, sempre a mais nova vence.
    ///
    /// **Sem porta** (fixtures e todo teste que não passa uma), o catálogo é
    /// `Fixtures.contacts` — o Marco 1 intacto. **Com porta**, quem decide se
    /// há conta é ela: `nil` de volta é "o banco não tem conta nenhuma", e
    /// cai no mesmo `Fixtures.contacts`; uma lista (mesmo vazia) é o
    /// catálogo real.
    private func refreshContactPool() async {
        contactPoolGeneration += 1
        let geracao = contactPoolGeneration
        guard let contactPort else {
            contactPool = Fixtures.contacts
            return
        }
        do {
            let contatos = try await contactPort.contacts(accountID: nil)
            // O carimbo: entre o `await` acima e esta linha outra troca de
            // conta pode ter começado uma segunda consulta. Se essa outra já
            // respondeu, gravar aqui por cima devolveria o catálogo à conta
            // velha — a mesma guarda de `refreshBodyMatches()`, sobre o
            // conjunto de contas em vez do termo de busca.
            guard geracao == contactPoolGeneration else { return }
            contactPool = contatos ?? Fixtures.contacts
        } catch {
            guard geracao == contactPoolGeneration else { return }
            report(error)
        }
    }

    /// Aplica um retrato inteiro, de uma vez.
    ///
    /// Atômico de propósito, como o `load()` do Marco 1 já era: ou as quatro
    /// listas mudam, ou nenhuma muda.
    /// `internal`, e não `private`: as três guardas que este método carrega —
    /// a conta filtrada que saiu, a pasta aberta que sumiu, a seleção que caiu
    /// fora da visão — são sobre **um retrato chegando**, e é assim que o teste
    /// precisa as encenar. Pelo caminho público (`observe()`) não há como
    /// escolher um filtro *entre* dois retratos de uma sequência já montada, e
    /// um teste que dependesse do tempo entre eles seria intermitente.
    func apply(_ snapshot: MailSnapshot) {
        accounts = snapshot.accounts
        let incoming = reconcilingPendingRuleActions(in: snapshot.messages)
        let ids = Set(incoming.map(\.id))
        if bodyStore.count != ids.count {
            bodyStore = bodyStore.filter { ids.contains($0.key) }
        }
        conversationPages.removeAll(keepingCapacity: true)
        rebuildIndexOnNextDidSet = true
        messages = incoming
        sourceAgenda = snapshot.agenda
        agenda = mergedAgenda(combinedAgenda()).map(overlayCancelled)
        pendingItems = snapshot.pendingItems
        folders = snapshot.folders
        loadError = nil
        // A pasta que sumiu do servidor (apagada no webmail, renomeada) não pode
        // deixar a lista filtrada por um lugar que já não existe — a mesma
        // armadilha sem saída do filtro de conta logo abaixo, e a mesma saída.
        if let aberta = selectedFolderID,
           !snapshot.folders.contains(where: { $0.id == aberta }) {
            selectedFolderID = nil
        }
        // Filtro apontando para uma conta que não existe mais é armadilha sem
        // saída, e ela só aparece quando a fonte é o banco: remover a conta que
        // está filtrando deixaria a lista vazia, o leitor vazio — e o "Limpar
        // filtro" mora no menu de contexto **da linha da conta**, que sumiu
        // junto. A pessoa ficaria com um app que parece quebrado e sem nada
        // para clicar.
        //
        // Aqui, e não em `remove`: quem tira a conta é o `AccountDirector`, do
        // outro lado do banco, e o retrato é o único lugar por onde essa
        // remoção chega à tela.
        if let filtrada = selectedAccountID,
           !snapshot.accounts.contains(where: { $0.id == filtrada }) {
            selectedAccountID = nil
        }
        // O protótipo abre com uma mensagem já aberta no leitor
        // (`state = { … selected: 'm1' … }`, a primeira da caixa "hoje").
        // O estado vazio fica reservado para uma caixa de fato vazia.
        selectDefaultMessage()
        applyRulesToNewMessages()
    }

    /// Executa regras somente sobre mensagens que chegaram depois do primeiro
    /// retrato desta sessão. A mutação usa os mesmos caminhos públicos da UI,
    /// portanto atualiza a tela imediatamente e enfileira a projeção no
    /// servidor em vez de criar um segundo protocolo de escrita.
    ///
    /// Limite intencional deste incremento: `messageIDsSeenByRules` é memória
    /// de sessão, não um ledger SQLite. Portanto a decisão de disparar uma
    /// regra ainda não sobrevive a uma reinicialização; o que já entrou no
    /// outbox sobrevive e é repetido com segurança pelo seu `Message-ID`.
    /// A persistência de execuções de regra precisa de uma migração própria.
    private func applyRulesToNewMessages() {
        let currentIDs = Set(messages.map(\.id))
        guard let known = messageIDsSeenByRules else {
            messageIDsSeenByRules = currentIDs
            return
        }
        messageIDsSeenByRules = known.union(currentIDs)
        guard let emailRules, !emailRules.rules.isEmpty else { return }

        let arrivals = messages.filter { message in
            !known.contains(message.id)
                && message.bucket != .sent
                && message.bucket != .trash
                && message.bucket != .drafts
        }
        for arrival in arrivals {
            let matchingRules = emailRules.matchingRules(for: arrival)
            let actions = matchingRules.flatMap(\.actions)
            let forwardingRules = matchingRules.compactMap(\.forwarding)
            // Duas regras que casam não podem mover a mesma mensagem para dois
            // destinos. A ordem persistida já é a prioridade do matcher, então
            // o primeiro destino vence de forma estável.
            let moveDestination = matchingRules.compactMap(\.moveDestination).first
            guard !actions.isEmpty || !forwardingRules.isEmpty || moveDestination != nil else { continue }

            if !actions.isEmpty {
                pendingRuleActions[arrival.id] = Set(actions)
            }
            if actions.contains(.markRead) { setRead(true, for: arrival.id) }
            if actions.contains(.flag) { setFlagged(true, for: arrival.id) }
            if actions.contains(.archive),
               let current = messages.first(where: { $0.id == arrival.id }),
               current.bucket != .archived {
                move(current, to: .archived)
            }

            applyRuleForwarding(forwardingRules, to: arrival)

            if let moveDestination, !moveDestination.isNoOp(for: arrival) {
                pendingRuleMoveDestinations[arrival.id] = moveDestination
                applyRuleMove(moveDestination, to: arrival)
            }
        }
    }

    /// Encaminha uma nova mensagem pelo outbox normal. Cada endereço entra uma
    /// vez mesmo se duas regras que casam carregarem o mesmo destino. O outbox
    /// preserva o `Message-ID` da cópia que entrou na fila, portanto o retry de
    /// rede não envia uma segunda cópia.
    private func applyRuleForwarding(
        _ forwardings: [EmailRuleForwarding], to message: Message
    ) {
        guard let account = account(message.accountID) else { return }
        let localAddresses = Set(accounts.map(\.address).map(SenderTrust.normalize))
        var recipients = Set<String>()

        for forwarding in forwardings {
            guard let recipient = forwarding.validatedAddress else { continue }
            let normalizedRecipient = SenderTrust.normalize(recipient)
            // Não encaminhar de volta à própria conta, a outra conta local ou
            // ao remetente que acabou de trazer a mensagem: são os três ciclos
            // mais comuns em automações de caixa de entrada.
            guard !localAddresses.contains(normalizedRecipient),
                  normalizedRecipient != SenderTrust.normalize(message.from.address),
                  recipients.insert(normalizedRecipient).inserted,
                  let outgoing = ruleForwardMessage(
                      recipient: recipient, account: account, original: message
                  )
            else { continue }
            _ = send(outgoing)
        }
    }

    /// A cópia automática é uma mensagem nova, nunca o MIME recebido: não
    /// carrega Cc/Cco, anexos ou cabeçalhos do original. Além de preservar a
    /// privacidade, isto impede que um Bcc recebido atravesse a automação.
    private func ruleForwardMessage(
        recipient: String, account: Account, original: Message
    ) -> OutgoingMessage? {
        guard let safeRecipient = EmailRuleForwarding.normalizedAddress(recipient) else { return nil }
        let seed = ComposerSeed.forward(
            of: original, dateLabel: DateLabels.eventDate(original.receivedAt)
        )
        return OutgoingMessage(
            messageID: OutgoingMessage.newMessageID(for: account.address),
            accountID: account.id,
            from: OutgoingAddress(name: account.displayName, address: account.address),
            to: [OutgoingAddress(name: "", address: safeRecipient)],
            subject: seed.subject,
            plainText: seed.body.trimmingCharacters(in: .newlines)
        )
    }

    /// Executa a mesma operação que um gesto "Mover para…". O destino nasce
    /// da descoberta real de pastas/marcadores e já carrega a origem INBOX que
    /// o Gmail precisa remover; IMAP, por sua vez, usa o move de pasta normal.
    private func applyRuleMove(_ destination: SwipeMoveDestination, to message: Message) {
        switch destination.transport {
        case .imapFolder:
            place(message, in: destination.target.folder, mode: .move)
        case .gmailLabelFromInbox:
            guard let source = destination.source else { return }
            moveGmail(message, from: source.folder, to: destination.target.folder)
        }
    }

    /// Mescla a confirmação ainda pendente sobre um retrato novo sem emitir
    /// outro comando. `MailCommandDispatcher` pode estar alguns instantes
    /// atrás do stream do banco; sem essa reconciliação, um retrato repetido
    /// apagaria o estado otimista logo depois de a regra agir.
    private func reconcilingPendingRuleActions(in incoming: [Message]) -> [Message] {
        guard !pendingRuleActions.isEmpty || !pendingRuleMoveDestinations.isEmpty else { return incoming }

        var remaining = pendingRuleActions
        var remainingMoves = pendingRuleMoveDestinations
        var reconciled: [Message] = []
        reconciled.reserveCapacity(incoming.count)

        for message in incoming {
            var current = message
            if let actions = remaining[message.id] {
                // Uma exclusão vence uma ação local pendente: reintroduzir uma
                // mensagem na caixa Arquivados depois de ela ter ido para Lixeira
                // seria mais surpreendente do que esperar a confirmação anterior.
                if message.bucket == .trash || ruleActionsAreReflected(actions, by: message) {
                    remaining.removeValue(forKey: message.id)
                } else {
                    let orderedActions = EmailRuleAction.allCases.filter(actions.contains)
                    current = EmailRuleMatcher.apply(orderedActions, to: current)
                }
            }

            if let destination = remainingMoves[message.id] {
                if message.bucket == .trash || destination.isNoOp(for: message) {
                    remainingMoves.removeValue(forKey: message.id)
                } else {
                    current = projectedRuleMove(destination, on: current)
                }
            }
            reconciled.append(current)
        }

        // Se a mensagem desapareceu da fonte, não há estado para manter em
        // sobreposição nesta sessão.
        let incomingIDs = Set(incoming.map(\.id))
        pendingRuleActions = remaining.filter { incomingIDs.contains($0.key) }
        pendingRuleMoveDestinations = remainingMoves.filter { incomingIDs.contains($0.key) }
        return reconciled
    }

    private func projectedRuleMove(
        _ destination: SwipeMoveDestination, on message: Message
    ) -> Message {
        switch destination.transport {
        case .imapFolder:
            return placing(message, in: destination.target.folder, mode: .move)
        case .gmailLabelFromInbox:
            guard let source = destination.source else { return message }
            return movingGmail(message, from: source.folder, to: destination.target.folder)
        }
    }

    private func ruleActionsAreReflected(
        _ actions: Set<EmailRuleAction>, by message: Message
    ) -> Bool {
        actions.allSatisfy { action in
            switch action {
            case .markRead:
                message.isRead
            case .archive:
                message.bucket == .archived
            case .flag:
                message.isFlagged
            }
        }
    }

    /// Uma escolha explícita da pessoa no sentido contrário vence o retrato
    /// otimista de uma regra que ainda não voltou do banco. A ação no mesmo
    /// sentido não precisa limpar nada — a confirmação da fonte faz isso.
    private func discardPendingRuleAction(_ action: EmailRuleAction, for messageID: String) {
        guard var actions = pendingRuleActions[messageID] else { return }
        actions.remove(action)
        if actions.isEmpty {
            pendingRuleActions.removeValue(forKey: messageID)
        } else {
            pendingRuleActions[messageID] = actions
        }
    }

    /// Põe o erro na tela — **a não ser** que ele seja um cancelamento.
    ///
    /// A lição da Task 12: cancelar é o caminho normal de saída de uma
    /// observação (a janela fechou, a conta saiu, a tecla seguinte chegou), e
    /// escrever estado de recuperação nele deixaria a janela de Contas
    /// anunciando "A operação foi cancelada" como se algo tivesse falhado.
    /// Cancelamento não é falha, e quem cancelou não pediu aviso nenhum.
    private func report(_ error: any Error) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        loadError = error.localizedDescription
    }

    /// Mensagens da caixa atual que casam com a busca, mais recentes primeiro.
    public var visibleMessages: [Message] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces)
        // Um único retrato do relógio por leitura evita que a chave e o
        // predicado discordem se a chamada atravessar a meia-noite.
        let referenceDay = agendaReferenceDay()
        let key = visibleCacheKey(query: normalizedQuery, referenceDay: referenceDay)
        if let cached = visibleMessagesCache, cached.key == key {
            return cached.value
        }
        let result = messages
            .filter {
                matchesCurrentView($0, referenceDay: referenceDay, normalizedQuery: normalizedQuery)
            }
            .sorted { $0.receivedAt > $1.receivedAt }
        visibleMessagesCache = (key, result)
        return result
    }

    /// A mensagem entra no recorte aberto agora? Uma função só, usada pela
    /// lista paginada e por `selectDefaultMessage`, para Tudo não montar um
    /// array de dezenas de milhares só para saber se a seleção ainda vale.
    private func matchesCurrentView(_ message: Message) -> Bool {
        matchesCurrentView(
            message,
            referenceDay: agendaReferenceDay(),
            normalizedQuery: query.trimmingCharacters(in: .whitespaces)
        )
    }

    private func matchesCurrentView(
        _ message: Message,
        referenceDay: Date,
        normalizedQuery: String
    ) -> Bool {
        guard isInCurrentViewBeforeCategory(
            message, referenceDay: referenceDay, normalizedQuery: normalizedQuery
        ) else { return false }
        if bucket == .today, let categoryFilter {
            return resolvedCategory(for: message) == categoryFilter
        }
        return true
    }

    /// O recorte compartilhado pela lista e pelas contagens das cápsulas. A
    /// categoria fica deliberadamente de fora para cada cápsula poder dizer
    /// quantas mensagens abrirá sem ser afetada pela cápsula já selecionada.
    private func isInCurrentViewBeforeCategory(
        _ message: Message,
        referenceDay: Date,
        normalizedQuery: String
    ) -> Bool {
        if searchesEverywhereNow {
            if let selectedAccountID, message.accountID != selectedAccountID { return false }
            return matches(message, normalizedQuery)
        }
        guard isInBucket(message, bucket: bucket, referenceDay: referenceDay) else { return false }
        if let selectedAccountID, message.accountID != selectedAccountID { return false }
        if let selectedFolderID, !message.folderIDs.contains(selectedFolderID) { return false }
        return normalizedQuery.isEmpty || matches(message, normalizedQuery)
    }

    /// Categoria efetiva da mensagem. A saída persistida da análise local
    /// vence; enquanto ela ainda não chegou, assunto e remetente dão um
    /// fallback imediato e conservador, terminando em Principal. O nome da
    /// pasta é ignorado: um provedor pode colocar uma conversa de cliente na
    /// pasta Newsletter.
    public func resolvedCategory(for message: Message) -> MailCategory {
        MailCategory.resolve(message: message)
    }

    /// Quantas mensagens uma categoria mostrará no recorte corrente de Hoje.
    /// `nil` representa Todos. Conta, pasta e busca continuam valendo; somente
    /// a categoria atualmente selecionada é ignorada.
    public func categoryCount(_ category: MailCategory?) -> Int {
        let referenceDay = agendaReferenceDay()
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces)
        let index = messageListIndex()
        var n = 0
        for i in 0..<index.ids.count {
            guard isInBucket(
                messageBucket: index.buckets[i],
                receivedAt: index.dates[i],
                folderIDs: index.folderIDs[i],
                accountID: index.accountIDs[i],
                bucket: .today,
                referenceDay: referenceDay
            ) else { continue }
            if let selectedAccountID, index.accountIDs[i] != selectedAccountID { continue }
            if let selectedFolderID, !index.folderIDs[i].contains(selectedFolderID) { continue }
            if !normalizedQuery.isEmpty {
                guard matches(messages[i], normalizedQuery) else { continue }
            }
            guard let category else {
                n += 1
                continue
            }
            if resolvedCategory(for: messages[i]) == category { n += 1 }
        }
        return n
    }

    /// A projeção do provedor usa `.today` para representar Inbox. Na tela,
    /// Hoje é o recorte do **dia local corrente**: Inbox de hoje, e o que o
    /// IMAP entregou numa subpasta (grava `.archived`, mas ainda chegou
    /// hoje). No Gmail, "Mover para marcador" tira `INBOX` e aplica o
    /// rótulo — isso é arquivar, e a mensagem some de Hoje. Arquivar uma
    /// Inbox continua saindo da lista. Depois, Enviadas, Rascunhos e Lixeira
    /// ficam de fora — são destinos explícitos, não "ainda não vi".
    ///
    /// `receivedAt` é um instante absoluto vindo de Gmail/IMAP. Compará-lo com
    /// `Calendar` (e não por 86.400 segundos ou dia UTC) preserva meia-noite e
    /// horário de verão. As demais caixas, especialmente Depois, mantêm sua
    /// semântica persistida e não recebem corte temporal.
    private func isInBucket(
        _ message: Message,
        bucket: TriageBucket,
        referenceDay: Date
    ) -> Bool {
        isInBucket(
            messageBucket: message.bucket,
            receivedAt: message.receivedAt,
            folderIDs: message.folderIDs,
            accountID: message.accountID,
            bucket: bucket,
            referenceDay: referenceDay
        )
    }

    private func isInBucket(
        messageBucket: TriageBucket,
        receivedAt: Date,
        folderIDs: [String],
        accountID: String,
        bucket: TriageBucket,
        referenceDay: Date
    ) -> Bool {
        if bucket == .today {
            switch messageBucket {
            case .later, .trash, .drafts, .junk:
                return false
            case .sent:
                // RSVP / mail para si: o Gmail deixa INBOX+SENT. A cópia da
                // caixa é caixa — Enviadas sem INBOX continua fora de Hoje.
                guard Calendar.current.isDate(receivedAt, inSameDayAs: referenceDay) else {
                    return false
                }
                return belongsToFolder(role: .inbox, folderIDs: folderIDs)
            case .today, .all:
                return Calendar.current.isDate(receivedAt, inSameDayAs: referenceDay)
            case .archived:
                guard Calendar.current.isDate(receivedAt, inSameDayAs: referenceDay) else {
                    return false
                }
                return arrivedInImapUserFolder(folderIDs, accountID: accountID)
            }
        }
        if bucket == .all {
            if messageBucket == .trash
                || messageBucket == .drafts
                || messageBucket == .junk
            {
                return false
            }
            if messageBucket == .sent {
                return belongsToFolder(role: .inbox, folderIDs: folderIDs)
                    && !belongsToJunkFolder(folderIDs)
            }
            // Projeção antiga gravava spam como Arquivado. A pertinência à
            // pasta de lixo ainda o tira de Tudo — senão a caixa unificada
            // só limpa depois do próximo sync.
            if belongsToJunkFolder(folderIDs) { return false }
            return true
        }
        if bucket == .junk {
            return messageBucket == .junk || belongsToJunkFolder(folderIDs)
        }
        if bucket == .sent {
            return messageBucket == .sent
                || belongsToFolder(role: .sent, folderIDs: folderIDs)
        }
        return messageBucket == bucket
    }

    /// Só o IMAP: a mensagem nasceu numa pasta da pessoa, não na Inbox.
    /// Gmail trata marcador como arquivo — "Mover para marcador" tira de
    /// Hoje, mesmo que o rótulo seja pasta `.other` e o dia seja hoje.
    private func arrivedInImapUserFolder(_ folderIDs: [String], accountID: String) -> Bool {
        guard !folderIDs.isEmpty,
              accounts.contains(where: { $0.id == accountID && $0.provider == .imap })
        else { return false }
        let owned = folders.filter { folderIDs.contains($0.id) }
        if owned.contains(where: { $0.role == .inbox }) { return false }
        return owned.contains { $0.role == .other }
    }

    /// A mensagem está na pasta de spam do provedor, mesmo que o bucket
    /// gravado ainda seja Arquivado (carga antiga).
    private func belongsToJunkFolder(_ folderIDs: [String]) -> Bool {
        belongsToFolder(role: .junk, folderIDs: folderIDs)
    }

    private func belongsToFolder(role: FolderRole, folderIDs: [String]) -> Bool {
        guard !folderIDs.isEmpty else { return false }
        return folders.contains { folderIDs.contains($0.id) && $0.role == role }
    }

    /// Predicado público para consumidores que montam projeções da mesma
    /// caixa, como o contexto factual do assistente. Evita que outro recurso
    /// volte a interpretar todo INBOX como Hoje.
    public func includes(_ message: Message, in bucket: TriageBucket) -> Bool {
        isInBucket(message, bucket: bucket, referenceDay: agendaReferenceDay())
    }

    private func visibleCacheKey(
        query: String? = nil,
        referenceDay: Date? = nil
    ) -> VisibleCacheKey {
        let reference = referenceDay ?? agendaReferenceDay()
        return VisibleCacheKey(
            messagesRevision: messagesRevision,
            bodyHitsRevision: bodyHitsRevision,
            bucket: bucket.rawValue,
            referenceDayStart: Calendar.current.startOfDay(for: reference),
            accountID: selectedAccountID,
            folderID: selectedFolderID,
            category: bucket == .today ? categoryFilter?.rawValue : nil,
            query: query ?? self.query.trimmingCharacters(in: .whitespaces),
            searchEverywhere: searchEverywhere
        )
    }

    // MARK: - As pastas do provedor

    /// As pastas de uma conta, na ordem em que a barra as desenha e já com o
    /// contador de não lidas.
    ///
    /// O contador conta **a pasta inteira**, e não o recorte da caixa aberta:
    /// a pasta é o mapa do servidor, e "3 não lidas em Faturas" tem de dizer o
    /// mesmo que o webmail diz, esteja a lista mostrando Hoje ou Arquivado.
    /// Enviadas e Lixeira ficam de fora da regra por nada: uma mensagem não
    /// lida é uma mensagem não lida, esteja onde estiver.
    public func folders(of accountID: String) -> [MailFolder] {
        resetCountsCacheIfNeeded()
        if let cached = foldersByAccountCache[accountID] { return cached }
        let index = messageListIndex()
        var unreadByFolder: [String: Int] = [:]
        for i in 0..<index.ids.count {
            guard index.accountIDs[i] == accountID, !index.isRead[i] else { continue }
            for folderID in index.folderIDs[i] {
                unreadByFolder[folderID, default: 0] += 1
            }
        }
        let daConta = folders.filter { $0.accountID == accountID }
        let result = MailFolder.ordered(daConta.map { pasta in
            pasta.withUnreadCount(unreadByFolder[pasta.id, default: 0])
        })
        foldersByAccountCache[accountID] = result
        return result
    }

    /// Quantas mensagens não lidas esta pasta tem.
    public func unreadCount(inFolder folderID: String) -> Int {
        let index = messageListIndex()
        var n = 0
        for i in 0..<index.ids.count {
            if !index.isRead[i], index.folderIDs[i].contains(folderID) { n += 1 }
        }
        return n
    }

    /// As pastas desta conta estão abertas na barra?
    public func foldersExpanded(_ accountID: String) -> Bool {
        expandedAccountIDs.contains(accountID)
    }

    /// Abre ou fecha as pastas de uma conta.
    ///
    /// Fechar **não** desfaz o filtro: quem abriu "Faturas" e recolheu a conta
    /// para ganhar altura na barra continua vendo Faturas, e a linha da conta
    /// continua realçada. Recolher é sobre espaço, não sobre o que a lista
    /// mostra.
    public func toggleFolders(of accountID: String) {
        if expandedAccountIDs.contains(accountID) {
            expandedAccountIDs.remove(accountID)
        } else {
            expandedAccountIDs.insert(accountID)
        }
    }

    /// Abre uma pasta do provedor — e clicar de novo na mesma a fecha, como a
    /// linha da conta já fazia com o filtro dela.
    ///
    /// Abrir uma pasta **acende o filtro da conta dela**: uma pasta pertence a
    /// uma conta, e mostrar "Faturas" da conta A junto com as mensagens da
    /// conta B seria a lista respondendo a uma pergunta que ninguém fez. É
    /// também o que faz a agenda seguir junto, pelo mesmo `visibleAgenda` de
    /// sempre — ela filtra por conta, e a conta acabou de ser escolhida.
    public func select(folder id: String?) {
        if selectedFolderID == id {
            selectedFolderID = nil
        } else {
            selectedFolderID = id
            if let id, let pasta = folders.first(where: { $0.id == id }) {
                selectedAccountID = pasta.accountID
                expandedAccountIDs.insert(pasta.accountID)
                // Pastas que Tudo recusa: abrir Spam/Lixeira/Enviadas com a
                // visão Tudo ainda ligada deixaria a lista vazia.
                switch pasta.role {
                case .junk: self.bucket = .junk
                case .trash: self.bucket = .trash
                case .sent: self.bucket = .sent
                case .drafts: self.bucket = .drafts
                default: break
                }
            }
        }
        selectDefaultMessage()
        pruneChecked()
    }

    // MARK: - As conversas

    /// A lista **como ela é desenhada**: uma linha por conversa, dentro da
    /// caixa atual.
    ///
    /// Derivada de `visibleMessages`, e não uma segunda consulta: o filtro de
    /// caixa, o de conta e a busca já foram aplicados lá, e agrupar por cima
    /// é o que garante que a contagem da linha ("3") conte o que a caixa
    /// mostra — arquivar uma das três não pode deixar o selo dizendo três.
    public var visibleConversations: [Conversation] {
        let key = visibleCacheKey()
        if let cached = visibleConversationsCache, cached.key == key {
            return cached.value
        }
        let result = Conversation.build(from: visibleMessages)
        visibleConversationsCache = (key, result)
        return result
    }

    /// As primeiras `limit` conversas da caixa, mais a contagem da caixa
    /// inteira. Um passe só: não aloca o recorte visível nem agrupa Tudo.
    ///
    /// A página fica por recorte: Tudo → Hoje → Tudo devolve a mesma página
    /// sem varrer a caixa de novo.
    public func conversationPage(limit: Int) -> ConversationPage {
        let cap = max(1, limit)
        resetConversationPagesIfNeeded()
        let recorte = RecortePageKey(visibleCacheKey())
        if let cached = conversationPages[recorte] {
            if cached.limit >= cap {
                let prefix = Array(cached.page.conversations.prefix(cap))
                let live = rehydratePage(prefix)
                if live.count == prefix.count {
                    return ConversationPage(
                        conversations: live,
                        messageCount: live.reduce(0) { $0 + $1.count },
                        hasMore: cached.page.conversations.count > cap || cached.page.hasMore
                    )
                }
            }
        }
        let page = buildConversationPage(limit: cap)
        conversationPages[recorte] = (cap, page)
        return page
    }

    private func resetConversationPagesIfNeeded() {
        // Só a busca invalida a página. Ler um email (isRead) não pode
        // obrigar Tudo a reconstruir a caixa no clique seguinte.
        guard conversationPagesStamp.bodyHits != bodyHitsRevision else { return }
        conversationPagesStamp.bodyHits = bodyHitsRevision
        conversationPages.removeAll(keepingCapacity: true)
    }

    private func messageListIndex() -> MessageListIndex {
        if let cached = listIndexCache, cached.revision == messagesRevision {
            return cached
        }
        let built = makeListIndex()
        listIndexCache = built
        return built
    }

    private func makeListIndex() -> MessageListIndex {
        let n = messages.count
        var dates: [Date] = []
        var buckets: [TriageBucket] = []
        var accountIDs: [String] = []
        var conversationKeys: [String] = []
        var folderIDs: [[String]] = []
        var ids: [String] = []
        var isRead: [Bool] = []
        dates.reserveCapacity(n)
        buckets.reserveCapacity(n)
        accountIDs.reserveCapacity(n)
        conversationKeys.reserveCapacity(n)
        folderIDs.reserveCapacity(n)
        ids.reserveCapacity(n)
        isRead.reserveCapacity(n)
        var idIndex: [String: Int] = [:]
        idIndex.reserveCapacity(n)
        for (i, message) in messages.enumerated() {
            dates.append(message.receivedAt)
            buckets.append(message.bucket)
            accountIDs.append(message.accountID)
            conversationKeys.append(message.conversationKey)
            folderIDs.append(message.folderIDs)
            ids.append(message.id)
            isRead.append(message.isRead)
            idIndex[message.id] = i
        }
        let ranked = dates.indices.sorted { dates[$0] > dates[$1] }
        let index = MessageListIndex(
            revision: messagesRevision,
            dates: dates,
            buckets: buckets,
            accountIDs: accountIDs,
            conversationKeys: conversationKeys,
            folderIDs: folderIDs,
            ids: ids,
            isRead: isRead,
            idIndex: idIndex,
            ranked: ranked
        )
        listIndexCache = index
        return index
    }

    private func matchesCurrentView(
        at i: Int,
        index: MessageListIndex,
        referenceDay: Date,
        normalizedQuery: String
    ) -> Bool {
        if searchesEverywhereNow {
            if let selectedAccountID, index.accountIDs[i] != selectedAccountID { return false }
            return matches(messages[i], normalizedQuery)
        }
        guard isInBucket(
            messageBucket: index.buckets[i],
            receivedAt: index.dates[i],
            folderIDs: index.folderIDs[i],
            accountID: index.accountIDs[i],
            bucket: bucket,
            referenceDay: referenceDay
        ) else { return false }
        if let selectedAccountID, index.accountIDs[i] != selectedAccountID { return false }
        if let selectedFolderID, !index.folderIDs[i].contains(selectedFolderID) { return false }
        if !normalizedQuery.isEmpty {
            guard matches(messages[i], normalizedQuery) else { return false }
        }
        if bucket == .today, let categoryFilter {
            return resolvedCategory(for: messages[i]) == categoryFilter
        }
        return true
    }

    private func buildConversationPage(limit: Int) -> ConversationPage {
        conversationPageBuildCount += 1
        let referenceDay = agendaReferenceDay()
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces)
        let index = messageListIndex()

        var order: [String] = []
        var latest: [String: Message] = [:]
        var hasMore = false
        order.reserveCapacity(min(limit, 32))

        for i in index.ranked {
            guard matchesCurrentView(
                at: i, index: index,
                referenceDay: referenceDay, normalizedQuery: normalizedQuery
            ) else { continue }
            let key = index.conversationKeys[i]
            if latest[key] != nil { continue }
            if order.count >= limit {
                hasMore = true
                break
            }
            order.append(key)
            latest[key] = messages[i].withoutHeavyPayload()
        }

        let conversations = order.compactMap { key in
            latest[key].flatMap { Conversation(key: key, messages: [$0]) }
        }
        let loaded = conversations.reduce(0) { $0 + $1.count }
        return ConversationPage(
            conversations: conversations, messageCount: loaded, hasMore: hasMore
        )
    }

    private func rehydratePage(_ conversations: [Conversation]) -> [Conversation] {
        guard let index = listIndexCache, index.revision == messagesRevision
                || index.ids.count == messages.count
        else { return [] }
        return conversations.compactMap { conv -> Conversation? in
            guard let i = index.idIndex[conv.latest.id] else { return nil }
            return Conversation(key: conv.key, messages: [messages[i].withoutHeavyPayload()])
        }
    }

    /// A conversa a que uma mensagem pertence, dentro do recorte visível.
    ///
    /// `nil` quando a mensagem não está na visão — o que é normal: o leitor
    /// mostra a mensagem revelada por "Ir para o email de origem" antes de a
    /// lista alcançá-la.
    public func conversation(of messageID: String) -> Conversation? {
        buildConversation(containing: messageID)
    }

    /// Contexto factual para o assistente: o corpo que o leitor já buscou,
    /// nunca a linha da lista. A lista não guarda HTML de propósito — gravar
    /// o payload ali invalidava o cache de Tudo. Quem pergunta à IA e usa
    /// `messages.first` manda só o snippet, e o modelo acha o email incompleto.
    public func assistantMailContext(for messageID: String) -> AssistantMailContext? {
        guard let message = message(messageID) else { return nil }
        if let conversation = conversation(of: messageID), conversation.count > 1 {
            return AssistantMailContext(conversation: conversation)
        }
        return AssistantMailContext(message: message)
    }

    private func buildConversation(containing messageID: String) -> Conversation? {
        let referenceDay = agendaReferenceDay()
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces)
        if let cached = listIndexCache, cached.revision == messagesRevision,
           let seed = cached.idIndex[messageID] {
            let threadKey = cached.conversationKeys[seed]
            var thread: [Message] = []
            for i in 0..<cached.ids.count {
                guard cached.conversationKeys[i] == threadKey,
                      matchesCurrentView(
                        at: i, index: cached,
                        referenceDay: referenceDay, normalizedQuery: normalizedQuery
                      )
                else { continue }
                thread.append(messages[i])
            }
            guard thread.contains(where: { $0.id == messageID }) else { return nil }
            thread.sort {
                $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt < $1.receivedAt
            }
            return Conversation(key: threadKey, messages: thread.map(hydrate))
        }
        guard let seed = messages.first(where: { $0.id == messageID }) else { return nil }
        let threadKey = seed.conversationKey
        var thread: [Message] = []
        for message in messages {
            guard message.conversationKey == threadKey,
                  matchesCurrentView(
                    message, referenceDay: referenceDay, normalizedQuery: normalizedQuery
                  )
            else { continue }
            thread.append(hydrate(message))
        }
        guard thread.contains(where: { $0.id == messageID }) else { return nil }
        thread.sort {
            $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt < $1.receivedAt
        }
        return Conversation(key: threadKey, messages: thread)
    }

    /// A conversa aberta no leitor.
    public var selectedConversation: Conversation? {
        guard let selectedMessageID else { return nil }
        return conversation(of: selectedMessageID)
    }

    /// As conversas marcadas que ainda estão na visão.
    public var checkedConversations: [Conversation] {
        let wanted = checkedConversationKeys
        return visibleConversations.filter { wanted.contains($0.key) }
    }

    public func isChecked(_ conversationKey: String) -> Bool {
        checkedConversationKeys.contains(conversationKey)
    }

    /// Todas as conversas visíveis estão marcadas? Caixa vazia é `false`.
    public var allVisibleChecked: Bool {
        guard !checkedConversationKeys.isEmpty else { return false }
        let visible = visibleConversations
        guard !visible.isEmpty else { return false }
        return visible.allSatisfy { checkedConversationKeys.contains($0.key) }
    }

    /// Algumas, mas não todas. É o estado misto do checkbox do cabeçalho.
    public var someVisibleChecked: Bool {
        guard !checkedConversationKeys.isEmpty else { return false }
        let visible = visibleConversations
        guard !visible.isEmpty else { return false }
        let n = visible.filter { checkedConversationKeys.contains($0.key) }.count
        return n > 0 && n < visible.count
    }

    /// Há alguma conversa marcada, nesta caixa ou noutra. A faixa de lote
    /// pergunta isto, e não se a caixa é Hoje: a seleção vale no sistema todo.
    public var hasChecked: Bool { !checkedConversationKeys.isEmpty }

    /// A conta comum das conversas marcadas. `nil` quando o lote mistura
    /// contas — aí "Mover para pasta" não tem um servidor só a quem falar.
    public var checkedAccountID: String? {
        let ids = Set(checkedConversations.map(\.latest.accountID))
        return ids.count == 1 ? ids.first : nil
    }

    public func toggleChecked(_ conversationKey: String) {
        if checkedConversationKeys.contains(conversationKey) {
            checkedConversationKeys.remove(conversationKey)
        } else {
            checkedConversationKeys.insert(conversationKey)
        }
    }

    public func selectAllVisible() {
        checkedConversationKeys = Set(visibleConversations.map(\.key))
    }

    public func clearChecked() {
        checkedConversationKeys = []
    }

    /// Marca todas se falta alguma; senão, limpa. É o clique do checkbox do
    /// cabeçalho da lista, em qualquer caixa.
    public func toggleSelectAllVisible() {
        if allVisibleChecked { clearChecked() } else { selectAllVisible() }
    }

    /// Descarta marcas que saíram da visão. Sem isto, trocar de Hoje para
    /// Depois deixaria um conjunto invisível governando a faixa de lote.
    private func pruneChecked() {
        guard !checkedConversationKeys.isEmpty else { return }
        let visible = Set(visibleConversations.map(\.key))
        checkedConversationKeys = checkedConversationKeys.intersection(visible)
    }

    /// O estado de triagem destas mensagens, agora. Quem vai agir sobre a
    /// conversa fotografa **antes**, pelo mesmo motivo de sempre: depois de
    /// arquivadas elas não sabem mais de que caixa vieram.
    public func states(of messageIDs: [String]) -> [MessageState] {
        let wanted = Set(messageIDs)
        return messages.filter { wanted.contains($0.id) }.map(MessageState.init)
    }

    /// O "Desfazer" de uma ação sobre a conversa: cada mensagem volta ao
    /// estado que ela tinha, e não ao estado da mais recente.
    ///
    /// Sem guarda contra id ausente, como `restoreDeleted`: desfazer o que já
    /// voltou (ou o que outra ação levou embora) não é erro, é o mesmo estado a
    /// que se pretendia chegar.
    public func restore(_ states: [MessageState]) {
        for state in states {
            setRead(state.isRead, for: state.messageID)
            setFlagged(state.isFlagged, for: state.messageID)
            guard let index = messages.firstIndex(where: { $0.id == state.messageID }) else {
                continue
            }
            move(messages[index], to: state.bucket)
        }
    }

    /// Move a conversa inteira. É o que arrastar ou arquivar **na linha da
    /// lista** faz: a linha é a conversa, e mover metade dela deixaria a outra
    /// metade na caixa, sozinha, com o mesmo assunto.
    ///
    /// **Uma chamada à porta, com todos os ids** — e não uma por mensagem: a
    /// porta já recebe `messageIDs`, e a fila de saída já sabe executar uma
    /// operação de vários ids. Ver `MailCommandPort`.
    ///
    /// As que já estão no destino ficam de fora da operação: é a mesma guarda
    /// que `move(_:to:)` faz por mensagem, aplicada ao conjunto.
    public func move(_ conversation: Conversation, to newBucket: TriageBucket) {
        let movendo = conversation.messages.filter { $0.bucket != newBucket }
        guard !movendo.isEmpty else { return }
        let positionBefore = visibleMessages.firstIndex { $0.id == conversation.latest.id }

        for (accountID, ids) in Self.porConta(movendo) {
            send { port in
                if newBucket == .trash {
                    try port.delete(accountID: accountID, messageIDs: ids)
                } else {
                    try port.move(to: newBucket, accountID: accountID, messageIDs: ids)
                }
            }
        }

        updateMessages(ids: Set(movendo.map(\.id))) { $0.withBucket(newBucket) }
        reselect(from: positionBefore, leaving: Set(conversation.messageIDs))
        pruneChecked()
    }

    /// Move uma conversa para uma pasta IMAP ou aplica um marcador Gmail.
    /// A pasta pertence a uma conta, então numa conversa que cruza contas a
    /// ação alcança somente as mensagens daquela conta — nunca manda ids de
    /// outro servidor para o provedor errado.
    public func place(
        _ conversation: Conversation,
        in folder: MailFolder,
        mode: FolderPlacement
    ) {
        let candidates = conversation.messages.filter { message in
            guard message.accountID == folder.accountID else { return false }
            return mode == .move || !message.folderIDs.contains(folder.id)
        }
        guard !candidates.isEmpty else { return }
        let positionBefore = visibleMessages.firstIndex { $0.id == conversation.latest.id }
        let ids = candidates.map(\.id)

        send { port in
            try port.place(
                in: folder, mode: mode,
                accountID: folder.accountID, messageIDs: ids
            )
        }

        updateMessages(ids: Set(ids)) { placing($0, in: folder, mode: mode) }
        reselect(from: positionBefore, leaving: Set(ids))
        pruneChecked()
    }

    /// “Mover para” do Gmail: troca somente o marcador que representa a
    /// localização aberta. Uma conversa pode misturar contas ou mensagens que
    /// não estão nessa origem; só as candidatas entram na operação.
    public func moveGmail(
        _ conversation: Conversation,
        from source: MailFolder,
        to destination: MailFolder
    ) {
        guard source.accountID == destination.accountID, source.id != destination.id else {
            return
        }
        let candidates = conversation.messages.filter {
            $0.accountID == source.accountID && $0.folderIDs.contains(source.id)
        }
        guard !candidates.isEmpty else { return }
        let positionBefore = visibleMessages.firstIndex { $0.id == conversation.latest.id }
        let ids = candidates.map(\.id)

        send { port in
            try port.moveGmailLabel(
                from: source, to: destination,
                accountID: source.accountID, messageIDs: ids
            )
        }
        updateMessages(ids: Set(ids)) { movingGmail($0, from: source, to: destination) }
        reselect(from: positionBefore, leaving: Set(ids))
        pruneChecked()
    }

    /// Marca a conversa inteira como lida (ou não lida).
    public func setRead(_ isRead: Bool, for conversation: Conversation) {
        let mudando = conversation.messages.filter { $0.isRead != isRead }
        guard !mudando.isEmpty else { return }
        for (accountID, ids) in Self.porConta(mudando) {
            send { port in try port.setRead(isRead, accountID: accountID, messageIDs: ids) }
        }
        updateMessages(ids: Set(mudando.map(\.id)), preservesListPages: true) { $0.withRead(isRead) }
    }

    /// Liga ou desliga a estrela da conversa inteira.
    public func setFlagged(_ isFlagged: Bool, for conversation: Conversation) {
        let mudando = conversation.messages.filter { $0.isFlagged != isFlagged }
        guard !mudando.isEmpty else { return }
        for (accountID, ids) in Self.porConta(mudando) {
            send { port in try port.setFlagged(isFlagged, accountID: accountID, messageIDs: ids) }
        }
        updateMessages(ids: Set(mudando.map(\.id)), preservesListPages: true) { $0.withFlagged(isFlagged) }
    }

    /// Apaga a conversa inteira de vez. Só faz sentido na Lixeira, como
    /// `deleteForever(_:)` — e é quem monta o menu que garante isso.
    public func deleteForever(_ conversation: Conversation) {
        let positionBefore = visibleMessages.firstIndex { $0.id == conversation.latest.id }
        for (accountID, ids) in Self.porConta(conversation.messages) {
            send { port in try port.deletePermanently(accountID: accountID, messageIDs: ids) }
        }
        for message in conversation.messages {
            deleted[message.id] = message
        }
        let indo = Set(conversation.messageIDs)
        messages.removeAll { indo.contains($0.id) }
        reselect(from: positionBefore, leaving: indo)
        pruneChecked()
    }

    /// Os ids agrupados por conta, na ordem em que as contas apareceram.
    ///
    /// Uma conversa **pode** cruzar contas — a mesma troca de emails chega no
    /// trabalho e no pessoal, e as duas mensagens compartilham a raiz de
    /// `References`. A porta é por conta; mandar os ids das duas numa chamada
    /// só faria o espelho procurar no servidor errado.
    /// Uma atribuição só em `messages`. Cada `messages[i] =` dispara a
    /// observação e refaz o recorte visível; numa thread de treze do GitHub
    /// isso eram treze redesenhos da caixa — a trava ao andar com as setas.
    private func updateMessages(
        ids: Set<String>,
        preservesListPages: Bool = false,
        _ transform: (Message) -> Message
    ) {
        guard !ids.isEmpty else { return }
        var found = false
        let next = messages.map { message -> Message in
            guard ids.contains(message.id) else { return message }
            found = true
            return transform(message)
        }
        guard found else { return }
        if preservesListPages { rebuildIndexOnNextDidSet = false }
        else { conversationPages.removeAll(keepingCapacity: true) }
        messages = next
        if preservesListPages { patchIndex(ids: ids) }
    }

    private func patchIndex(ids: Set<String>) {
        // `move` altera um bucket sem reconstruir o índice. Se o cache ainda
        // tiver a revisão anterior, copiar os buckets dele carimba a revisão
        // nova em cima da caixa antiga — e Hoje/Lixeira passam a mentir.
        guard let index = listIndexCache,
              index.ids.count == messages.count,
              index.revision == messagesRevision else {
            listIndexCache = makeListIndex()
            return
        }
        var isRead = index.isRead
        var buckets = index.buckets
        for id in ids {
            guard let i = index.idIndex[id] else { continue }
            let live = messages[i]
            isRead[i] = live.isRead
            buckets[i] = live.bucket
        }
        listIndexCache = MessageListIndex(
            revision: messagesRevision,
            dates: index.dates,
            buckets: buckets,
            accountIDs: index.accountIDs,
            conversationKeys: index.conversationKeys,
            folderIDs: index.folderIDs,
            ids: index.ids,
            isRead: isRead,
            idIndex: index.idIndex,
            ranked: index.ranked
        )
    }

    private static func porConta(_ messages: [Message]) -> [(String, [String])] {
        var order: [String] = []
        var byAccount: [String: [String]] = [:]
        for message in messages {
            if byAccount[message.accountID] == nil { order.append(message.accountID) }
            byAccount[message.accountID, default: []].append(message.id)
        }
        return order.map { ($0, byAccount[$0] ?? []) }
    }

    /// A seleção depois de uma ação que tirou a conversa da visão.
    ///
    /// A mesma regra de `move(_:to:)`: quem ocupou o lugar dela, ou a que ficou
    /// acima quando era a última. Só age quando a mensagem selecionada era uma
    /// das que saíram — arquivar uma conversa que não estava aberta não pode
    /// tirar a pessoa da que estava.
    private func reselect(from positionBefore: Int?, leaving ids: Set<String>) {
        guard let selectedMessageID, ids.contains(selectedMessageID) else { return }
        let remaining = visibleMessages
        guard !remaining.contains(where: { ids.contains($0.id) }) else { return }
        guard let positionBefore else {
            self.selectedMessageID = remaining.first?.id
            return
        }
        self.selectedMessageID = remaining.indices.contains(positionBefore)
            ? remaining[positionBefore].id
            : remaining.last?.id
    }

    /// A agenda depois do filtro de conta.
    ///
    /// Clicar numa caixa filtra a lista **e** a grade da agenda. O protótipo
    /// aplica `st.account` só à lista, mas isso é lacuna dele: uma caixa
    /// selecionada que não mexe na agenda deixa metade da janela mentindo sobre
    /// o que está sendo mostrado.
    public var visibleAgenda: [AgendaItem] {
        projectedAgenda().visible
    }

    /// A grade da aba Agenda: todos os calendários ligados, **sem** o filtro
    /// da caixa de email. Filtrar por conta de correio escondia Todoist,
    /// iCloud e o resto do macOS no momento em que uma caixa estava selecionada.
    public var calendarAgenda: [AgendaItem] {
        projectedAgenda().calendar
    }

    /// Uma passada só: coalescer a agenda inteira em cada `body` da grade
    /// (cabeçalho, mini-mês, semana, seletor) é o que congelava o `‹ ›`.
    private func projectedAgenda() -> (calendar: [AgendaItem], visible: [AgendaItem]) {
        let cache = agendaProjection
        let fingerprint = agendaProjectionFingerprint()
        if cache.fingerprint == fingerprint,
           cache.hidden == hiddenCalendarIDs,
           cache.concealed == concealedCalendarIDs,
           cache.selectedAccount == selectedAccountID
        {
            return (cache.calendar, cache.visible)
        }
        let hidden = hiddenCalendarIDs
        let concealed = concealedCalendarIDs
        let calendar = InviteAgenda.coalesce(
            agenda.filter { item in
                let id = calendarFilterID(for: item)
                return !hidden.contains(id) && !concealed.contains(id)
            }
        )
        let visible: [AgendaItem]
        if let selectedAccountID {
            visible = InviteAgenda.coalesce(agenda.filter { $0.accountID == selectedAccountID })
        } else {
            visible = InviteAgenda.coalesce(agenda)
        }
        cache.fingerprint = fingerprint
        cache.hidden = hidden
        cache.concealed = concealed
        cache.selectedAccount = selectedAccountID
        cache.calendar = calendar
        cache.visible = visible
        return (calendar, visible)
    }

    private func agendaProjectionFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(agenda.count)
        for item in agenda {
            hasher.combine(item.id)
            hasher.combine(item.dayOffset)
            hasher.combine(item.startMinute)
            hasher.combine(item.endMinute)
            hasher.combine(item.isCancelled)
            hasher.combine(item.calendarSequence)
            hasher.combine(item.calendarUID)
            hasher.combine(item.calendarID)
        }
        return hasher.finalize()
    }

    /// Calendários da lateral: os do macOS, os CalDAV das caixas IMAP, e um
    /// calendário OkamiUNI por conta que o EventKit não cobre (Zoho,
    /// Hostinger, Yahoo, Microsoft…).
    public var calendarsForSidebar: [ConnectedCalendar] {
        var list = connectedCalendars
        let calDAVAccounts = Set(list.compactMap { ConnectedCalendar.calDAVAccountID(from: $0.id) })
        for account in accounts where ConnectedCalendar.needsMailboxCalendar(account) {
            if calDAVAccounts.contains(account.id) { continue }
            let mailbox = ConnectedCalendar.mailbox(for: account)
            if !list.contains(where: { $0.id == mailbox.id }) {
                list.append(mailbox)
            }
        }
        if agenda.contains(where: { calendarFilterID(for: $0) == ConnectedCalendar.email.id }),
           !list.contains(where: { $0.id == ConnectedCalendar.email.id })
        {
            list.append(.email)
        }
        return list
    }

    /// A lista visível: sem os calendários que a pessoa ocultou.
    public var visibleCalendarsForSidebar: [ConnectedCalendar] {
        calendarsForSidebar.filter { !concealedCalendarIDs.contains($0.id) }
    }

    /// Os que foram para a seção Ocultos.
    public var concealedCalendarsForSidebar: [ConnectedCalendar] {
        calendarsForSidebar.filter { concealedCalendarIDs.contains($0.id) }
    }

    /// O calendário da lateral a que um compromisso pertence. Item sem
    /// `calendarID` de uma caixa IMAP cai no calendário OkamiUNI daquela
    /// conta — era isso que fazia Zoho e Hostinger existirem no correio e
    /// sumirem na Agenda.
    func calendarFilterID(for item: AgendaItem) -> String {
        if let id = item.calendarID { return id }
        if ConnectedCalendar.needsMailboxCalendar(account(item.accountID)) {
            return ConnectedCalendar.mailboxID(forAccountID: item.accountID)
        }
        return ConnectedCalendar.email.id
    }

    /// A cor da bolinha na lateral, para o bloco na grade pintar a mesma.
    /// Sem isto o Termin de Odette nascia no acento verde do tema — cor que
    /// nenhuma agenda da lista tem.
    public func calendarSwatchHex(for item: AgendaItem) -> String? {
        if let hex = item.calendarColorHex?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hex.isEmpty {
            return hex
        }
        let id = calendarFilterID(for: item)
        if let calendar = calendarsForSidebar.first(where: { $0.id == id }) {
            return calendar.colorHex
        }
        return account(item.accountID)?.tintLightHex
    }

    public func isCalendarEnabled(_ id: String) -> Bool {
        !hiddenCalendarIDs.contains(id)
    }

    public func toggleCalendar(_ id: String) {
        if hiddenCalendarIDs.contains(id) {
            hiddenCalendarIDs.remove(id)
        } else {
            hiddenCalendarIDs.insert(id)
        }
        calendarDefaults?.set(Array(hiddenCalendarIDs), forKey: Self.hiddenCalendarsKey)
    }

    public func isCalendarConcealed(_ id: String) -> Bool {
        concealedCalendarIDs.contains(id)
    }

    /// Some da lista e da trilha. Os compromissos saem da grade até a pessoa
    /// devolver o calendário em Ocultos.
    public func concealCalendar(_ id: String) {
        concealedCalendarIDs.insert(id)
        persistConcealedCalendars()
        collapsedCalendarSources.remove(Self.concealedCalendarsSection)
        calendarDefaults?.set(
            Array(collapsedCalendarSources), forKey: Self.collapsedCalendarSourcesKey
        )
    }

    public func revealCalendar(_ id: String) {
        concealedCalendarIDs.remove(id)
        persistConcealedCalendars()
    }

    private func persistConcealedCalendars() {
        calendarDefaults?.set(Array(concealedCalendarIDs), forKey: Self.concealedCalendarsKey)
    }

    public func calendarSourceExpanded(_ source: String) -> Bool {
        !collapsedCalendarSources.contains(source)
    }

    /// Recolher é só espaço na barra: os calendários do grupo continuam
    /// ligados ou desligados na grade.
    public func toggleCalendarSource(_ source: String) {
        if collapsedCalendarSources.contains(source) {
            collapsedCalendarSources.remove(source)
        } else {
            collapsedCalendarSources.insert(source)
        }
        calendarDefaults?.set(
            Array(collapsedCalendarSources), forKey: Self.collapsedCalendarSourcesKey
        )
    }

    /// Atualiza a agenda conectada. Sem `requestAuthorization`, a abertura só
    /// lê o estado do sistema — nunca dispara uma caixa de permissão por trás
    /// da tela. O botão visível da Agenda chama a mesma função com `true`.
    ///
    /// Mesmo sem autorização do EventKit a sincronização roda: CalDAV das
    /// caixas IMAP (Zoho, Yahoo, Fastmail) não depende do Calendário do macOS.
    public func refreshCalendar(requestAuthorization: Bool = false) async {
        guard let calendarSync else { return }
        calendarAvailability = .loading
        do {
            synchronizedAgenda = try await calendarSync.synchronize(
                referenceDay: agendaReferenceDay(), requestAuthorization: requestAuthorization
            )
            connectedCalendars = await calendarSync.calendars()
            calendarAvailability = await calendarSync.availability()
            agenda = mergedAgenda(combinedAgenda()).map(overlayCancelled)
        } catch {
            let reported = await calendarSync.availability()
            calendarAvailability = reported.isAvailable
                ? .unavailable(error.localizedDescription)
                : reported
        }
    }

    /// `pendingItems` depois do mesmo filtro de conta que `visibleAgenda`
    /// aplica. É o que a seção "Vindo do email" da trilha deve ler: seguindo
    /// o padrão de `visibleAgenda`, uma caixa selecionada não pode deixar a
    /// seção citando um item de outra conta.
    public var visiblePendingItems: [PendingItem] {
        guard let selectedAccountID else { return pendingItems }
        return pendingItems.filter { $0.accountID == selectedAccountID }
    }

    /// Recorte da aba Dashboard. Cacheado: o `body` da aba lia a caixa
    /// inteira várias vezes por quadro, e era isso que congelava a troca.
    public func dashboardFocus(nowMinute: Int) -> DashboardFocus {
        let revision = messagesRevision
        let account = selectedAccountID
        let pending = visiblePendingItems
        let agendaVisible = visibleAgenda
        let key = DashboardFocusCacheKey(
            messagesRevision: revision,
            accountID: account,
            nowMinute: nowMinute,
            agendaFingerprint: agendaProjectionFingerprint(),
            pendingCount: pending.count
        )
        if let cached = dashboardFocusCache, cached.key == key {
            return cached.value
        }
        let index = messageListIndex()
        var candidates: [Message] = []
        candidates.reserveCapacity(min(DashboardFocus.candidateCap, index.ranked.count))
        for i in index.ranked {
            if let account, index.accountIDs[i] != account { continue }
            switch index.buckets[i] {
            case .junk, .trash, .drafts, .sent: continue
            case .today, .later, .all, .archived: break
            }
            candidates.append(messages[i])
            if candidates.count >= DashboardFocus.candidateCap { break }
        }
        let value = DashboardFocus.snapshot(
            messages: candidates,
            agenda: agendaVisible,
            pending: pending,
            nowMinute: nowMinute,
            accountID: nil
        )
        dashboardFocusCache = (key, value)
        return value
    }

    // MARK: - A agenda que sobrevive ao fechar o app

    /// Relê do disco tudo o que a pessoa criou, traduzido para o "hoje" desta
    /// abertura.
    ///
    /// Chamado no começo de `load()` e de `observe()`, e não a cada retrato: a
    /// lista só muda por ação de quem está aqui, e essas ações a atualizam na
    /// hora (`persist`/`forget`). Reler por retrato seria uma consulta a cada
    /// lote da carga inicial, pelo mesmo resultado.
    private func reloadPersistedAgenda() {
        guard let agendaPort else { return }
        do {
            let hoje = agendaReferenceDay()
            persistedAgenda = try agendaPort.savedAgendaItems().map { $0.item(referenceDay: hoje) }
        } catch {
            report(error)
        }
    }

    /// A agenda que a tela vê: a da fonte **mais** a que a pessoa criou.
    ///
    /// O compromisso guardado ganha do da fonte no mesmo `id` — ele é o mais
    /// recente por construção, porque a fonte não o conhece. E ele entra
    /// **mesmo sem conta conectada**, onde a fonte são as fixtures: um
    /// compromisso que alguém criou não é agenda de exemplo, e sumir ao
    /// reiniciar foi exatamente o defeito. A agenda de exemplo, essa, continua
    /// nascendo das fixtures a cada abertura, byte a byte como no Marco 1 —
    /// sem porta, `persistedAgenda` é vazia e isto é a ordenação de sempre.
    private func mergedAgenda(_ daFonte: [AgendaItem]) -> [AgendaItem] {
        let juntos: [AgendaItem]
        if persistedAgenda.isEmpty {
            juntos = daFonte
        } else {
            let guardados = Set(persistedAgenda.map(\.id))
            juntos = daFonte.filter { !guardados.contains($0.id) } + persistedAgenda
        }
        return juntos
            .map(stampedForMailbox)
            .sorted { $0.startMinute < $1.startMinute }
    }

    /// Junta fonte e sincronização por identidade. Um evento salvo pelo
    /// OkamiUNI pode voltar pelo EventKit no quadro seguinte; sem a chave, a
    /// mesma reunião apareceria duas vezes até o próximo relançamento.
    private func combinedAgenda() -> [AgendaItem] {
        var byID = Dictionary(
            sourceAgenda.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest }
        )
        for item in synchronizedAgenda { byID[item.id] = item }
        return Array(byID.values)
    }

    /// Grava um compromisso e o põe na lista do que está guardado.
    ///
    /// Na **mesma ação** que o pôs na tela, e não numa tarefa depois: era essa
    /// a distância entre "coloquei na agenda" e "sumiu ao reabrir".
    private func persist(_ item: AgendaItem, writeToSystemCalendar: Bool = true) {
        if let agendaPort {
            persistedAgenda.removeAll { $0.id == item.id }
            persistedAgenda.append(item)
            do {
                try agendaPort.saveAgendaItem(
                    StoredAgendaItem(item, referenceDay: agendaReferenceDay())
                )
            } catch {
                report(error)
            }
        }
        if writeToSystemCalendar {
            writeToConnectedCalendar(item)
        }
    }

    /// O contrário: some do disco e da lista. É o "Desfazer" e o "Tirar da
    /// agenda", e os dois têm de alcançar o disco — senão reabrir traz de volta
    /// o que a pessoa acabou de tirar.
    private func forget(_ id: String) {
        if let agendaPort {
            persistedAgenda.removeAll { $0.id == id }
            do {
                try agendaPort.removeAgendaItem(id)
            } catch {
                report(error)
            }
        }
        removeFromConnectedCalendar(id)
    }

    /// A escrita no calendário real é assíncrona; a confirmação local continua
    /// imediata e qualquer falha fica declarada na própria aba Agenda.
    ///
    /// Calendário OkamiUNI de uma caixa IMAP fica só no disco do app: mandar
    /// para o EventKit ia pousar no calendário padrão do macOS (quase sempre
    /// o Gmail) e misturar a agenda de outra conta.
    private func writeToConnectedCalendar(_ item: AgendaItem) {
        if let id = item.calendarID, id.hasPrefix(ConnectedCalendar.mailboxPrefix) {
            return
        }
        if item.calendarID == nil,
           ConnectedCalendar.needsMailboxCalendar(account(item.accountID))
        {
            return
        }
        guard let calendarSync else { return }
        let referenceDay = agendaReferenceDay()
        Task { [weak self, calendarSync] in
            do {
                try await calendarSync.save(item, referenceDay: referenceDay)
                await self?.refreshCalendar()
            } catch {
                self?.calendarAvailability = .unavailable(error.localizedDescription)
            }
        }
    }

    private func removeFromConnectedCalendar(_ id: String) {
        guard let calendarSync else { return }
        let referenceDay = agendaReferenceDay()
        Task { [weak self, calendarSync] in
            do {
                try await calendarSync.remove(id: id, referenceDay: referenceDay)
                await self?.refreshCalendar()
            } catch {
                self?.calendarAvailability = .unavailable(error.localizedDescription)
            }
        }
    }

    // MARK: - Agenda a partir de um email

    /// Cria um compromisso diretamente na Agenda. É a contraparte do botão
    /// “Novo compromisso”: entra na mesma lista, persistência local e ponte do
    /// EventKit usadas pelos compromissos extraídos de e-mail.
    @discardableResult
    public func addManualAgendaItem(
        title: String,
        startMinute: Int,
        endMinute: Int,
        dayOffset: Int,
        accountID: String,
        place: String = "",
        meetingLink: String = "",
        note: String = "",
        recurrence: RecurrenceRule = .none,
        guests: [Contact] = [],
        syncToSystemCalendar: Bool = true,
        sendInvites: Bool = true,
        calendarUID: String? = nil
    ) -> AgendaItem? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPlace = place.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawMeetingLink = meetingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMeetingLink = MeetingLink.normalizado(rawMeetingLink)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              (0..<24 * 60).contains(startMinute),
              (1...24 * 60).contains(endMinute),
              endMinute > startMinute,
              rawMeetingLink.isEmpty || cleanMeetingLink != nil,
              let account = account(accountID)
        else { return nil }

        let owner = EventPerson(
            name: account.displayName,
            address: account.address,
            role: "organizador · você",
            status: .yes
        )
        let people = guests
            .filter {
                !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.address.lowercased() != account.address.lowercased()
            }
            .map { guest in
                EventPerson(
                    name: guest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? guest.address : guest.name,
                    address: guest.address.trimmingCharacters(in: .whitespacesAndNewlines),
                    role: "convidado",
                    status: .pending
                )
            }
        let detail = EventDetail(
            place: cleanPlace,
            link: cleanMeetingLink,
            organizer: owner,
            people: people,
            note: "Criado manualmente",
            recurrence: recurrence.storage,
            notice: "Sem lembrete",
            agenda: [],
            thread: [],
            descricao: cleanNote.isEmpty ? nil : cleanNote
        )
        let item = stampedForMailbox(
            AgendaItem(
                id: "manual-\(UUID().uuidString)",
                title: cleanTitle,
                startMinute: startMinute,
                endMinute: endMinute,
                accountID: accountID,
                dayOffset: dayOffset,
                calendarUID: calendarUID,
                detail: detail
            )
        )
        agenda.append(item)
        agenda.sort {
            $0.dayOffset == $1.dayOffset
                ? $0.startMinute < $1.startMinute
                : $0.dayOffset < $1.dayOffset
        }
        persist(item, writeToSystemCalendar: syncToSystemCalendar)
        if sendInvites {
            sendMeetingInvite(
                item,
                guests: people.map { Contact(name: $0.name, address: $0.address) },
                account: account
            )
        }
        return item
    }

    /// Manda o `METHOD:REQUEST` para quem entrou em Convidados. Sem porta de
    /// envio o compromisso existe mesmo assim — o convite é o extra.
    private func sendMeetingInvite(_ item: AgendaItem, guests: [Contact], account: Account) {
        guard canSend, !guests.isEmpty, let detail = item.detail else { return }
        let start = date(dayOffset: item.dayOffset, minute: item.startMinute)
        let end = date(dayOffset: item.dayOffset, minute: item.endMinute)
        let ics = ICalendar.request(
            uid: item.calendarUID ?? item.id,
            title: item.title,
            start: start,
            end: end,
            organizer: Contact(name: account.displayName, address: account.address),
            attendees: guests,
            location: detail.place.isEmpty ? nil : detail.place,
            url: detail.meetingLink,
            description: [detail.visibleDescription, detail.meetingLink]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            rrule: RecurrenceRule.parse(detail.recurrence)?.rfc5545
        )
        let mensagem = OutgoingMessage(
            messageID: OutgoingMessage.newMessageID(for: account.address),
            accountID: account.id,
            from: OutgoingAddress(name: account.displayName, address: account.address),
            to: guests.map(OutgoingAddress.init),
            subject: item.title,
            plainText: ContextMenus.inviteText(item, detail: detail, date: agendaDate(for: item)),
            calendarICS: ics
        )
        _ = send(mensagem)
    }

    private func date(dayOffset: Int, minute: Int) -> Date {
        let day = Calendar.current.date(
            byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: agendaReferenceDay())
        ) ?? agendaReferenceDay()
        return Calendar.current.date(byAdding: .minute, value: minute, to: Calendar.current.startOfDay(for: day))
            ?? day
    }

    /// "Colocar na agenda", no cartão de resumo do leitor: cria o
    /// `AgendaItem` que `DetectedEventConversion` deriva do `DetectedEvent`
    /// da mensagem, e o acrescenta a `agenda`.
    ///
    /// `accountID` é sempre o da mensagem de origem, nunca o da conta
    /// selecionada no momento. Sem isso o compromisso escaparia do filtro que
    /// `visibleAgenda` aplica: filtrar pela conta errada o esconderia, mesmo
    /// tendo nascido do email daquela conta — e o filtro por caixa foi pedido
    /// explicitamente.
    ///
    /// O `id` é determinístico
    /// (`DetectedEventConversion.agendaID(forMessageID:)`), não `UUID()`: um
    /// segundo clique no mesmo botão recalcula o **mesmo** `id`, e a guarda
    /// abaixo o recusa em vez de duplicar o compromisso na trilha, no Dia, na
    /// Semana e no Mês — as quatro superfícies leem esta mesma `agenda`.
    ///
    /// Devolve o item criado, ou `nil` quando ele já existia. É o sinal que
    /// diz ao chamador se há retorno visível **novo** para mostrar; um
    /// segundo clique não ganha uma segunda confirmação.
    /// O compromisso que este evento detectado já é na agenda, se houver.
    /// O cartão de "Compromisso detectado" pergunta isto **ao desenhar**.
    public func existingAgendaItem(for event: DetectedEvent, from message: Message) -> AgendaItem? {
        InviteAgenda.existing(
            for: event,
            messageID: message.id,
            accountID: message.accountID,
            referenceDay: agendaReferenceDay(),
            in: agenda
        )
    }

    @discardableResult
    public func addToAgenda(_ event: DetectedEvent, from message: Message) -> AgendaItem? {
        guard existingAgendaItem(for: event, from: message) == nil else { return nil }
        let id = DetectedEventConversion.agendaID(forMessageID: message.id)

        let item = stampedForMailbox(
            DetectedEventConversion.agendaItem(
                from: event, id: id, accountID: message.accountID,
                referenceDay: agendaReferenceDay(),
                detail: InviteAgenda.detail(
                    from: message,
                    accountHost: account(message.accountID)?.host
                )
            )
        )
        agenda.append(item)
        agenda.sort { $0.startMinute < $1.startMinute }
        persist(item)
        return item
    }

    // MARK: - Agenda a partir de um convite

    /// O que o cartão do convite deve oferecer: colocar, atualizar, ou dizer
    /// que já está lá.
    ///
    /// É perguntado **ao desenhar**, e não depois de um clique: era essa a
    /// diferença entre o cartão que oferece de novo o que já está na agenda —
    /// e duplica — e o cartão que já abre dizendo "Na agenda".
    public func agendaState(for invite: CalendarInvite, from message: Message) -> InviteAgendaState {
        let id = DetectedEventConversion.agendaID(forMessageID: message.id)
        let proposto = proposedItem(for: invite, from: message, id: id)
        return InviteAgenda.state(
            for: invite,
            existing: existingAgendaItem(for: invite, proposed: proposto, id: id, accountID: message.accountID),
            proposed: proposto
        )
    }

    /// UID, id da mensagem, ou o mesmo título+horário que o EventKit já trouxe.
    private func existingAgendaItem(
        for invite: CalendarInvite, proposed: AgendaItem?, id: String, accountID: String
    ) -> AgendaItem? {
        if let porIdentidade = InviteAgenda.existing(
            for: invite, id: id, accountID: accountID, in: agenda
        ) {
            return porIdentidade
        }
        guard let proposed else { return nil }
        return InviteAgenda.existing(matching: proposed, in: agenda)
    }

    /// O compromisso que este convite pede, com tudo o que a janela 04 mostra
    /// já pendurado nele. Uma função só, porque desenhar o cartão e clicar no
    /// botão precisam do **mesmo** valor: se as duas montassem por conta
    /// própria, o botão diria "Na agenda" e o clique criaria outro.
    private func proposedItem(
        for invite: CalendarInvite, from message: Message, id: String
    ) -> AgendaItem? {
        let proposto = InviteAgenda.item(
            for: invite, id: id, accountID: message.accountID,
            referenceDay: agendaReferenceDay(),
            detail: InviteAgenda.detail(
                for: invite,
                subject: message.subject,
                sender: message.from,
                when: message.receivedAt.formatted(
                    .dateTime.day().month(.abbreviated).hour().minute()
                ),
                accountHost: account(message.accountID)?.host
            )
        )
        return proposto.map(stampedForMailbox)
    }

    /// "Colocar na agenda" / "Atualizar na agenda", a partir do convite.
    ///
    /// **Um evento, um compromisso.** O convite traz o `UID` do iCalendar, que
    /// é o mesmo no original, na atualização e em todo encaminhamento — e é por
    /// ele que este caminho reencontra o que já existe. O original criava, a
    /// atualização criava outro, e a agenda do dono ficou com dois blocos
    /// "DreamSquad" idênticos.
    ///
    /// Devolve o item criado **ou atualizado**, e `nil` quando não havia o que
    /// fazer (já está lá, igual) ou quando o convite não tem começo. É o mesmo
    /// contrato de `addToAgenda(_:from:)`: só há confirmação quando algo mudou.
    @discardableResult
    public func addToAgenda(_ invite: CalendarInvite, from message: Message) -> AgendaItem? {
        let id = DetectedEventConversion.agendaID(forMessageID: message.id)
        guard let proposto = proposedItem(for: invite, from: message, id: id) else { return nil }

        let existente = existingAgendaItem(
            for: invite, proposed: proposto, id: id, accountID: message.accountID
        )
        switch InviteAgenda.state(for: invite, existing: existente, proposed: proposto) {
        case .naAgenda:
            return nil
        case .ausente:
            agenda.append(proposto)
            agenda.sort { $0.startMinute < $1.startMinute }
            persist(proposto)
            return proposto
        case .desatualizado:
            guard let existente,
                  let posicao = agenda.firstIndex(where: { $0.id == existente.id })
            else { return nil }
            let atualizado = InviteAgenda.updated(existente, with: proposto)
            agenda[posicao] = atualizado
            agenda.sort { $0.startMinute < $1.startMinute }
            persist(atualizado)
            return atualizado
        }
    }

    /// O compromisso que um `METHOD:CANCEL` deve tirar, se ainda estiver lá.
    public func cancelledAgendaItem(
        for invite: CalendarInvite, from message: Message
    ) -> AgendaItem? {
        matchingCancelledInvite(invite, from: message)
    }

    /// `METHOD:CANCEL`: o compromisso continua no dia, transparente — o jeito
    /// do Google Agenda. `nil` quando o cancelamento não encontra nada.
    @discardableResult
    public func applyCancelledInvite(
        _ invite: CalendarInvite, from message: Message
    ) -> AgendaItem? {
        guard invite.isCancelled, let item = matchingCancelledInvite(invite, from: message)
        else { return nil }
        rememberCancelled(item, uid: invite.uid)
        let marcado = overlayCancelled(item)
        agenda = agenda.map { $0.id == item.id ? marcado : overlayCancelled($0) }
        return marcado
    }

    /// Ainda existe para quem quer tirar de vez. O cartão do convite passou a
    /// marcar como cancelado, não a apagar.
    @discardableResult
    public func removeCancelledInvite(
        _ invite: CalendarInvite, from message: Message
    ) -> AgendaItem? {
        applyCancelledInvite(invite, from: message)
    }

    private func matchingCancelledInvite(
        _ invite: CalendarInvite, from message: Message
    ) -> AgendaItem? {
        let id = DetectedEventConversion.agendaID(forMessageID: message.id)
        return InviteAgenda.matchingCancellation(
            invite, messageID: message.id, in: agenda,
            proposed: proposedItem(for: invite, from: message, id: id)
        )
    }

    private func overlayCancelled(_ item: AgendaItem) -> AgendaItem {
        if item.isCancelled { return item }
        if cancelledAgendaKeys.contains(item.id) { return item.markingCancelled() }
        if let uid = item.calendarUID, cancelledAgendaKeys.contains(uid) {
            return item.markingCancelled()
        }
        if cancelledAgendaKeys.contains(item.cancellationFingerprint) {
            return item.markingCancelled()
        }
        return item
    }

    private func rememberCancelled(_ item: AgendaItem, uid: String?) {
        cancelledAgendaKeys.insert(item.id)
        cancelledAgendaKeys.insert(item.cancellationFingerprint)
        if let uid, !uid.isEmpty { cancelledAgendaKeys.insert(uid) }
        if let calendarUID = item.calendarUID { cancelledAgendaKeys.insert(calendarUID) }
        calendarDefaults?.set(Array(cancelledAgendaKeys), forKey: Self.cancelledAgendaKeysKey)
    }

    /// O "Desfazer" de `addToAgenda`. Tira o item pelo `id` que ela devolveu.
    ///
    /// Sem guarda contra `id` ausente: desfazer o que já não está lá — outra
    /// pessoa apagou por outro caminho, ou "Desfazer" foi clicado duas vezes
    /// — não é erro, é o mesmo estado a que se pretendia chegar.
    public func removeFromAgenda(_ id: String) {
        if let item = agenda.first(where: { $0.id == id }) { removedFromAgenda[id] = item }
        agenda.removeAll { $0.id == id }
        forget(id)
    }

    /// Cancela um compromisso criado no OkamiUNI: manda `METHOD:CANCEL` para
    /// os convidados e tira da agenda. A sala no Google some pelo caminho da
    /// fábrica, que precisa do OAuth.
    public func cancelMeeting(_ id: String) {
        if let item = agenda.first(where: { $0.id == id }) {
            sendMeetingCancellation(item)
        }
        removeFromAgenda(id)
    }

    private func sendMeetingCancellation(_ item: AgendaItem) {
        guard canSend, let account = account(item.accountID), let detail = item.detail else { return }
        let guests = detail.people.map { Contact(name: $0.name, address: $0.address) }
            .filter { $0.address.lowercased() != account.address.lowercased() }
        guard !guests.isEmpty else { return }
        let start = date(dayOffset: item.dayOffset, minute: item.startMinute)
        let end = date(dayOffset: item.dayOffset, minute: item.endMinute)
        let ics = ICalendar.cancellation(
            uid: item.calendarUID ?? item.id,
            title: item.title,
            start: start,
            end: end,
            organizer: Contact(name: account.displayName, address: account.address),
            attendees: guests
        )
        let mensagem = OutgoingMessage(
            messageID: OutgoingMessage.newMessageID(for: account.address),
            accountID: account.id,
            from: OutgoingAddress(name: account.displayName, address: account.address),
            to: guests.map(OutgoingAddress.init),
            subject: "Cancelado: \(item.title)",
            plainText: "A reunião \"\(item.title)\" foi cancelada.",
            calendarICS: ics
        )
        _ = send(mensagem)
    }

    /// O que saiu da agenda, para "Desfazer" ter o que devolver — o mesmo
    /// cofre de sessão que `deleteForever` usa, e pelo mesmo motivo: fora da
    /// lista, o compromisso não sabe mais o horário nem a conta dele.
    private var removedFromAgenda: [String: AgendaItem] = [:]

    /// Caixa IMAP ganha o calendário OkamiUNI da conta. Gmail fica sem, para
    /// o EventKit continuar sendo a fonte daquela agenda. Item que já veio
    /// com calendário (EventKit, CalDAV) não é tocado.
    private func stampedForMailbox(_ item: AgendaItem) -> AgendaItem {
        guard item.calendarID == nil,
              let account = account(item.accountID),
              ConnectedCalendar.needsMailboxCalendar(account)
        else { return item }
        return item.withCalendar(.mailbox(for: account))
    }

    /// O "Desfazer" de "Tirar da agenda". Devolve o compromisso à ordenação
    /// por horário em que a trilha e as três grades o esperam.
    public func restoreToAgenda(_ id: String) {
        guard let item = removedFromAgenda.removeValue(forKey: id) else { return }
        guard !agenda.contains(where: { $0.id == id }) else { return }
        agenda.append(item)
        agenda.sort { $0.startMinute < $1.startMinute }
        persist(item)
    }

    private func matches(_ message: Message, _ term: String) -> Bool {
        // O acerto de corpo **soma** à busca do Marco 1, não a substitui: uma
        // fonte que não sabe procurar no corpo devolve `nil`, `bodyHits` fica
        // vazio, e remetente/assunto/prévia continuam sendo o que decide.
        if bodyHits.contains(message.id) { return true }
        let needle = ContactDirectory.fold(term)
        return [message.from.name, message.from.address, message.subject, message.snippet]
            .contains { ContactDirectory.fold($0).contains(needle) }
    }

    /// Pergunta à fonte quais mensagens casam **pelo corpo** com a busca atual.
    ///
    /// Quem chama é a tela, quando a busca muda. Termo vazio limpa os acertos
    /// em vez de perguntar: consultar o índice com string vazia devolveria a
    /// caixa inteira.
    public func refreshBodyMatches() async {
        let termo = query.trimmingCharacters(in: .whitespaces)
        guard !termo.isEmpty else {
            bodyHits = []
            return
        }
        do {
            // `?? []` e não `?? algo`: `nil` ("não sei procurar no corpo") e
            // conjunto vazio ("procurei e não achei") chegam aqui iguais só
            // porque `matches` usa `bodyHits` como **acréscimo**. Trocar o
            // acréscimo por substituição faria os dois divergirem — e a busca
            // sobre as fixtures esvaziaria a lista a cada tecla.
            let acertos = try await source.bodyMatches(termo, accountID: selectedAccountID) ?? []
            // O carimbo: entre o `await` acima e esta linha, a pessoa pode ter
            // digitado mais uma tecla — "a" virou "ab", e outra chamada a
            // `refreshBodyMatches()` já está em voo. Se essa outra responder
            // primeiro, gravar aqui por cima apagaria o acerto do termo atual
            // com o do termo velho. `termo` é o que **esta** chamada pediu;
            // se `query` já não bate mais com ele, a resposta chegou tarde
            // demais para valer, e é descartada.
            guard query.trimmingCharacters(in: .whitespaces) == termo else { return }
            bodyHits = acertos
        } catch {
            // A busca no corpo falhar não pode apagar a lista: a busca do
            // Marco 1 continua valendo, e o erro aparece na janela de Contas —
            // exceto quando o que houve foi cancelamento, ver `report`. A
            // mesma guarda do carimbo vale aqui: uma falha atrasada de um
            // termo velho não pode limpar os acertos do termo atual.
            guard query.trimmingCharacters(in: .whitespaces) == termo else { return }
            bodyHits = []
            report(error)
        }
    }

    /// Aponta o leitor para a primeira mensagem da visão atual.
    ///
    /// Só age quando a seleção corrente não está mais na visão (ou não existe),
    /// então recarregar não tira o usuário da mensagem que ele estava lendo.
    /// A escolha sai sempre de `visibleMessages`, então a seleção padrão nunca
    /// aponta para fora do que a lista mostra — e numa caixa vazia ela é `nil`,
    /// que é quando o estado vazio do leitor deve aparecer.
    private func selectDefaultMessage() {
        let referenceDay = agendaReferenceDay()
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces)
        if let current = selectedMessageID {
            if let cached = listIndexCache, cached.revision == messagesRevision,
               let i = cached.idIndex[current],
               matchesCurrentView(
                at: i, index: cached,
                referenceDay: referenceDay, normalizedQuery: normalizedQuery
               ) {
                return
            }
            if let message = messages.first(where: { $0.id == current }),
               matchesCurrentView(
                message, referenceDay: referenceDay, normalizedQuery: normalizedQuery
               ) {
                return
            }
        }
        if let cached = listIndexCache, cached.revision == messagesRevision {
            for i in cached.ranked {
                guard matchesCurrentView(
                    at: i, index: cached,
                    referenceDay: referenceDay, normalizedQuery: normalizedQuery
                ) else { continue }
                selectedMessageID = cached.ids[i]
                return
            }
            selectedMessageID = nil
            return
        }
        // Sem índice: o retrato já vem da mais nova. Para no primeiro acerto.
        for message in messages {
            guard matchesCurrentView(
                message, referenceDay: referenceDay, normalizedQuery: normalizedQuery
            ) else { continue }
            selectedMessageID = message.id
            return
        }
        selectedMessageID = nil
    }

    public var selectedMessage: Message? {
        guard let selectedMessageID else { return nil }
        _ = bodiesRevision
        return message(selectedMessageID)
    }

    /// A mensagem com o corpo que o leitor já buscou, se buscou.
    public func message(_ id: String) -> Message? {
        _ = bodiesRevision
        let raw: Message?
        if let cached = listIndexCache, cached.revision == messagesRevision,
           let i = cached.idIndex[id] {
            raw = messages[i]
        } else {
            raw = messages.first { $0.id == id }
        }
        guard let raw else { return nil }
        return hydrate(raw)
    }

    private func hydrate(_ message: Message) -> Message {
        guard let loaded = bodyStore[message.id] else { return message }
        return message.withBody(
            loaded.body.isEmpty ? message.body : loaded.body,
            html: loaded.bodyHTML ?? message.bodyHTML,
            calendarICS: loaded.calendarICS ?? message.calendarICS,
            attachments: loaded.attachments.isEmpty ? message.attachments : loaded.attachments
        )
    }

    public func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    public func select(bucket newBucket: TriageBucket) {
        bucket = newBucket
        // Tocar numa caixa é voltar ao recorte inteiro dela. Assim uma
        // categoria antiga não reaparece invisivelmente ao retornar a Hoje.
        categoryFilter = nil
        pruneChecked()
        selectDefaultMessage()
    }

    /// Abre uma categoria dentro de Hoje. `nil` é a cápsula Todos.
    public func select(category: MailCategory?) {
        guard bucket == .today else {
            categoryFilter = nil
            return
        }
        categoryFilter = category
        selectDefaultMessage()
        pruneChecked()
    }

    public func select(account id: String?) {
        if selectedAccountID == id {
            // Clicar de novo na mesma conta desliga o filtro
            selectedAccountID = nil
        } else {
            selectedAccountID = id
        }
        // A pasta aberta é de **uma** conta: trocar (ou limpar) o filtro de
        // conta sem soltar a pasta deixaria a lista filtrada por uma pasta que
        // não pertence ao que a barra mostra como selecionado — uma lista vazia
        // sem nada na tela que explique por quê.
        selectedFolderID = nil
        selectDefaultMessage()
        pruneChecked()
    }

    public func select(message id: String) {
        selectedMessageID = id
        markRead(id)
    }

    /// Anda uma conversa na lista visível. `+1` é para baixo (a seguinte na
    /// ordem da caixa, mais antiga); `-1` é para cima.
    ///
    /// A unidade é a **linha**, que é a conversa — não a mensagem de dentro
    /// da pilha. É o que as setas fazem no Mail e no Gmail.
    ///
    /// Devolve `false` só quando não há lista: aí a tecla segue o caminho
    /// dela. No começo ou no fim da caixa a seleção fica onde está, e a
    /// tecla é consumida — um beep no fim da lista seria a tecla falhando.
    @discardableResult
    public func selectAdjacentConversation(offset: Int) -> Bool {
        guard offset != 0 else { return false }
        let referenceDay = agendaReferenceDay()
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces)
        let index = messageListIndex()
        var order: [String] = []
        var latestID: [String: String] = [:]
        var seen = Set<String>()
        for i in index.ranked {
            guard matchesCurrentView(
                at: i, index: index,
                referenceDay: referenceDay, normalizedQuery: normalizedQuery
            ) else { continue }
            let key = index.conversationKeys[i]
            if seen.insert(key).inserted {
                order.append(key)
                latestID[key] = index.ids[i]
            }
        }
        guard !order.isEmpty else { return false }
        let currentKey = selectedMessageID.flatMap { id in
            index.idIndex[id].map { index.conversationKeys[$0] }
        }
        let current = currentKey.flatMap { order.firstIndex(of: $0) }
        let target: Int
        if let current {
            target = current + offset
            guard order.indices.contains(target) else { return true }
        } else {
            target = offset > 0 ? 0 : order.count - 1
        }
        guard let id = latestID[order[target]] else { return false }
        select(message: id)
        return true
    }

    /// Traz uma mensagem para a tela, custe o que custar em filtros.
    ///
    /// É o destino de "Ir para o email de origem", no menu de um compromisso.
    /// Selecionar sozinho não bastaria: o leitor mostraria a mensagem e a lista
    /// ao lado não a teria, porque a caixa aberta, o filtro de conta ou a busca
    /// a escondem. "Ir para" que deixa a lista noutro lugar é meia ação.
    ///
    /// Desfaz só o que **de fato** esconde a mensagem — filtro de outra conta,
    /// caixa que não a contém, busca que não casa. Um filtro que já a mostrava
    /// permanece, para a pessoa não perder o recorte em que estava.
    ///
    /// `id` desconhecido não mexe em nada.
    public func reveal(_ messageID: String) {
        guard let message = messages.first(where: { $0.id == messageID }) else { return }
        revealCount += 1
        let referenceDay = agendaReferenceDay()

        if let filtered = selectedAccountID, filtered != message.accountID {
            selectedAccountID = nil
        }
        // A pasta aberta esconde tanto quanto o filtro de conta, e "ir para o
        // email de origem" que deixa a lista sem ele é meia ação — a mesma
        // regra dos outros três filtros desta função.
        if let pasta = selectedFolderID, !message.folderIDs.contains(pasta) {
            selectedFolderID = nil
        }
        if !isInBucket(message, bucket: bucket, referenceDay: referenceDay) {
            // Uma Inbox antiga não cabe em Hoje. Revelá-la em Hoje selecionaria
            // uma linha que a lista não desenha; Tudo é a menor visão que a
            // contém sem falsificar a data de recebimento.
            bucket = message.bucket == .today ? .all : message.bucket
            categoryFilter = nil
        }
        if bucket == .today,
           let categoryFilter,
           resolvedCategory(for: message) != categoryFilter {
            self.categoryFilter = nil
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty, !matches(message, query) {
            query = ""
        }
        select(message: messageID)
    }

    /// Move a **mensagem** de caixa, sem mexer na caixa que a lista está
    /// mostrando. É o que os botões de triagem do leitor fazem no protótipo:
    /// `setState({ moved: { [sel.id]: a.id } })` altera a mensagem selecionada,
    /// não a visão.
    ///
    /// Depois de mover, a mensagem costuma sair de `visibleMessages` — mover de
    /// "Hoje" para "Depois" estando na caixa Hoje tira ela da lista. A seleção
    /// não pode ficar apontando para fora da visão, então ela passa para a
    /// próxima mensagem da lista (ou a anterior, se a movida era a última).
    public func move(_ message: Message, to newBucket: TriageBucket) {
        defer { pruneChecked() }
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let current = messages[index]
        if newBucket != .archived {
            discardPendingRuleAction(.archive, for: current.id)
        }
        guard current.bucket != newBucket else { return }

        // Onde ela estava na lista, para saber quem herda a seleção.
        let positionBefore = visibleMessages.firstIndex { $0.id == current.id }

        // A porta primeiro: é a escrita no banco, na mesma transação em que a
        // operação entra na fila de saída — o conserto do defeito do dono.
        // Mover para a Lixeira é `delete`, não `move`; o resto da triagem
        // (Hoje/Depois/Arquivado) é `move(to:)`. Ver `MailCommandPort`.
        send { port in
            if newBucket == .trash {
                try port.delete(accountID: current.accountID, messageIDs: [current.id])
            } else {
                try port.move(to: newBucket, accountID: current.accountID, messageIDs: [current.id])
            }
        }

        // `withBucket` e não um `Message(...)` à mão: reconstruir aqui já
        // significou uma mensagem de ontem reaparecendo sob "Hoje", porque os
        // campos com default no `init` **compilam** quando esquecidos. Com
        // `to`, `cc` e `isFlagged` no modelo são cinco campos nessa condição.
        messages[index] = current.withBucket(newBucket)

        guard selectedMessageID == current.id else { return }
        let remaining = visibleMessages
        // Se a caixa aberta é "Tudo", a mensagem continua visível e nada muda.
        guard !remaining.contains(where: { $0.id == current.id }) else { return }

        guard let positionBefore else {
            selectedMessageID = remaining.first?.id
            return
        }
        // A que ocupou o lugar dela; se era a última, a que ficou acima.
        selectedMessageID = remaining.indices.contains(positionBefore)
            ? remaining[positionBefore].id
            : remaining.last?.id
    }

    /// Move para uma pasta IMAP ou aplica um marcador Gmail, com projeção
    /// otimista igual à que o banco grava na mesma transação do outbox.
    public func place(
        _ message: Message,
        in folder: MailFolder,
        mode: FolderPlacement
    ) {
        defer { pruneChecked() }
        guard message.accountID == folder.accountID,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let current = messages[index]
        if mode == .label, current.folderIDs.contains(folder.id) { return }
        if mode == .move, current.folderIDs == [folder.id] { return }
        let positionBefore = visibleMessages.firstIndex { $0.id == current.id }

        send { port in
            try port.place(
                in: folder, mode: mode,
                accountID: current.accountID, messageIDs: [current.id]
            )
        }
        messages[index] = placing(current, in: folder, mode: mode)

        guard selectedMessageID == current.id else { return }
        let remaining = visibleMessages
        guard !remaining.contains(where: { $0.id == current.id }) else { return }
        guard let positionBefore else {
            selectedMessageID = remaining.first?.id
            return
        }
        selectedMessageID = remaining.indices.contains(positionBefore)
            ? remaining[positionBefore].id
            : remaining.last?.id
    }

    /// A versão por mensagem da movimentação entre marcadores Gmail. Remover a
    /// Inbox arquiva; remover um marcador do usuário preserva a caixa de
    /// triagem e todos os demais marcadores.
    public func moveGmail(
        _ message: Message,
        from source: MailFolder,
        to destination: MailFolder
    ) {
        defer { pruneChecked() }
        guard source.accountID == destination.accountID,
              message.accountID == source.accountID,
              source.id != destination.id,
              let index = messages.firstIndex(where: { $0.id == message.id })
        else { return }
        let current = messages[index]
        guard current.folderIDs.contains(source.id) else { return }
        let positionBefore = visibleMessages.firstIndex { $0.id == current.id }

        send { port in
            try port.moveGmailLabel(
                from: source, to: destination,
                accountID: current.accountID, messageIDs: [current.id]
            )
        }
        messages[index] = movingGmail(current, from: source, to: destination)

        guard selectedMessageID == current.id else { return }
        let remaining = visibleMessages
        guard !remaining.contains(where: { $0.id == current.id }) else { return }
        guard let positionBefore else {
            selectedMessageID = remaining.first?.id
            return
        }
        selectedMessageID = remaining.indices.contains(positionBefore)
            ? remaining[positionBefore].id
            : remaining.last?.id
    }

    /// Reverte a colocação de pasta/marcador guardada por um gesto. Cada item
    /// volta pelo mesmo caminho persistente (`place`) que uma ação normal,
    /// portanto a projeção SQLite e o outbox permanecem em sincronia também no
    /// "Desfazer".
    public func restoreFolderPlacements(_ placements: [FolderPlacementUndo]) {
        for placement in placements {
            switch placement {
            case .moveToFolder(let messageID, let folder):
                guard let message = messages.first(where: { $0.id == messageID }) else { continue }
                place(message, in: folder, mode: .move)

            case .restoreGmailInbox(let messageID, let inbox):
                guard let message = messages.first(where: { $0.id == messageID }) else { continue }
                // `label` acrescenta INBOX sem retirar marcadores que já
                // estavam na mensagem antes do gesto.
                place(message, in: inbox, mode: .label)
            }
        }
    }

    /// Cor local da caixa/conta. Não há operação remota: ela persiste no
    /// registro da conta e a observação do banco redesenha a barra lateral.
    public func setAccountTint(
        accountID: String,
        lightHex: String,
        darkHex: String
    ) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        send { port in
            try port.setAccountTint(
                lightHex: lightHex, darkHex: darkHex, accountID: accountID
            )
        }
        accounts[index] = accounts[index].withTint(lightHex: lightHex, darkHex: darkHex)
    }

    private func placing(
        _ message: Message,
        in folder: MailFolder,
        mode: FolderPlacement
    ) -> Message {
        switch mode {
        case .label:
            var updated = message.withFolderIDs(message.folderIDs + [folder.id])
            // Em Gmail, recolocar o marcador INBOX é o inverso de tirar a
            // mensagem da caixa de entrada. Não mexemos em "Depois": uma
            // mensagem adiada continua adiada mesmo que receba INBOX de novo.
            if folder.role == .inbox,
               updated.bucket == .archived || updated.bucket == .junk {
                updated = updated.withBucket(.today)
            }
            return updated
        case .move:
            return message
                .withFolderIDs([folder.id])
                .withBucket(Self.bucket(for: folder.role))
        }
    }

    private func movingGmail(
        _ message: Message,
        from source: MailFolder,
        to destination: MailFolder
    ) -> Message {
        var folderIDs = message.folderIDs.filter { $0 != source.id }
        if !folderIDs.contains(destination.id) { folderIDs.append(destination.id) }
        var updated = message.withFolderIDs(folderIDs)
        if destination.role == .junk {
            updated = updated.withBucket(.junk)
        } else if source.role == .junk {
            updated = updated.withBucket(destination.role == .inbox ? .today : .archived)
        } else if source.role == .inbox, updated.bucket == .today {
            updated = updated.withBucket(.archived)
        } else if destination.role == .inbox, updated.bucket == .archived {
            updated = updated.withBucket(.today)
        }
        return updated
    }

    private static func bucket(for role: FolderRole) -> TriageBucket {
        switch role {
        case .inbox: .today
        case .later: .later
        case .archive, .other: .archived
        case .junk: .junk
        case .drafts: .drafts
        case .trash: .trash
        case .sent: .sent
        }
    }

    // MARK: - Lixeira

    /// O que `deleteForever` tirou do store, para "Desfazer" ter o que
    /// devolver.
    ///
    /// Guardar a **mensagem inteira** e não só o id é o que faz o caminho de
    /// volta existir: uma vez fora de `messages`, nada mais sabe o assunto, o
    /// corpo, a caixa de onde ela veio. É a mesma razão pela qual o recibo do
    /// arraste nasce **antes** da mudança.
    ///
    /// Memória da sessão, como os rascunhos de resposta: Marco 1 não tem disco.
    /// `esvaziar` limpa este cofre junto — é o que faz dele o único destrutivo
    /// sem volta, e o motivo de ele perguntar antes.
    private var deleted: [String: Message] = [:]

    /// Tira a mensagem do store. Só faz sentido na Lixeira, e é quem monta o
    /// menu que garante isso — aqui a guarda é a de sempre: id desconhecido não
    /// mexe em nada.
    ///
    /// A seleção anda como em `move(_:to:)`, e pelo mesmo motivo: ela não pode
    /// ficar apontando para uma mensagem que não está mais na lista.
    public func deleteForever(_ messageID: String) {
        defer { pruneChecked() }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let going = messages[index]
        let positionBefore = visibleMessages.firstIndex { $0.id == messageID }

        send { port in
            try port.deletePermanently(accountID: going.accountID, messageIDs: [messageID])
        }

        deleted[messageID] = going
        messages.remove(at: index)

        guard selectedMessageID == messageID else { return }
        let remaining = visibleMessages
        guard let positionBefore else {
            selectedMessageID = remaining.first?.id
            return
        }
        selectedMessageID = remaining.indices.contains(positionBefore)
            ? remaining[positionBefore].id
            : remaining.last?.id
    }

    /// O "Desfazer" de `deleteForever`. Devolve a mensagem à caixa de onde ela
    /// saiu, na posição que a ordenação de `visibleMessages` lhe der.
    ///
    /// Sem guarda contra id ausente, como `removeFromAgenda`: desfazer o que já
    /// voltou não é erro, é o mesmo estado a que se pretendia chegar.
    ///
    /// E não há segunda guarda contra duplicar: `removeValue` **tira** a
    /// mensagem do cofre ao devolvê-la, então a segunda chamada não acha nada e
    /// sai. Uma guarda a mais aqui seria código morto — provado por mutação:
    /// arrancá-la não faz teste nenhum falhar.
    public func restoreDeleted(_ messageID: String) {
        guard let message = deleted.removeValue(forKey: messageID) else { return }
        messages.append(message)
    }

    /// Esvazia a Lixeira. `accountID` nulo abrange todas as contas.
    ///
    /// **É o único caminho sem volta do app.** Ele limpa o cofre de
    /// `deleteForever` junto, senão "esvaziar" deixaria mensagens restauráveis
    /// atrás de si e a palavra mentiria.
    ///
    /// Ignora a busca, como `markAllRead(in:accountID:)` e pela mesma razão:
    /// "esvaziar" com filtro de texto ligado apagaria só o que coube na tela.
    ///
    /// Devolve quantas foram, para o retorno visível poder dizer o número em
    /// vez de uma frase genérica.
    @discardableResult
    public func emptyTrash(accountID: String? = nil) -> Int {
        let scope: (Message) -> Bool = { message in
            guard let accountID else { return true }
            return message.accountID == accountID
        }
        let doomed = messages.filter { $0.bucket == .trash && scope($0) }

        // Uma chamada por conta tocada — a porta esvazia uma conta por vez.
        // `accountID` nulo aqui pode abranger várias contas; sem ele, é uma
        // só, e o laço abaixo faz uma única chamada mesmo assim.
        for touched in Set(doomed.map(\.accountID)) {
            send { port in try port.emptyTrash(accountID: touched) }
        }

        let ids = Set(doomed.map(\.id))
        messages.removeAll { ids.contains($0.id) }
        // O cofre inteiro do recorte, e não só o das que acabaram de sair: uma
        // mensagem apagada definitivamente segundos antes ainda tinha
        // "Desfazer" na tela, e deixá-lo funcionar faria "esvaziar" mentir.
        // Depois desta linha, nada da Lixeira volta.
        deleted = deleted.filter { !scope($0.value) }

        if let selectedMessageID, ids.contains(selectedMessageID) {
            self.selectedMessageID = visibleMessages.first?.id
        }
        return doomed.count
    }

    /// Quantas mensagens a Lixeira tem, com o mesmo recorte de conta que
    /// `emptyTrash` usa. É o que decide se "Esvaziar lixeira" entra no menu:
    /// com a lixeira vazia o item some, em vez de aparecer prometendo esvaziar
    /// o que já não está lá.
    public func trashCount(accountID: String? = nil) -> Int {
        let referenceDay = agendaReferenceDay()
        resetCountsCacheIfNeeded()
        let key = CountCacheKey(
            bucket: TriageBucket.trash.rawValue,
            accountID: accountID,
            dayStart: Calendar.current.startOfDay(for: referenceDay)
        )
        if let cached = bucketCountCache[key] { return cached }
        let index = messageListIndex()
        var n = 0
        for i in 0..<index.buckets.count {
            guard index.buckets[i] == .trash else { continue }
            if let accountID, index.accountIDs[i] != accountID { continue }
            n += 1
        }
        bucketCountCache[key] = n
        return n
    }

    /// Quantas mensagens esta conta tem, em qualquer caixa. É o número da
    /// linha da conta na barra — e não pode copiar Tudo só para contar.
    public func count(forAccount accountID: String) -> Int {
        resetCountsCacheIfNeeded()
        if accountCountCache.isEmpty, !messages.isEmpty {
            var counts: [String: Int] = [:]
            for id in messageListIndex().accountIDs {
                counts[id, default: 0] += 1
            }
            accountCountCache = counts
        }
        return accountCountCache[accountID, default: 0]
    }

    /// Abrir uma mensagem para ler. Se ela é a mais recente da conversa, a
    /// conversa inteira deixa de ser trabalho: as anteriores que ficaram por
    /// ler são o contexto da última, não uma linha marcada sem dizer qual.
    private func markRead(_ id: String) {
        if let conversation = conversation(of: id), conversation.latest.id == id {
            setRead(true, for: conversation)
            return
        }
        setRead(true, for: id)
    }

    // MARK: - Estado de leitura

    /// Marca uma mensagem como lida ou **não lida**.
    ///
    /// A metade "não lida" é a única ação dos menus de contexto que não tinha
    /// caminho nenhum no app antes — `markRead` era privado e só chegava por
    /// `select(message:)`, que é de mão única. Ler dava para desfazer em
    /// lugar nenhum.
    ///
    /// Não mexe na seleção de propósito: no macOS marcar a mensagem aberta
    /// como não lida a deixa não lida na lista sem tirá-la da tela. E como
    /// `select(message:)` só marca lida ao **trocar** de seleção, a mensagem
    /// que já estava aberta continua não lida até você sair dela.
    public func setRead(_ isRead: Bool, for messageID: String) {
        if !isRead {
            discardPendingRuleAction(.markRead, for: messageID)
        }
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].isRead != isRead else { return }
        let accountID = messages[index].accountID
        send { port in try port.setRead(isRead, accountID: accountID, messageIDs: [messageID]) }
        messages[index] = messages[index].withRead(isRead)
    }

    /// Liga e desliga a estrela.
    ///
    /// Não mexe na caixa nem na seleção: sinalizar é um estado **da mensagem**,
    /// ortogonal à triagem — uma mensagem arquivada continua sinalizada, e a
    /// linha continua onde estava. É o contrário de arquivar, que a tira da
    /// lista, e é por isso que as duas ações podem conviver no mesmo menu sem
    /// se atrapalharem.
    ///
    /// Não há caixa "Sinalizadas" neste marco — dívida registrada no relatório
    /// da Task AR.
    public func setFlagged(_ isFlagged: Bool, for messageID: String) {
        if !isFlagged {
            discardPendingRuleAction(.flag, for: messageID)
        }
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].isFlagged != isFlagged else { return }
        let accountID = messages[index].accountID
        send { port in try port.setFlagged(isFlagged, accountID: accountID, messageIDs: [messageID]) }
        messages[index] = messages[index].withFlagged(isFlagged)
    }

    /// Percorre uma caixa marcando tudo como lido. `accountID` nulo abrange
    /// todas as contas; com um id, só a daquela conta.
    ///
    /// **Ignora a busca**, ao contrário de `visibleMessages`. "Marcar tudo
    /// como lido" numa caixa com filtro de texto ativo marcaria só o que
    /// coube na tela e diria "tudo" — e o contador da barra lateral, que não
    /// olha a busca, continuaria acusando não lidas logo abaixo do item que
    /// acabou de dizer que não havia mais.
    public func markAllRead(in bucket: TriageBucket, accountID: String? = nil) {
        let referenceDay = agendaReferenceDay()
        let ids = Set(messages.compactMap { message -> String? in
            guard !message.isRead,
                  isInBucket(message, bucket: bucket, referenceDay: referenceDay)
            else { return nil }
            if let accountID, message.accountID != accountID { return nil }
            return message.id
        })
        updateMessages(ids: ids, preservesListPages: true) { $0.withRead(true) }
    }

    /// Quantas não lidas há numa caixa, com o mesmo recorte de
    /// `markAllRead(in:accountID:)`.
    ///
    /// É o que decide se "Marcar tudo como lido" **entra** no menu: com zero
    /// não lidas o item some, em vez de aparecer desabilitado dizendo que a
    /// caixa tem o que marcar.
    public func unreadCount(in bucket: TriageBucket, accountID: String? = nil) -> Int {
        let referenceDay = agendaReferenceDay()
        resetCountsCacheIfNeeded()
        let key = CountCacheKey(
            bucket: bucket.rawValue,
            accountID: accountID,
            dayStart: Calendar.current.startOfDay(for: referenceDay)
        )
        if let cached = unreadCountCache[key] { return cached }
        let index = messageListIndex()
        var n = 0
        for i in 0..<index.ids.count {
            guard !index.isRead[i],
                  isInBucket(
                    messageBucket: index.buckets[i],
                    receivedAt: index.dates[i],
                    folderIDs: index.folderIDs[i],
                    accountID: index.accountIDs[i],
                    bucket: bucket,
                    referenceDay: referenceDay
                  )
            else { continue }
            if let accountID, index.accountIDs[i] != accountID { continue }
            n += 1
        }
        unreadCountCache[key] = n
        return n
    }

    private func resetCountsCacheIfNeeded() {
        guard countsCacheRevision != messagesRevision else { return }
        countsCacheRevision = messagesRevision
        unreadCountCache.removeAll(keepingCapacity: true)
        bucketCountCache.removeAll(keepingCapacity: true)
        foldersByAccountCache.removeAll(keepingCapacity: true)
        accountCountCache.removeAll(keepingCapacity: true)
    }

    // MARK: - O corpo por demanda

    /// Em que pé está a busca do corpo de uma mensagem.
    ///
    /// A ausência de valor é o quarto estado, e o mais comum: "nunca foi
    /// preciso buscar". Ele não está no enum de propósito — um `.naoTentado`
    /// que precisasse ser escrito no dicionário para toda mensagem da caixa
    /// seria estado a manter em dia sem nada a dizer.
    public enum BodyLoad: Sendable, Equatable {
        case carregando
        /// A causa, no idioma da pessoa. É o que a faixa de erro mostra ao lado
        /// do "Tentar de novo".
        case falhou(String)
        /// Buscamos. O corpo pode ter vindo (e então está em `body`) ou a
        /// mensagem pode de fato não ter texto nenhum — um anexo sozinho, um
        /// convite de calendário. Este estado é o que impede a segunda coisa de
        /// virar um laço: sem ele, o leitor pediria o corpo de novo a cada
        /// redesenho de uma mensagem que nunca vai ter um.
        case buscado
    }

    private var bodyLoads: [String: BodyLoad] = [:]
    /// Já tentamos buscar o `.ics` desta mensagem. Sem isto, um cancelamento
    /// cujo anexo não veio ainda reabria a viagem a cada redesenho.
    private var icsBuscado: Set<String> = []

    /// Em que pé está o corpo desta mensagem. `nil` é "nunca foi preciso".
    public func bodyLoad(for messageID: String) -> BodyLoad? { bodyLoads[messageID] }

    /// Busca o corpo desta mensagem, se ela não tiver um e ninguém já estiver
    /// buscando.
    ///
    /// Quem chama é o leitor, ao abrir a mensagem. Todas as guardas são de
    /// "não fazer duas vezes o que já foi feito": sem porta, sem mensagem, com
    /// corpo, já buscando, já buscado ou já falhado — sai. A falha só volta a
    /// ser tentada por `retryBody(_:)`, que é a pessoa pedindo.
    public func loadBodyIfNeeded(_ messageID: String) async {
        guard let bodyPort else { return }
        if case .carregando = bodyLoads[messageID] { return }
        guard let raw = message(messageID) else { return }
        let faltaCorpo = raw.body.isEmpty || !raw.htmlResolved || raw.hasPendingInlineImages
        let faltaICS = raw.calendarICS == nil
            && raw.attachments.contains(where: \.looksLikeCalendarInvite)
            && !icsBuscado.contains(messageID)
        guard faltaCorpo || faltaICS else { return }
        if bodyLoads[messageID] != nil, !faltaICS { return }
        if faltaICS { icsBuscado.insert(messageID) }

        bodyLoads[messageID] = .carregando
        do {
            let corpo = try await bodyPort.fetchBody(
                accountID: raw.accountID, messageID: messageID
            )
            bodyLoads[messageID] = .buscado
            // O corpo **não** entra em `messages`: gravar HTML na lista
            // invalidava o cache de Tudo e o clique seguinte reconstruía a
            // caixa. O leitor lê `bodyStore` via `message(_:)`.
            let atual = message(messageID) ?? raw
            bodyStore[messageID] = LoadedBody(
                body: corpo.paragraphs.isEmpty ? atual.body : corpo.paragraphs,
                bodyHTML: corpo.html,
                calendarICS: corpo.calendarICS ?? atual.calendarICS,
                attachments: corpo.attachments
            )
            bodiesRevision &+= 1
        } catch is CancellationError {
            // A pessoa trocou de mensagem antes de a resposta chegar. Isso não
            // é falha e não pode virar uma faixa vermelha: o estado volta a
            // "nunca foi preciso", e voltar à mensagem tenta de novo.
            bodyLoads[messageID] = nil
        } catch {
            guard !Task.isCancelled else {
                bodyLoads[messageID] = nil
                return
            }
            bodyLoads[messageID] = .falhou(error.localizedDescription)
        }
    }

    /// O "Tentar de novo" da faixa de erro. Limpa a falha e busca outra vez.
    public func retryBody(_ messageID: String) async {
        bodyLoads[messageID] = nil
        icsBuscado.remove(messageID)
        await loadBodyIfNeeded(messageID)
    }

    // MARK: - Rascunhos de resposta

    /// O que foi escrito na faixa de resposta rápida, por mensagem respondida.
    ///
    /// Mora aqui, e não em `@State` da faixa, porque precisa sobreviver a duas
    /// coisas: a faixa fechar depois de "Responder aqui", e o "⤢" promover a
    /// resposta para a janela cheia — que é outra cena, com outra hierarquia de
    /// `View`. Perder o rascunho em qualquer um dos dois casos é pior do que
    /// não ter o botão.
    ///
    /// Marco 1 não tem rede nem disco: isto é memória da sessão, e é tudo o que
    /// o marco promete.
    private var replyDrafts: [String: ReplyDraft] = [:]

    /// O rascunho guardado para esta mensagem, se houver.
    ///
    /// **Interface para a janela 03 (`ComposerWindow`).** Quando o "⤢" da faixa
    /// abre a janela cheia, é daqui que ela deve semear "Para" e o corpo, em
    /// vez de recomeçar do zero.
    public func replyDraft(for messageID: String) -> ReplyDraft? {
        replyDrafts[messageID]
    }

    /// Guarda (ou apaga, com `nil`) o rascunho desta mensagem. Rascunho vazio
    /// não fica ocupando lugar: some, para "não salvo" voltar a ser verdade.
    public func setReplyDraft(_ draft: ReplyDraft?, for messageID: String) {
        guard let draft, !draft.isEmpty else {
            replyDrafts.removeValue(forKey: messageID)
            return
        }
        replyDrafts[messageID] = draft
    }

    /// Contagem por caixa, para os contadores da barra lateral, respeitando o filtro de conta.
    public func count(for bucket: TriageBucket) -> Int {
        let referenceDay = agendaReferenceDay()
        resetCountsCacheIfNeeded()
        let key = CountCacheKey(
            bucket: bucket.rawValue,
            accountID: selectedAccountID,
            dayStart: Calendar.current.startOfDay(for: referenceDay)
        )
        if let cached = bucketCountCache[key] { return cached }
        let index = messageListIndex()
        var n = 0
        for i in 0..<index.ids.count {
            guard isInBucket(
                messageBucket: index.buckets[i],
                receivedAt: index.dates[i],
                folderIDs: index.folderIDs[i],
                accountID: index.accountIDs[i],
                bucket: bucket,
                referenceDay: referenceDay
            ) else { continue }
            if let accountID = selectedAccountID, index.accountIDs[i] != accountID { continue }
            n += 1
        }
        bucketCountCache[key] = n
        return n
    }
}
