import Foundation
import Testing

@testable import UNICore

/// A linha do tempo do painel 11: onde cada bloco cai, e por quê.
@Suite("Plano do dia · a linha do tempo")
struct PlanoDoDiaTests {

    /// Quinta, 3 de setembro de 2026, 10:00 — o mesmo dia do resto das suítes.
    private static let agora: Date = {
        var partes = DateComponents()
        partes.year = 2026; partes.month = 9; partes.day = 3; partes.hour = 10
        return Calendar.current.date(from: partes)!
    }()
    private let agoraMinuto = 600

    private var agenda: [AgendaItem] {
        [
            AgendaItem(
                id: "odette", title: "Odette", startMinute: 570, endMinute: 600,
                accountID: "gmail"
            ),
            AgendaItem(
                id: "aitherion", title: "Aitherion", startMinute: 600, endMinute: 720,
                accountID: "gmail"
            ),
        ]
    }

    /// O defeito que o dono descreveu: "nem dá pra saber que porra que tá
    /// agendado e ao invés de colocar scroll tu me deixou as coisas encolhidas
    /// e amassadas". A densidade não negocia com a largura da tela.
    @Test("a densidade é fixa: 138 pt por hora, e o eixo é o dia inteiro")
    func theAxisHasAFixedDensity() {
        #expect(PlanoDoDia.pontosPorHora == 138)
        #expect(PlanoDoDia.x(0) == 0)
        #expect(PlanoDoDia.x(60) == 138)
        #expect(PlanoDoDia.x(1_410) == 3_243)          // 23h30
        #expect(PlanoDoDia.larguraDoEixo == 3_312)     // 24 h × 138
        // E o eixo escreve as vinte e cinco horas cheias, sem rarear: numa
        // densidade destas nenhuma legenda encosta na outra.
        #expect(PlanoDoDia.horasDoEixo.count == 25)
        #expect(PlanoDoDia.horasDoEixo.first == 0)
        #expect(PlanoDoDia.horasDoEixo.last == 1_440)
    }

    /// O outro defeito da captura: blocos virados em chips "01:00" "09:30".
    @Test("o bloco nunca encolhe abaixo do que o título pede")
    func aBlockIsNeverNarrowerThanItsTitle() {
        // Meia hora vale 69 pt; um título medido em 120 pt manda no tamanho.
        let postos = PlanoDoDia.postos([
            (id: "odette", startMinute: 570, minutes: 30, tituloEmPontos: 120),
            (id: "aitherion", startMinute: 1_410, minutes: 60, tituloEmPontos: 40),
        ])
        let odette = postos.first { $0.id == "odette" }
        #expect(odette?.largura == 120 + PlanoDoDia.respiroDoBloco)
        #expect(odette?.x == PlanoDoDia.x(570))
        // E o bloco largo o bastante para o título fica com a largura da hora:
        // uma hora é uma hora, e não o tamanho da palavra.
        #expect(postos.first { $0.id == "aitherion" }?.largura == 138)
    }

    /// Antes o segundo bloco era empurrado para a direita — e aí o eixo mentia
    /// sobre a hora dele.
    @Test("dois blocos que se sobrepõem descem de sub-linha, e não de horário")
    func overlapDropsToASubLine() {
        let postos = PlanoDoDia.postos([
            (id: "a", startMinute: 780, minutes: 20, tituloEmPontos: 200),
            (id: "b", startMinute: 800, minutes: 45, tituloEmPontos: 100),
            (id: "c", startMinute: 1_200, minutes: 30, tituloEmPontos: 40),
        ])
        let porID = Dictionary(uniqueKeysWithValues: postos.map { ($0.id, $0) })
        #expect(porID["a"]?.subLinha == 0)
        #expect(porID["b"]?.subLinha == 1)
        // O que desceu continua exatamente no minuto em que começa.
        #expect(porID["b"]?.x == PlanoDoDia.x(800))
        // E quem não colide com ninguém volta para a sub-linha de cima.
        #expect(porID["c"]?.subLinha == 0)
    }

