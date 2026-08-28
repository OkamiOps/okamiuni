import Foundation
import Testing
@testable import UNICore

@Suite("DayAgenda — as lacunas do \"Livre hoje\"")
struct DayAgendaTests {

    private func item(_ id: String, _ start: Int, _ end: Int) -> AgendaItem {
        AgendaItem(id: id, title: id, startMinute: start, endMinute: end, accountID: "zoho")
    }

    /// A terça do protótipo, com os cinco blocos da trilha. Os números estão
    /// travados em literal porque são o desenho: 08:00–09:30 é a lacuna da
    /// manhã, e 15:00–16:30 a da tarde que o cabeçalho da trilha anuncia.
    @Test("a terça de agosto tem cinco lacunas, nos horários do desenho")
    func tuesdayGaps() {
        let gaps = DayAgenda.gaps(in: Fixtures.agenda)

        #expect(gaps.map(\.rangeLabel) == [
            "08:00 – 09:30",
            "10:00 – 11:00",
            "11:45 – 12:30",
            "15:00 – 16:30",
            "18:00 – 19:00",
        ])
        #expect(gaps.map(\.lengthLabel) == ["1h30", "1h", "45min", "1h30", "1h"])
    }

    /// O corte de 45 minutos. Entre "Almoço" (termina 13:30) e "Revisão do
    /// contrato" (começa 14:00) há meia hora — e ela **não** aparece acima.
    @Test("buraco de meia hora não é oferecido")
    func belowMinimumIsDropped() {
        let gaps = DayAgenda.gaps(in: Fixtures.agenda)
        #expect(!gaps.contains { $0.startMinute == 810 })

        // Exatamente 45 entra; 44 não.
        let tight = [item("a", 480, 600), item("b", 645, 700)]
        #expect(DayAgenda.gaps(in: tight).first?.rangeLabel == "10:00 – 10:45")

        let tighter = [item("a", 480, 600), item("b", 644, 700)]
        #expect(!DayAgenda.gaps(in: tighter).contains { $0.startMinute == 600 })
    }

    /// O `max` no cursor. Um bloco curto **dentro** de um longo não pode
    /// devolver o cursor para trás: sem o `max`, a lacuna 12:00–14:00 sairia
    /// como livre, e ela está inteiramente dentro do bloco de foco.
    @Test("compromisso contido em outro não reabre horário já ocupado")
    func containedEventDoesNotRewindTheCursor() {
        let events = [
            item("foco", 540, 1020),   // 09:00–17:00
            item("almoco", 720, 780),  // 12:00–13:00, dentro do foco
        ]
        let gaps = DayAgenda.gaps(in: events)

        #expect(gaps.map(\.rangeLabel) == ["08:00 – 09:00", "17:00 – 19:00"])
        #expect(!gaps.contains { $0.startMinute == 780 })
    }

    /// Dia sem compromisso: a janela inteira é uma lacuna só.
    @Test("dia vazio devolve a janela inteira")
    func emptyDay() {
        let gaps = DayAgenda.gaps(in: [])
        #expect(gaps.count == 1)
        #expect(gaps[0].rangeLabel == "08:00 – 19:00")
        #expect(gaps[0].lengthLabel == "11h")
    }

    /// Compromissos fora de 08:00–19:00 continuam contando. Um que vai das
    /// 07:00 às 10:00 fecha a manhã inteira, e não só o pedaço depois das 8.
    @Test("compromisso que começa antes das 8 fecha o começo da janela")
    func eventBeforeTheWindow() {
        let gaps = DayAgenda.gaps(in: [item("madrugada", 420, 600)])
        #expect(gaps.map(\.rangeLabel) == ["10:00 – 19:00"])
    }

    /// E o que começa depois das 19:00 não cria lacuna nenhuma nova — só
    /// encurta a última se invadir a janela.
    @Test("compromisso da noite encurta a última lacuna")
    func eventCrossingTheEnd() {
        let gaps = DayAgenda.gaps(in: [item("noite", 1080, 1260)])
        #expect(gaps.map(\.rangeLabel) == ["08:00 – 18:00"])
    }

    /// Ordem de entrada não muda o resultado: a função ordena antes de varrer.
    @Test("a ordem da lista de entrada não altera as lacunas")
    func inputOrderIsIrrelevant() {
        let forward = DayAgenda.gaps(in: Fixtures.agenda)
        let backward = DayAgenda.gaps(in: Fixtures.agenda.reversed())
        #expect(forward == backward)
    }

    @Test("o rótulo de contagem trata o singular e o dia vazio")
    func blockCount() {
        #expect(DayAgenda.blockCountLabel(0) == "nenhum bloco")
        #expect(DayAgenda.blockCountLabel(1) == "1 bloco")
        #expect(DayAgenda.blockCountLabel(5) == "5 blocos")
    }
}

@Suite("MinuteFormat")
struct MinuteFormatTests {

    @Test("o relógio dá a volta em 24:00")
    func clockWraps() {
        #expect(MinuteFormat.clock(0) == "00:00")
        #expect(MinuteFormat.clock(570) == "09:30")
        #expect(MinuteFormat.clock(1440) == "00:00")
    }

    /// A regra do protótipo que mais dá errado ao reescrever de cabeça.
    @Test("hora cheia não vira 1h00 e o resto sai sem unidade")
    func durationShape() {
        #expect(MinuteFormat.duration(45) == "45min")
        #expect(MinuteFormat.duration(60) == "1h")
        #expect(MinuteFormat.duration(90) == "1h30")
        #expect(MinuteFormat.duration(125) == "2h5")
    }

    @Test("o travessão da faixa vem entre espaços")
    func rangeShape() {
        #expect(MinuteFormat.range(480, 570) == "08:00 – 09:30")
    }
}
