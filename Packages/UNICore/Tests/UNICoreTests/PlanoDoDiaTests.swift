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

    @Test("a posição é a fração do eixo de 09 h às 19 h")
    func positionIsTheAxisFraction() {
        #expect(PlanoDoDia.fracao(540) == 0)
        #expect(PlanoDoDia.fracao(1_140) == 1)
        #expect(PlanoDoDia.fracao(840) == 0.5)
        // Fora da janela, gruda na borda em vez de sair do eixo.
        #expect(PlanoDoDia.fracao(60) == 0)
        #expect(PlanoDoDia.fracao(1_400) == 1)
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
