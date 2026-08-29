import Foundation

/// O que a coluna da direita da linha da lista escreve: hora, "Ontem", data —
/// e data **com ano** quando o email é de outro ano.
///
/// **O defeito que ele conserta.** A linha decidia pelo `Message.dayOffset`, e
/// `dayOffset` só é preenchido pelas fixtures do Marco 1: toda mensagem que
/// desce de um servidor de verdade nasce com `0`, "hoje". Foi assim que a caixa
/// do dono ficou cheia de emails de julho carimbados "16:55" e "20:13", como se
/// tivessem chegado hoje de manhã — a pessoa não tinha como saber **quando** o
/// email chegou.
///
/// A regra é a dos clientes grandes, e é a mesma nos três: hoje mostra a hora,
/// porque o dia já está implícito; ontem tem nome; o resto do ano mostra dia e
/// mês; e o ano só aparece quando ele não é o corrente — escrever "2026" em
/// toda linha de uma caixa inteira do ano corrente seria ruído em cada linha.
///
/// **Nada aqui olha para `Date()`.** O agora entra pela porta, como em
/// `ICalendar.parse(_:timeZone:)` e em `DetectedEventConversion.agendaItem`,
/// pelo motivo registrado em `docs/decisoes-de-engenharia.md`: um formatador
/// que lê o relógio por dentro não tem como ser afirmado por teste, e a
/// fronteira da meia-noite é justamente onde ele erra.
public enum MessageStamp: Sendable, Hashable, CaseIterable {
    /// Chegou hoje: "16:55". Quem desenha usa o formato de hora de sempre.
    case clock
    /// Chegou ontem: "Ontem".
    case yesterday
    /// Este ano, nem hoje nem ontem: "21 de jul.".
    case dayMonth
    /// Outro ano: "21 de jul. de 2025".
    case dayMonthYear

    /// Qual carimbo a mensagem recebida em `date` ganha, com `now` de agora.
    ///
    /// A comparação é por **dia de calendário**, não por horas decorridas: uma
    /// mensagem das 23:50 continua sendo de hoje às 23:59 e vira "Ontem" à
    /// meia-noite e um minuto, que é o que a pessoa espera. Contar 24 horas
    /// para trás diria "hoje" para um email de ontem às 23:00.
    public static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> MessageStamp {
        if calendar.isDate(date, inSameDayAs: now) { return .clock }
        let dia = calendar.startOfDay(for: date)
        let hoje = calendar.startOfDay(for: now)
        if let ontem = calendar.date(byAdding: .day, value: -1, to: hoje), dia == ontem {
            return .yesterday
        }
        let anoDaMensagem = calendar.component(.year, from: date)
        let anoDeHoje = calendar.component(.year, from: now)
        return anoDaMensagem == anoDeHoje ? .dayMonth : .dayMonthYear
    }
}