    /// O 01:00 duplicado da captura: duas contas espelhando o mesmo calendário.
    @Test("a mesma reunião vinda de duas contas vira um bloco só")
    func theSameMeetingFromTwoAccountsIsOneBlock() {
        let espelhada = [
            AgendaItem(
                id: "gmail-luna", title: "Luna · Dev time weekly",
                startMinute: 60, endMinute: 120, accountID: "gmail",
                calendarUID: "luna-weekly"
            ),
            AgendaItem(
                id: "vantion-luna", title: "Luna · Dev time weekly",
                startMinute: 60, endMinute: 120, accountID: "vantion",
                calendarUID: "luna-weekly"
            ),
        ]
        let blocos = PlanoDoDia.make(
            agenda: espelhada, replyBlock: nil, replyTitle: "",
            promessas: [], prazos: [], now: Self.agora, nowMinute: agoraMinuto
        )
        #expect(blocos.filter { $0.startMinute == 60 }.count == 1)
        // E sem UID nenhum, o título+horário ainda casa as duas cópias.
        let semUID = espelhada.map {
            AgendaItem(
                id: $0.id, title: $0.title, startMinute: $0.startMinute,
                endMinute: $0.endMinute, accountID: $0.accountID
            )
        }
        #expect(PlanoDoDia.make(
            agenda: semUID, replyBlock: nil, replyTitle: "",
            promessas: [], prazos: [], now: Self.agora, nowMinute: agoraMinuto
        ).count == 1)
    }

    @Test("o FreeSlots devolve folgas distintas para duas propostas seguidas")
    func twoProposalsGetTwoDistinctSlots() {
        let blocos = PlanoDoDia.make(
            agenda: agenda,
            replyBlock: DayPlan.ReplyBlock(
                day: 0, startMinute: 780, minutes: 20, messageIDs: ["jack"]
            ),
            replyTitle: "Responder Jack",
            promessas: [
                PlanoDoDia.Promessa(id: "p1", title: "Proposta Marina", dueMinute: 1_080),
            ],
            prazos: [], now: Self.agora, nowMinute: agoraMinuto
        )
        let propostos = blocos.filter { $0.tipo == .proposto }
            .sorted { $0.startMinute < $1.startMinute }
        #expect(propostos.count == 2)
        // O segundo começa **depois** do fim do primeiro. Sem isto os dois
        // caem às 13 h, e a agenda mente por construção.
        #expect(
            propostos[1].startMinute
                >= propostos[0].startMinute + propostos[0].minutes
        )
    }

    @Test("o bloco de respostas cai onde o DayPlan achou folga, na trilha você")
    func replyBlockLandsOnItsSlot() {
        let blocos = PlanoDoDia.make(
            agenda: agenda,
            replyBlock: DayPlan.ReplyBlock(
                day: 0, startMinute: 720, minutes: 20, messageIDs: ["jack"]
            ),
            replyTitle: "Responder Jack",
            promessas: [], prazos: [],
            now: Self.agora, nowMinute: agoraMinuto
        )
        let resposta = blocos.first { $0.id == "plano-respostas" }
        #expect(resposta?.startMinute == 720)
        #expect(resposta?.trilha == .voce)
        #expect(resposta?.tipo == .proposto)
        // E os compromissos continuam na trilha de cima.
        #expect(blocos.filter { $0.trilha == .agenda }.count == 2)
    }

    @Test("a promessa é reservada antes do prazo dela, e depois do que já existe")
    func promiseFitsBeforeItsDeadline() {
        let blocos = PlanoDoDia.make(
            agenda: agenda, replyBlock: nil, replyTitle: "",
            promessas: [
                PlanoDoDia.Promessa(id: "p1", title: "Proposta Marina", dueMinute: 900),
            ],
            prazos: [], now: Self.agora, nowMinute: agoraMinuto
        )
        let promessa = try? #require(blocos.first { $0.id == "p1" })
        #expect(promessa?.minutes == PlanoDoDia.minutosDaPromessa)
        // Depois do Aitherion (que vai até 720) e inteira antes das 15 h.
        #expect(promessa?.startMinute == 720)
        #expect((promessa?.startMinute ?? 0) + (promessa?.minutes ?? 0) <= 900)
    }

    @Test("nada é proposto no passado")
    func nothingIsProposedInThePast() {
        let blocos = PlanoDoDia.make(
            agenda: [], replyBlock: DayPlan.ReplyBlock(
                day: 0, startMinute: 540, minutes: 20, messageIDs: ["jack"]
            ),
            replyTitle: "Responder Jack",
            promessas: [
                PlanoDoDia.Promessa(id: "p1", title: "Proposta Marina", dueMinute: 660),
            ],
            prazos: [], now: Self.agora, nowMinute: agoraMinuto
        )
        // O bloco das 9 h já passou: não entra.
        #expect(!blocos.contains { $0.id == "plano-respostas" })
        // E a promessa que só caberia antes das 11 h também não, porque
        // 45 min depois das 10 h passam das 10h45 — cabe, e começa agora.
        let promessa = blocos.first { $0.id == "p1" }
        #expect(promessa?.startMinute == 600)
        #expect(blocos.allSatisfy { $0.tipo != .proposto || $0.startMinute >= 600 })
    }

    @Test("o valor só aparece quando o texto o afirma")
    func moneyOnlyWhenTheTextSaysSo() {
        #expect(DinheiroNoTexto.primeiro(em: "NF de agosto: R$ 4.200 até sexta")?.texto
            == "R$ 4.200")
        #expect(DinheiroNoTexto.primeiro(em: "USD 250/h pela consultoria")?.texto
            == "USD 250")
        #expect(DinheiroNoTexto.primeiro(em: "Ihre 6.000 Bonus-Credits laufen ab")?.texto
            == "6.000 créditos")
        #expect(DinheiroNoTexto.primeiro(em: "Pode confirmar o horário de quinta?") == nil)
    }
}
