import Foundation

/// A linha do tempo do "Plano de hoje" (`design/11-painel-do-dia.dc.html`):
/// duas trilhas — o que já está marcado e o que a IA propõe — no mesmo eixo de
/// 09 h às 19 h.
///
/// **Pura.** Entra a agenda, o bloco de resposta do `DayPlan`, as promessas que
/// vencem hoje e os prazos do dia; sai a lista de blocos com posição. Nenhuma
/// `View` decide onde um bloco cai, e nenhum relógio é lido aqui dentro: `now`
/// e `nowMinute` entram pela porta, como no `DayPlan`.
///
/// **Nada é executado.** Todo bloco da trilha "você" é proposta — quem cria
/// compromisso é o clique em "Aceitar o plano", pelo comando de agenda de
/// sempre.
public enum PlanoDoDia {

    /// A janela do eixo: 09 h às 19 h, como as horas escritas no mockup.
    public static let inicio = 540
    public static let fim = 1_140

    /// O bloco que uma promessa ganha. Quarenta e cinco minutos é o que o
    /// mockup escreve ("Proposta Marina · 45m"), e é uma promessa por bloco:
    /// juntar duas numa hora só seria a agenda decidindo que elas são a mesma
    /// tarefa.
    public static let minutosDaPromessa = 45

    public enum Trilha: Sendable, Hashable {
        /// O que já está marcado.
        case agenda
        /// O que a IA propõe, e o que vence.
        case voce
    }

    public enum Tipo: Sendable, Hashable {
        /// Compromisso de verdade.
        case compromisso
        /// Proposta — tracejada na tela.
        case proposto
        /// Prazo: bloco vazado, sem duração.
        case prazo
    }

    /// Um bloco desenhável. `minutes` é a largura em minutos; `title` e
    /// `duration` são o que o bloco escreve.
    public struct Bloco: Sendable, Hashable, Identifiable {
        public let id: String
        public let trilha: Trilha
        public let tipo: Tipo
        public let title: String
        public let duration: String
        public let startMinute: Int
        public let minutes: Int

        public init(
            id: String, trilha: Trilha, tipo: Tipo, title: String,
            duration: String, startMinute: Int, minutes: Int
        ) {
            self.id = id
            self.trilha = trilha
            self.tipo = tipo
            self.title = title
            self.duration = duration
            self.startMinute = startMinute
            self.minutes = minutes
        }
    }

    /// Uma promessa que vence hoje — "você prometeu", com a hora do
    /// compromisso quando o texto a afirma.
    public struct Promessa: Sendable, Hashable {
        public let id: String
        public let title: String
        /// O minuto de hoje em que ela vence. `nil` = vence hoje sem hora, e
        /// aí o limite é o fim do expediente.
        public let dueMinute: Int?

        public init(id: String, title: String, dueMinute: Int?) {
            self.id = id
            self.title = title
            self.dueMinute = dueMinute
        }
    }

    /// Um prazo de hoje, do `MessageTriage.deadline`.
    public struct Prazo: Sendable, Hashable {
        public let id: String
        public let title: String
        public let minute: Int

        public init(id: String, title: String, minute: Int) {
            self.id = id
            self.title = title
            self.minute = minute
        }
    }

    /// Onde o minuto cai no eixo, de 0 a 1. Fora da janela, gruda na borda —
    /// um bloco das 8 h não é desenhado à esquerda do eixo.
    public static func fracao(_ minute: Int) -> Double {
        let bruta = Double(minute - inicio) / Double(fim - inicio)
        return min(max(bruta, 0), 1)
    }

    /// Os blocos das duas trilhas, na ordem do relógio.
    ///
    /// A trilha "você" é montada **em sequência**: cada promessa é encaixada na
    /// primeira folga que ainda cabe antes do prazo dela, e o bloco recém-posto
    /// passa a ocupar o dia para a próxima — sem isso, duas promessas cairiam
    /// no mesmo horário, que é a agenda mentindo por construção.
    public static func make(
        agenda: [AgendaItem],
        replyBlock: DayPlan.ReplyBlock?,
        replyTitle: String,
        promessas: [Promessa],
        prazos: [Prazo],
        now: Date,
        nowMinute: Int,
        calendar: Calendar = .current
    ) -> [Bloco] {
        var blocos: [Bloco] = []
        // Ocupado: o que já está marcado mais o que este plano já propôs.
        var ocupado = agenda.filter { $0.dayOffset == 0 && !$0.isCancelled }

        for item in ocupado.sorted(by: { $0.startMinute < $1.startMinute }) {
            blocos.append(Bloco(
                id: item.id, trilha: .agenda, tipo: .compromisso,
                title: item.title, duration: item.durationLabel,
                startMinute: item.startMinute, minutes: item.durationMinutes
            ))
        }

        if let replyBlock, replyBlock.day == 0, replyBlock.startMinute >= nowMinute {
            blocos.append(Bloco(
                id: "plano-respostas", trilha: .voce, tipo: .proposto,
                title: replyTitle,
                duration: MinuteFormat.duration(replyBlock.minutes),
                startMinute: replyBlock.startMinute, minutes: replyBlock.minutes
            ))
            ocupado.append(reserva(
                id: "plano-respostas", start: replyBlock.startMinute,
                minutes: replyBlock.minutes
            ))
        }

        for promessa in promessas {
            let limite = promessa.dueMinute ?? fim
            guard let folga = FreeSlots.next(
                days: 1, minMinutes: minutosDaPromessa, agenda: ocupado,
                now: now, nowMinute: nowMinute, calendar: calendar
            ).first(where: { $0.day == 0 && $0.start + minutosDaPromessa <= limite })
            else { continue }
            blocos.append(Bloco(
                id: promessa.id, trilha: .voce, tipo: .proposto,
                title: promessa.title,
                duration: MinuteFormat.duration(minutosDaPromessa),
                startMinute: folga.start, minutes: minutosDaPromessa
            ))
            ocupado.append(reserva(
                id: promessa.id, start: folga.start, minutes: minutosDaPromessa
            ))
        }

        for prazo in prazos {
            blocos.append(Bloco(
                id: prazo.id, trilha: .voce, tipo: .prazo,
                title: prazo.title, duration: "",
                startMinute: prazo.minute, minutes: 30
            ))
        }

        return blocos.sorted { $0.startMinute < $1.startMinute }
    }

    /// Um compromisso de mentira só para ocupar a folga que este plano acabou
    /// de propor. Nunca sai daqui — não vira agenda, não vira tela.
    private static func reserva(id: String, start: Int, minutes: Int) -> AgendaItem {
        AgendaItem(
            id: "reserva-\(id)", title: "", startMinute: start,
            endMinute: start + minutes, accountID: ""
        )
    }
}
