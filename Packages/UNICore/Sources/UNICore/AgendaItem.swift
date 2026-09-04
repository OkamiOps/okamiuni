import Foundation

/// Um compromisso na trilha lateral. `startMinute` e `endMinute` são minutos
/// desde a meia-noite, como o protótipo modela (`s: 570, e: 600`).
public struct AgendaItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let startMinute: Int
    public let endMinute: Int
    public let accountID: String

    /// Em que dia o compromisso cai, contado em dias inteiros a partir de
    /// `Fixtures.today`: `0` é hoje, `-1` ontem, `+2` depois de amanhã.
    ///
    /// **É um inteiro, e não uma `Date`, de propósito.** O resto do tipo modela
    /// horário como minutos desde a meia-noite justamente para não atravessar
    /// fuso; guardar o dia como `Date` reintroduziria a conversão que já foi
    /// bug aqui — `Fixtures.today` fixada num fuso, o minuto lido com
    /// `Calendar.current`, e a agenda marcando "agora" às 17:00 em Berlim.
    /// Um deslocamento em dias não atravessa fuso nenhum.
    ///
    /// **Dívida deliberada.** No Marco 4, com o EventKit, isto vira data real
    /// e o offset sai. Até lá ele é o que permite uma lista só carregar a
    /// semana inteira: a trilha diária filtra `dayOffset == 0`, a grade da
    /// semana agrupa por ele, e a janela 04 continua achando qualquer item
    /// pelo `id`.
    ///
    /// O default `0` é aditivo: todo call site que existia antes da semana
    /// continua compilando e continua significando "hoje".
    public let dayOffset: Int

    /// O `UID` do convite que gerou este compromisso — a identidade que o
    /// iCalendar dá ao evento, igual em todas as cópias dele.
    ///
    /// **É a guarda contra a agenda em dobro.** Sem ele, o convite original e o
    /// "Convite atualizado" do mesmo evento eram dois compromissos, e cada
    /// encaminhamento seria mais um: foram os dois "DreamSquad" idênticos da
    /// tela do dono.
    ///
    /// `nil` no compromisso que não veio de convite — o detectado no texto de
    /// um email, o da agenda de exemplo. Aditivo, como `dayOffset` foi.
    ///
    /// **Agora é coluna também.** Era só modelo, e a nota antiga aqui dizia que
    /// "a agenda ainda é de sessão" — dívida que o dono cobrou do jeito mais
    /// direto: "coloco o item no calendário e ao fechar e abrir o OkamiUNI a
    /// agenda some". A M3-11 a pagou com a migração v5 e a tabela
    /// `created_agenda_item`, e é este `UID` guardado que faz "✓ Na agenda"
    /// sobreviver ao reinício em vez de o cartão oferecer de novo o que já está
    /// lá. Ver `AgendaPersisting`.
    ///
    /// Quando o Marco 4 trouxer o EventKit, este campo é o que casa com o
    /// `calendarItemExternalIdentifier` de lá.
    public let calendarUID: String?

    /// O `SEQUENCE` da versão do convite que este compromisso reflete. É contra
    /// ele que um "Convite atualizado" se anuncia como mais novo.
    public let calendarSequence: Int?

    /// O que a janela 04 mostra além do horário — local, link, organizador,
    /// participantes, descrição — **quando o compromisso trouxe isso**.
    ///
    /// `nil` é o compromisso da agenda de exemplo, e aí a janela cai em
    /// `Fixtures.eventDetail(for:)` como sempre caiu. Era o único caminho que
    /// existia: um compromisso criado de um convite do Favini abria com "Sem
    /// local definido", organizador "Ricardo Gomes · ricardo@empresa.com" e a
    /// nota "Criado manualmente na agenda" — dado de fixture numa reunião de
    /// verdade.
    public let detail: EventDetail?

    /// Calendário do macOS de onde o compromisso veio. `nil` é item criado
    /// pelo OkamiUNI a partir de um email — a lateral agrupa esses em
    /// `ConnectedCalendar.email`.
    public let calendarID: String?
    public let calendarTitle: String?
    public let calendarColorHex: String?
    public let calendarSource: String?

    /// Como o Google Agenda: o compromisso continua no dia, desenhado
    /// transparente. `false` no compromisso ativo.
    public let isCancelled: Bool

    public init(
        id: String, title: String,
        startMinute: Int, endMinute: Int, accountID: String,
        dayOffset: Int = 0,
        calendarUID: String? = nil,
        calendarSequence: Int? = nil,
        detail: EventDetail? = nil,
        calendarID: String? = nil,
        calendarTitle: String? = nil,
        calendarColorHex: String? = nil,
        calendarSource: String? = nil,
        isCancelled: Bool = false
    ) {
        self.calendarUID = calendarUID
        self.calendarSequence = calendarSequence
        self.detail = detail
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.calendarSource = calendarSource
        self.isCancelled = isCancelled
        self.id = id
        self.title = title
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.accountID = accountID
        self.dayOffset = dayOffset
    }

    /// O mesmo compromisso noutro calendário da lateral, sem mexer no resto.
    public func withCalendar(_ calendar: ConnectedCalendar) -> AgendaItem {
        AgendaItem(
            id: id, title: title,
            startMinute: startMinute, endMinute: endMinute,
            accountID: accountID, dayOffset: dayOffset,
            calendarUID: calendarUID, calendarSequence: calendarSequence,
            detail: detail,
            calendarID: calendar.id, calendarTitle: calendar.title,
            calendarColorHex: calendar.colorHex, calendarSource: calendar.source,
            isCancelled: isCancelled
        )
    }

    public func markingCancelled() -> AgendaItem {
        guard !isCancelled else { return self }
        return AgendaItem(
            id: id, title: title,
            startMinute: startMinute, endMinute: endMinute,
            accountID: accountID, dayOffset: dayOffset,
            calendarUID: calendarUID, calendarSequence: calendarSequence,
            detail: detail,
            calendarID: calendarID, calendarTitle: calendarTitle,
            calendarColorHex: calendarColorHex, calendarSource: calendarSource,
            isCancelled: true
        )
    }

    /// Chave estável para o cancelamento que chegou por email: o EventKit
    /// guarda outro `calendarUID` que o `UID` do iCalendar.
    public var cancellationFingerprint: String {
        Self.cancellationFingerprint(title: title, startMinute: startMinute)
    }

    public static func cancellationFingerprint(title: String, startMinute: Int) -> String {
        let nome = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(nome)|\(startMinute)"
    }

    public var durationMinutes: Int { endMinute - startMinute }

    /// "09:30"
    ///
    /// A regra em si mora em `MinuteFormat`, que é a mesma que a grade usa nos
    /// rótulos de hora e o "Livre hoje" usa nas lacunas. Três cópias divergem
    /// no primeiro ajuste; esta chama a única.
    public var startLabel: String { MinuteFormat.clock(startMinute) }

    /// "10:00"
    public var endLabel: String { MinuteFormat.clock(endMinute) }

    /// "09:30 – 10:00". Protótipo: `fmt(s) + ' – ' + fmt(e)`, com espaço fino
    /// dos dois lados do travessão.
    public var rangeLabel: String { MinuteFormat.range(startMinute, endMinute) }

    /// "45min", "1h", "1h30". Protótipo:
    /// `floor(d/60) ? floor(d/60) + 'h' + (d%60 ? d%60 : '') : d + 'min'`.
    /// Repare que a hora cheia não vira "1h00" — vira "1h".
    public var durationLabel: String { MinuteFormat.duration(durationMinutes) }
}

/// Rótulos de data que mais de uma tela escreve.
public enum DateLabels {
    /// "Terça, 25 de agosto" — o `dateLabel` que o protótipo passa para
    /// `openEvent`. Ele tem a lista `DOWLONG` escrita à mão ('Terça'), enquanto
    /// o `pt_BR` do sistema devolve "terça-feira": o sufixo cai aqui.
    public static func eventDate(_ date: Date, locale: Locale = L10n.locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let text = formatter.string(from: date)
        let withoutWeekdaySuffix = locale.language.languageCode?.identifier == "pt"
            ? text.replacingOccurrences(of: "-feira", with: "")
            : text
        return withoutWeekdaySuffix.prefix(1).uppercased() + withoutWeekdaySuffix.dropFirst()
    }
}
