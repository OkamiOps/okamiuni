import UNICore

/// Como o nome de um calendário cabe na trilha recolhida.
///
/// A trilha tem 72pt e a marca ocupa 40 — igual à da caixa de email
/// (`HostMark`). Cor sozinha não identifica: "Google", "Trabalho" e
/// "contato@meusite.com" viram três pílulas iguais. A marca é renderização,
/// não modelo: o título inteiro continua no `help`.
public enum CalendarMark {

    /// A marca de três letras: "Todoist" → "TOD", "Work" → "WOR",
    /// "contato@hostinger.com" → "HOS".
    public static func rail(_ calendar: ConnectedCalendar) -> String {
        HostMark.rail(stem(of: calendar))
    }

    /// Quando dois calendários cairiam na mesma marca, a primeira letra da
    /// origem entra na frente: Google/Work e iCloud/Work viram "GWO" e "IWO".
    public static func rail(_ calendar: ConnectedCalendar, among siblings: [ConnectedCalendar]) -> String {
        let base = rail(calendar)
        let clash = siblings.contains { $0.id != calendar.id && rail($0) == base }
        guard clash else { return base }
        let sourceLetter = HostMark.rail(calendar.source).prefix(1)
        let rest = HostMark.rail(stem(of: calendar)).prefix(2)
        return String(sourceLetter + rest).uppercased()
    }

    /// De onde saem as três letras: o título, ou o host de um endereço
    /// (`contato@hostinger.com` → `hostinger`, não `con`).
    public static func stem(of calendar: ConnectedCalendar) -> String {
        stem(from: calendar.title)
    }

    public static func stem(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.firstIndex(of: "@") {
            let domain = String(trimmed[trimmed.index(after: at)...])
            if let host = domain.split(separator: ".").first, !host.isEmpty {
                return String(host)
            }
        }
        let words = trimmed.split { $0.isWhitespace || $0 == "-" || $0 == "/" }
        if words.count >= 2 {
            let initials = words.prefix(HostMark.railLetters).compactMap(\.first)
            if initials.count >= 2 { return String(initials) }
        }
        return trimmed
    }
}
