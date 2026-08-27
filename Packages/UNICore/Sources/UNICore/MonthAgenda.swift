import Foundation

/// A grade do mês — seis linhas de sete dias — e a aritmética de navegação por
/// dia que sai dela.
///
/// Serve **duas** telas do protótipo com a mesma conta: a visão Mês (linhas
/// 1439–1462) e o seletor de data de 244pt da visão Dia (1409–1428). No
/// protótipo é literalmente a mesma constante `MONTH` nos dois lugares
/// (`monthWeeks` e `pickerDays`), e continuar assim é o que impede o ponto do
/// seletor e o cartão do mês discordarem sobre que dia tem compromisso.
///
/// Mora em `UNICore`, fora de qualquer `View`, pelo motivo já registrado em
/// `docs/decisoes-de-engenharia.md`: `View` é `@MainActor` implícito no Swift 6
/// e um `static` lá dentro trapa quando um teste nonisolated o chama.
public enum MonthAgenda {

    /// Os rótulos das colunas, de segunda a domingo — a ordem em que a grade
    /// desenha. Protótipo: `dowLabels` (linha 2363).
    ///
    /// Diferente de `WeekAgenda.weekdayLabels`, que é indexado pelo `weekday`
    /// do `Calendar` (1 = domingo): aqui o índice **é** a coluna.
    public static let columnLabels = ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"]

    /// Quantas linhas a grade tem, sempre.
    ///
    /// Fixo em 6, como o protótipo (`MONTH` tem seis linhas, e o `sc-for` do
    /// seletor anuncia 42 células). Um número variável faria a grade do mês
    /// mudar de altura de linha entre fevereiro e março, e o popover de 244pt
    /// mudar de altura ao navegar — a régua tem de ser a mesma o ano inteiro.
    public static let weekCount = 6

    /// Uma célula da grade.
    public struct Day: Sendable, Hashable, Identifiable {
        /// Dias inteiros a partir da âncora — o mesmo `dayOffset` do `AgendaItem`.
        public let dayOffset: Int
        /// O número que a célula mostra: 27, 28, …, 1, 2.
        public let dayNumber: Int
        /// Célula de outro mês — as pontas cinzas da grade. Protótipo: `out`.
        public let isOutsideMonth: Bool
        public let isToday: Bool
        /// Em ordem de início. A visão Mês desenha o título; o seletor só
        /// pergunta se está vazia.
        public let events: [AgendaItem]

        public init(
            dayOffset: Int, dayNumber: Int,
            isOutsideMonth: Bool, isToday: Bool, events: [AgendaItem]
        ) {
            self.dayOffset = dayOffset
            self.dayNumber = dayNumber
            self.isOutsideMonth = isOutsideMonth
            self.isToday = isToday
            self.events = events
        }

        public var id: Int { dayOffset }
        public var hasEvents: Bool { !events.isEmpty }
    }

    /// Uma linha da grade.
    public struct Week: Sendable, Hashable, Identifiable {
        public let index: Int
        public let days: [Day]

        public init(index: Int, days: [Day]) {
            self.index = index
            self.days = days
        }

        public var id: Int { index }
    }

    // MARK: - Os 42 deslocamentos

    /// Os deslocamentos em dias, a partir de `anchor`, das 42 células da grade
    /// do mês que contém `anchor`.
    ///
    /// A grade começa na segunda-feira da semana em que cai o dia 1º. Para
    /// agosto de 2026, ancorado em terça 25, dá `-29` (segunda 27 de julho) até
    /// `+12` (domingo 6 de setembro) — exatamente as pontas do `MONTH` do
    /// protótipo.
    ///
    /// Sai do calendário e não de uma lista fixa: o protótipo só tem um mês
    /// para desenhar, o app tem todos.
    public static func dayOffsets(for anchor: Date, calendar: Calendar = .current) -> [Int] {
        let start = gridStart(for: anchor, calendar: calendar)
        let anchorDay = calendar.startOfDay(for: anchor)
        let first = calendar.dateComponents([.day], from: anchorDay, to: start).day ?? 0
        return (0..<(weekCount * 7)).map { first + $0 }
    }

