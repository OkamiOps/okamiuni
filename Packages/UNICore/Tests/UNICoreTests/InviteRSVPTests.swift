import Foundation
import Testing
@testable import UNICore

@Suite("RSVP/iTIP do convite")
@MainActor
struct InviteRSVPTests {
    private final class SendPort: MailSendPort, @unchecked Sendable {
        private(set) var sent: [OutgoingMessage] = []
        func send(_ message: OutgoingMessage) throws { sent.append(message) }
    }

    private let account = Account(
        id: "conta-a", address: "eu@okami.example", displayName: "Eu",
        provider: .imap, host: "okami", tintLightHex: "#000000", tintDarkHex: "#ffffff"
    )

    private var invite: CalendarInvite {
        CalendarInvite(
            summary: "Planejamento", start: Fixtures.today, end: nil,
            organizer: Contact(name: "Marina", address: "marina@cliente.example"),
            attendees: [
                Contact(name: "Outra", address: "outra@cliente.example"),
                Contact(name: "Eu", address: "EU@OKAMI.EXAMPLE"),
            ],
            method: "REQUEST", uid: "evento-42", sequence: 7
        )
    }

    private var message: Message {
        Message(
            id: "m-42", accountID: account.id,
            from: Contact(name: "Marina", address: "marina@cliente.example"),
            receivedAt: Fixtures.today, subject: "Planejamento", snippet: "convite", body: [],
            tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil,
            calendarICS: "BEGIN:VCALENDAR", rfcMessageID: "convite-42@cliente.example"
        )
    }

    @Test("Os botões usam ações; o estado usa a resposta já dada")
    func rotulosDeAcaoEEstado() {
        #expect(InviteRSVPResponse.allCases.map(\.actionLabel) == ["Aceitar", "Talvez", "Recusar"])
        #expect(InviteRSVPResponse.allCases.map(\.label) == ["Aceito", "Talvez", "Recusado"])
        #expect(InviteRSVPResponse.tentative.otherResponses.map(\.actionLabel) == ["Aceitar", "Recusar"])
        #expect(InviteRSVPResponse.accepted.otherResponses.map(\.actionLabel) == ["Talvez", "Recusar"])
        #expect(InviteRSVPResponse.declined.otherResponses.map(\.actionLabel) == ["Aceitar", "Talvez"])
        #expect(InviteRSVPResponse.accepted.placesOnAgenda)
        #expect(InviteRSVPResponse.tentative.placesOnAgenda)
        #expect(!InviteRSVPResponse.declined.placesOnAgenda)
    }

