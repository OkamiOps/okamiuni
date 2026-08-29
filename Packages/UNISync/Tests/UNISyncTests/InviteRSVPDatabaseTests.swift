import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("RSVP persistido na fila")
struct InviteRSVPDatabaseTests {
    private let account = Account(
        id: "conta-a", address: "eu@okami.example", displayName: "Eu",
        provider: .imap, host: "okami", tintLightHex: "#000000", tintDarkHex: "#ffffff"
    )

    private func database() throws -> SyncDatabase {
        let database = try SyncDatabase.temporary()
        try database.pool.write {
            try AccountRecord(account, createdAt: Date(timeIntervalSince1970: 1)).insert($0)
        }
        return database
    }

    private func reply(messageID: String = "rsvp-1@okami.example") -> OutgoingMessage {
        OutgoingMessage(
            messageID: messageID, accountID: account.id,
            from: OutgoingAddress(name: "Eu", address: account.address),
            to: [OutgoingAddress(name: "Marina", address: "marina@cliente.example")],
            subject: "Resposta: Planejamento", plainText: "Aceito",
            calendarICS: "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR\r\n"
        )
    }

    @Test("A resposta e o send entram juntos; mesma chave atualiza estado sem duplicar o estado")
    func transacaoEEstado() throws {
        let database = try database()
        let port = DatabaseCommandPort(database: database)
        let accepted = InviteRSVPState(
            accountID: account.id, eventKey: "uid:evento-42", response: .accepted
        )
        try port.queueInviteRSVP(reply(), state: accepted)

        #expect(try port.savedInviteRSVPStates() == [accepted])
        #expect(try database.pool.read { try OutboxRecord.fetchCount($0) } == 1)

        let declined = InviteRSVPState(
            accountID: account.id, eventKey: "uid:evento-42", response: .declined
        )
        try port.queueInviteRSVP(reply(messageID: "rsvp-2@okami.example"), state: declined)

        #expect(try port.savedInviteRSVPStates() == [declined])
        // Mudar de ideia é uma nova intenção e precisa sair; só o estado tem
        // chave única, para o cartão restaurar a última decisão.
        #expect(try database.pool.read { try OutboxRecord.fetchCount($0) } == 2)
    }

    @Test("O MIME da fila declara text/calendar com o METHOD do iTIP")
    func mimeDaResposta() {
        let raw = OutgoingMime.compose(
            reply(), date: Date(timeIntervalSince1970: 1), includeBcc: false, boundary: "rsvp"
        )
        #expect(raw.contains("Content-Type: text/calendar; method=REPLY; charset=utf-8"))
        #expect(raw.contains("METHOD:REPLY"))
    }
}
