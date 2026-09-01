import Foundation

/// O estado de triagem de **uma** mensagem, fotografado antes de uma ação.
///
/// É o caminho de volta de uma ação sobre a conversa inteira, e ele precisa ser
/// por mensagem: arquivar três mensagens que vieram de Hoje, Depois e Hoje e
/// desfazer com "todas para Hoje" devolveria uma delas ao lugar errado — a
/// mesma classe do "Desfazer" que adivinha a caixa e que `SwipeAction.undo` já
/// documenta.
public struct MessageState: Sendable, Hashable {
    public let messageID: String
    public let bucket: TriageBucket
    public let isRead: Bool
    public let isFlagged: Bool

    public init(messageID: String, bucket: TriageBucket, isRead: Bool, isFlagged: Bool) {
        self.messageID = messageID
        self.bucket = bucket
        self.isRead = isRead
        self.isFlagged = isFlagged
    }

    public init(_ message: Message) {
        self.init(
            messageID: message.id, bucket: message.bucket,
            isRead: message.isRead, isFlagged: message.isFlagged
        )
    }
}

/// Uma conversa: as mensagens que compartilham a mesma `conversationKey`,
/// dentro do recorte que a lista está mostrando.
///
/// **Uma linha da lista é uma conversa, não uma mensagem** — é o que o dono
/// viu no webmail e não via aqui: "Lembrete rápido: nossa call amanhã" com a
/// original e as duas respostas soltas em três linhas, e abrir uma não mostrava
/// as outras.
///
/// Mora em `UNICore` pela razão de sempre nesta base: agrupar, contar e ordenar
/// são regras puras, e uma `View` é `@MainActor` implícito no Swift 6 — um
/// `static` lá dentro herda o isolamento e um teste nonisolated que o chamasse
/// trapa em runtime. Ver `docs/decisoes-de-engenharia.md`.
public struct Conversation: Sendable, Hashable, Identifiable {
    /// A chave que juntou estas mensagens. É o `id` da linha da lista, e é
    /// estável entre retratos: o `ForEach` não recria a linha porque uma
    /// resposta nova chegou.
    public let key: String

    /// As mensagens, **da mais antiga para a mais nova** — a ordem em que a
    /// conversa aconteceu, e a que o modelo de resposta (`References`) lê.
    ///
    /// A pilha **na tela** é o contrário: ver `newestFirst`. Nunca vazia:
    /// `init` recusa a lista vazia devolvendo `nil`. Uma conversa sem
    /// mensagem nenhuma não é um estado, é um defeito — e deixá-la existir
    /// obrigaria toda leitura de `latest` a um `first` opcional.
    public let messages: [Message]

    public var id: String { key }

    public init?(key: String, messages: [Message]) {
        guard !messages.isEmpty else { return nil }
        self.key = key
        self.messages = messages
    }

    /// A mais recente — a que a linha da lista descreve e a que o leitor abre
    /// expandida. As ações da barra miram esta.
    public var latest: Message { messages[messages.count - 1] }

    /// A ordem da pilha no leitor: mais nova no topo, mais antiga embaixo.
    public var newestFirst: [Message] { Array(messages.reversed()) }

    public var count: Int { messages.count }

    public var messageIDs: [String] { messages.map(\.id) }

    /// A conversa tem alguma não lida?
    ///
    /// **Alguma**, e não "a mais recente": uma resposta antiga que ficou por
    /// ler continua sendo trabalho por fazer, e a linha tem de dizer isso. É a
    /// mesma regra do Gmail e do Mail.
    public var hasUnread: Bool { messages.contains { !$0.isRead } }

    /// A conversa tem alguma sinalizada — pela mesma razão de `hasUnread`.
    public var isFlagged: Bool { messages.contains { $0.isFlagged } }

    /// O selo de contagem da linha, **ou `nil` quando a conversa tem uma
    /// mensagem só**.
    ///
    /// `nil`, e não `"1"`: uma linha de conversa única tem de desenhar
    /// exatamente o que desenhava antes desta tarefa — é a condição byte a byte
    /// que os retratos do Marco 1 impõem.
    public var countLabel: String? { count > 1 ? String(count) : nil }

    public func contains(_ messageID: String?) -> Bool {
        guard let messageID else { return false }
        return messages.contains { $0.id == messageID }
    }

    /// Agrupa uma lista de mensagens em conversas.
    ///
    /// **A ordem de entrada é preservada**: quem chama já ordenou (a lista
    /// entrega as mais recentes primeiro), e a conversa aparece na posição da
    /// sua mensagem mais recente. Reordenar aqui faria a lista discordar do
    /// `visibleMessages` que a alimentou.
    ///
    /// Dentro da conversa a ordem é **cronológica crescente**, com o `id` como
    /// critério de desempate: duas mensagens no mesmo segundo (o que acontece
    /// numa importação) não podem trocar de lugar entre dois retratos.
    public static func build(from messages: [Message]) -> [Conversation] {
        var order: [String] = []
        var byKey: [String: [Message]] = [:]
        for message in messages {
            let key = message.conversationKey
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(message)
        }
        return order.compactMap { key in
            let inThread = (byKey[key] ?? []).sorted {
                $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt < $1.receivedAt
            }
            return Conversation(key: key, messages: inThread)
        }
    }
}

/// Um recorte da lista: as primeiras conversas da caixa, a contagem total e se
/// ainda há linha abaixo. A lista pede isto em páginas para Tudo não montar
/// milhares de `Conversation` no clique.
public struct ConversationPage: Sendable, Equatable {
    public let conversations: [Conversation]
    public let messageCount: Int
    public let hasMore: Bool

    public init(conversations: [Conversation], messageCount: Int, hasMore: Bool) {
        self.conversations = conversations
        self.messageCount = messageCount
        self.hasMore = hasMore
    }
}
