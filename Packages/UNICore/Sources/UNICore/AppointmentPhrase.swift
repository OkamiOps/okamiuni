import Foundation

/// A frase que vira compromisso — lida **aqui**, na máquina, sem rede e sem
/// modelo de linguagem.
///
/// ## Por que não é IA
///
/// O protótipo mostra "amanhã 15h com a Marina sobre a proposta" virando um
/// evento e um cartão "ENTENDI ASSIM" que diz de onde cada pedaço saiu. A
/// tentação é mandar a frase para um modelo. Isso seria pior em todas as
/// dimensões que importam aqui: a folha abriria esperando rede, a mesma frase
/// daria resultados diferentes em dois dias, o cartão de explicação não teria o
/// que citar, e uma conta de IA passaria a ser requisito para criar um
/// compromisso. "amanhã 15h" não é uma pergunta difícil — é uma gramática
/// pequena e fechada, e gramática pequena e fechada se escreve.
///
/// O que entra: `NSDataDetector` para datas que ele já reconhece em português,
/// mais regras para o que ele erra ou ignora — "amanhã", "depois de amanhã",
/// os sete dias da semana, "15h", "15h30", "às 15", durações ("1h", "30min"),
/// e "com <nome>" para os convidados.
///
/// O que **não** entra: adivinhar título por tema, inferir local, decidir
/// fuso. Quando nada é reconhecido, `interpret` devolve `nil` em todos os
/// campos e a folha simplesmente abre os campos — que é o que o brief pede.
public struct AppointmentPhrase: Sendable, Equatable {

    /// Um pedaço reconhecido, com o trecho da frase que o produziu. É o que o
    /// cartão "ENTENDI ASSIM" mostra entre aspas: sem a citação, a pessoa não
    /// tem como saber se o app entendeu "15h" ou "às 15 de maio".
    public struct Piece: Sendable, Equatable {
        public let value: String
        public let source: String

        public init(value: String, source: String) {
            self.value = value
            self.source = source
        }
    }

    /// O título que sobrou depois de tirar data, hora, duração e convidados.
    public let title: String
    /// Nulo quando a frase não disse dia nem hora.
    public let start: Date?
    public let end: Date?
    /// Em minutos. Nulo quando a frase não disse duração — a folha usa 60.
    public let duration: Int?
    /// Os nomes que vieram depois de "com". Resolver nome → endereço é do
    /// chamador, que é quem tem a agenda de contatos.
    public let guestNames: [String]
    /// A citação de cada pedaço, para o cartão de explicação.
    public let dateSource: String?
    public let timeSource: String?

    /// `true` quando algo foi reconhecido — o único sinal que a folha precisa
    /// para decidir entre mostrar o cartão e abrir os campos.
    public var understood: Bool { start != nil || !guestNames.isEmpty }

    public init(
        title: String, start: Date?, end: Date?, duration: Int?,
        guestNames: [String], dateSource: String?, timeSource: String?
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.duration = duration
        self.guestNames = guestNames
        self.dateSource = dateSource
        self.timeSource = timeSource
    }

    public static let empty = AppointmentPhrase(
        title: "", start: nil, end: nil, duration: nil,
        guestNames: [], dateSource: nil, timeSource: nil
    )

    // MARK: - A leitura

