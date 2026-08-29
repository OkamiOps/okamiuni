import Foundation

/// Um dia do calendário civil: ano, mês e dia, e mais nada.
///
/// ## Por que não uma `Date`
///
/// Pelo mesmo motivo que `AgendaItem` guarda horário como minuto desde a
/// meia-noite e dia como deslocamento: **fuso não atravessa o modelo**. Uma
/// `Date` é um instante absoluto, e gravar "30 de agosto" como instante obriga
/// quem lê a escolher um fuso para o traduzir de volta — a conversão que já foi
/// bug aqui, com a agenda marcando "agora" às 17:00 em Berlim.
///
/// Três inteiros não têm fuso nenhum. "30 de agosto de 2026" é 30 de agosto de
/// 2026 em qualquer máquina, e continua sendo depois de uma viagem.
///
/// ## Por que não o `dayOffset` cru
///
/// Porque `dayOffset` é **relativo**, e o que ele é relativo a muda. Com uma
/// conta conectada, o "hoje" das telas de agenda é o relógio da máquina
/// (`AgendaClock.live`): um compromisso gravado como `+1` seria "amanhã" hoje,
/// "amanhã" amanhã e "amanhã" na semana que vem — o compromisso andando um dia
/// a cada abertura, para sempre. O deslocamento é bom para a tela, que sabe
/// contra que dia está contando; é péssimo para o disco, que não sabe.
///
/// A conversão nos dois sentidos mora aqui, e é a única fronteira: quem grava
/// converte deslocamento em dia civil, quem lê converte de volta contra o
/// "hoje" daquela abertura.
public struct CivilDay: Sendable, Hashable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// "2026-08-30" — a forma em que o dia vai para o banco.
    ///
    /// Escrita à mão, sem `DateFormatter`: um formatador carrega fuso e
    /// calendário, que é exatamente o que este tipo existe para não carregar.
    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// A volta de `iso`. `nil` para qualquer coisa que não seja três números
    /// nessa ordem — uma linha estragada no banco vale menos que um dia errado.
    public init?(iso: String) {
        let partes = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard partes.count == 3,
              let year = Int(partes[0]), let month = Int(partes[1]), let day = Int(partes[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// O dia civil a que `dayOffset` aponta, contado a partir de `reference`.
    public static func from(
        dayOffset: Int, reference: Date, calendar: Calendar = .current
    ) -> CivilDay {
        let dia = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: reference))
            ?? reference
        let partes = calendar.dateComponents([.year, .month, .day], from: dia)
        return CivilDay(
            year: partes.year ?? 0, month: partes.month ?? 1, day: partes.day ?? 1
        )
    }

    /// O deslocamento em dias deste dia civil em relação a `reference`. É a
    /// volta exata de `from(dayOffset:reference:)`.
    public func dayOffset(from reference: Date, calendar: Calendar = .current) -> Int {
        var partes = DateComponents()
        partes.year = year
        partes.month = month
        partes.day = day
        guard let dia = calendar.date(from: partes) else { return 0 }
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: dia)
        ).day ?? 0
    }
}

/// Um compromisso **como ele é guardado**: tudo o que o `AgendaItem` e o
/// `EventDetail` dele carregam, com o dia em calendário civil no lugar do
/// deslocamento.
///
/// Existe para a fronteira ter um tipo. Sem ele, ou a porta de gravação
/// receberia um `AgendaItem` e teria de conhecer o "hoje" para o converter (uma
/// segunda cópia da regra de fuso, longe daqui), ou o `dayOffset` iria cru para
/// o disco — que é o defeito que o dono viu do outro lado, o compromisso
/// andando de dia.
public struct StoredAgendaItem: Sendable, Hashable {
    public let id: String
    public let title: String
    public let startMinute: Int
    public let endMinute: Int
    public let accountID: String
    public let day: CivilDay
    public let calendarUID: String?
    public let calendarSequence: Int?
    public let detail: EventDetail?

    public init(
        id: String, title: String, startMinute: Int, endMinute: Int,
        accountID: String, day: CivilDay,
        calendarUID: String? = nil, calendarSequence: Int? = nil, detail: EventDetail? = nil
    ) {
        self.id = id
        self.title = title
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.accountID = accountID
        self.day = day
        self.calendarUID = calendarUID
        self.calendarSequence = calendarSequence
        self.detail = detail
    }

    /// O compromisso da tela virando o compromisso do disco.
    public init(_ item: AgendaItem, referenceDay: Date, calendar: Calendar = .current) {
        self.init(
            id: item.id, title: item.title,
            startMinute: item.startMinute, endMinute: item.endMinute,
            accountID: item.accountID,
            day: CivilDay.from(
                dayOffset: item.dayOffset, reference: referenceDay, calendar: calendar
            ),
            calendarUID: item.calendarUID,
            calendarSequence: item.calendarSequence,
            detail: item.detail
        )
    }

    /// E a volta, contra o "hoje" **desta** abertura.
    public func item(referenceDay: Date, calendar: Calendar = .current) -> AgendaItem {
        AgendaItem(
            id: id, title: title,
            startMinute: startMinute, endMinute: endMinute,
            accountID: accountID,
            dayOffset: day.dayOffset(from: referenceDay, calendar: calendar),
            calendarUID: calendarUID,
            calendarSequence: calendarSequence,
            detail: detail
        )
    }
}

/// Onde os compromissos que a **pessoa** criou sobrevivem ao fechar o app.
///
/// "Coloco o item no calendário e ao fechar e abrir o OkamiUNI a agenda some" —
/// e sumia mesmo: `MailStore.addToAgenda` acrescentava à lista em memória, o
/// retrato seguinte vinha do banco (ou das fixtures), e a lista era substituída
/// inteira. Nada escrevia.
///
/// **Só o que a pessoa criou.** A agenda de exemplo continua nascendo das
/// fixtures a cada abertura, e a agenda de um servidor é o Marco 4: esta porta
/// guarda o compromisso que só existe porque alguém clicou "Colocar na agenda".
///
/// Síncrona de propósito: quem lê é a montagem do retrato, que não pode esperar
/// — e a leitura é uma tabela pequena de SQLite local, do mesmo tamanho que a
/// UI já paga para desenhar. `nil` nas fixtures e em todo teste que não passa
/// uma, e nesse caso o comportamento é o do Marco 1, intacto.
public protocol AgendaPersisting: Sendable {
    /// Grava ou substitui. É a mesma chamada para "Colocar na agenda" e para
    /// "Atualizar na agenda": o `id` é o que manda, e ele é estável.
    func saveAgendaItem(_ item: StoredAgendaItem) throws

    /// Tira. Sem erro quando não havia nada — "Desfazer" duas vezes chega ao
    /// mesmo estado a que se pretendia chegar.
    func removeAgendaItem(_ id: String) throws

    /// Tudo o que está guardado.
    func savedAgendaItems() throws -> [StoredAgendaItem]
}
