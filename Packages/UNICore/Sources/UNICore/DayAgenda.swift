import Foundation

/// A lateral "Livre hoje" da visão Dia (protótipo, linhas 1488–1496 e o helper
/// `gaps(evs)` na 2778): que buracos o dia tem entre um compromisso e o
/// seguinte.
///
/// Fora de `View` pelo motivo de sempre — a conta precisa ser chamável de um
/// teste nonisolated.
public enum DayAgenda {

    /// A janela de trabalho que a lateral considera. Protótipo: `cur = 480` e
    /// `1140 - cur`, ou seja, 08:00 às 19:00.
    ///
    /// Não é a faixa da **grade**, que vai de 00:00 a 24:00. São coisas
    /// diferentes de propósito: a grade mostra o dia inteiro porque um
    /// compromisso pode cair a qualquer hora; a lateral responde "onde eu
    /// encaixo uma reunião", e 03:00 não é resposta.
    public static let windowStart = 480
    public static let windowEnd = 1140

    /// Abaixo disto o buraco não é oferecido. Protótipo: `>= 45`.
    /// Meia hora entre dois compromissos é respiro, não disponibilidade.
    public static let minimumGap = 45

    /// Um intervalo livre.
    public struct Gap: Sendable, Hashable, Identifiable {
        public let startMinute: Int
        public let endMinute: Int

        public init(startMinute: Int, endMinute: Int) {
            self.startMinute = startMinute
            self.endMinute = endMinute
        }

        public var id: Int { startMinute }
        public var minutes: Int { endMinute - startMinute }

        /// "08:00 – 09:30"
        public var rangeLabel: String { MinuteFormat.range(startMinute, endMinute) }

        /// "1h30", "1h", "45min"
        public var lengthLabel: String { MinuteFormat.duration(minutes) }
    }

    /// Os buracos de `windowStart` a `windowEnd`, na ordem do dia.
    ///
    /// A regra é a do protótipo, inclusive no detalhe que importa: o cursor
    /// avança com `cur = max(cur, e.e)`, e **não** com `cur = e.e`. Sem o
    /// `max`, um compromisso curto inteiramente dentro de um longo (almoço
    /// dentro de um bloco de foco) puxaria o cursor para trás e a lateral
    /// ofereceria como livre um horário que já está ocupado.
    ///
    /// Compromissos que terminam antes de `windowStart` ou começam depois de
    /// `windowEnd` não somem: eles entram na conta e podem fechar a primeira e
    /// a última lacuna, que é o que faz "livre" querer dizer livre de verdade.
    public static func gaps(in items: [AgendaItem]) -> [Gap] {
        var out: [Gap] = []
        var cursor = windowStart

        for item in items.sorted(by: { ($0.startMinute, $0.id) < ($1.startMinute, $1.id) }) {
            if item.startMinute - cursor >= minimumGap {
                out.append(Gap(startMinute: cursor, endMinute: item.startMinute))
            }
            cursor = max(cursor, item.endMinute)
        }
        if windowEnd - cursor >= minimumGap {
            out.append(Gap(startMinute: cursor, endMinute: windowEnd))
        }
        return out
    }

    /// "5 blocos", "1 bloco", "nenhum bloco" — o `calMeta` da visão Dia.
    /// Protótipo: `dayEvs.length + (dayEvs.length === 1 ? ' bloco' : ' blocos')`.
    ///
    /// O caso vazio é acréscimo: o protótipo escreveria "0 blocos", que lê como
    /// erro de contagem em vez de dia livre.
    public static func blockCountLabel(_ count: Int) -> String {
        switch count {
        case 0: "nenhum bloco"
        case 1: "1 bloco"
        default: "\(count) blocos"
        }
    }
}
