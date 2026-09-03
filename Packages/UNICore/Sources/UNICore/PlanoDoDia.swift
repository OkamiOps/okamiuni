import Foundation

/// A linha do tempo do "Plano de hoje" (`design/11-painel-do-dia.dc.html`):
/// duas trilhas — o que já está marcado e o que a IA propõe — no mesmo eixo.
///
/// **A densidade é fixa: 138 pt por hora, sempre.** A janela que se estreitava
/// para caber na largura da tela foi o defeito que o dono descreveu — "nem dá
/// pra saber que porra que tá agendado": o dia inteiro espremido em 1380 pt dá
/// 57 pt por hora, e nesse tamanho todo bloco vira um chip de "01:00" sem
/// título. Agora o eixo tem o tamanho do dia (24 h × 138 = 3312 pt) e quem se
/// move é a rolagem, não o desenho.
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

    /// Quantos pontos vale uma hora do eixo. É a medida do mockup aprovado:
    /// uma janela de dez horas ocupando a largura inteira do painel dá 138 pt
    /// por hora, e é essa densidade que faz um bloco de meia hora ter 69 pt —
    /// espaço para "Odette" em vez de para "09:30".
    public static let pontosPorHora: Double = 138

    /// O eixo cobre o dia inteiro: 00 h às 24 h. Nada de janela que encolhe.
    public static let minutosDoDia = 1_440

    /// A largura total do eixo, em pontos. É o conteúdo da rolagem.
    public static var larguraDoEixo: Double {
        Double(minutosDoDia) / 60 * pontosPorHora
    }

    /// A folga interna do bloco — 9 pt de cada lado do texto. Entra na largura
    /// mínima porque um bloco do tamanho exato da palavra a encosta na borda.
    public static let respiroDoBloco: Double = 18

    /// Quanto a trilha cresce quando um bloco precisa descer de sub-linha.
    public static let alturaDaSubLinha: Double = 30

    /// Onde o minuto cai no eixo, em pontos a partir da meia-noite.
    public static func x(_ minute: Int) -> Double {
        Double(minute) / 60 * pontosPorHora
    }

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

    /// As horas que o eixo escreve: todas, das 00 às 24. Numa densidade de
    /// 138 pt por hora nenhuma legenda encosta na outra, então não há o que
    /// rarear — rarear era consequência da janela que espremia.
    public static var horasDoEixo: [Int] {
        Array(stride(from: 0, through: minutosDoDia, by: 60))
    }

    /// Onde um bloco cai depois de resolvida a sobreposição: a posição no eixo,
    /// a largura que ele exige, e em que sub-linha da trilha ele ficou.
    public struct Posto: Sendable, Hashable, Identifiable {
        public let id: String
        public let x: Double
        public let largura: Double
        /// 0 é a sub-linha de cima. Cada sub-linha a mais faz a trilha crescer
        /// `alturaDaSubLinha`.
        public let subLinha: Int

        public init(id: String, x: Double, largura: Double, subLinha: Int) {
            self.id = id
            self.x = x
            self.largura = largura
            self.subLinha = subLinha
        }
    }

    /// A posição de cada bloco de **uma** trilha, sem nunca encolher nem
    /// abreviar.
    ///
    /// A largura é o maior entre a duração (`minutes` na densidade fixa) e o que
    /// o título pede — é isto que cria a sobreposição, porque dois blocos de
    /// vinte minutos separados por vinte minutos não se cruzam no relógio mas
    /// cruzam na palavra. Antes o segundo era **empurrado para a direita**, e
    /// aí o eixo mentia sobre a hora dele; agora ele **desce de sub-linha** e
    /// continua exatamente no minuto em que começa.
    ///
    /// `tituloEmPontos` é a largura medida do texto do bloco — quem sabe medir
    /// tipo é a `View`, e ela entra por aqui em vez de a regra descer para lá.
    public static func postos(
        _ entradas: [(id: String, startMinute: Int, minutes: Int, tituloEmPontos: Double)]
    ) -> [Posto] {
        var fimDaSubLinha: [Double] = []
        var saida: [Posto] = []
        for entrada in entradas.sorted(by: { $0.startMinute < $1.startMinute }) {
            let x = x(entrada.startMinute)
            let largura = max(
                Double(entrada.minutes) / 60 * pontosPorHora,
                entrada.tituloEmPontos + respiroDoBloco
            )
            var linha = 0
            while linha < fimDaSubLinha.count, x < fimDaSubLinha[linha] { linha += 1 }
            if linha == fimDaSubLinha.count { fimDaSubLinha.append(0) }
            fimDaSubLinha[linha] = x + largura
            saida.append(Posto(id: entrada.id, x: x, largura: largura, subLinha: linha))
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
        //
        // **Coalescido, como a grade da Agenda já fazia.** A mesma reunião
        // chega por duas contas que espelham o mesmo calendário, e por três
        // origens (EventKit, convite por email, "Colocar na agenda"); sem esta
        // linha ela virava dois blocos idênticos à 01 h na tela do dono. O
        // conserto é aqui, na fonte: um `Set` na `View` esconderia a cópia da
        // linha do tempo e a deixaria contando duas vezes em todo o resto.
        var ocupado = InviteAgenda.coalesce(
            agenda.filter { $0.dayOffset == 0 && !$0.isCancelled }
        )

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
