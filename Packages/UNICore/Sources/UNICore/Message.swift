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
    /// A lixeira. É um lugar de verdade, e não um sumiço: a mensagem continua
    /// no store, na caixa Lixeira, até alguém a apagar definitivamente ou
    /// esvaziar a caixa.
    case trash = "lixeira"
    /// O que **você** mandou. É caixa, e não estado de triagem: uma mensagem
    /// enviada não é "não lida", não entra em Hoje e não conta em selo de não
    /// lidas nenhum — ver `contains(_:)` e `TriageBucket.triage`.
    case sent = "enviadas"

    /// As caixas do **fluxo** de triagem, na ordem da barra lateral.
    ///
    /// Enviadas fica de fora, e é para isso que esta lista existe: `allCases`
    /// serve para desenhar a barra (que mostra a caixa nova) e esta serve para
    /// tudo o que é triagem — mover uma mensagem recebida para Enviadas não
    /// quer dizer nada, e "Marcar tudo como lido" numa caixa que nasce lida
    /// também não.
    public static let triage: [TriageBucket] = [.today, .later, .all, .archived, .trash]

    public var label: String {
        switch self {
        case .today: "Hoje"
        case .later: "Depois"
        case .all: "Tudo"
        case .archived: "Arquivado"
        case .trash: "Lixeira"
        case .sent: "Enviadas"
        }
    }

    /// `all` é uma visão, não um estado — mas ela **não** mostra a lixeira.
    ///
    /// É como Gmail, Outlook e Mail se comportam, e não é cosmético: "Tudo"
    /// com a lixeira dentro faria apagar não ter efeito visível nenhum na
    /// caixa que a pessoa costuma deixar aberta, e o contador dela continuaria
    /// somando o que ela acabou de jogar fora. Apagar tem de parecer apagar.
    ///
    /// O mesmo vale para os contadores e para `markAllRead`, que passam por
    /// aqui: eles herdam a regra em vez de a repetirem.
    /// Enviadas fica de fora de "Tudo" pela mesma razão que a Lixeira: "Tudo" é
    /// a visão da **triagem**, do que chegou e ainda pede decisão. Com o que
    /// você escreveu dentro dela, a caixa que a pessoa deixa aberta o dia
    /// inteiro passaria a crescer a cada mensagem respondida — e o contador
    /// dela contaria as respostas como se fossem trabalho por fazer.
    public func contains(_ message: Message) -> Bool {
        if self == .all { return message.bucket != .trash && message.bucket != .sent }
        return message.bucket == self
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

    /// Anexos recebidos. São só metadados; os bytes saem de `AttachmentFetching`
    /// quando a pessoa decide salvar um deles.
    public let attachments: [MailAttachment]

    /// O HTML da mensagem, já sanitizado por quem a decodificou.
    ///
    /// **Três valores, três significados** — os mesmos da coluna `html` da v3:
    /// `nil` é "esta mensagem nunca passou pelo decodificador que conhece
    /// HTML", e é o que faz o leitor pedir o corpo uma vez ao abrir; `""` é
    /// "passou, e ela não tem HTML" — só-texto fica só-texto; e o resto é o
    /// HTML que o leitor desenha. Ver `hasHTML` e `htmlResolved`, que são as
    /// duas perguntas que a interface faz de verdade.
    ///
    /// Aditivo (`nil` no `init`): as fixtures do Marco 1 não têm HTML nenhum, e
    /// é por isso que o leitor delas continua desenhando exatamente os mesmos
    /// parágrafos de antes.
    public let bodyHTML: String?

    /// O `text/calendar` cru do convite, quando a mensagem trouxe um. Quem o
    /// lê é `ICalendar`; quem o desenha é o cartão do leitor.
    public let calendarICS: String?

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

    /// O id que o **servidor** dá a esta mensagem, opaco para nós.
    ///
    /// Gmail: o `id` da `messages.get`. IMAP: o UID, em texto. Nulo nas
    /// fixtures e em qualquer mensagem que não nasceu de um servidor — é
    /// aditivo, como `dayOffset` foi.
    ///
    /// Opaco de verdade: nada no app interpreta este texto, faz `switch` sobre
    /// ele nem presume formato. Quem precisa de um id **nosso** usa
    /// `Message.id`, que `UNISync.MessageIdentity` monta de forma estável.
    public let serverID: String?

    /// O `UIDVALIDITY` da pasta IMAP de onde o UID veio. Nulo para Gmail e
    /// para as fixtures.
    ///
    /// Existe porque UID sozinho não identifica nada: o servidor pode trocar o
    /// `UIDVALIDITY` da pasta e reciclar os UIDs desde 1. Guardar o par é o que
    /// permite ao Marco 3 detectar a troca e refazer a pasta em vez de casar
    /// mensagem errada com mensagem errada.
    public let uidValidity: Int64?

    /// O `Message-ID` do RFC 5322 desta mensagem, **sem** os sinais de menor e
    /// maior — `uuid@dominio`, a mesma forma pelada que `OutgoingMessage`
    /// guarda, para não haver duas leituras do mesmo campo.
    ///
    /// É a identidade que atravessa servidores: é por ela que a resposta que
    /// **nós** mandamos sabe a quem responde (`In-Reply-To`), e é por ela que
    /// uma mensagem filha acha a mãe dentro do banco.
    ///
    /// Aditivo (`nil`): as fixtures do Marco 1 não têm cabeçalho nenhum, e as
    /// linhas gravadas antes da v4 também não.
    public let rfcMessageID: String?

    /// A corrente da conversa, da mais antiga para a mais nova, sem `<>` — o
    /// cabeçalho `References`, ou o `In-Reply-To` sozinho quando é só o que a
    /// mensagem trouxe.
    ///
    /// Vazia é o caso comum e legítimo: toda mensagem que **abre** uma conversa
    /// não responde a nada.
    public let references: [String]

    /// A chave da conversa a que esta mensagem pertence.
    ///
    /// Derivada por `UNISync.ThreadKey` na hora de gravar, e **guardada** — não
    /// recalculada a cada retrato: a derivação olha a mensagem-mãe no banco, e
    /// refazê-la por linha a cada leitura da lista seria uma consulta por linha.
    ///
    /// `nil` é "ninguém derivou chave para esta mensagem" — o caso das fixtures
    /// do Marco 1. Quem agrupa cai em `conversationKey`, que devolve o `id`:
    /// mensagem sem chave é uma conversa de uma mensagem só, que é exatamente o
    /// que o Marco 1 mostrava.
    public let threadKey: String?

    /// Em que pastas do provedor esta mensagem está.
    ///
    /// Uma no IMAP (a pasta em que ela mora), várias no Gmail (os rótulos dela,
    /// que **são** as pastas de lá), nenhuma nas fixtures do Marco 1 — que é o
    /// valor padrão e o que faz a barra lateral sem conta continuar sendo a de
    /// sempre.
    ///
    /// Lista, e não um id só, porque o Gmail não cabe num id só: a mesma
    /// mensagem está em "Faturas" e em "Clientes" ao mesmo tempo, e escolher uma
    /// das duas faria a outra pasta abrir sem ela.
    public let folderIDs: [String]

    public init(
        id: String, accountID: String, from: Contact, receivedAt: Date,
        subject: String, snippet: String, body: [String],
        tags: [Tag], bucket: TriageBucket, isRead: Bool,
        summary: String?, detectedEvent: DetectedEvent?,
        dayOffset: Int = 0, replyHints: [String] = [],
        to: [Contact] = [], cc: [Contact] = [], isFlagged: Bool = false,
        serverID: String? = nil, uidValidity: Int64? = nil,
        bodyHTML: String? = nil, calendarICS: String? = nil,
        rfcMessageID: String? = nil, references: [String] = [],
        threadKey: String? = nil, folderIDs: [String] = [],
        attachments: [MailAttachment] = []
    ) {
        self.folderIDs = folderIDs
        self.rfcMessageID = rfcMessageID
        self.references = references
        self.threadKey = threadKey
        self.bodyHTML = bodyHTML
        self.calendarICS = calendarICS
        self.serverID = serverID
        self.uidValidity = uidValidity
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
        self.attachments = attachments
        self.tags = tags
        self.bucket = bucket
        self.isRead = isRead
        self.summary = summary
        self.detectedEvent = detectedEvent
    }
}

