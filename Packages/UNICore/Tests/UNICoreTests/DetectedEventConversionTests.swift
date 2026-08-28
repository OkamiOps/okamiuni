import Testing
import Foundation
@testable import UNICore

/// A conversão que "Colocar na agenda" precisa: `DetectedEvent` (um instante
/// absoluto) → `AgendaItem` (minuto desde a meia-noite + `dayOffset`). É a
/// fronteira de fuso da tarefa — ver o comentário de
/// `DetectedEventConversion` — e as fronteiras que o brief pede: hoje, ontem,
/// amanhã, vários dias; 00:00; 23:59; meia-noite atravessada; duração zero.
@Suite("Conversão DetectedEvent → AgendaItem")
struct DetectedEventConversionTests {

    /// Terça, 25 de agosto de 2026, meio-dia — a mesma âncora das fixtures.
    private var referenceDay: Date { Fixtures.today }

    private func at(
        _ hour: Int, _ minute: Int, daysFromReference: Int = 0, calendar: Calendar = .current
    ) -> Date {
        let day = calendar.date(byAdding: .day, value: daysFromReference, to: referenceDay) ?? referenceDay
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: - dayOffset nos quatro casos que o brief pede

    @Test("evento hoje tem dayOffset 0, com o minuto certo")
    func today() {
        let event = DetectedEvent(label: "Hoje", start: at(15, 0), duration: 3600)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.dayOffset == 0)
        #expect(item.startMinute == 900)  // 15:00
        #expect(item.endMinute == 960)    // 16:00
    }

