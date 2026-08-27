import Testing
import UNICore
@testable import UNIShell

@Suite("AgendaRail")
struct AgendaRailTests {

    private let layout = AgendaRail.Layout(
        pointsPerMinute: 0.78
    )

    @Test("a trilha tem a largura do design")
    func width() {
        #expect(AgendaRail.width == 262)
    }

    @Test("um compromisso das 09:30 às 10:00 cai na posição certa")
    func placesEvent() {
        let standup = AgendaItem(
            id: "e1", title: "Standup produto",
            startMinute: 570, endMinute: 600, accountID: "zoho"
        )
        // 09:30 é 90 minutos depois das 08:00 (480) -> 90 × 0.78 = 70.2pt
        #expect(layout.offset(for: standup) == 70.2)
        // 30 min × 0.78 - 3 = 23.4 - 3 = 20.4pt, mas mínimo é 42 para modo tight
        #expect(layout.height(for: standup) == 42)
    }

    @Test("compromissos curtos ainda têm altura clicável")
    func minimumHeight() {
        let tiny = AgendaItem(
            id: "x", title: "Rápido",
            startMinute: 600, endMinute: 605, accountID: "zoho"
        )
        // 5 min × 0.78 - 3 = 3.9 - 3 = 0.9pt, deve subir para 42 (tight threshold)
        #expect(layout.height(for: tiny) == 42)
    }

    @Test("a trilha cobre a faixa inteira do dia (480 a 1140)")
    func totalHeight() {
        // 1140 - 480 = 660 min × 0.78 = 514.8pt (com tolerância de floating point)
        #expect(abs(layout.totalHeight - 514.8) < 0.01)
    }

    @Test("o rótulo de início é HH:MM")
    func startLabel() {
        let item = AgendaItem(id: "e", title: "T", startMinute: 570, endMinute: 600, accountID: "z")
        #expect(item.startLabel == "09:30")
    }

