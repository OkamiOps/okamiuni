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
}

public struct InMemoryMailSource: MailSource {
    private let _accounts: [Account]
    private let _messages: [Message]
    private let _agenda: [AgendaItem]
    private let _pendingItems: [PendingItem]

    public init(
        accounts: [Account], messages: [Message], agenda: [AgendaItem],
        pendingItems: [PendingItem] = []
    ) {
        self._accounts = accounts
        self._messages = messages
        self._agenda = agenda
        self._pendingItems = pendingItems
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
}

@MainActor
@Observable
public final class MailStore {
    public private(set) var accounts: [Account] = []
    public private(set) var messages: [Message] = []
    public private(set) var agenda: [AgendaItem] = []
    public private(set) var pendingItems: [PendingItem] = []

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
    public private(set) var selectedMessageID: String?
    public private(set) var selectedAccountID: String?
    public var query: String = ""
    public private(set) var loadError: String?

    private let source: MailSource

    public init(source: MailSource) {
        self.source = source
    }

    public func load() async {
        do {
            // Buscar os três valores em variáveis locais, antes de atualizar o estado.
            // Isto garante atomicidade: ou todos os três chegam, ou nenhuma propriedade muda.
            let newAccounts = try await source.accounts()
            let newMessages = try await source.messages()
            let newAgenda = try await source.agenda().sorted { $0.startMinute < $1.startMinute }
            let newPendingItems = try await source.pendingItems()
            // Só agora, se todos chegaram com sucesso:
            accounts = newAccounts
            messages = newMessages
            agenda = newAgenda
            pendingItems = newPendingItems
            loadError = nil
            // O protótipo abre com uma mensagem já aberta no leitor
            // (`state = { … selected: 'm1' … }`, a primeira da caixa "hoje").
            // O estado vazio fica reservado para uma caixa de fato vazia.
            selectDefaultMessage()
        } catch {
            // Em erro, nenhuma propriedade muda; o estado anterior continua válido.
            loadError = error.localizedDescription
        }
    }

    /// Mensagens da caixa atual que casam com a busca, mais recentes primeiro.
    public var visibleMessages: [Message] {
        let inBucket = messages.filter { bucket.contains($0) }
        let inAccount = selectedAccountID == nil
            ? inBucket
            : inBucket.filter { $0.accountID == selectedAccountID }
        let searched = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? inAccount
            : inAccount.filter { matches($0, query) }
        return searched.sorted { $0.receivedAt > $1.receivedAt }
    }

    /// A agenda depois do filtro de conta.
    ///
    /// Clicar numa caixa filtra a lista **e** a grade da agenda. O protótipo
    /// aplica `st.account` só à lista, mas isso é lacuna dele: uma caixa
    /// selecionada que não mexe na agenda deixa metade da janela mentindo sobre
    /// o que está sendo mostrado.
    public var visibleAgenda: [AgendaItem] {
        guard let selectedAccountID else { return agenda }
        return agenda.filter { $0.accountID == selectedAccountID }
    }

    /// `pendingItems` depois do mesmo filtro de conta que `visibleAgenda`
    /// aplica. É o que a seção "Vindo do email" da trilha deve ler: seguindo
    /// o padrão de `visibleAgenda`, uma caixa selecionada não pode deixar a
    /// seção citando um item de outra conta.
    public var visiblePendingItems: [PendingItem] {
        guard let selectedAccountID else { return pendingItems }
        return pendingItems.filter { $0.accountID == selectedAccountID }
    }

    // MARK: - Agenda a partir de um email

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
    @discardableResult
    public func addToAgenda(_ event: DetectedEvent, from message: Message) -> AgendaItem? {
        let id = DetectedEventConversion.agendaID(forMessageID: message.id)
        guard !agenda.contains(where: { $0.id == id }) else { return nil }

        let item = DetectedEventConversion.agendaItem(
            from: event, id: id, accountID: message.accountID, referenceDay: Fixtures.today
        )
        agenda.append(item)
        agenda.sort { $0.startMinute < $1.startMinute }
        return item
    }