    @Test("evento ontem tem dayOffset -1")
    func yesterday() {
        let event = DetectedEvent(label: "Ontem", start: at(9, 0, daysFromReference: -1), duration: 1800)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.dayOffset == -1)
        #expect(item.startMinute == 540)  // 09:00
    }

    @Test("evento amanhã tem dayOffset 1")
    func tomorrow() {
        let event = DetectedEvent(label: "Amanhã", start: at(9, 0, daysFromReference: 1), duration: 1800)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.dayOffset == 1)
    }

    @Test("evento daqui a vários dias tem o dayOffset certo", arguments: [2, 5, 10, 30])
    func severalDaysAhead(days: Int) {
        let event = DetectedEvent(label: "Depois", start: at(9, 0, daysFromReference: days), duration: 1800)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.dayOffset == days)
    }

    // MARK: - As pontas do dia

    @Test("evento que começa 00:00 cai no minuto 0")
    func startsAtMidnight() {
        let midnight = Calendar.current.startOfDay(for: referenceDay)
        let event = DetectedEvent(label: "Início do dia", start: midnight, duration: 1800)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.startMinute == 0)
        #expect(item.dayOffset == 0)
    }

    @Test("evento que termina 23:59 sem atravessar a meia-noite não é recortado")
    func endsAt2359() {
        // 23:00 + 59 min = 23:59, ainda no mesmo dia — não atravessa.
        let event = DetectedEvent(label: "Fim do dia", start: at(23, 0), duration: 59 * 60)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.startMinute == 1380)  // 23:00
        #expect(item.endMinute == 1439)    // 23:59, o fim de verdade — não um recorte
        #expect(item.dayOffset == 0)
    }

    // MARK: - Atravessar a meia-noite (a decisão que o brief pede escrita no código)

    @Test("evento que atravessa a meia-noite fica no dia em que começa, recortado às 23:59")
    func crossesMidnight() {
        // 23:30 + 60 min = 00:30 do dia seguinte.
        let event = DetectedEvent(label: "Atravessa", start: at(23, 30), duration: 3600)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.dayOffset == 0)          // fica no dia em que começa, não no seguinte
        #expect(item.startMinute == 1410)     // 23:30
        #expect(item.endMinute == 1439)       // recortado, não os 30 min reais de sobra
        // Prova que o recorte de verdade aconteceu, e não que o cálculo por
        // acaso bateu com a duração real — os dois números divergem.
        #expect(item.endMinute != item.startMinute + Int(event.duration / 60))
    }

    @Test("terminar exatamente à meia-noite também conta como atravessar")
    func endsExactlyAtMidnight() {
        // 23:00 + 60 min = 00:00 do dia seguinte, exatamente.
        let event = DetectedEvent(label: "Limite", start: at(23, 0), duration: 3600)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.dayOffset == 0)
        #expect(item.endMinute == 1439)
    }

    // MARK: - Duração zero

    @Test("duração zero começa e termina no mesmo minuto")
    func zeroDuration() {
        let event = DetectedEvent(label: "Instantâneo", start: at(10, 15), duration: 0)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: referenceDay
        )
        #expect(item.startMinute == item.endMinute)
        #expect(item.startMinute == 615)
        #expect(item.durationMinutes == 0)
    }

    // MARK: - accountID passa direto

    @Test("a conta do item é a que a chamada passar, não uma derivada")
    func accountIDPassesThrough() {
        let event = DetectedEvent(label: "Qualquer", start: at(10, 0), duration: 600)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "host", referenceDay: referenceDay
        )
        #expect(item.accountID == "host")
    }

    // MARK: - Independência de fuso

    /// A mesma ideia de `FixtureTimeZoneTests`, só que provada de dentro do
    /// teste em vez de depender do fuso do executor: constrói a referência e o
    /// evento pelo **mesmo** calendário, com fuso trocado a cada rodada, e
    /// espera o mesmo resultado sempre. Se a conversão support subtraísse
    /// `Date` de `Date` em segundos (a conta errada, documentada no arquivo),
    /// isto continuaria batendo — porque os dois lados nasceriam no mesmo
    /// fuso. O que travaria o defeito de verdade é `Calendar.current` correndo
    /// solto num teste sem fuso fixo: por isso a suíte inteira roda de novo
    /// sob `TZ` trocado como parte da verificação da tarefa (ver o relatório).
    @Test("o mesmo horário de parede vale o mesmo minuto, qualquer que seja o fuso do calendário",
          arguments: ["America/Sao_Paulo", "Europe/Berlin", "Pacific/Kiritimati", "Pacific/Midway", "UTC"])
    func timezoneIndependent(identifier: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: identifier))

        var refComponents = DateComponents()
        refComponents.year = 2026; refComponents.month = 8; refComponents.day = 25
        refComponents.hour = 12; refComponents.minute = 0
        let reference = try #require(calendar.date(from: refComponents))

        var startComponents = DateComponents()
        startComponents.year = 2026; startComponents.month = 8; startComponents.day = 27
        startComponents.hour = 15; startComponents.minute = 0
        let start = try #require(calendar.date(from: startComponents))

        let event = DetectedEvent(label: "Call", start: start, duration: 3600)
        let item = DetectedEventConversion.agendaItem(
            from: event, id: "x", accountID: "zoho", referenceDay: reference, calendar: calendar
        )

        // 27/08 - 25/08 = 2 dias; 15:00 é sempre o minuto 900, em qualquer
        // fuso — porque a referência e o evento nasceram do mesmo calendário,
        // com a mesma hora de parede.
        #expect(item.dayOffset == 2)
        #expect(item.startMinute == 900)
        #expect(item.endMinute == 960)
    }

    // MARK: - O id estável

    @Test("o id do compromisso é determinístico por mensagem")
    func agendaIDIsDeterministic() {
        #expect(DetectedEventConversion.agendaID(forMessageID: "m1")
                == DetectedEventConversion.agendaID(forMessageID: "m1"))
    }

    @Test("mensagens diferentes geram ids diferentes")
    func agendaIDDiffersByMessage() {
        #expect(DetectedEventConversion.agendaID(forMessageID: "m1")
                != DetectedEventConversion.agendaID(forMessageID: "m2"))
    }
}
