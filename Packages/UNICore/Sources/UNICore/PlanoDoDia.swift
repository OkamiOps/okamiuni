import Foundation

/// A linha do tempo do "Plano de hoje" (`design/11-painel-do-dia.dc.html`):
/// duas trilhas — o que já está marcado e o que a IA propõe — no mesmo eixo.
///
/// **O eixo é o dia que a pessoa tem, não o expediente que o mockup desenhou.**
/// Um eixo fixo de 09 h às 19 h escondia a reunião da 01 h e o voo das 23h30, e
/// às 21h40 não tinha sequer onde pôr o marcador do agora — a tela dizia que o
/// dia já tinha acabado. A janela sai de `janela(blocos:nowMinute:)`, é pura, e
/// **sempre** contém o agora.
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

    /// O mínimo que o eixo mostra mesmo num dia vazio: das 08 h às 20 h. É o
    /// piso da janela, nunca o teto — o que existe fora disso a alarga.
    public static let inicioPadrao = 480
    public static let fimPadrao = 1_200

    /// A folga que o eixo dá antes do primeiro e depois do último bloco, para
    /// nenhum deles nascer colado na borda.
    public static let margem = 30

    /// Até quando uma promessa sem hora pode ser encaixada: o fim do
    /// expediente, que é o mesmo limite que o `FreeSlots` já respeita.
    public static let limiteDaPromessa = FreeSlots.workday.upperBound

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

    /// A janela do eixo: de onde a onde o dia é desenhado.
    ///
    /// **Pura, e sempre contém o agora.** Início e fim são arredondados à hora
    /// para as legendas caírem em horas cheias, e ficam dentro do dia (0 a
    /// 1440) porque não existe eixo antes da meia-noite.
    public struct Janela: Sendable, Hashable {
        public let inicio: Int
        public let fim: Int

        public init(inicio: Int, fim: Int) {
            self.inicio = min(max(inicio, 0), 1_440)
            // Uma janela de largura zero dividiria por zero na fração.
            self.fim = min(max(fim, self.inicio + 60), 1_440)
        }

        /// Onde o minuto cai no eixo, de 0 a 1. Fora da janela, gruda na borda.
        public func fracao(_ minute: Int) -> Double {
            let bruta = Double(minute - inicio) / Double(fim - inicio)
            return min(max(bruta, 0), 1)
        }

        /// As horas que o eixo escreve. O passo dobra enquanto as legendas não
        /// couberem: um dia inteiro com vinte e quatro "00 01 02…" seria uma
        /// régua ilegível, e o eixo existe para ser lido.
        public var horas: [Int] {
            var passo = 60
            while (fim - inicio) / passo > Self.legendasNoEixo { passo *= 2 }
            let primeira = ((inicio + passo - 1) / passo) * passo
            return Array(stride(from: primeira, through: fim, by: passo))
        }

        /// Quantas legendas cabem no eixo sem se tocarem, na largura que o
        /// painel dá à linha do tempo.
        static let legendasNoEixo = 14
    }

    /// A janela deste dia: o expediente padrão alargado pelo que existe fora
    /// dele, e pelo agora.
    ///
    /// - início: o menor entre 08 h e o primeiro bloco menos meia hora;
    /// - fim: o maior entre 20 h, o último bloco mais meia hora, e o agora mais
    ///   uma hora — é esta última parcela que garante que o marcador do agora
    ///   nunca fica encostado na borda direita às 21h40.
    public static func janela(blocos: [Bloco], nowMinute: Int) -> Janela {
        let primeiro = blocos.map(\.startMinute).min()
        let ultimo = blocos.map { $0.startMinute + $0.minutes }.max()

        var inicio = min(inicioPadrao, (primeiro ?? inicioPadrao) - margem)
        var fim = max(fimPadrao, (ultimo ?? fimPadrao) + margem, nowMinute + 60)

        // Arredonda para fora: a legenda é de hora cheia dos dois lados.
        inicio = Int(floor(Double(inicio) / 60)) * 60
        fim = Int(ceil(Double(fim) / 60)) * 60

        // E o agora entra sempre — um dia que começa às 08 h não pode esconder
        // um marcador das 03 h.
        inicio = min(inicio, (nowMinute / 60) * 60)
        return Janela(inicio: inicio, fim: fim)
    }

    /// Empurra para a direita o bloco que a largura mínima faria cair em cima
    /// do anterior.
    ///
    /// Existe porque a colisão não é de horário: dois blocos de vinte minutos
    /// separados por vinte minutos **não** se sobrepõem no relógio, mas num
    /// eixo de um dia inteiro cada um ocupa a largura mínima que a palavra
    /// exige, e aí sim um cobre o outro. A regra é a mesma da agenda: o segundo
    /// começa onde o primeiro acaba. Entra em ordem de `x`.
    public static func semColisao(_ blocos: [(x: Double, largura: Double)]) -> [Double] {
        var saida: [Double] = []
        var cursor = -Double.greatestFiniteMagnitude
        for bloco in blocos {
            let x = max(bloco.x, cursor)
            saida.append(x)
            cursor = x + bloco.largura
        }
        return saida
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
            let limite = promessa.dueMinute ?? limiteDaPromessa
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
