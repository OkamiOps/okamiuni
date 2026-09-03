import Foundation
import UNICore

/// A coluna "Seu dia" do 08, decidida fora da `View`.
///
/// O mockup mistura quatro coisas numa lista só: os compromissos de hoje, o
/// marcador "Agora", o bloco sugerido de respostas e os prazos (de hoje com
/// hora, dos outros dias com o dia da semana). A ordem é a do relógio, e é
/// regra — então mora aqui, com teste próprio, e a `View` só desenha a lista
/// que sai pronta.
enum DashboardDay {

    /// Uma linha da coluna do dia.
    enum Entry: Hashable {
        /// Compromisso de hoje: hora, título, subtítulo.
        case event(id: String, hour: String, title: String, sub: String)
        /// O agora — versalete em accent com a hairline a 50%.
        case now
        /// O bloco sugerido de `DayPlan.replyBlock`.
        case plan(hour: String, title: String, sub: String)
        /// Prazo: hora (ou dia) em `warn`, título e subtítulo.
        case deadline(id: String, hour: String, title: String, sub: String)
    }

    /// Um prazo que a lista de emails conhece.
    struct Deadline: Hashable {
        let messageID: String
        let senderName: String
        /// Minuto de hoje, ou `nil` quando o prazo não é hoje.
        let minuteToday: Int?
        /// "Sáb" quando não é hoje.
        let dayLabel: String?
        let sub: String
    }

    /// A lista inteira, na ordem do relógio.
    ///
    /// - `agenda`: os compromissos de **hoje** (dayOffset 0), não cancelados.
    /// - `deadlines`: os prazos das linhas do plano.
    /// - `plan`: o bloco sugerido, quando o `DayPlan` achou folga.
    static func entries(
        agenda: [AgendaItem],
        deadlines: [Deadline],
        plan: DayPlan.ReplyBlock?,
        planNames: [String],
        nowMinute: Int
    ) -> [Entry] {
        struct Timed {
            let minute: Int
            /// Desempate no mesmo minuto: agora < bloco < evento < prazo.
            let rank: Int
            let entry: Entry
        }
        var timed: [Timed] = []

        for item in agenda where item.dayOffset == 0 && !item.isCancelled {
            timed.append(Timed(
                minute: item.startMinute, rank: 2,
                entry: .event(
                    id: item.id,
                    hour: MinuteFormat.clock(item.startMinute),
                    title: item.title,
                    sub: eventSub(item)
                )
            ))
        }

        if let plan, plan.day == 0 {
            timed.append(Timed(
                minute: plan.startMinute, rank: 1,
                entry: .plan(
                    hour: MinuteFormat.clock(plan.startMinute),
                    title: DashboardMetrics.replyBlockTitle(names: planNames),
                    sub: DashboardMetrics.replyBlockSub(
                        count: plan.messageIDs.count, minutes: plan.minutes
                    )
                )
            ))
        }

        for prazo in deadlines {
            guard let minuto = prazo.minuteToday else { continue }
            timed.append(Timed(
                minute: minuto, rank: 3,
                entry: .deadline(
                    id: prazo.messageID,
                    hour: MinuteFormat.clock(minuto),
                    title: "Prazo de \(prazo.senderName)",
                    sub: prazo.sub
                )
            ))
        }

        timed.append(Timed(minute: nowMinute, rank: 0, entry: .now))
        timed.sort {
            $0.minute != $1.minute ? $0.minute < $1.minute : $0.rank < $1.rank
        }
        var lista = timed.map(\.entry)

        // Prazos de outros dias fecham a lista, na ordem em que vieram: eles
        // não têm hora de hoje para disputar.
        for prazo in deadlines where prazo.minuteToday == nil {
            lista.append(.deadline(
                id: prazo.messageID,
                hour: prazo.dayLabel ?? "",
                title: "Prazo de \(prazo.senderName)",
                sub: prazo.sub
            ))
        }
        return lista
    }

    /// "30 min · gmail" — duração e origem, como o mockup escreve.
    static func eventSub(_ item: AgendaItem) -> String {
        var partes = [item.durationLabel]
        if let titulo = item.calendarTitle, !titulo.isEmpty {
            partes.append(titulo)
        } else if !item.accountID.isEmpty {
            partes.append(item.accountID)
        }
        return partes.joined(separator: " · ")
    }

    /// Os prazos das linhas do plano — hora de hoje em minuto, resto com o
    /// dia da semana abreviado.
    static func deadlines(
        in plan: DayPlan, today: Date, calendar: Calendar = .current
    ) -> [Deadline] {
        var lista: [Deadline] = []
        for section in plan.sections {
            for row in section.rows {
                guard let prazo = row.item.message.triage?.deadline else { continue }
                let nome = firstName(of: row.item.message.from)
                let sub = prazo.evidence
                if calendar.isDate(prazo.date, inSameDayAs: today) {
                    let hora = calendar.component(.hour, from: prazo.date)
                    let minuto = calendar.component(.minute, from: prazo.date)
                    lista.append(Deadline(
                        messageID: row.id, senderName: nome,
                        minuteToday: hora * 60 + minuto, dayLabel: nil, sub: sub
                    ))
                } else {
                    let dia = DayPlan.weekdayName(
                        calendar.component(.weekday, from: prazo.date)
                    )
                    let curto = String(dia.prefix(3))
                    lista.append(Deadline(
                        messageID: row.id, senderName: nome,
                        minuteToday: nil,
                        dayLabel: curto.prefix(1).uppercased() + curto.dropFirst(),
                        sub: sub
                    ))
                }
            }
        }
        return lista
    }

    /// Os primeiros nomes de quem o bloco responde, na ordem do bloco.
    static func planNames(for plan: DayPlan) -> [String] {
        guard let bloco = plan.replyBlock else { return [] }
        var porID: [String: Contact] = [:]
        for section in plan.sections {
            for row in section.rows { porID[row.id] = row.item.message.from }
        }
        return bloco.messageIDs.compactMap { porID[$0].map(firstName(of:)) }
    }

    /// "Jack Whitmore" → "Jack"; sem nome, a parte antes do arroba.
    static func firstName(of contact: Contact) -> String {
        let nome = contact.name.trimmingCharacters(in: .whitespaces)
        if let primeiro = nome.split(separator: " ").first, !primeiro.isEmpty {
            return String(primeiro)
        }
        return String(contact.address.split(separator: "@").first ?? "")
    }
}
