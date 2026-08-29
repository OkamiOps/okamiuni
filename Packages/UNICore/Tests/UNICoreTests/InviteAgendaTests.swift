import Foundation
import Testing
@testable import UNICore

/// O convite do DreamSquad, o mesmo da tela do dono: o original e o "Convite
/// atualizado", com o **mesmo** `UID` e `SEQUENCE` maior.
enum DreamSquad {
    static let uid = "3n4k5m6l7@google.com"

    static func ics(
        sequence: Int?, hora: String = "T095400", titulo: String = "DreamSquad",
        uid: String? = DreamSquad.uid, local: String = "Google Meet"
    ) -> String {
        var linhas = [
            "BEGIN:VCALENDAR",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "SUMMARY:\(titulo)",
            "DTSTART;TZID=America/Sao_Paulo:20260901\(hora)",
            "DTEND;TZID=America/Sao_Paulo:20260901T104400",
            "LOCATION:\(local)",
            "ORGANIZER;CN=Favini:mailto:favini@vantion.com.br",
        ]
        if let uid { linhas.append("UID:\(uid)") }
        if let sequence { linhas.append("SEQUENCE:\(sequence)") }
        linhas += ["END:VEVENT", "END:VCALENDAR"]
        return linhas.joined(separator: "\r\n")
    }

    static var saoPaulo: TimeZone { TimeZone(identifier: "America/Sao_Paulo")! }

    static func convite(
        sequence: Int?, hora: String = "T095400", titulo: String = "DreamSquad",
        uid: String? = DreamSquad.uid
    ) -> CalendarInvite {
        ICalendar.parse(
            ics(sequence: sequence, hora: hora, titulo: titulo, uid: uid), timeZone: saoPaulo
        )!
    }
}

@Suite("O convite e a agenda: um evento, um compromisso")
struct InviteAgendaTests {

    private func item(_ convite: CalendarInvite, id: String = "email-m1") -> AgendaItem? {
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = DreamSquad.saoPaulo
        return InviteAgenda.item(
            for: convite, id: id, accountID: "zoho",
            referenceDay: Fixtures.today, calendar: calendario
        )
    }

    @Test("O UID e o SEQUENCE atravessam o parse")
    func uidESequence() throws {
        let lido = DreamSquad.convite(sequence: 2)
        #expect(lido.uid == DreamSquad.uid)
        #expect(lido.sequence == 2)
    }

    @Test("Sem UID e sem SEQUENCE, o convite continua sendo convite")
    func semUID() throws {
        let lido = DreamSquad.convite(sequence: nil, uid: nil)
        #expect(lido.uid == nil)
        #expect(lido.sequence == nil)
        #expect(lido.summary == "DreamSquad")
    }

    @Test("O compromisso criado carrega o UID e a versão do convite")
    func compromissoCarregaOUID() throws {
        let criado = try #require(item(DreamSquad.convite(sequence: 1)))
        #expect(criado.calendarUID == DreamSquad.uid)
        #expect(criado.calendarSequence == 1)
    }

    /// O encaminhamento: outra mensagem, outro `id`, **mesmo** UID. Sem casar
    /// pelo UID, seriam duas agendas idênticas — e com cinquenta
    /// encaminhamentos, cinquenta.
    @Test("O mesmo UID reencontra o compromisso, mesmo vindo de outra mensagem")
    func mesmoUIDOutraMensagem() throws {
        let original = try #require(item(DreamSquad.convite(sequence: 0), id: "email-m1"))
        let encaminhado = DreamSquad.convite(sequence: 0)
        let achado = InviteAgenda.existing(
            for: encaminhado, id: "email-m2", accountID: "zoho", in: [original]
        )
        #expect(achado?.id == "email-m1")
        #expect(
            InviteAgenda.state(
                for: encaminhado, existing: achado,
                proposed: item(encaminhado, id: "email-m2")
            ) == .naAgenda
        )
    }

    @Test("Sem nada na agenda, o cartão oferece colocar")
    func ausente() throws {
        let convite = DreamSquad.convite(sequence: 0)
        #expect(
            InviteAgenda.state(for: convite, existing: nil, proposed: item(convite)) == .ausente
        )
    }

    /// O "Convite atualizado": mesmo UID, `SEQUENCE` maior, horário novo.
    @Test("SEQUENCE maior pede atualização, não um segundo compromisso")
    func sequenceMaior() throws {
        let original = try #require(item(DreamSquad.convite(sequence: 0)))
        let atualizado = DreamSquad.convite(sequence: 1, hora: "T110000")
        let proposto = try #require(item(atualizado, id: "email-m2"))
        #expect(InviteAgenda.state(for: atualizado, existing: original, proposed: proposto) == .desatualizado)

        let final = InviteAgenda.updated(original, with: proposto)
        // O horário é o novo; o `id` continua o que a agenda já conhece — é
        // ele que "Desfazer" e "Ir para o email de origem" seguram.
        #expect(final.id == original.id)
        #expect(final.startMinute == 11 * 60)
        #expect(final.calendarSequence == 1)
    }

    /// Quem manda alteração sem mexer no `SEQUENCE` existe. Uma reunião que
    /// mudou de horário não pode ficar com o horário velho por causa disso.
    @Test("Mesmo SEQUENCE com horário diferente ainda pede atualização")
    func mesmoSequenceOutroHorario() throws {
        let original = try #require(item(DreamSquad.convite(sequence: 3)))
        let mudado = DreamSquad.convite(sequence: 3, hora: "T140000")
        #expect(
            InviteAgenda.state(for: mudado, existing: original, proposed: item(mudado)) == .desatualizado
        )
    }

    @Test("Mesmo SEQUENCE e tudo igual é 'Na agenda'")
    func mesmoSequenceTudoIgual() throws {
        let original = try #require(item(DreamSquad.convite(sequence: 3)))
        let copia = DreamSquad.convite(sequence: 3)
        #expect(InviteAgenda.state(for: copia, existing: original, proposed: item(copia)) == .naAgenda)
    }

    /// Convite sem UID cai na identidade de antes — a mensagem que o trouxe —
    /// e continua sem duplicar dentro dela.
    @Test("Sem UID, a identidade continua sendo a da mensagem")
    func semUIDCaiNoID() throws {
        let convite = DreamSquad.convite(sequence: nil, uid: nil)
        let criado = try #require(item(convite, id: "email-m1"))
        #expect(criado.calendarUID == nil)
        #expect(
            InviteAgenda.existing(for: convite, id: "email-m1", accountID: "zoho", in: [criado])?.id
                == "email-m1"
        )
        #expect(
            InviteAgenda.existing(for: convite, id: "email-m9", accountID: "zoho", in: [criado]) == nil
        )
    }

    /// A mesma reunião pode estar legitimamente em duas contas da pessoa, e
    /// cada agenda é da sua.
    @Test("O UID de outra conta não conta como já estando na agenda")
    func outraConta() throws {
        let naZoho = try #require(item(DreamSquad.convite(sequence: 0)))
        let convite = DreamSquad.convite(sequence: 0)
        #expect(
            InviteAgenda.existing(for: convite, id: "email-m2", accountID: "gmail", in: [naZoho]) == nil
        )
    }
}

