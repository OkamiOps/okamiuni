import Foundation

/// Um compromisso na trilha lateral. `startMinute` e `endMinute` são minutos
/// desde a meia-noite, como o protótipo modela (`s: 570, e: 600`).
public struct AgendaItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let startMinute: Int
    public let endMinute: Int
    public let accountID: String

    public init(
        id: String, title: String,
        startMinute: Int, endMinute: Int, accountID: String
    ) {
        self.id = id
        self.title = title
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.accountID = accountID
    }

    public var durationMinutes: Int { endMinute - startMinute }

    /// "09:30"
    public var startLabel: String {
        String(format: "%02d:%02d", startMinute / 60, startMinute % 60)
    }

    /// "10:00"
    public var endLabel: String {
        String(format: "%02d:%02d", endMinute / 60, endMinute % 60)
    }

    /// "09:30 – 10:00". Protótipo: `fmt(s) + ' – ' + fmt(e)`, com espaço fino
    /// dos dois lados do travessão.
    public var rangeLabel: String { "\(startLabel) – \(endLabel)" }

    /// "45min", "1h", "1h30". Protótipo:
    /// `floor(d/60) ? floor(d/60) + 'h' + (d%60 ? d%60 : '') : d + 'min'`.
    /// Repare que a hora cheia não vira "1h00" — vira "1h".
    public var durationLabel: String {
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        guard hours > 0 else { return "\(durationMinutes)min" }
        return minutes > 0 ? "\(hours)h\(minutes)" : "\(hours)h"
    }
}

/// Rótulos de data que mais de uma tela escreve.
public enum DateLabels {
    /// "Terça, 25 de agosto" — o `dateLabel` que o protótipo passa para
    /// `openEvent`. Ele tem a lista `DOWLONG` escrita à mão ('Terça'), enquanto
    /// o `pt_BR` do sistema devolve "terça-feira": o sufixo cai aqui.
    public static func eventDate(_ date: Date, locale: Locale = Locale(identifier: "pt_BR")) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE, d 'de' MMMM"
        let text = formatter.string(from: date).replacingOccurrences(of: "-feira", with: "")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
