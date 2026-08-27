import Foundation
import Observation

/// De onde as mensagens vêm. No Marco 1 só existe a implementação em memória;
/// no Marco 2, Gmail, Graph e IMAP passam a conformar a este mesmo protocolo
/// e a UI não muda.
public protocol MailSource: Sendable {
    func accounts() async throws -> [Account]
    func messages() async throws -> [Message]
    func agenda() async throws -> [AgendaItem]
}

public struct InMemoryMailSource: MailSource {
    private let _accounts: [Account]
    private let _messages: [Message]
    private let _agenda: [AgendaItem]

    public init(accounts: [Account], messages: [Message], agenda: [AgendaItem]) {
        self._accounts = accounts
        self._messages = messages
        self._agenda = agenda
    }

    /// A agenda entra pela **semana inteira**, não só por hoje.
    ///
    /// Uma lista só é o que faz a janela 04 achar qualquer compromisso pelo
    /// `id`, inclusive o de quarta. Quem mostra um dia filtra por `dayOffset`:
    /// a trilha diária pede 0, a grade da semana agrupa. `Fixtures.week`
    /// contém `Fixtures.agenda`, então a terça é a mesma nos dois lugares.
    public static var fixtures: InMemoryMailSource {
        InMemoryMailSource(
            accounts: Fixtures.accounts,
            messages: Fixtures.messages,
            agenda: Fixtures.week
        )
    }

    public func accounts() async throws -> [Account] { _accounts }
    public func messages() async throws -> [Message] { _messages }
    public func agenda() async throws -> [AgendaItem] { _agenda }
}

@MainActor
@Observable
public final class MailStore {
    public private(set) var accounts: [Account] = []
    public private(set) var messages: [Message] = []
    public private(set) var agenda: [AgendaItem] = []

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
            // Só agora, se todos chegaram com sucesso:
            accounts = newAccounts
            messages = newMessages
            agenda = newAgenda
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
            detectedEvent: current.detectedEvent
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
        guard let index = messages.firstIndex(where: { $0.id == id }),
              !messages[index].isRead else { return }
        let m = messages[index]
        messages[index] = Message(
            id: m.id, accountID: m.accountID, from: m.from, receivedAt: m.receivedAt,
            subject: m.subject, snippet: m.snippet, body: m.body, tags: m.tags,
            bucket: m.bucket, isRead: true, summary: m.summary,
            detectedEvent: m.detectedEvent
        )
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
