import Foundation

/// De que pedaços o título da faixa da agenda pode ser feito.
///
/// Existe por um defeito de layout, e não por gosto de abstração: a faixa
/// desenha `título · abas · ‹ seletor › Hoje · contagem` num `HStack`, e o
/// título mede o que a data que ele mostra medir. "Julho 2026" é mais estreito
/// que "Setembro 2026", então trocar de mês empurrava as abas e os botões para
/// os lados — o dono navegava com cliques repetidos em `›` e o botão fugia do
/// cursor.
///
/// O conserto é reservar ao título a largura do **maior** título que aquela
/// visão pode mostrar. Quem mede é o desenho, com a fonte que estiver de fato
/// disponível (uma constante em pontos mentiria na máquina onde a Newsreader
/// não está instalada); o que mora aqui são só as palavras a medir, que são
/// dado e não aparência.
///
/// **A largura de um texto é a soma das larguras dos pedaços dele**, então o
/// maior título da visão Dia é o maior prefixo somado ao maior sufixo: 7 + 12
/// medidas em vez dos 2.604 títulos possíveis. O corte cai **dentro do
/// número**, nunca num espaço, porque espaço na ponta de um texto pode não
/// entrar na medida.
///
/// Uma reserva um fio curta não faz nada andar — a fatia tem largura fixa e o
/// título apenas avança sobre o intervalo de 14pt que o separa das abas. É por
/// isso que "30" basta como pior caso de número: dois algarismos nunca medem
/// menos que um.
public enum CalendarTitleReserve {

    /// Onde o número do dia é cortado, para o prefixo e o sufixo não terminarem
    /// nem começarem em espaço.
    private static let worstDay = (head: "3", tail: "0")

    /// Os doze títulos que a visão Semana ou Mês pode mostrar no ano de `date`
    /// — "Janeiro 2026" … "Dezembro 2026".
    public static func monthTitles(
        inYearOf date: Date,
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "pt_BR")
    ) -> [String] {
        months(inYearOf: date, calendar: calendar).map {
            WeekAgenda.monthTitle(for: $0, locale: locale)
        }
    }

    /// A visão Dia, em dois pedaços: `("Terça, 3", "0 de agosto")`.
    ///
    /// A composição é a de `DateLabels.eventDate` — dia da semana, vírgula,
    /// número, " de ", mês —, e é por isso que este tipo mora ao lado dela.
    public static func longDayTitlePieces(
        inYearOf date: Date,
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "pt_BR")
    ) -> (prefixes: [String], suffixes: [String]) {
        let prefixes = weekdays(inYearOf: date, calendar: calendar).map {
            DateLabels.eventDate($0, locale: locale).weekdayPrefix + ", " + worstDay.head
        }
        let suffixes = months(inYearOf: date, calendar: calendar).map { mes in
            worstDay.tail + " de " + DateLabels.eventDate(mes, locale: locale).monthSuffix
        }
        return (prefixes, suffixes)
    }

    /// O botão que abre o seletor de data, no mesmo corte:
    /// `("ter, 3", "0 ago")`. A composição é a de
    /// `MonthAgenda.shortDayLabel`.
    public static func shortDayLabelPieces(
        inYearOf date: Date,
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "pt_BR")
    ) -> (prefixes: [String], suffixes: [String]) {
        let prefixes = weekdays(inYearOf: date, calendar: calendar).map {
            MonthAgenda.shortDayLabel(dayOffset: 0, anchor: $0, calendar: calendar, locale: locale)
                .weekdayPrefix + ", " + worstDay.head
        }
        let suffixes = months(inYearOf: date, calendar: calendar).map { mes in
            worstDay.tail + " "
                + MonthAgenda.shortDayLabel(
                    dayOffset: 0, anchor: mes, calendar: calendar, locale: locale
                ).monthSuffixShort
        }
        return (prefixes, suffixes)
    }

    /// Sete dias seguidos — um de cada dia da semana, em qualquer ordem.
    private static func weekdays(inYearOf date: Date, calendar: Calendar) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: date) }
    }

    /// O dia 20 de cada mês do ano de `date`. O dia 20 e não o 1º porque o
    /// nome do mês é a única coisa lida daqui, e 20 existe em fevereiro.
    private static func months(inYearOf date: Date, calendar: Calendar) -> [Date] {
        let ano = calendar.component(.year, from: date)
        return (1...12).compactMap {
            calendar.date(from: DateComponents(year: ano, month: $0, day: 20))
        }
    }
}

/// Os três recortes que a decomposição acima precisa. `fileprivate`: são
/// leituras do formato desta faixa, não vocabulário do pacote.
fileprivate extension String {
    /// "Terça" de "Terça, 25 de agosto" — o que vem antes da vírgula.
    var weekdayPrefix: String {
        String(prefix { $0 != "," })
    }

    /// "agosto" de "Terça, 25 de agosto" — o que vem depois do último " de ".
    var monthSuffix: String {
        guard let range = range(of: " de ", options: .backwards) else { return self }
        return String(self[range.upperBound...])
    }

    /// "ago" de "ter, 25 ago" — o que vem depois do último espaço.
    var monthSuffixShort: String {
        guard let range = range(of: " ", options: .backwards) else { return self }
        return String(self[range.upperBound...])
    }
}
