import Foundation
import Testing
@testable import UNICore

/// O convite do Favini, como ele chega: local, link no meio da descrição,
/// organizador e participantes de verdade.
private let conviteDoFavini = """
    BEGIN:VCALENDAR
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:dreamsquad@vantion.com.br
    SEQUENCE:0
    SUMMARY:DreamSquad
    DTSTART;TZID=America/Sao_Paulo:20260901T095400
    DTEND;TZID=America/Sao_Paulo:20260901T104400
    LOCATION:Sala Vantion\\, 4º andar
    ORGANIZER;CN=Favini:mailto:favini@vantion.com.br
    ATTENDEE;CN=Marcos Santos:mailto:marcos@vantion.com.br
    ATTENDEE:mailto:equipe@vantion.com.br
    DESCRIPTION:Pauta do time.\\nEntrar por https://meet.google.com/abc-defg-hij\\nAté lá.
    END:VEVENT
    END:VCALENDAR
    """

@Suite("O convite carrega o que a janela do compromisso mostra")
struct InviteDetailTests {
    private static let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!

    private func lido(_ ics: String = conviteDoFavini) throws -> CalendarInvite {
        try #require(ICalendar.parse(ics, timeZone: Self.saoPaulo))
    }

    @Test("Descrição e URL atravessam o parse")
    func descricaoEURL() throws {
        let convite = try lido()
        #expect(convite.descricao?.contains("Pauta do time.") == true)
        // O `\\n` do RFC é quebra de linha de verdade, e não duas letras.
        #expect(convite.descricao?.contains("\n") == true)
    }

    @Test("O organizador tem nome E endereço — o de verdade, não o de fixture")
    func organizadorDeVerdade() throws {
        let convite = try lido()
        #expect(convite.organizerContact?.name == "Favini")
        #expect(convite.organizerContact?.address == "favini@vantion.com.br")
        // O cartão do leitor continua lendo o nome, como na M3-8.
        #expect(convite.organizer == "Favini")
    }