extension Message {
    /// Quem a linha da lista escreve na primeira linha.
    ///
    /// O remetente, quase sempre — mas **o destinatário em Enviadas**, como
    /// Mail.app e Gmail fazem. Numa caixa em que o remetente é sempre você, a
    /// coluna do remetente repetiria o seu nome em toda linha e esconderia a
    /// única informação que distingue uma mensagem da outra: para quem ela foi.
    ///
    /// Aqui, e não dentro da `View`: é regra do produto, e a mesma pergunta é
    /// feita pela linha da lista e por quem a testa. Uma mensagem enviada sem
    /// destinatário nenhum (a que só tem cópia oculta, por exemplo) cai no
    /// remetente — dizer o seu nome é menos errado do que uma linha vazia.
    public var listHeadline: String {
        guard bucket == .sent else { return from.name }
        let nomes = to.map { $0.name.isEmpty ? $0.address : $0.name }
            .filter { !$0.isEmpty }
        return nomes.isEmpty ? from.name : nomes.joined(separator: ", ")
    }

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

    /// Por qual chave esta mensagem se agrupa numa conversa.
    ///
    /// `threadKey` quando alguém a derivou; o **próprio id** quando não —
    /// e é aí que mora a garantia de que o Marco 1 continua igual: um id é
    /// único por construção, então uma mensagem sem chave nunca se junta a
    /// ninguém. A lista das fixtures desenha sete conversas de uma mensagem.
    public var conversationKey: String { threadKey ?? id }

