import Foundation

/// Funções puras para análise de agenda, isoladas de SwiftUI e ator.
public struct AgendaSummary {
    /// Rótulo dinâmico para o item de agenda "próximo a rodar".
    /// Retorna uma das três frases:
    /// - "agora: <título> · termina HH:MM"
    /// - "em N min: <título>"
    /// - "nada mais hoje"
    public static func nextUpLabel(for items: [AgendaItem], now: Int) -> String {
        let fmt = { (m: Int) -> String in
            String(format: "%02d:%02d", m / 60, m % 60)
        }

        let running = items.first { now >= $0.startMinute && now < $0.endMinute }
        if let running = running {
            return "agora: \(running.title) · termina \(fmt(running.endMinute))"
        }

        let upcoming = items.first { $0.startMinute > now }
        if let upcoming = upcoming {
            let minLeft = upcoming.startMinute - now
            return "em \(minLeft) min: \(upcoming.title)"
        }

        return "nada mais hoje"
    }
}
