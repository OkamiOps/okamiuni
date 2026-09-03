import Foundation

/// As folgas do expediente: o que sobra do dia depois de descontar a agenda.
///
/// Serve a duas coisas do 08: o bloco sugerido da coluna do dia ("13:00 ·
/// Responder Jack, Jayden e Maria") e o rascunho que precisa propor horário —
/// o `usedAgenda` do `ReadyDraft` é isto aqui, catorze dias à frente.
///
/// **Minutos, não `Date`.** O `AgendaItem` modela horário como minutos desde a
/// meia-noite justamente para não atravessar fuso, e converter aqui
/// reintroduziria o bug que ele evita. A `Date` entra por um motivo só, e é o
/// único que os minutos não sabem responder: **que dia da semana é**. Sábado e
/// domingo não são expediente, e isso não se descobre num inteiro.
public struct FreeSlots {

    /// Uma folga: em que dia (deslocamento a partir de hoje) e entre que
    /// minutos.
    public typealias Slot = (day: Int, start: Int, end: Int)

    /// O expediente padrão do 08: 9h às 18h.
    public static let workday = 540...1080

    /// As folgas de pelo menos `minMinutes` nos próximos `days` dias.
    ///
    /// `days: 1` é só hoje. Fim de semana não conta — não é expediente, e
    /// oferecer sábado como "sua próxima folga" é a mesma falta de educação de
    /// marcar reunião no domingo. Hoje começa **em `nowMinute`**: uma folga que
    /// já passou não é folga.
    public static func next(
        days: Int,
        minMinutes: Int,
        agenda: [AgendaItem],
        workday: ClosedRange<Int> = FreeSlots.workday,
        now: Date,
        nowMinute: Int,
        calendar: Calendar = .current
    ) -> [Slot] {
        guard days > 0, minMinutes > 0 else { return [] }
        var folgas: [Slot] = []
        for offset in 0..<days {
            guard let dia = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let semana = calendar.component(.weekday, from: dia)
            // 1 é domingo, 7 é sábado no calendário gregoriano.
            if semana == 1 || semana == 7 { continue }

            let ocupado = busyIntervals(
                agenda: agenda, dayOffset: offset, workday: workday
            )
            var cursor = workday.lowerBound
            if offset == 0 { cursor = max(cursor, nowMinute) }
            for intervalo in ocupado {
                if intervalo.start - cursor >= minMinutes {
                    folgas.append((day: offset, start: cursor, end: intervalo.start))
                }
                cursor = max(cursor, intervalo.end)
            }
            if workday.upperBound - cursor >= minMinutes {
                folgas.append((day: offset, start: cursor, end: workday.upperBound))
            }
        }
        return folgas
    }

    /// A mesma pergunta com a assinatura do plano: o minuto de hoje sai da
    /// própria `now`. Existe para quem já tem só a data na mão; quem tem o
    /// `nowMinute` que a tela usa deve passá-lo, porque é ele que a Caixa e o
    /// dashboard já compartilham.
    public static func next(
        days: Int,
        minMinutes: Int,
        agenda: [AgendaItem],
        workday: ClosedRange<Int> = FreeSlots.workday,
        now: Date,
        calendar: Calendar = .current
    ) -> [Slot] {
        let componentes = calendar.dateComponents([.hour, .minute], from: now)
        let minuto = (componentes.hour ?? 0) * 60 + (componentes.minute ?? 0)
        return next(
            days: days, minMinutes: minMinutes, agenda: agenda,
            workday: workday, now: now, nowMinute: minuto, calendar: calendar
        )
    }

    /// Os compromissos do dia, recortados ao expediente e em ordem de início.
    ///
    /// Sem fundir os sobrepostos: quem varre a lista avança o cursor com um
    /// `max`, e duas reuniões que se cruzam já não produzem folga nenhuma entre
    /// elas. Fundir aqui seria uma segunda cópia da mesma regra — e uma cópia
    /// que nenhum teste conseguiria distinguir da outra.
    private static func busyIntervals(
        agenda: [AgendaItem], dayOffset: Int, workday: ClosedRange<Int>
    ) -> [(start: Int, end: Int)] {
        agenda
            .filter { $0.dayOffset == dayOffset && !$0.isCancelled }
            .map { item in
                (
                    start: max(item.startMinute, workday.lowerBound),
                    end: min(item.endMinute, workday.upperBound)
                )
            }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
    }
}