@Suite("A agenda do MailStore recebe convites sem duplicar")
@MainActor
struct InviteAgendaStoreTests {

    private func store() async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: [])
        )
        await store.load()
        return store
    }

    private func mensagem(_ id: String, ics: String) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: "Favini", address: "favini@vantion.com.br"),
            receivedAt: Fixtures.today, subject: "DreamSquad", snippet: "convite", body: [],
            tags: [], bucket: .today, isRead: true, summary: nil, detectedEvent: nil,
            calendarICS: ics
        )
    }

    /// O defeito inteiro, do jeito que o dono o viveu: o convite, o "Convite
    /// atualizado" do mesmo evento, e um clique em cada.
    @Test("Convite e convite atualizado dão UM compromisso, não dois")
    func naoDuplica() async throws {
        let store = await store()
        let original = mensagem("m1", ics: DreamSquad.ics(sequence: 0))
        let atualizado = mensagem("m2", ics: DreamSquad.ics(sequence: 1, hora: "T110000"))

        let convite1 = try #require(ICalendar.parse(original.calendarICS!, timeZone: DreamSquad.saoPaulo))
        let convite2 = try #require(ICalendar.parse(atualizado.calendarICS!, timeZone: DreamSquad.saoPaulo))

        #expect(store.agendaState(for: convite1, from: original) == .ausente)
        #expect(store.addToAgenda(convite1, from: original) != nil)
        #expect(store.agenda.count == 1)

        // Ao **abrir** a segunda mensagem, o cartão já sabe: é o mesmo evento,
        // versão nova.
        #expect(store.agendaState(for: convite2, from: atualizado) == .desatualizado)
        let mexido = try #require(store.addToAgenda(convite2, from: atualizado))
        #expect(store.agenda.count == 1)
        #expect(mexido.id == "email-m1")
        #expect(store.agenda[0].calendarSequence == 1)
    }

    @Test("Abrir de novo a mesma mensagem mostra 'Na agenda', sem clique nenhum")
    func jaEstaLa() async throws {
        let store = await store()
        let mensagem = mensagem("m1", ics: DreamSquad.ics(sequence: 0))
        let convite = try #require(ICalendar.parse(mensagem.calendarICS!, timeZone: DreamSquad.saoPaulo))
        store.addToAgenda(convite, from: mensagem)
        #expect(store.agendaState(for: convite, from: mensagem) == .naAgenda)
        // E o segundo clique não faz nada — nem compromisso, nem confirmação.
        #expect(store.addToAgenda(convite, from: mensagem) == nil)
        #expect(store.agenda.count == 1)
    }

    /// O encaminhamento é a versão feia do mesmo defeito: cinquenta cópias da
    /// mesma reunião, cinquenta blocos na agenda.
    @Test("Cinquenta encaminhamentos do mesmo convite continuam sendo um compromisso")
    func encaminhamentos() async throws {
        let store = await store()
        for indice in 0..<50 {
            let mensagem = mensagem("m\(indice)", ics: DreamSquad.ics(sequence: 0))
            let convite = try #require(ICalendar.parse(mensagem.calendarICS!, timeZone: DreamSquad.saoPaulo))
            store.addToAgenda(convite, from: mensagem)
        }
        #expect(store.agenda.count == 1)
    }
}