    /// Lê a frase contra um "agora" dado. `now` é parâmetro, e não
    /// `Date()`, porque "amanhã" só é testável quando o teste escolhe que dia
    /// é hoje.
    public static func interpret(
        _ phrase: String,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> AppointmentPhrase {
        var calendar = calendar
        calendar.timeZone = TimeZone.current
        let raw = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .empty }

        var rest = raw
        var guestNames: [String] = []
        var dateSource: String?
        var timeSource: String?
        var duration: Int?

        // 1. "com a Marina", "com João e Ana" — antes de tudo, porque o nome
        //    não pode ser confundido com título e porque "com" é a única
        //    preposição deste vocabulário que introduz pessoa.
        if let found = guests(in: rest) {
            guestNames = found.names
            rest = remove(found.range, from: rest)
        }

        // 2. A duração, que é um número com unidade e **não** um horário:
        //    "por 30min", "de 1h". Lida antes da hora para "1h" preso a "por"
        //    não virar "01:00".
        if let found = explicitDuration(in: rest) {
            duration = found.minutes
            rest = remove(found.range, from: rest)
        }

        // 3. O dia.
        var day: Date?
        if let found = relativeDay(in: rest, now: now, calendar: calendar) {
            day = found.day
            dateSource = found.source
            rest = remove(found.range, from: rest)
        } else if let found = weekday(in: rest, now: now, calendar: calendar) {
            day = found.day
            dateSource = found.source
            rest = remove(found.range, from: rest)
        } else if let found = numericDay(in: rest, now: now, calendar: calendar) {
            day = found.day
            dateSource = found.source
            rest = remove(found.range, from: rest)
        }

        // 4. A hora.
        var clock: (hour: Int, minute: Int)?
        if let found = time(in: rest) {
            clock = (found.hour, found.minute)
            timeSource = found.source
            rest = remove(found.range, from: rest)
        }

        // 5. Sem dia e sem hora, o detector do sistema ainda pode achar uma
        //    data escrita por extenso ("15 de outubro às 15"). Só então: ele é
        //    bom nisso e ruim em "amanhã".
        if day == nil, clock == nil, let found = systemDetector(in: rest, now: now) {
            day = calendar.startOfDay(for: found.date)
            let parts = calendar.dateComponents([.hour, .minute], from: found.date)
            if (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0 {
                clock = (parts.hour ?? 0, parts.minute ?? 0)
                timeSource = found.source
            }
            dateSource = found.source
            rest = remove(found.range, from: rest)
        }

        // Hora sem dia é hoje — ou amanhã, se a hora já passou: ninguém
        // escreve "9h" às 18h querendo um compromisso no passado.
        var start: Date?
        if let clock {
            let base = day ?? calendar.startOfDay(for: now)
            var candidate = calendar.date(
                bySettingHour: clock.hour, minute: clock.minute, second: 0, of: base
            )
            if day == nil, let fixed = candidate, fixed < now {
                candidate = calendar.date(byAdding: .day, value: 1, to: fixed)
            }
            start = candidate
        } else if let day {
            // Dia sem hora: a próxima hora cheia **naquele** dia, a partir das
            // 9h, que é onde o dia de trabalho começa neste app.
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
        }

        let minutes = duration ?? 60
        let end = start.flatMap { calendar.date(byAdding: .minute, value: minutes, to: $0) }

        return AppointmentPhrase(
            title: cleanTitle(rest),
            start: start, end: end, duration: duration,
            guestNames: guestNames,
            dateSource: dateSource, timeSource: timeSource
        )
    }

    // MARK: - Convidados

    static let guestPrefixes = ["com a ", "com o ", "com as ", "com os ", "com "]

    private static func guests(in text: String) -> (names: [String], range: Range<String.Index>)? {
        for prefix in guestPrefixes {
            guard let found = text.range(of: prefix, options: .caseInsensitive) else { continue }
            // O nome vai até a próxima palavra de ligação — "sobre", "sobre
            // a", "às", "para" — ou até o fim da frase.
            let after = text[found.upperBound...]
            let stops = [" sobre ", " às ", " as ", " para ", " em ", " no ", " na ", " amanhã", " hoje"]
            var end = after.endIndex
            for stop in stops {
                if let s = after.range(of: stop, options: .caseInsensitive), s.lowerBound < end {
                    end = s.lowerBound
                }
            }
            let blob = String(after[after.startIndex..<end])
            let names = blob
                .replacingOccurrences(of: " e ", with: ",")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count > 1 }
            guard !names.isEmpty else { continue }
            return (names, found.lowerBound..<end)
        }
        return nil
    }

    // MARK: - Duração