    /// O "Desfazer" de `addToAgenda`. Tira o item pelo `id` que ela devolveu.
    ///
    /// Sem guarda contra `id` ausente: desfazer o que já não está lá — outra
    /// pessoa apagou por outro caminho, ou "Desfazer" foi clicado duas vezes
    /// — não é erro, é o mesmo estado a que se pretendia chegar.
    public func removeFromAgenda(_ id: String) {
        agenda.removeAll { $0.id == id }
    }

    private func matches(_ message: Message, _ term: String) -> Bool {
        [message.from.name, message.from.address, message.subject, message.snippet]
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }

    /// Aponta o leitor para a primeira mensagem da visão atual.
    ///
    /// Só age quando a seleção corrente não está mais na visão (ou não existe),
    /// então recarregar não tira o usuário da mensagem que ele estava lendo.
    /// A escolha sai sempre de `visibleMessages`, então a seleção padrão nunca
    /// aponta para fora do que a lista mostra — e numa caixa vazia ela é `nil`,
    /// que é quando o estado vazio do leitor deve aparecer.
    private func selectDefaultMessage() {
        let visible = visibleMessages
        if let current = selectedMessageID, visible.contains(where: { $0.id == current }) {
            return
        }
        selectedMessageID = visible.first?.id
    }

    public var selectedMessage: Message? {
        guard let selectedMessageID else { return nil }
        return messages.first { $0.id == selectedMessageID }
    }

    public func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    public func select(bucket newBucket: TriageBucket) {
        bucket = newBucket
        // Limpar sem reescolher deixava o leitor vazio com mensagens na lista.
        // `selectDefaultMessage()` só age quando a seleção saiu da visão, então
        // ele preserva quem continua visível e escolhe a primeira quando não.
        selectDefaultMessage()
    }

    public func select(account id: String?) {
        if selectedAccountID == id {
            // Clicar de novo na mesma conta desliga o filtro
            selectedAccountID = nil
        } else {
            selectedAccountID = id
        }
        selectDefaultMessage()
    }

    public func select(message id: String) {
        selectedMessageID = id
        markRead(id)
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

        if let filtered = selectedAccountID, filtered != message.accountID {
            selectedAccountID = nil
        }
        if !bucket.contains(message) {
            bucket = message.bucket
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
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let current = messages[index]
        guard current.bucket != newBucket else { return }

        // Onde ela estava na lista, para saber quem herda a seleção.
        let positionBefore = visibleMessages.firstIndex { $0.id == current.id }

        messages[index] = Message(
            id: current.id, accountID: current.accountID, from: current.from,
            receivedAt: current.receivedAt, subject: current.subject,
            snippet: current.snippet, body: current.body, tags: current.tags,
            bucket: newBucket, isRead: current.isRead, summary: current.summary,
            detectedEvent: current.detectedEvent,
            // `dayOffset` e `replyHints` têm default: omitir aqui não daria
            // erro de compilação, daria uma mensagem de ontem reaparecendo sob
            // "Hoje" e as sugestões de resposta sumindo depois de mudar de
            // caixa. Triagem não muda quando ela chegou nem o que ela diz.
            dayOffset: current.dayOffset, replyHints: current.replyHints
        )

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

    private func markRead(_ id: String) {
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
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].isRead != isRead else { return }
        messages[index] = messages[index].withRead(isRead)
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
        for index in messages.indices where !messages[index].isRead {
            let message = messages[index]
            guard bucket.contains(message) else { continue }
            if let accountID, message.accountID != accountID { continue }
            messages[index] = message.withRead(true)
        }
    }

    /// Quantas não lidas há numa caixa, com o mesmo recorte de
    /// `markAllRead(in:accountID:)`.
    ///
    /// É o que decide se "Marcar tudo como lido" **entra** no menu: com zero
    /// não lidas o item some, em vez de aparecer desabilitado dizendo que a
    /// caixa tem o que marcar.
    public func unreadCount(in bucket: TriageBucket, accountID: String? = nil) -> Int {
        messages.filter { message in
            guard !message.isRead, bucket.contains(message) else { return false }
            guard let accountID else { return true }
            return message.accountID == accountID
        }.count
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
        let inBucket = messages.filter { bucket.contains($0) }
        if let accountID = selectedAccountID {
            return inBucket.filter { $0.accountID == accountID }.count
        }
        return inBucket.count
    }
}