    @Test("nextUpLabel mostra o compromisso em andamento")
    func nextUpLabelRunning() {
        let items = Fixtures.agenda
        let now = 580  // 09:40, meio do Standup (570-600)
        // Standup rodando, termina às 10:00
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "agora: Standup produto · termina 10:00")
    }

    @Test("nextUpLabel mostra o próximo compromisso")
    func nextUpLabelUpcoming() {
        let items = Fixtures.agenda
        let now = 630  // 10:30, depois do Standup, antes da 1:1 (660-705)
        // Próximo em 30 min
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "em 30 min: 1:1 Marina Duarte")
    }

    @Test("nextUpLabel diz 'nada mais hoje' quando sem eventos restantes")
    func nextUpLabelNone() {
        let items = Fixtures.agenda
        let now = 1100  // 18:20, depois do último (990-1080)
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "nada mais hoje")
    }

    @Test("nextUpLabel com agenda vazia")
    func nextUpLabelEmpty() {
        let items: [AgendaItem] = []
        let now = 600
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "nada mais hoje")
    }

    @Test("nextUpLabel no exato início de um compromisso")
    func nextUpLabelExactStart() {
        let items = Fixtures.agenda
        let now = 570  // exatamente 09:30, início do Standup
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "agora: Standup produto · termina 10:00")
    }

    @Test("nextUpLabel no exato fim de um compromisso")
    func nextUpLabelExactEnd() {
        let items = Fixtures.agenda
        let now = 600  // exatamente 10:00, fim do Standup
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        // Já terminou, próximo é 1:1 em 60 min
        #expect(label == "em 60 min: 1:1 Marina Duarte")
    }

    @Test("altura mínima é 42 para modo tight")
    func tightThreshold() {
        // Evento que dá exatamente na borda: 54 min × 0.78 - 3 = 42.12 - 3 = 39.12 < 42
        let item = AgendaItem(
            id: "x", title: "T",
            startMinute: 500, endMinute: 554, accountID: "z"
        )
        #expect(layout.height(for: item) == 42)

        // Evento que não ativa tight: 55 min × 0.78 - 3 = 42.9 - 3 = 39.9 < 42 ainda
        let item2 = AgendaItem(
            id: "x", title: "T",
            startMinute: 500, endMinute: 555, accountID: "z"
        )
        #expect(layout.height(for: item2) == 42)

        // Evento maior que 42: 60 min × 0.78 - 3 = 46.8 - 3 = 43.8 > 42
        let item3 = AgendaItem(
            id: "x", title: "T",
            startMinute: 500, endMinute: 560, accountID: "z"
        )
        #expect(abs(layout.height(for: item3) - 43.8) < 0.01)
    }

    @Test("posição não desenha fora da faixa (480-1140)")
    func offsetOutsideRail() {
        let early = AgendaItem(id: "x", title: "Cedo", startMinute: 300, endMinute: 400, accountID: "z")
        let late = AgendaItem(id: "x", title: "Tarde", startMinute: 1200, endMinute: 1300, accountID: "z")

        // Fora da faixa: a lógica de offset continua funcionando, mas a View não desenha
        // (isso é responsabilidade da View, não do Layout)
        #expect(layout.offset(for: early) < 0)
        #expect(layout.offset(for: late) > layout.totalHeight)
    }

    @Test("cabeçalho da agenda formata a data corretamente")
    func headerDateFormatting() {
        let dateString = AgendaRail.headerDateString(Fixtures.today)
        // Fixtures.today é terça-feira, 25 de agosto de 2026
        #expect(dateString == "Terça-feira, 25 de agosto")
    }

    @Test("rótulo de duração — minutos para N < 90")
    func durationMinutes() {
        let items = Fixtures.agenda
        // now = 720 (12:00), almoço às 12:30 (750) → 30 min
        let label = AgendaRail.nextUpLabel(for: items, now: 720)
        #expect(label == "em 30 min: Almoço — bloqueado")
    }

    @Test("rótulo de duração — 89 min (limite inferior, sem formato em horas)")
    func duration89Minutes() {
        let items = Fixtures.agenda
        // now = 901 (15:01), foco às 16:30 (990) → 89 min
        let label = AgendaRail.nextUpLabel(for: items, now: 901)
        #expect(label == "em 89 min: Foco: proposta TransRota")
    }

    @Test("rótulo de duração — 90 min (limite superior, formato 1h30)")
    func duration90Minutes() {
        let items = Fixtures.agenda
        // now = 900 (15:00), foco às 16:30 (990) → 90 min = 1h30
        let label = AgendaRail.nextUpLabel(for: items, now: 900)
        #expect(label == "em 1h30: Foco: proposta TransRota")
    }

    @Test("rótulo de duração — 271 min (1:1 14h até Foco 16:30)")
    func duration271Minutes() {
        let items = Fixtures.agenda
        // Usa item customizado para testar número grande de minutos
        let customItem = AgendaItem(id: "x", title: "Evento longe",
                                   startMinute: 990, endMinute: 1000, accountID: "z")
        let label = AgendaRail.nextUpLabel(for: [customItem], now: 660)
        // 990 - 660 = 330 min = 5h30
        #expect(label == "em 5h30: Evento longe")
    }

    // MARK: - Calha das horas (Task P, defeito 1 e 3)

    @Test("o cartão de evento nunca invade a calha dos rótulos de hora")
    func eventNeverCoversHourLabel() {
        // O defeito medido: o cartão começava em 24pt, dentro da calha de 26pt,
        // e escondia "10", "11", "13", "14" e "17" atrás do bloco.
        #expect(layout.eventLeading >= layout.labelGutter + layout.gutterGap)
    }

    @Test("a calha e o recuo dos cartões vêm do protótipo")
    func gutterMatchesPrototype() {
        // Protótipo: linha da hora com `gap: 6px`, cartão com `right: 2px`.
        // A calha tem 30 e não os 26 declarados no span porque o texto do
        // protótipo é "08:00", que em mono 9pt não cabe em 26.
        #expect(layout.gutterGap == 6)
        #expect(layout.eventTrailing == 2)
        #expect(layout.labelGutter == 30)
        // O recuo do cartão sai da calha mais a folga: 30 + 6.
        // (A relação em si está travada em `eventNeverCoversHourLabel`.)
        #expect(layout.eventLeading == 36)
    }

    @Test("o rótulo da hora é HH:MM, como o fmt() do protótipo")
    func hourLabelIsHourAndMinute() {
        #expect(AgendaRail.hourLabel(minuteOfDay: 480) == "08:00")
        #expect(AgendaRail.hourLabel(minuteOfDay: 540) == "09:00")
        #expect(AgendaRail.hourLabel(minuteOfDay: 1080) == "18:00")
        // O mesmo fmt() serve para qualquer minuto, não só a hora cheia.
        #expect(AgendaRail.hourLabel(minuteOfDay: 705) == "11:45")
        #expect(AgendaRail.hourLabel(minuteOfDay: 0) == "00:00")
    }

    @Test("a calha cabe o rótulo que o protótipo escreve")
    func gutterFitsTheLabel() {
        // "08:00" em mono 9pt mede ~27pt: a calha tem de ser maior que isso,
        // senão o rótulo trunca — foi por medir esse 27 que ela saiu de 26.
        let widest = AgendaRail.hourLabel(minuteOfDay: 1080)
        #expect(widest.count == 5)
        #expect(layout.labelGutter >= 30)
    }

    @Test("o marcador de agora encosta na calha em vez de atravessá-la")
    func nowMarkerStartsAfterGutter() {
        // Protótipo: `nowStyle … left: 26px`. Zero faria o traço vermelho passar
        // por cima do rótulo "12", que era o defeito 3.
        #expect(layout.nowMarkerLeading == layout.labelGutter)
        #expect(layout.nowMarkerLeading > 0)
    }

    @Test("minuto das fixtures é sempre 720, independente do fuso da máquina")
    func fixturesNowMinuteIsTimezoneIndependent() {
        // Fixtures.nowMinute é uma constante (720 = 12:00)
        #expect(Fixtures.nowMinute == 720)

        // Com esse minuto, o rótulo deve refletir o meio-dia (Almoço em 30 min)
        let label = AgendaRail.nextUpLabel(for: Fixtures.agenda, now: Fixtures.nowMinute)
        #expect(label == "em 30 min: Almoço — bloqueado")

        // Mesmo se usarmos Fixtures.today (que é um instante, não um minuto),
        // a injeção em InboxScreen deve usar nowMinute, não derivar de hoje
        let headerDate = AgendaRail.headerDateString(Fixtures.today)
        #expect(headerDate == "Terça-feira, 25 de agosto")
    }
}
