import Foundation
import Testing
@testable import UNICore

/// A frase do protótipo, e as vizinhas dela.
///
/// O caso que importa não é "a frase do desenho funciona": é que ela funcione
/// **sem rede e sem modelo**, do mesmo jeito em dois dias diferentes. Por isso
/// todo caso aqui passa um "agora" fixo — 14 de outubro de 2026, uma
/// quarta-feira, que é o dia em que o desenho foi aprovado.
@Suite("A frase que vira compromisso")
struct AppointmentPhraseTests {

    /// Quarta, 14 de outubro de 2026, 10:00 local.
    private var agora: Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 14
        parts.hour = 10; parts.minute = 0
        return Calendar(identifier: .gregorian).date(from: parts)!
    }

    private var calendario: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    @Test("a frase do desenho: amanhã 15h com a Marina sobre a proposta")
    func aFraseDoDesenho() throws {
        let lida = AppointmentPhrase.interpret(
            "amanhã 15h com a Marina sobre a proposta", now: agora
        )
        #expect(lida.understood)
        let inicio = try #require(lida.start)
        let partes = calendario.dateComponents([.year, .month, .day, .hour, .minute], from: inicio)
        #expect(partes.day == 15)          // amanhã
        #expect(partes.month == 10)
        #expect(partes.hour == 15)         // 15h
        #expect(partes.minute == 0)
        #expect(lida.guestNames == ["Marina"])
        #expect(lida.title == "Proposta")
        #expect(lida.dateSource?.lowercased() == "amanhã")
        #expect(lida.timeSource?.contains("15") == true)
        // Sem duração dita, uma hora — e é o que o cartão do desenho mostra.
        let fim = try #require(lida.end)
        #expect(calendario.dateComponents([.minute], from: inicio, to: fim).minute == 60)
    }

    @Test("sem nada reconhecível, nada é inventado")
    func fraseOpaca() {
        let lida = AppointmentPhrase.interpret("conversa", now: agora)
        #expect(!lida.understood)
        #expect(lida.start == nil)
        #expect(lida.guestNames.isEmpty)
    }

    @Test("dia da semana aponta para a próxima ocorrência")
    func diaDaSemana() throws {
        // Quarta pedindo "sexta" quer a sexta desta semana: dia 16.
        let lida = AppointmentPhrase.interpret("sexta 9h alinhamento", now: agora)
        let inicio = try #require(lida.start)
        #expect(calendario.component(.day, from: inicio) == 16)
        #expect(calendario.component(.hour, from: inicio) == 9)
    }

    @Test("quarta pedindo quarta quer a semana que vem, não hoje")
    func mesmoDiaDaSemana() throws {
        let lida = AppointmentPhrase.interpret("quarta 14h", now: agora)
        let inicio = try #require(lida.start)
        #expect(calendario.component(.day, from: inicio) == 21)
    }

    @Test("hora sem dia que já passou vai para amanhã")
    func horaQueJaPassou() throws {
        let lida = AppointmentPhrase.interpret("9h café", now: agora)   // agora são 10h
        let inicio = try #require(lida.start)
        #expect(calendario.component(.day, from: inicio) == 15)
        #expect(calendario.component(.hour, from: inicio) == 9)
    }

    @Test("duração explícita entra, e não é confundida com horário")
    func duracao() throws {
        let lida = AppointmentPhrase.interpret("amanhã 15h por 30min retro", now: agora)
        #expect(lida.duration == 30)
        let inicio = try #require(lida.start)
        #expect(calendario.component(.hour, from: inicio) == 15)
        let fim = try #require(lida.end)
        #expect(calendario.dateComponents([.minute], from: inicio, to: fim).minute == 30)
    }

    @Test("dois convidados, separados por 'e'")
    func doisConvidados() {
        let lida = AppointmentPhrase.interpret("hoje 16h com João e Ana sobre o orçamento", now: agora)
        #expect(lida.guestNames == ["João", "Ana"])
        #expect(lida.title == "Orçamento")
    }

    @Test("hora com minutos, nas duas grafias")
    func horaComMinutos() throws {
        for frase in ["amanhã 15h30", "amanhã 15:30"] {
            let lida = AppointmentPhrase.interpret(frase, now: agora)
            let inicio = try #require(lida.start, "\(frase)")
            #expect(calendario.component(.hour, from: inicio) == 15, "\(frase)")
            #expect(calendario.component(.minute, from: inicio) == 30, "\(frase)")
        }
    }

    @Test("dia escrito: 20 de novembro")
    func diaEscrito() throws {
        let lida = AppointmentPhrase.interpret("20 de novembro 11h fechamento", now: agora)
        let inicio = try #require(lida.start)
        #expect(calendario.component(.day, from: inicio) == 20)
        #expect(calendario.component(.month, from: inicio) == 11)
        #expect(calendario.component(.hour, from: inicio) == 11)
    }

    @Test("o título perde as palavras de ligação, e só elas")
    func tituloLimpo() {
        #expect(AppointmentPhrase.cleanTitle(" sobre a proposta ") == "Proposta")
        #expect(AppointmentPhrase.cleanTitle("revisão da proposta") == "Revisão da proposta")
        #expect(AppointmentPhrase.cleanTitle("   ") == "")
    }
}
