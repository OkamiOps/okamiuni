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
        dayOffset: Int = 0, replyHints: [String] = []
    ) {
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
    /// Só para testes e previews.
    public static func preview(
        id: String = "m1",
        bucket: TriageBucket = .today,
        dayOffset: Int = 0
    ) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: .now, subject: "Assunto", snippet: "Trecho",
            body: ["Corpo"], tags: [], bucket: bucket, isRead: false,
            summary: nil, detectedEvent: nil, dayOffset: dayOffset
        )
    }
}
