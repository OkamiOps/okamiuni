import SwiftUI
import UNICore

/// De onde vem o minuto "agora" que a trilha e as três visões da agenda
/// desenham.
///
/// O primeiro teste com conta real trouxe o defeito: o "agora" que essas
/// telas mostram era `Fixtures.nowMinute` (720 = meio-dia) **sempre**, mesmo
/// com uma conta de verdade no ar. `.fixed` é o que capturas, ensaios e os
/// testes de `swift test` continuam pedindo — o mesmo minuto não importa
/// quando o processo roda, para o retrato sair sempre igual. `.live` é o
/// relógio da máquina, e é o que uma conta real precisa: a pessoa que abre o
/// app às 21h quer ver a linha de "agora" nas 21h, não ao meio-dia.
public enum AgendaClock: Sendable, Equatable {
    case fixed(Int)
    case live

    /// Que dia é hoje, para este relógio.
    ///
    /// A mesma escolha do minuto, um degrau acima: `.fixed` é o mundo
    /// congelado do Marco 1, e o "hoje" dele é `Fixtures.today` — é o que faz
    /// capturas e retratos saírem sempre iguais, com as fixtures de 25 de
    /// agosto de 2026 carimbadas como o design as carimba. `.live` é o dia da
    /// máquina, e é o que a lista precisa para dizer que um email é de julho.
    public var today: Date {
        switch self {
        case .fixed: Fixtures.today
        case .live: Date()
        }
    }

    /// Minutos desde a meia-noite, pelo relógio informado. Só quem usa
    /// `.live` chama isto — `.fixed` já carrega o número.
    public static func minutesSinceMidnight(
        for date: Date = Date(), calendar: Calendar = .current
    ) -> Int {
        let partes = calendar.dateComponents([.hour, .minute], from: date)
        return (partes.hour ?? 0) * 60 + (partes.minute ?? 0)
    }
}

/// Dá a `content` o minuto "agora" certo para o `clock` escolhido.
///
/// Com `.fixed`, é uma chamada direta — sem `TimelineView`, sem recorrer ao
/// relógio do sistema, para a árvore de `View` continuar previsível nos
/// testes e nas capturas. Com `.live`, `TimelineView(.everyMinute)` refaz
/// `content` a cada troca de minuto: é o que move a linha de "agora" e o
/// rótulo "Próximo" sozinhos, sem a pessoa precisar reabrir a aba.
public struct AgendaClockReader<Content: View>: View {
    let clock: AgendaClock
    @ViewBuilder let content: (Int) -> Content

    public init(_ clock: AgendaClock, @ViewBuilder content: @escaping (Int) -> Content) {
        self.clock = clock
        self.content = content
    }

    public var body: some View {
        switch clock {
        case .fixed(let minuto):
            content(minuto)
        case .live:
            TimelineView(.everyMinute) { context in
                content(AgendaClock.minutesSinceMidnight(for: context.date))
            }
        }
    }
}
