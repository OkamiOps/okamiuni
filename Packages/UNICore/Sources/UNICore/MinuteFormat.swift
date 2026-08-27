import Foundation

/// Os dois formatos de horário que o protótipo escreve, em um lugar só.
///
/// Existem porque três telas os repetiam: `AgendaItem` (o cartão), a grade
/// (rótulo de hora) e as lacunas do "Livre hoje". Três cópias da mesma regra
/// divergem no primeiro ajuste — e a regra tem um detalhe fácil de errar:
/// hora cheia é `"1h"`, não `"1h00"`.
///
/// Mora fora de qualquer `View` porque `View` é `@MainActor` implícito no
/// Swift 6 e um `static` lá dentro herda o isolamento.
public enum MinuteFormat {

    /// `"09:30"`. Protótipo: `fmt(m)`.
    ///
    /// O `% 1440` é o que faz a última linha da grade dizer `00:00` em vez de
    /// `24:00` — o protótipo escreve `fmt(min % 1440)` exatamente por isso.
    public static func clock(_ minuteOfDay: Int) -> String {
        let wrapped = ((minuteOfDay % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }

    /// `"45min"`, `"1h"`, `"1h30"`. Protótipo:
    /// `(h ? h + 'h' : '') + (r ? (h ? String(r) : r + 'min') : '')`.
    ///
    /// Repare no que ele **não** faz: hora cheia não vira `"1h00"`, e o resto
    /// depois de uma hora sai sem unidade (`"1h30"`, não `"1h30min"`).
    public static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours > 0 else { return "\(minutes)min" }
        return rest > 0 ? "\(hours)h\(rest)" : "\(hours)h"
    }

    /// `"08:00 – 09:30"`. Protótipo: `fmt(a) + ' – ' + fmt(b)`, com o travessão
    /// entre espaços.
    public static func range(_ start: Int, _ end: Int) -> String {
        "\(clock(start)) – \(clock(end))"
    }
}
