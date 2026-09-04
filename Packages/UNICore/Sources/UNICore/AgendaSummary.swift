import Foundation

/// Funções puras para análise de agenda, isoladas de SwiftUI e ator.
public struct AgendaSummary {
    /// Rótulo dinâmico para o item de agenda "próximo a rodar".
    /// Retorna uma das três frases:
    /// - "agora: <título> · termina HH:MM"
    /// - "em N min: <título>" (para N < 90)
    /// - "em NhMM: <título>" (para N >= 90, formatado em horas)
    /// - "nada mais hoje"
    public static func nextUpLabel(for items: [AgendaItem], now: Int) -> String {
        let fmt = { (m: Int) -> String in
            String(format: "%02d:%02d", m / 60, m % 60)
        }

        let vivos = items.filter { !$0.isCancelled }
        let running = vivos.first { now >= $0.startMinute && now < $0.endMinute }
        if let running = running {
            return L10n.tr("agora: \(running.title) · termina \(fmt(running.endMinute))")
        }

        let upcoming = vivos.first { $0.startMinute > now }
        if let upcoming = upcoming {
            let minLeft = upcoming.startMinute - now
            let duration = durationString(minLeft)
            return L10n.tr("em \(duration): \(upcoming.title)")
        }

        return L10n.tr("nada mais hoje")
    }

    /// Formata duração em minutos para string legível.
    /// < 90 min: "N min"
    /// >= 90 min: "NhMM" (ex: "2h30", "1h", "1h30")
    private static func durationString(_ minutes: Int) -> String {
        guard minutes >= 90 else {
            return L10n.tr("\(minutes) min")
        }

        let hours = minutes / 60
        let mins = minutes % 60

        if mins == 0 {
            return "\(hours)h"
        } else {
            return "\(hours)h\(mins)"
        }
    }
}
