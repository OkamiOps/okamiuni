import Foundation
import Testing
@testable import UNICore

@Suite("O carimbo de data da linha")
struct MessageStampTests {

    /// Relógio injetado, calendário fixo: o teste não pode depender do dia em
    /// que a suíte roda nem do fuso da máquina.
    private var calendario: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }

    private func quando(_ ano: Int, _ mes: Int, _ dia: Int, _ hora: Int = 12, _ minuto: Int = 0) -> Date {
        calendario.date(from: DateComponents(year: ano, month: mes, day: dia, hour: hora, minute: minuto))!
    }

    private var agora: Date { quando(2026, 8, 29, 10, 0) }

    private func carimbo(_ data: Date) -> MessageStamp {
        MessageStamp.of(data, now: agora, calendar: calendario)
    }

    @Test("Hoje mostra a hora")
    func hoje() {
        #expect(carimbo(quando(2026, 8, 29, 16, 55)) == .clock)
    }

    @Test("Ontem tem nome")
    func ontem() {
        #expect(carimbo(quando(2026, 8, 28, 20, 13)) == .yesterday)
    }

    /// O defeito da tela: um email de 21 de julho carimbado "16:55", como se
    /// fosse de hoje.
    @Test("Deste ano mostra dia e mês, e nunca a hora")
    func desteAno() {
        #expect(carimbo(quando(2026, 7, 21, 16, 55)) == .dayMonth)
        #expect(carimbo(quando(2026, 1, 1)) == .dayMonth)
    }

    @Test("De outro ano mostra o ano junto")
    func outroAno() {
        #expect(carimbo(quando(2025, 7, 21)) == .dayMonthYear)
        #expect(carimbo(quando(2025, 12, 31)) == .dayMonthYear)
    }

    /// A fronteira: um minuto separa a hora do nome do dia. É por isso que a
    /// conta é por dia de calendário e não por horas decorridas — 24 horas
    /// para trás diriam "hoje" para um email de ontem à noite.
    @Test("A meia-noite vira o carimbo, e não as 24 horas decorridas")
    func meiaNoite() {
        let umMinutoDepoisDaMeiaNoite = quando(2026, 8, 29, 0, 1)
        let umMinutoAntes = quando(2026, 8, 28, 23, 59)
        #expect(MessageStamp.of(umMinutoDepoisDaMeiaNoite, now: agora, calendar: calendario) == .clock)
        #expect(MessageStamp.of(umMinutoAntes, now: agora, calendar: calendario) == .yesterday)
        // E às 00:05, a mensagem das 23:50 de ontem já é "Ontem" — cinco
        // minutos de idade, e o dia mudou.
        #expect(
            MessageStamp.of(
                quando(2026, 8, 28, 23, 50), now: quando(2026, 8, 29, 0, 5), calendar: calendario
            ) == .yesterday
        )
    }

    /// A virada do ano: 31 de dezembro visto no dia 1º é "Ontem", e não uma
    /// data com ano. O nome do dia vale mais que o ano — é o que a pessoa lê
    /// primeiro.
    @Test("O 31 de dezembro visto no dia 1º continua sendo Ontem")
    func viradaDoAno() {
        #expect(
            MessageStamp.of(
                quando(2025, 12, 31, 22, 0), now: quando(2026, 1, 1, 9, 0), calendar: calendario
            ) == .yesterday
        )
    }

    /// As fixtures do Marco 1 continuam carimbadas como sempre: as de `today`
    /// com a hora, as da véspera com "Ontem". É a condição byte a byte dos
    /// retratos — se este teste cair, os vinte PNGs mudaram.
    @Test("As fixtures do Marco 1 não mudam de carimbo")
    func fixturesIntactas() throws {
        let hoje = try #require(Fixtures.messages.first { $0.dayOffset == 0 })
        let ontem = try #require(Fixtures.messages.first { $0.dayOffset == -1 })
        #expect(MessageStamp.of(hoje.receivedAt, now: Fixtures.today) == .clock)
        #expect(MessageStamp.of(ontem.receivedAt, now: Fixtures.today) == .yesterday)
        for mensagem in Fixtures.messages {
            let esperado: MessageStamp = mensagem.dayOffset == 0 ? .clock : .yesterday
            #expect(MessageStamp.of(mensagem.receivedAt, now: Fixtures.today) == esperado)
        }
    }
}
