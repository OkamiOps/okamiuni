import Foundation
import Testing
@testable import UNICore

@Suite("O convite de agenda, lido do `text/calendar`")
struct ICalendarTests {
    private static let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!

    private static let convite = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Revisão do contrato
        DTSTART;TZID=America/Sao_Paulo:20260827T150000
        DTEND;TZID=America/Sao_Paulo:20260827T160000
        LOCATION:Sala 4\\, 3º andar
        ORGANIZER;CN=Marina Duarte:mailto:marina@clientepremium.com
        ATTENDEE;CN=Eu:mailto:eu@meusite.com
        ATTENDEE:mailto:juridico@clientepremium.com
        STATUS:CONFIRMED
        END:VEVENT
        END:VCALENDAR
        """

    @Test("O convite inteiro: título, quando, onde, quem")
    func conviteInteiro() throws {
        let lido = try #require(ICalendar.parse(Self.convite, timeZone: Self.saoPaulo))
        #expect(lido.summary == "Revisão do contrato")
        // A vírgula escapada é vírgula, não separador de parâmetro.
        #expect(lido.location == "Sala 4, 3º andar")
        #expect(lido.organizer == "Marina Duarte")
        // O `CN` quando existe; o endereço sem `mailto:` quando não.
        #expect(lido.attendees == ["Eu", "juridico@clientepremium.com"])
        #expect(lido.method == "REQUEST")
        #expect(lido.status == "CONFIRMED")
        #expect(lido.isAllDay == false)

        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = Self.saoPaulo
        let inicio = try #require(lido.start)
        #expect(calendario.component(.hour, from: inicio) == 15)
        #expect(calendario.component(.day, from: inicio) == 27)
        #expect(lido.end?.timeIntervalSince(inicio) == 3_600)
    }

    @Test("O `Z` é UTC, e ele vence o fuso da máquina")
    func horaEmUTC() throws {
        let lido = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            DTSTART:20260827T180000Z
            END:VEVENT
            END:VCALENDAR
            """, timeZone: Self.saoPaulo))
        // 18:00 UTC é 15:00 em São Paulo. Ler o valor como hora local daria
        // 18:00 na tela e três horas de atraso na vida da pessoa.
        var emSaoPaulo = Calendar(identifier: .gregorian)
        emSaoPaulo.timeZone = Self.saoPaulo
        let inicio = try #require(lido.start)
        #expect(emSaoPaulo.component(.hour, from: inicio) == 15)
        var emUTC = Calendar(identifier: .gregorian)
        emUTC.timeZone = TimeZone(identifier: "UTC")!
        #expect(emUTC.component(.hour, from: inicio) == 18)
    }

    @Test("`VALUE=DATE` é dia inteiro, à meia-noite do fuso do convite")
    func diaInteiro() throws {
        let lido = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Feriado
            DTSTART;VALUE=DATE:20260827
            END:VEVENT
            END:VCALENDAR
            """, timeZone: Self.saoPaulo))
        #expect(lido.isAllDay)
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = Self.saoPaulo
        let inicio = try #require(lido.start)
        #expect(calendario.component(.hour, from: inicio) == 0)
        #expect(calendario.component(.day, from: inicio) == 27)
    }

    @Test("Data ilegível não derruba o convite: o resto continua no cartão")
    func dataIlegivel() throws {
        let lido = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Reunião sem data
            DTSTART:amanhã de manhã
            DTEND:20260899T999999
            LOCATION:Online
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(lido.start == nil)
        #expect(lido.end == nil)
        #expect(lido.summary == "Reunião sem data")
        #expect(lido.location == "Online")
        // Sem começo não há compromisso a criar — o botão não pode existir para
        // não fazer nada.
        #expect(lido.detectedEvent == nil)
    }

    @Test("A linha dobrada em 75 octetos é remontada antes de ser lida")
    func linhaDobrada() throws {
        let lido = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Revisão do contrato com a
              equipe jurídica
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(lido.summary == "Revisão do contrato com a equipe jurídica")
    }

    @Test("Sem `DTEND`, o compromisso dura uma hora — a convenção que a pessoa já viu")
    func semFim() throws {
        let lido = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Café
            DTSTART:20260827T180000Z
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(lido.detectedEvent?.duration == CalendarInvite.duracaoPadrao)
    }

    @Test("O convite vira o mesmo `DetectedEvent` que 'Colocar na agenda' já recebe")
    func viraDetectedEvent() throws {
        let lido = try #require(ICalendar.parse(Self.convite, timeZone: Self.saoPaulo))
        let evento = try #require(lido.detectedEvent)
        #expect(evento.label == "Revisão do contrato")
        #expect(evento.duration == 3_600)
        #expect(evento.end == lido.end)
    }

    @Test("Convite cancelado se anuncia, pelo METHOD ou pelo STATUS")
    func cancelado() throws {
        let porMetodo = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            METHOD:CANCEL
            BEGIN:VEVENT
            SUMMARY:Não vai mais ter
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(porMetodo.isCancelled)

        let porStatus = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            STATUS:CANCELLED
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(porStatus.isCancelled)
        #expect(try #require(ICalendar.parse(Self.convite)).isCancelled == false)
    }

    @Test("Texto que não é calendário nenhum devolve nada — sem crash e sem cartão vazio")
    func naoEhCalendario() {
        #expect(ICalendar.parse("") == nil)
        #expect(ICalendar.parse("Bom dia, tudo bem?") == nil)
        // Um `VCALENDAR` sem `VEVENT` (um `VTODO`, um fuso solto) não é
        // convite: desenhar um cartão em branco seria pior do que não desenhar.
        #expect(ICalendar.parse("BEGIN:VCALENDAR\nEND:VCALENDAR") == nil)
    }

    @Test("O segundo VEVENT de uma série não sobrescreve o primeiro")
    func primeiroEventoVence() throws {
        let lido = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:O primeiro
            END:VEVENT
            BEGIN:VEVENT
            SUMMARY:O segundo
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(lido.summary == "O primeiro")
    }

    @Test("`CN` com vírgula e dois-pontos sobrevive ao corte da linha")
    func nomeComPontuacao() throws {
        let lido = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            ORGANIZER;CN="Duarte, Marina: a chefe":mailto:marina@x.com
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(lido.organizer == "Duarte, Marina: a chefe")
    }
}