    private static func explicitDuration(
        in text: String
    ) -> (minutes: Int, range: Range<String.Index>)? {
        // "por 30 min", "de 1h30", "por 2 horas". Só com preposição: "1h" sem
        // ela é horário.
        let pattern = "(?:por|de|durante)\\s+(\\d{1,2})\\s*(h|hora|horas)(?:\\s*(\\d{1,2}))?|(?:por|de|durante)\\s+(\\d{1,3})\\s*(min|minutos?)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text)
        else { return nil }
        func group(_ index: Int) -> Int? {
            guard let r = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[r])
        }
        if let hours = group(1) {
            return (hours * 60 + (group(3) ?? 0), range)
        }
        if let mins = group(4) {
            return (mins, range)
        }
        return nil
    }

    // MARK: - Dia

    private static func relativeDay(
        in text: String, now: Date, calendar: Calendar
    ) -> (day: Date, source: String, range: Range<String.Index>)? {
        // A ordem importa: "depois de amanhã" contém "amanhã".
        let table: [(String, Int)] = [
            ("depois de amanhã", 2), ("depois de amanha", 2),
            ("amanhã", 1), ("amanha", 1),
            ("hoje", 0),
        ]
        for (word, offset) in table {
            guard let found = text.range(of: word, options: .caseInsensitive) else { continue }
            guard let day = calendar.date(
                byAdding: .day, value: offset, to: calendar.startOfDay(for: now)
            ) else { continue }
            return (day, String(text[found]), found)
        }
        return nil
    }

    /// "segunda", "na terça", "sexta que vem". Sempre a **próxima** ocorrência:
    /// quem escreve "terça" na quarta quer a terça seguinte.
    private static func weekday(
        in text: String, now: Date, calendar: Calendar
    ) -> (day: Date, source: String, range: Range<String.Index>)? {
        let table: [(String, Int)] = [
            ("segunda", 2), ("terça", 3), ("terca", 3), ("quarta", 4), ("quinta", 5),
            ("sexta", 6), ("sábado", 7), ("sabado", 7), ("domingo", 1),
        ]
        for (word, weekday) in table {
            guard let found = text.range(of: word, options: .caseInsensitive) else { continue }
            let today = calendar.component(.weekday, from: now)
            var delta = weekday - today
            if delta <= 0 { delta += 7 }
            guard let day = calendar.date(
                byAdding: .day, value: delta, to: calendar.startOfDay(for: now)
            ) else { continue }
            return (day, String(text[found]), found)
        }
        return nil
    }

    /// "dia 20", "20/11", "20 de novembro".
    private static func numericDay(
        in text: String, now: Date, calendar: Calendar
    ) -> (day: Date, source: String, range: Range<String.Index>)? {
        let months = [
            "janeiro": 1, "fevereiro": 2, "março": 3, "marco": 3, "abril": 4, "maio": 5,
            "junho": 6, "julho": 7, "agosto": 8, "setembro": 9, "outubro": 10,
            "novembro": 11, "dezembro": 12,
        ]
        let pattern = "(?:dia\\s+)?(\\d{1,2})\\s*(?:/|\\s+de\\s+)\\s*([a-zç]+|\\d{1,2})"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text),
           let dayRange = Range(match.range(at: 1), in: text),
           let monthRange = Range(match.range(at: 2), in: text),
           let dayNumber = Int(text[dayRange])
        {
            let monthText = text[monthRange].lowercased()
            let month = Int(monthText) ?? months[String(monthText)]
            if let month, (1...12).contains(month), (1...31).contains(dayNumber) {
                var parts = calendar.dateComponents([.year], from: now)
                parts.month = month
                parts.day = dayNumber
                parts.hour = 0
                if let day = calendar.date(from: parts) {
                    // Data que já passou neste ano é do ano que vem.
                    let fixed = day < calendar.startOfDay(for: now)
                        ? calendar.date(byAdding: .year, value: 1, to: day) ?? day
                        : day
                    return (fixed, String(text[range]), range)
                }
            }
        }
        return nil
    }

    // MARK: - Hora

    private static func time(
        in text: String
    ) -> (hour: Int, minute: Int, source: String, range: Range<String.Index>)? {
        // "15h", "15h30", "15:30", "às 15", "9 da manhã", "3 da tarde".
        let pattern = "(?:à?s?\\s*)?(\\d{1,2})\\s*(?:h|:)\\s*(\\d{2})?|(?:às|as)\\s+(\\d{1,2})(?:\\s*(?:da|de)\\s*(manhã|manha|tarde|noite))?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        if let hourText = group(1), let hour = Int(hourText), hour <= 23 {
            let minute = group(2).flatMap { Int($0) } ?? 0
            guard minute <= 59 else { return nil }
            return (hour, minute, String(text[range]), range)
        }
        if let hourText = group(3), var hour = Int(hourText), hour <= 23 {
            let period = group(4)?.lowercased()
            if let period, period.hasPrefix("tarde") || period.hasPrefix("noite"), hour < 12 {
                hour += 12
            }
            // "às 3" sem período, num app de trabalho, é 15h e não 3 da manhã.
            if period == nil, hour < 8 { hour += 12 }
            return (hour, 0, String(text[range]), range)
        }
        return nil
    }

    // MARK: - O detector do sistema

    private static func systemDetector(
        in text: String, now: Date
    ) -> (date: Date, source: String, range: Range<String.Index>)? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let date = match.date,
              let found = Range(match.range, in: text)
        else { return nil }
        _ = now
        return (date, String(text[found]), found)
    }

    // MARK: - O que sobra é o título

    private static func remove(_ range: Range<String.Index>, from text: String) -> String {
        var copy = text
        copy.removeSubrange(range)
        return copy
    }

    /// Tira as palavras de ligação que sobraram sozinhas e devolve o resto com
    /// a primeira letra em maiúscula — "sobre a proposta" vira "Proposta".
    static func cleanTitle(_ text: String) -> String {
        var words = text
            .replacingOccurrences(of: "  ", with: " ")
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")) }
            .filter { !$0.isEmpty }
        let fillers: Set<String> = [
            "sobre", "a", "o", "as", "os", "de", "da", "do", "para", "em", "no", "na",
            "às", "as", "e", "um", "uma", "marcar", "agendar", "criar", "reunião",
        ]
        while let first = words.first?.lowercased(), fillers.contains(first) {
            words.removeFirst()
        }
        while let last = words.last?.lowercased(), fillers.contains(last) {
            words.removeLast()
        }
        guard let first = words.first else { return "" }
        words[0] = first.prefix(1).uppercased() + first.dropFirst()
        return words.joined(separator: " ")
    }
}
