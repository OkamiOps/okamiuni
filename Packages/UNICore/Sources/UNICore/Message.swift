import Foundation

/// Etiqueta do protótipo: "Precisa resposta", "Compromisso", "Lead"...
public struct Tag: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Cor do design, em hex. `nil` usa `ink3` do tema.
    public let tintHex: String?

    public init(name: String, tintHex: String? = nil) {
        self.name = name
        self.tintHex = tintHex
    }
}

public enum TriageBucket: String, Sendable, CaseIterable {
    case today = "hoje"
    case later = "depois"
    case all = "todos"
    case archived = "arquivar"

    public var label: String {
        switch self {
        case .today: "Hoje"
        case .later: "Depois"
        case .all: "Tudo"
        case .archived: "Arquivado"
        }
    }

    /// `all` é uma visão, não um estado: aceita tudo.
    public func contains(_ message: Message) -> Bool {
        self == .all || message.bucket == self
    }
}

public struct Message: Sendable, Hashable, Identifiable {
    public let id: String
    public let accountID: String
    public let from: Contact

    /// Para quem a mensagem veio, e quem estava em cópia.
    ///
    /// Existem por causa do "Responder a todos", que sem eles não teria a quem
    /// responder: o seed é remetente + `to` + `cc` menos a conta dona. É dado
    /// da mensagem, como `from` — não da tela que a desenha.
    ///
    /// Aditivos (`[]` no `init`), e a lista vazia é **legítima**: a newsletter
    /// e o recibo das fixtures não trazem destinatário nenhum, e é sobre elas
    /// que o item "Responder a todos" aparece desabilitado em vez de sumir.
    /// Ver `ContextMenus.replyAllItem`.
    public let to: [Contact]
    public let cc: [Contact]

    public let receivedAt: Date

    /// Em que dia a mensagem chegou, em dias inteiros a partir do dia de
    /// referência: `0` é hoje, `-1` ontem. É daqui que sai o cabeçalho de
    /// grupo da lista ("Hoje", "Ontem"), como no design (`day: 'Hoje'`).
    ///
    /// **É dado, não derivação do relógio.** O agrupamento chamava
    /// `Calendar.isDateInToday(receivedAt)` contra o relógio da máquina, e
    /// como `Fixtures.today` é 25/08/2026 isso dava falso todo dia que não
    /// fosse aquele — a lista mostrava "25 DE AGO." onde o design mostra
    /// "Hoje". Mesma classe do bug de fuso registrado em
    /// `docs/decisoes-de-engenharia.md`: hora e dia de parede não podem
    /// nascer de uma conversão que a máquina do usuário pode errar.
    ///
    /// Pelo mesmo motivo que `AgendaItem.dayOffset` é `Int`, este também é —
    /// e não um rótulo pronto: "Hoje" e "Ontem" são texto de tela, e a
    /// terceira-feira retrasada não tem rótulo próprio. Traduzir offset em
    /// palavra é trabalho de quem desenha.
    ///
    /// Default `0` — mensagem que acabou de chegar é de hoje —, aditivo como
    /// o de `AgendaItem`.
    public let dayOffset: Int

    public let subject: String
    public let snippet: String
    public let body: [String]
    public let tags: [Tag]
    public let bucket: TriageBucket
    public let isRead: Bool

    /// A estrela do Gmail, a bandeira do Mail. Estado da mensagem, e não da
    /// caixa: uma mensagem arquivada continua sinalizada.
    ///
    /// Aditivo (`false` no `init`). **Não há caixa "Sinalizadas" neste
    /// marco** — dívida registrada no relatório da Task AR: o campo existe, a
    /// linha desenha a estrela e o menu a liga e desliga, mas filtrar por ela
    /// é de outra tarefa.
    public let isFlagged: Bool

    /// Resumo gerado no dispositivo. `nil` enquanto não houver.
    public let summary: String?
    public let detectedEvent: DetectedEvent?