    @Test("Os participantes trazem endereço, com ou sem CN")
    func participantes() throws {
        let convite = try lido()
        #expect(convite.attendeeContacts.map(\.address)
                == ["marcos@vantion.com.br", "equipe@vantion.com.br"])
        #expect(convite.attendees == ["Marcos Santos", "equipe@vantion.com.br"])
    }

    // MARK: - O link da reunião

    @Test("O link no meio da descrição é achado")
    func linkNaDescricao() throws {
        #expect(try lido().meetingURL == "https://meet.google.com/abc-defg-hij")
    }

    @Test("O `URL:` do convite manda quando existe")
    func linkNoCampoURL() throws {
        let convite = try lido("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            DTSTART:20260901T120000Z
            URL:https://zoom.us/j/123456
            DESCRIPTION:Também tem https://meet.google.com/xxx-yyyy-zzz aqui
            END:VEVENT
            END:VCALENDAR
            """)
        #expect(convite.meetingURL == "https://zoom.us/j/123456")
    }

    @Test("O Google Meet escrito na LOCATION conta como link")
    func linkNaLocation() throws {
        let convite = try lido("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            DTSTART:20260901T120000Z
            LOCATION:https://teams.microsoft.com/l/meetup-join/19%3ameeting
            END:VEVENT
            END:VCALENDAR
            """)
        #expect(convite.meetingURL == "https://teams.microsoft.com/l/meetup-join/19%3ameeting")
    }

    /// **Só sala conhecida.** Um convite traz mapa, cancelamento e política de
    /// privacidade; a primeira URL do texto poria qualquer um deles onde a
    /// pessoa espera o botão de entrar.
    @Test("Link que não é de reunião não vira link de reunião")
    func linkQualquerNaoConta() {
        #expect(MeetingLink.first(in: "veja https://maps.google.com/?q=Sala") == nil)
        #expect(MeetingLink.first(in: "https://zoom.us.golpe.com/j/1") == nil)
        #expect(MeetingLink.first(in: "sem link nenhum") == nil)
        // Pontuação colada e sinais em volta não estragam o endereço.
        #expect(
            MeetingLink.first(in: "Entrar: <https://meet.google.com/abc-defg-hij>.")
                == "https://meet.google.com/abc-defg-hij"
        )
    }

    @Test("Meet nas notas vira sala e o bloco automático não vira descrição")
    func linkNasNotasDoCalendar() {
        let automatic = """
            -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
            --
            Entrar com o Google Meet: https://meet.google.com/us-qnjh-suq

            Saiba mais sobre o Meet em: https://support.google.com/a/users/answer/9282720

            Não edite esta seção.
            -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
            --
            """
        let detail = EventDetail(
            place: EventPlace.semLocal,
            link: nil,
            organizer: EventPerson(
                name: "Vanderson",
                address: "vanderson@example.com",
                role: "organizador",
                status: .yes
            ),
            people: [],
            note: "Calendário do macOS",
            recurrence: "Evento único",
            notice: "Consulte o Calendário para alertas",
            agenda: [],
            thread: [],
            descricao: automatic
        )

        #expect(detail.meetingLink == "https://meet.google.com/us-qnjh-suq")
        #expect(detail.visibleDescription == nil)
        #expect(detail.hasLink)
    }

    @Test("Ao promover a sala, a pauta escrita pela pessoa permanece")
    func pautaPermaneceSemLinkRepetido() {
        let detail = EventDetail(
            place: EventPlace.semLocal,
            link: nil,
            organizer: EventPerson(
                name: "Time",
                address: "time@example.com",
                role: "organizador",
                status: .yes
            ),
            people: [],
            note: "Convite",
            recurrence: "Evento único",
            notice: "Sem alerta",
            agenda: [],
            thread: [],
            descricao: "Pauta: revisar a entrega.\nEntrar: https://zoom.us/j/123456\nLevar os números."
        )

        #expect(detail.meetingLink == "https://zoom.us/j/123456")
        #expect(detail.visibleDescription == "Pauta: revisar a entrega.\nLevar os números.")
    }

    // MARK: - O detalhe do compromisso

    private func detalhe(_ convite: CalendarInvite) -> EventDetail {
        InviteAgenda.detail(
            for: convite,
            subject: "Convite: DreamSquad",
            sender: Contact(name: "Favini", address: "favini@vantion.com.br"),
            when: "29 de ago., 09:41",
            accountHost: "vantion"
        )
    }

    /// A tela do dono: "Sem local definido", organizador "Ricardo Gomes ·
    /// ricardo@empresa.com" (fixture!), participante 1, nota "Criado
    /// manualmente na agenda" — num compromisso que veio de um convite.
    @Test("O compromisso do convite mostra local, organizador e gente de verdade")
    func detalheDeVerdade() throws {
        let detalhe = detalhe(try lido())
        #expect(detalhe.place == "Sala Vantion, 4º andar")
        #expect(detalhe.organizer.name == "Favini")
        #expect(detalhe.organizer.address == "favini@vantion.com.br")
        #expect(detalhe.people.map(\.address) == ["marcos@vantion.com.br", "equipe@vantion.com.br"])
        // Organizador + dois convidados.
        #expect(detalhe.guestCount == 3)
        #expect(detalhe.link == "https://meet.google.com/abc-defg-hij")
        #expect(detalhe.descricao?.contains("Pauta do time.") == true)
    }

    @Test("A nota diz de onde veio, e não que alguém criou à mão")
    func aNotaDizDeOndeVeio() throws {
        let detalhe = detalhe(try lido())
        #expect(detalhe.note == "Do convite por email · conta vantion")
        #expect(detalhe.note != Fixtures.eventDefault.note)
        // E o histórico aponta para a mensagem que trouxe o convite.
        #expect(detalhe.thread.first?.what == "Convite: DreamSquad")
        #expect(detalhe.thread.first?.kind == .email)
    }

    /// Sem local e sem link, a janela diz o que sempre disse — e não inventa
    /// uma sala.
    @Test("Convite sem local nem link não inventa nenhum dos dois")
    func semLocalNemLink() throws {
        let convite = try lido("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Café
            DTSTART:20260901T120000Z
            END:VEVENT
            END:VCALENDAR
            """)
        let detalhe = detalhe(convite)
        #expect(detalhe.place == Fixtures.eventDefault.place)
        #expect(detalhe.link == nil)
        #expect(detalhe.hasLink == false)
        // Sem `ORGANIZER`, quem organiza é quem mandou a mensagem — melhor que
        // um organizador de fixture.
        #expect(detalhe.organizer.address == "favini@vantion.com.br")
    }
}

@Suite("O compromisso criado do convite carrega o detalhe")
@MainActor
struct InviteDetailStoreTests {

    private static let conta = Account(
        id: "vantion", address: "marcos@vantion.com.br", displayName: "Vantion",
        provider: .imap, host: "vantion", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )

    private var mensagem: Message {
        Message(
            id: "m1", accountID: "vantion",
            from: Contact(name: "Favini", address: "favini@vantion.com.br"),
            receivedAt: Fixtures.today, subject: "Convite: DreamSquad",
            snippet: "convite", body: [], tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil, calendarICS: conviteDoFavini
        )
    }

    @Test("O item da agenda leva local, link, organizador e descrição")
    func oItemLevaTudo() async throws {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [Self.conta], messages: [mensagem], agenda: [])
        )
        await store.load()
        let convite = try #require(
            ICalendar.parse(conviteDoFavini, timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        )
        let item = try #require(store.addToAgenda(convite, from: mensagem))
        let detalhe = try #require(item.detail)
        #expect(detalhe.place == "Sala Vantion, 4º andar")
        #expect(detalhe.organizer.address == "favini@vantion.com.br")
        #expect(detalhe.link == "https://meet.google.com/abc-defg-hij")
        #expect(detalhe.note == "Do convite por email · conta vantion")
        #expect(detalhe.descricao?.isEmpty == false)
    }

    /// Um "Convite atualizado" que só mudou a sala continua sendo o mesmo
    /// evento — e a agenda tem de passar a mostrar a sala nova.
    @Test("A atualização troca o local sem criar um segundo compromisso")
    func atualizaOLocal() async throws {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [Self.conta], messages: [mensagem], agenda: [])
        )
        await store.load()
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        let original = try #require(ICalendar.parse(conviteDoFavini, timeZone: saoPaulo))
        store.addToAgenda(original, from: mensagem)

        let mudado = try #require(
            ICalendar.parse(
                conviteDoFavini.replacingOccurrences(
                    of: "LOCATION:Sala Vantion\\, 4º andar", with: "LOCATION:Sala 12"
                ),
                timeZone: saoPaulo
            )
        )
        #expect(store.agendaState(for: mudado, from: mensagem) == .desatualizado)
        store.addToAgenda(mudado, from: mensagem)
        #expect(store.agenda.count == 1)
        #expect(store.agenda[0].detail?.place == "Sala 12")
    }
}
