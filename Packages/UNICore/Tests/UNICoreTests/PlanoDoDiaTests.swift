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

    @Test("a posição é a fração da janela, e fora dela gruda na borda")
    func positionIsTheAxisFraction() {
        let janela = PlanoDoDia.Janela(inicio: 540, fim: 1_140)
        #expect(janela.fracao(540) == 0)
        #expect(janela.fracao(1_140) == 1)
        #expect(janela.fracao(840) == 0.5)
        #expect(janela.fracao(60) == 0)
        #expect(janela.fracao(1_400) == 1)
    }

    /// O defeito 3 da captura do dono: o dia ia das 9 às 19, e eram 21h40.
    @Test("o dia dele cabe inteiro no eixo, e o agora das 21h40 também")
    func theWindowHoldsHisWholeDay() {
        let blocos = [
            bloco(id: "madrugada", inicio: 60, minutos: 60),      // 01:00
            bloco(id: "manha", inicio: 570, minutos: 30),          // 09:30
            bloco(id: "voo", inicio: 1_410, minutos: 30),          // 23:30
        ]
        let janela = PlanoDoDia.janela(blocos: blocos, nowMinute: 1_300) // 21h40
        #expect(janela.inicio == 0)
        #expect(janela.fim == 1_440)
        // O marcador do agora cai **dentro** do eixo, e não colado na borda.
        let agora = janela.fracao(1_300)
        #expect(agora > 0.85 && agora < 1)
        // E os três blocos são distinguíveis, cada um na sua fração.
        #expect(janela.fracao(60) < janela.fracao(570))
        #expect(janela.fracao(570) < janela.fracao(1_410))
    }

    @Test("o dia comum continua sendo o expediente com folga")
    func anOrdinaryDayKeepsTheOfficeHours() {
        let janela = PlanoDoDia.janela(
            blocos: [bloco(id: "reuniao", inicio: 600, minutos: 60)], nowMinute: 600
        )
        #expect(janela.inicio == PlanoDoDia.inicioPadrao)
        #expect(janela.fim == PlanoDoDia.fimPadrao)
        // Doze horas: uma legenda por hora ainda cabe.
        #expect(janela.horas.count <= PlanoDoDia.Janela.legendasNoEixo)
    }

    @Test("o eixo de um dia inteiro rareia as legendas em vez de amontoá-las")
    func aFullDayThinsTheHourLabels() {
        let janela = PlanoDoDia.Janela(inicio: 0, fim: 1_440)
        #expect(janela.horas.count <= PlanoDoDia.Janela.legendasNoEixo)
        #expect(janela.horas.first == 0)
        #expect(janela.horas.last == 1_440)
    }

    /// O defeito 4: "Responder" e "Proposta" um em cima do outro às 13 h.
    @Test("dois blocos que a largura mínima faria colidir são separados")
    func minimumWidthNeverStacksTwoBlocks() {
        // 13:00 com 20 min e 13:20 com 45 min, num eixo de um dia inteiro: no
        // relógio não se cruzam, na tela cada um ocupa a largura da palavra.
        let xs = PlanoDoDia.semColisao([(x: 100, largura: 64), (x: 118, largura: 64)])
        #expect(xs == [100, 164])
        // E quem já estava separado não é empurrado.
        #expect(PlanoDoDia.semColisao([(x: 0, largura: 44), (x: 200, largura: 44)])
            == [0, 200])
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

    private func bloco(id: String, inicio: Int, minutos: Int) -> PlanoDoDia.Bloco {
        PlanoDoDia.Bloco(
            id: id, trilha: .agenda, tipo: .compromisso, title: id,
            duration: "", startMinute: inicio, minutes: minutos
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