    /// A segunda-feira em que a grade abre: o dia 1º do mês da âncora, recuado
    /// até a segunda.
    private static func gridStart(for anchor: Date, calendar: Calendar = .current) -> Date {
        let anchorDay = calendar.startOfDay(for: anchor)
        let parts = calendar.dateComponents([.year, .month], from: anchorDay)
        let firstOfMonth = calendar.date(from: parts) ?? anchorDay
        // `weekday` do Calendar: 1 = domingo … 7 = sábado. A grade começa na
        // segunda, então segunda vira 0 e domingo vira 6 — a mesma conta de
        // `WeekAgenda.weekOffsets`, e pelo mesmo motivo: `Calendar.current`
        // pode começar a semana no domingo e a grade nunca começa.
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let indexInWeek = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -indexInWeek, to: firstOfMonth) ?? firstOfMonth
    }

    /// A faixa de dias que a grade cobre — o que o passo `‹ ›` e o seletor
    /// podem alcançar sem trocar de mês.
    ///
    /// Protótipo: `stepDay` trava em `w` entre 0 e `MONTH.length - 1` e `d`
    /// entre 0 e 6, ou seja, não sai da grade. Aqui é a mesma trava, escrita
    /// como faixa em vez de dois `if`.
    public static func offsetRange(
        for anchor: Date, calendar: Calendar = .current
    ) -> ClosedRange<Int> {
        let offsets = dayOffsets(for: anchor, calendar: calendar)
        return (offsets.first ?? 0)...(offsets.last ?? 0)
    }

    /// Um dia para frente ou para trás, sem sair da grade.
    public static func step(
        _ dayOffset: Int, by direction: Int, anchor: Date, calendar: Calendar = .current
    ) -> Int {
        let range = offsetRange(for: anchor, calendar: calendar)
        return min(max(dayOffset + direction, range.lowerBound), range.upperBound)
    }

    // MARK: - A grade montada

    /// As seis linhas da grade, já com os compromissos de cada dia.
    ///
    /// Compromissos fora das 42 células simplesmente não aparecem — a lista da
    /// store carrega o que quiser sem que a grade precise saber.
    public static func weeks(
        from items: [AgendaItem], anchor: Date, calendar: Calendar = .current
    ) -> [Week] {
        let anchorMonth = calendar.component(.month, from: anchor)
        let anchorYear = calendar.component(.year, from: anchor)
        let byDay = Dictionary(grouping: items, by: \.dayOffset)
        let anchorDay = calendar.startOfDay(for: anchor)

        let cells: [Day] = dayOffsets(for: anchor, calendar: calendar).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: anchorDay) ?? anchorDay
            let parts = calendar.dateComponents([.day, .month, .year], from: date)
            return Day(
                dayOffset: offset,
                dayNumber: parts.day ?? 1,
                isOutsideMonth: parts.month != anchorMonth || parts.year != anchorYear,
                isToday: offset == 0,
                events: (byDay[offset] ?? []).sorted {
                    ($0.startMinute, $0.id) < ($1.startMinute, $1.id)
                }
            )
        }

        return (0..<weekCount).map { row in
            Week(index: row, days: Array(cells[(row * 7)..<(row * 7 + 7)]))
        }
    }

    /// Quantos compromissos o **mês** tem — as pontas de julho e setembro ficam
    /// de fora. É o `calMeta` da visão Mês.
    ///
    /// O protótipo escreve a literal `'12 compromissos'`, que não bate com
    /// nenhuma contagem do próprio `MONTH` dele: é um número de maquete. Uma
    /// literal aqui estaria errada em todo mês que não fosse agosto de 2026 —
    /// o mesmo motivo pelo qual `WeekAgenda.monthTitle` deriva "Agosto 2026"
    /// em vez de cravar.
    public static func eventCount(
        from items: [AgendaItem], anchor: Date, calendar: Calendar = .current
    ) -> Int {
        weeks(from: items, anchor: anchor, calendar: calendar)
            .flatMap(\.days)
            .filter { !$0.isOutsideMonth }
            .reduce(0) { $0 + $1.events.count }
    }

    // MARK: - Rótulos de um dia solto

    /// "Terça, 25 de agosto" — o `calTitle` da visão Dia. Protótipo:
    /// `DOWLONG[st.dayD] + ', ' + day.n + ' de ' + monthName(...)`.
    public static func longDayTitle(
        dayOffset: Int, anchor: Date,
        calendar: Calendar = .current, locale: Locale = Locale(identifier: "pt_BR")
    ) -> String {
        let date = self.date(dayOffset: dayOffset, anchor: anchor, calendar: calendar)
        return DateLabels.eventDate(date, locale: locale)
    }

    /// "ter, 25 ago" — o rótulo do botão que abre o seletor. Protótipo:
    /// `DOW[st.dayD] + ', ' + day.n + ' ' + monthAbbr(...)`.
    ///
    /// O protótipo escreve o mês abreviado sem ponto (`'ago'`); o `pt_BR` do
    /// sistema devolve "ago." — o ponto cai aqui, para o botão de 26pt não
    /// ganhar um caractere que o desenho não tem.
    public static func shortDayLabel(
        dayOffset: Int, anchor: Date,
        calendar: Calendar = .current, locale: Locale = Locale(identifier: "pt_BR")
    ) -> String {
        let date = self.date(dayOffset: dayOffset, anchor: anchor, calendar: calendar)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateFormat = "EEE, d MMM"
        return formatter.string(from: date)
            .replacingOccurrences(of: ".", with: "")
            .lowercased(with: locale)
    }

    /// A data de um deslocamento. Só isto converte — o resto do módulo trabalha
    /// em dias inteiros, que não atravessam fuso.
    public static func date(
        dayOffset: Int, anchor: Date, calendar: Calendar = .current
    ) -> Date {
        calendar.date(byAdding: .day, value: dayOffset, to: anchor) ?? anchor
    }
}