    /// As respostas de um toque que o design oferece por mensagem —
    /// `replyHints: ['Confirmar quinta 15h', 'Pedir mais um dia']`. Vazio é
    /// legítimo: no design a newsletter e o recibo não têm nenhuma.
    ///
    /// Está aqui porque é dado **da mensagem**, não da faixa que o desenha: as
    /// sugestões saem do conteúdo dela. Quem desenha a faixa ainda não lê este
    /// campo — ver o relatório da Task Y.
    public let replyHints: [String]

    public init(
        id: String, accountID: String, from: Contact, receivedAt: Date,
        subject: String, snippet: String, body: [String],
        tags: [Tag], bucket: TriageBucket, isRead: Bool,
        summary: String?, detectedEvent: DetectedEvent?,
        dayOffset: Int = 0, replyHints: [String] = [],
        to: [Contact] = [], cc: [Contact] = [], isFlagged: Bool = false
    ) {
        self.to = to
        self.cc = cc
        self.isFlagged = isFlagged
        self.replyHints = replyHints
        self.id = id
        self.accountID = accountID
        self.from = from
        self.receivedAt = receivedAt
        self.dayOffset = dayOffset
        self.subject = subject
        self.snippet = snippet
        self.body = body
        self.tags = tags
        self.bucket = bucket
        self.isRead = isRead
        self.summary = summary
        self.detectedEvent = detectedEvent
    }
}

extension Message {
    /// A mesma mensagem com outro estado de leitura.
    ///
    /// Existe porque `Message` é imutável e reconstruí-la à mão em cada ponto
    /// que mexe em `isRead` já foi armadilha aqui: `dayOffset` e `replyHints`
    /// têm valor padrão no `init`, então esquecer de passá-los **compila** —
    /// e devolve uma mensagem de ontem sob o cabeçalho "Hoje", sem sugestões
    /// de resposta. Com três chamadores (abrir, marcar não lida, marcar a
    /// caixa inteira) a chance de repetir o esquecimento triplica.
    public func withRead(_ isRead: Bool) -> Message {
        copy(isRead: isRead)
    }

    /// A mesma mensagem noutra caixa. É o que `MailStore.move(_:to:)` usa.
    public func withBucket(_ bucket: TriageBucket) -> Message {
        copy(bucket: bucket)
    }

    /// A mesma mensagem com a estrela ligada ou desligada.
    public func withFlagged(_ isFlagged: Bool) -> Message {
        copy(isFlagged: isFlagged)
    }

    /// O único lugar que reconstrói uma `Message`.
    ///
    /// Cada campo novo com default no `init` é uma armadilha a mais para quem
    /// copia à mão — `dayOffset` e `replyHints` já custaram uma mensagem de
    /// ontem reaparecendo sob "Hoje". Com `to`, `cc` e `isFlagged` são cinco.
    /// Aqui a lista é escrita uma vez, e os três copiadores acima passam por
    /// ela; acrescentar um campo ao modelo quebra **este** arquivo, que é onde
    /// se quer que quebre.
    private func copy(
        bucket: TriageBucket? = nil,
        isRead: Bool? = nil,
        isFlagged: Bool? = nil
    ) -> Message {
        Message(
            id: id, accountID: accountID, from: from, receivedAt: receivedAt,
            subject: subject, snippet: snippet, body: body, tags: tags,
            bucket: bucket ?? self.bucket, isRead: isRead ?? self.isRead,
            summary: summary, detectedEvent: detectedEvent,
            dayOffset: dayOffset, replyHints: replyHints,
            to: to, cc: cc, isFlagged: isFlagged ?? self.isFlagged
        )
    }

    /// Só para testes e previews.
    public static func preview(
        id: String = "m1",
        bucket: TriageBucket = .today,
        dayOffset: Int = 0,
        to: [Contact] = [],
        cc: [Contact] = [],
        isFlagged: Bool = false
    ) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: .now, subject: "Assunto", snippet: "Trecho",
            body: ["Corpo"], tags: [], bucket: bucket, isRead: false,
            summary: nil, detectedEvent: nil, dayOffset: dayOffset,
            to: to, cc: cc, isFlagged: isFlagged
        )
    }
}