    /// A mensagem tem HTML para desenhar?
    ///
    /// `""` não conta: ele é o carimbo de "decodificada, e sem HTML". Sem esta
    /// distinção o leitor abriria uma WebView vazia por cima do texto.
    public var hasHTML: Bool { !(bodyHTML ?? "").isEmpty }

    /// Alguém já perguntou ao decodificador se esta mensagem tem HTML?
    ///
    /// É a guarda contra a rebusca eterna: `false` só nas linhas gravadas antes
    /// da v3, e cada uma delas custa **uma** ida ao servidor, na primeira vez
    /// que a pessoa a abrir. Depois disso a resposta está no banco, seja ela
    /// qual for.
    public var htmlResolved: Bool { bodyHTML != nil }

    /// O HTML gravado ainda tem imagem embutida por buscar?
    ///
    /// **É a terceira razão para rebuscar um corpo.** A do Gmail: a imagem
    /// dentro da mensagem quase sempre chega como `attachmentId`, e o corpo
    /// gravado por quem não a foi buscar guarda um vazio de 1×1 no lugar da
    /// foto — a newsletter que é só imagem abre em branco, e o email com uma
    /// foto no meio abre com um buraco. Ver `InlineImagePlaceholder`, que também
    /// explica por que a imagem que só era **grande demais** não cai aqui: ela
    /// não tem conserto, e rebuscá-la seria uma viagem por abertura, para
    /// sempre.
    public var hasPendingInlineImages: Bool {
        InlineImagePlaceholder.temPendente(bodyHTML)
    }

    /// A mesma mensagem com o corpo que a busca por demanda acabou de trazer.
    ///
    /// A porta (`BodyFetching`) grava no banco, e o retrato seguinte traria o
    /// corpo de qualquer jeito — mas "o retrato seguinte" é uma observação
    /// assíncrona, e a mensagem está **aberta na tela** enquanto isso. Pôr o
    /// corpo aqui é o que faz o texto aparecer no instante em que ele chega, em
    /// vez de no instante em que o SQLite acorda quem observa.
    public func withBody(
        _ body: [String], html: String?, calendarICS: String?, attachments: [MailAttachment]? = nil
    ) -> Message {
        copy(body: body, bodyHTML: html, calendarICS: calendarICS, attachments: attachments)
    }

    /// O único lugar que reconstrói uma `Message`.
    ///
    /// Cada campo novo com default no `init` é uma armadilha a mais para quem
    /// copia à mão — `dayOffset` e `replyHints` já custaram uma mensagem de
    /// ontem reaparecendo sob "Hoje". Com `to`, `cc`, `isFlagged`, `serverID` e
    /// `uidValidity` são sete. Aqui a lista é escrita uma vez, e os três
    /// copiadores acima passam por ela.
    private func copy(
        bucket: TriageBucket? = nil,
        isRead: Bool? = nil,
        isFlagged: Bool? = nil,
        body: [String]? = nil,
        bodyHTML: String?? = nil,
        calendarICS: String?? = nil,
        attachments: [MailAttachment]? = nil
    ) -> Message {
        Message(
            id: id, accountID: accountID, from: from, receivedAt: receivedAt,
            subject: subject, snippet: snippet, body: body ?? self.body, tags: tags,
            bucket: bucket ?? self.bucket, isRead: isRead ?? self.isRead,
            summary: summary, detectedEvent: detectedEvent,
            dayOffset: dayOffset, replyHints: replyHints,
            to: to, cc: cc, isFlagged: isFlagged ?? self.isFlagged,
            serverID: serverID, uidValidity: uidValidity,
            // `String??` e não `String?`: o `nil` de fora é "não mexe", e o
            // `.some(nil)` é "apaga". Sem os dois níveis não haveria como
            // devolver uma mensagem ao estado de "nunca decodificada".
            bodyHTML: bodyHTML ?? self.bodyHTML,
            calendarICS: calendarICS ?? self.calendarICS,
            // Os três da conversa atravessam toda cópia. Esquecê-los aqui é a
            // armadilha que este método existe para não ter: marcar uma
            // mensagem como lida a tiraria da conversa dela, e isso **compila**.
            rfcMessageID: rfcMessageID, references: references, threadKey: threadKey,
            // Pela mesma razão dos três acima: arquivar uma mensagem não a tira
            // da pasta do provedor em que ela está, e esquecê-la aqui **compila**
            // — a mensagem sumiria da pasta aberta no instante em que alguém a
            // marcasse como lida.
            folderIDs: folderIDs, attachments: attachments ?? self.attachments
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
