import Foundation

/// A aritmética da grade semanal, isolada de SwiftUI e de ator.
///
/// Mora aqui, e não num `static` dentro da `View`, porque no Swift 6 uma `View`
/// é implicitamente `@MainActor`: o `static` herdaria o isolamento e o teste
/// `nonisolated` trapava em runtime.
public enum WeekAgenda {

    // MARK: - Dias da semana

    /// Os rótulos curtos das colunas, como o protótipo escreve:
    /// `['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom']`.
    ///
    /// Indexado pelo `weekday` do `Calendar` (1 = domingo), não pela posição na
    /// coluna — por isso começa em "dom".
    public static let weekdayLabels = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]

    /// Os deslocamentos em dias que formam a semana **de segunda a domingo** que
    /// contém `date`.
    ///
    /// Para a terça 25/08/2026 dá `[-1, 0, 1, 2, 3, 4, 5]` — segunda 24 a
    /// domingo 30, que é a semana que o protótipo desenha. Sai do dia da semana
    /// e não de uma lista fixa, então uma âncora em qualquer outro dia continua
    /// produzindo a semana certa.
    /// Os sete dias da semana visível, **em offsets relativos ao `anchor`**.
    ///
    /// `focusOffset` diz qual semana mostrar: 0 é a do `anchor`, 7 a seguinte,
    /// −7 a anterior. Os offsets continuam contados do `anchor` porque é assim
    /// que `AgendaItem.dayOffset` é medido — deslocar o próprio `anchor` faria
    /// os compromissos escorregarem junto com a grade.
    public static func weekOffsets(
        for date: Date, focusOffset: Int = 0, calendar: Calendar = .current
    ) -> [Int] {
        let focused = calendar.date(byAdding: .day, value: focusOffset, to: date) ?? date
        // `weekday` do Calendar: 1 = domingo … 7 = sábado.
        // A grade começa na segunda, então segunda precisa virar 0 e domingo 6.
        let weekday = calendar.component(.weekday, from: focused)
        let indexInWeek = (weekday + 5) % 7
        return (0..<7).map { focusOffset + $0 - indexInWeek }
    }

    /// O número ISO da semana — o "semana 35" do cabeçalho.
    ///
    /// ISO 8601 de propósito: o `Calendar.current` do usuário pode começar a
    /// semana no domingo, e aí a numeração andaria um dia em relação à grade,
    /// que é sempre de segunda a domingo.
    public static func weekNumber(for date: Date) -> Int {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = Calendar.current.timeZone
        return iso.component(.weekOfYear, from: date)
    }

    /// "Agosto 2026" — o título do cabeçalho.
    ///
    /// O protótipo escreve a literal, porque só tem um mês para mostrar. Aqui
    /// sai da âncora: uma literal ficaria errada em qualquer outra semana.
    public static func monthTitle(
        for date: Date, locale: Locale = Locale(identifier: "pt_BR")
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "MMMM yyyy"
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - Filtro por dia

    /// Os compromissos de um dia, em ordem de início.
    ///
    /// A lista da `MailStore` carrega a semana inteira numa lista só — é o que
    /// deixa a janela 04 achar qualquer compromisso pelo `id`. Filtrar por dia
    /// é responsabilidade de quem consome: a trilha diária pede `0`, a grade da
    /// semana pede um dia por coluna.
    ///
    /// A ordenação desempata pelo `id` porque `sorted(by:)` do Swift não é
    /// estável: sem o desempate, dois compromissos que começam no mesmo minuto
    /// podiam trocar de lugar entre execuções e levar as faixas junto.
    public static func items(on dayOffset: Int, in items: [AgendaItem]) -> [AgendaItem] {
        items
            .filter { $0.dayOffset == dayOffset }
            .sorted { ($0.startMinute, $0.id) < ($1.startMinute, $1.id) }
    }

    // MARK: - Faixas de sobreposição

    /// Um compromisso já com a faixa que ele ocupa na coluna do dia.
    /// `column` é o índice da faixa (0 é a mais à esquerda) e `columns` quantas
    /// faixas o grupo sobreposto abriu.
    public struct Placed: Sendable, Hashable, Identifiable {
        public let item: AgendaItem
        public let column: Int
        public let columns: Int

        public init(item: AgendaItem, column: Int, columns: Int) {
            self.item = item
            self.column = column
            self.columns = columns
        }

        public var id: String { item.id }
    }

    /// Divide compromissos sobrepostos em faixas lado a lado.
    /// Protótipo: `lanes(evs)`.
    ///
    /// A regra é a do protótipo, inclusive no detalhe que importa: um grupo
    /// cresce enquanto o próximo começa **antes do fim mais tardio já visto**
    /// (`e.s < end`, com `end` acumulando o máximo), não antes do fim do
    /// anterior. É isso que faz A(9–12), B(10–11) e C(11:30–12:30) caírem no
    /// mesmo grupo de três faixas: C não encosta em B, mas encosta em A.
    ///
    /// Encostar sem invadir não conta como sobreposição: um evento que começa
    /// exatamente no minuto em que o outro termina abre grupo novo.
    public static func lanes(_ events: [AgendaItem]) -> [Placed] {
        let sorted = events.sorted {
            $0.startMinute != $1.startMinute
                ? $0.startMinute < $1.startMinute
                : ($0.endMinute != $1.endMinute ? $0.endMinute > $1.endMinute : $0.id < $1.id)
        }

        var groups: [[AgendaItem]] = []
        var current: [AgendaItem] = []
        var end = Int.min

        for event in sorted {
            if !current.isEmpty && event.startMinute < end {
                current.append(event)
                end = max(end, event.endMinute)
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [event]
                end = event.endMinute
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.flatMap { group in
            group.enumerated().map {
                Placed(item: $0.element, column: $0.offset, columns: group.count)
            }
        }
    }

    // MARK: - A semana montada

    /// Uma coluna da grade.
    public struct Day: Sendable, Hashable, Identifiable {
        /// Dias inteiros a partir da âncora — o mesmo `dayOffset` do `AgendaItem`.
        public let dayOffset: Int
        /// O número que a coluna mostra: 24, 25, …
        public let dayNumber: Int
        /// "seg", "ter", …
        public let weekdayLabel: String
        public let isToday: Bool
        public let events: [Placed]

        public init(
            dayOffset: Int, dayNumber: Int, weekdayLabel: String,
            isToday: Bool, events: [Placed]
        ) {
            self.dayOffset = dayOffset
            self.dayNumber = dayNumber
            self.weekdayLabel = weekdayLabel
            self.isToday = isToday
            self.events = events
        }

        public var id: Int { dayOffset }
    }

    /// As sete colunas da semana que contém `anchor`, já com as faixas
    /// resolvidas.
    ///
    /// `anchor` é o "hoje" do app (`Fixtures.today` no Marco 1), e é dele que
    /// saem os números dos dias. Compromissos com `dayOffset` fora da semana
    /// simplesmente não aparecem — a lista da store pode carregar mais do que
    /// sete dias sem que a grade precise saber disso.
    public static func days(
        from items: [AgendaItem], anchor: Date, focusOffset: Int = 0,
        calendar: Calendar = .current
    ) -> [Day] {
        weekOffsets(for: anchor, focusOffset: focusOffset, calendar: calendar).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: anchor) ?? anchor
            let weekday = calendar.component(.weekday, from: date)
            return Day(
                dayOffset: offset,
                dayNumber: calendar.component(.day, from: date),
                weekdayLabel: weekdayLabels[(weekday - 1) % 7],
                isToday: offset == 0,
                events: lanes(self.items(on: offset, in: items))
            )
        }
    }
}
