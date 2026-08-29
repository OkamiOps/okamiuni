import Foundation

/// Como um deslocamento em dias vira palavra na tela.
///
/// Mora em `UNICore`, e não numa `View`, por dois motivos. O primeiro é a
/// regra do projeto: `View` é `@MainActor` implícito e um `static` lá dentro
/// trapa quando um teste nonisolated o chama. O segundo é que **é a mesma
/// regra em dois lugares** — o cabeçalho de grupo da lista e o carimbo de
/// horário da linha —, e duas cópias divergem.
///
/// Nada aqui olha para o relógio. Era exatamente isso que estava errado antes:
/// o cabeçalho perguntava `Calendar.isDateInToday(message.receivedAt)`, a
/// fixture é de 25/08/2026, e em qualquer outro dia a resposta era "não" — a
/// lista escrevia a data formatada onde o design escreve "Hoje". Um dia
/// nomeado é dado da mensagem, não uma conclusão sobre a máquina de quem lê.
public enum DayLabel {

    /// O nome que o dia tem, se tiver: `0` é "Hoje", `-1` é "Ontem".
    ///
    /// `nil` para todos os outros — a terça retrasada não tem nome, tem data,
    /// e escolher o formato dela é de quem desenha. Sem tabela de meses aqui.
    public static func name(forOffset offset: Int) -> String? {
        switch offset {
        case 0: today
        case -1: yesterday
        default: nil
        }
    }

    /// As duas palavras, para quem chega pela data e não pelo offset — a
    /// linha da lista, que carimba por `MessageStamp`. Mesma palavra, uma
    /// definição só: duas cópias divergem no primeiro ajuste.
    public static let today = "Hoje"
    public static let yesterday = "Ontem"

    /// Se a coluna de horário da linha deve escrever a hora ou o dia.
    ///
    /// Design (`MSGS`): mensagem de hoje mostra `time: '09:42'`; as de ontem
    /// mostram `time: 'Ontem'`. A hora só distingue quando o dia já está
    /// implícito, e ele só está implícito no dia corrente.
    public static func showsClockTime(forOffset offset: Int) -> Bool {
        offset == 0
    }
}
