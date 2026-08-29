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

    public init(
        accounts: [Account], messages: [Message],
        agenda: [AgendaItem], pendingItems: [PendingItem]
    ) {
        self.accounts = accounts
        self.messages = messages
        self.agenda = agenda
        self.pendingItems = pendingItems
    }
}

extension MailSource {
    /// Um retrato, agora.
    public func snapshot() async throws -> MailSnapshot {
        MailSnapshot(
            accounts: try await accounts(),
            messages: try await messages(),
            agenda: try await agenda(),
            pendingItems: try await pendingItems()
        )
    }

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

    /// Os ids que a fonte achou pelo **corpo**, para a busca corrente.
    ///
    /// Vive aqui e não em `matches` porque procurar no corpo é `async` (é
    /// consulta ao índice do banco) e `visibleMessages` é síncrono — a lista
    /// não pode esperar disco a cada redesenho.
    private var bodyHits: Set<String> = []

    private let source: MailSource

    /// Para onde as seis mutações do Marco 3 são enviadas, quando há para
    /// onde enviar. `nil` é o caso das fixtures e de todo teste que não passa
    /// uma — o comportamento fica **idêntico** ao do Marco 1: só memória.
    ///
    /// Falha aqui nunca some silenciosa e nunca desfaz a mutação local — ela
    /// vira `loadError`, pelo mesmo `report(_:)` que a carga usa. A mutação
    /// otimista na lista continua valendo mesmo se a porta falhar: é UI que
    /// nunca espera rede, o mesmo princípio do Marco 2 aplicado à escrita.
    private let commandPort: MailCommandPort?

    /// Quem busca o corpo que o banco não tem. `nil` nas fixtures e em todo
    /// teste que não passa uma — e nesse caso `loadBodyIfNeeded` não faz nada,
    /// que é o comportamento do Marco 1 intacto.
    private let bodyPort: BodyFetching?

    /// Para onde vai o "Enviar" do composer. `nil` nas fixtures e em todo
    /// teste que não passa uma — e nesse caso a janela continua fechando sem
    /// mandar nada, que é o Marco 1 intacto. `canSend` é o que deixa a janela
    /// dizer a verdade sobre isso em vez de fingir que enviou.
    private let sendPort: MailSendPort?

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

    public init(
        source: MailSource,
        commandPort: MailCommandPort? = nil,
        bodyPort: BodyFetching? = nil,
        sendPort: MailSendPort? = nil,
        contactPort: ContactDirectoryPort? = nil
    ) {
        self.source = source
        self.commandPort = commandPort
        self.bodyPort = bodyPort
        self.sendPort = sendPort
        self.contactPort = contactPort
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

    /// Manda a mutação para a porta, se houver uma. Erro vira `loadError` —
    /// nunca é engolido — mas nunca desfaz o que já mudou em memória.
    private func send(_ operation: (MailCommandPort) throws -> Void) {
        guard let commandPort else { return }
        do {
            try operation(commandPort)
        } catch {
            report(error)
        }
    }

    public func load() async {
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
    private func apply(_ snapshot: MailSnapshot) {
        accounts = snapshot.accounts
        messages = snapshot.messages
        agenda = snapshot.agenda.sorted { $0.startMinute < $1.startMinute }
        pendingItems = snapshot.pendingItems
        loadError = nil
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
        if let item = agenda.first(where: { $0.id == id }) { removedFromAgenda[id] = item }
        agenda.removeAll { $0.id == id }
    }

    /// O que saiu da agenda, para "Desfazer" ter o que devolver — o mesmo
    /// cofre de sessão que `deleteForever` usa, e pelo mesmo motivo: fora da
    /// lista, o compromisso não sabe mais o horário nem a conta dele.
    private var removedFromAgenda: [String: AgendaItem] = [:]

    /// O "Desfazer" de "Tirar da agenda". Devolve o compromisso à ordenação
    /// por horário em que a trilha e as três grades o esperam.
    public func restoreToAgenda(_ id: String) {
        guard let item = removedFromAgenda.removeValue(forKey: id) else { return }
        guard !agenda.contains(where: { $0.id == id }) else { return }
        agenda.append(item)
        agenda.sort { $0.startMinute < $1.startMinute }
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
        messages.filter { message in
            guard message.bucket == .trash else { return false }
            guard let accountID else { return true }
            return message.accountID == accountID
        }.count
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
        guard let bodyPort, bodyLoads[messageID] == nil else { return }
        guard let message = messages.first(where: { $0.id == messageID }),
              message.body.isEmpty else { return }

        bodyLoads[messageID] = .carregando
        do {
            let paragrafos = try await bodyPort.fetchBody(
                accountID: message.accountID, messageID: messageID
            )
            bodyLoads[messageID] = .buscado
            // O corpo entra na lista agora. A porta já o gravou no banco, e o
            // retrato seguinte o traria — mas a mensagem está aberta na tela
            // enquanto isso, e esperar a observação acordar é um piscar de
            // "Carregando…" a mais por nada.
            guard !paragrafos.isEmpty,
                  let indice = messages.firstIndex(where: { $0.id == messageID }) else { return }
            messages[indice] = messages[indice].withBody(paragrafos)
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
        let inBucket = messages.filter { bucket.contains($0) }
        if let accountID = selectedAccountID {
            return inBucket.filter { $0.accountID == accountID }.count
        }
        return inBucket.count
    }
}