    @Test("Aceitar e Talvez põem o compromisso na agenda; Recusar tira")
    func aceitarColocaNaAgenda() async throws {
        let port = SendPort()
        let aceitar = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [message], agenda: []),
            sendPort: port
        )
        await aceitar.load()
        #expect(aceitar.respondToInvite(invite, from: message, response: .accepted) == .queued(.accepted))
        #expect(aceitar.agenda.contains { $0.calendarUID == "evento-42" })

        let recusar = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [message], agenda: []),
            sendPort: SendPort()
        )
        await recusar.load()
        #expect(recusar.respondToInvite(invite, from: message, response: .declined) == .queued(.declined))
        #expect(recusar.agenda.isEmpty)
    }

    @Test("Recusar tira o compromisso que o Aceitar tinha posto")
    func recusarTiraDaAgenda() async throws {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [message], agenda: []),
            sendPort: SendPort()
        )
        await store.load()
        #expect(store.respondToInvite(invite, from: message, response: .accepted) == .queued(.accepted))
        #expect(!store.agenda.isEmpty)
        #expect(store.respondToInvite(invite, from: message, response: .declined) == .queued(.declined))
        #expect(store.agenda.isEmpty)
    }

    @Test("resposta já gravada ainda coloca na agenda ao reabrir o convite")
    func ensureAgendaReabre() async throws {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [message], agenda: []),
            sendPort: SendPort()
        )
        await store.load()
        #expect(store.respondToInvite(invite, from: message, response: .tentative) == .queued(.tentative))
        let id = try #require(store.agenda.first?.id)
        store.removeFromAgenda(id)
        #expect(store.agenda.isEmpty)
        store.ensureAgendaForRSVP(invite, from: message)
        #expect(store.agenda.contains { $0.calendarUID == "evento-42" })
    }

    /// Mutation check: trocar METHOD ou PARTSTAT no construtor abaixo torna
    /// esta prova vermelha; não compara uma cópia local da implementação.
    @Test("Aceitar monta METHOD:REPLY e PARTSTAT=ACCEPTED para a conta convidada")
    func metodoEPartstat() throws {
        let outgoing = try #require(
            InviteRSVP.message(
                response: .accepted, invite: invite, original: message, account: account,
                now: Date(timeIntervalSince1970: 1_788_156_123)
            )
        )
        let calendar = try #require(outgoing.calendarICS)
        #expect(calendar.contains("METHOD:REPLY"))
        #expect(calendar.contains("ATTENDEE;PARTSTAT=ACCEPTED:mailto:eu@okami.example"))
        #expect(calendar.contains("ORGANIZER:mailto:marina@cliente.example"))
        #expect(calendar.contains("UID:evento-42"))
        #expect(calendar.contains("SEQUENCE:7"))
        #expect(outgoing.to.map(\.address) == ["marina@cliente.example"])
        #expect(outgoing.from.address == account.address)
        #expect(outgoing.inReplyTo == "convite-42@cliente.example")
    }

    @Test("A mesma decisão não duplica a fila; mudar para recusar cria uma nova resposta")
    func deduplicacaoPorDecisao() async throws {
        let port = SendPort()
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [message], agenda: []),
            sendPort: port
        )
        await store.load()

        #expect(store.respondToInvite(invite, from: message, response: .tentative) == .queued(.tentative))
        #expect(store.respondToInvite(invite, from: message, response: .tentative) == .alreadyQueued(.tentative))
        #expect(port.sent.count == 1)
        #expect(store.inviteRSVPState(for: invite, from: message) == .tentative)

        #expect(store.respondToInvite(invite, from: message, response: .declined) == .queued(.declined))
        #expect(port.sent.count == 2)
        #expect(port.sent.last?.calendarICS?.contains("PARTSTAT=DECLINED") == true)
        #expect(store.inviteRSVPState(for: invite, from: message) == .declined)
    }

    @Test("Convite sem organizador, sem attendee ou cancelado explica por que não responde")
    func recusasHonestas() {
        let semOrganizador = CalendarInvite(
            summary: "x", start: nil, end: nil,
            attendees: [Contact(name: "Eu", address: account.address)], uid: "x"
        )
        #expect(
            InviteRSVP.unavailableReason(for: semOrganizador, account: account, canQueue: true)
                == .organizerMissing
        )

        let semAtendente = CalendarInvite(
            summary: "x", start: nil, end: nil,
            organizer: Contact(name: "Marina", address: "marina@cliente.example"), uid: "x"
        )
        #expect(
            InviteRSVP.unavailableReason(for: semAtendente, account: account, canQueue: true)
                == .attendeeMissing
        )

        let cancelado = CalendarInvite(
            summary: "x", start: nil, end: nil,
            organizer: Contact(name: "Marina", address: "marina@cliente.example"),
            attendees: [Contact(name: "Eu", address: account.address)], method: "CANCEL", uid: "x"
        )
        #expect(
            InviteRSVP.unavailableReason(for: cancelado, account: account, canQueue: true) == .cancelled
        )
    }

    @Test("Quem organizou o evento não responde como convidado")
    func organizadorNaoEConvidado() {
        let proprio = CalendarInvite(
            summary: "Meet", start: nil, end: nil,
            organizer: Contact(name: "Eu", address: account.address),
            attendees: [Contact(name: "Outra", address: "outra@cliente.example")],
            uid: "meet-1"
        )
        #expect(
            InviteRSVP.unavailableReason(for: proprio, account: account, canQueue: true)
                == .accountIsOrganizer
        )
    }
}
