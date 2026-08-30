import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Cartão RSVP no leitor")
@MainActor
struct ReaderRSVPTests {
    private final class SendPort: MailSendPort, @unchecked Sendable {
        private(set) var sent: [OutgoingMessage] = []
        func send(_ message: OutgoingMessage) throws { sent.append(message) }
    }

    private let account = Account(
        id: "a", address: "eu@okami.example", displayName: "Eu",
        provider: .imap, host: "okami", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )

    private func message(cancelled: Bool) -> Message {
        let status = cancelled ? "METHOD:CANCEL\r\nSTATUS:CANCELLED\r\n" : "METHOD:REQUEST\r\n"
        let ics = """
            BEGIN:VCALENDAR\r
            \(status)BEGIN:VEVENT\r
            UID:evento-42\r
            SUMMARY:Planejamento\r
            ORGANIZER:mailto:marina@cliente.example\r
            ATTENDEE:mailto:eu@okami.example\r
            END:VEVENT\r
            END:VCALENDAR\r
            """
        return Message(
            id: cancelled ? "cancelado" : "ativo", accountID: account.id,
            from: Contact(name: "Marina", address: "marina@cliente.example"),
            receivedAt: Fixtures.today, subject: "Planejamento", snippet: "convite",
            body: ["Convite de planejamento."], tags: [], bucket: .today,
            isRead: false, summary: nil, detectedEvent: nil, calendarICS: ics
        )
    }

    private func render(cancelled: Bool) async -> NSBitmapImageRep? {
        let item = message(cancelled: cancelled)
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [item], agenda: []),
            // Deixa os três controles do convite ativo renderizarem no estado
            // normal; não há clique nem envio neste ensaio offscreen.
            sendPort: SendPort()
        )
        await store.load()
        store.select(message: item.id)
        return Render.snapshot(
            ReaderPane(store: store),
            named: cancelled ? "m4-rsvp-cancelado" : "m4-rsvp-ativo",
            size: CGSize(width: 760, height: 700), theme: .tinta
        )
    }

    @Test("o cartão com RSVP e o convite cancelado renderizam estados visivelmente distintos")
    func renderizaEstados() async throws {
        let active = try #require(await render(cancelled: false))
        let cancelled = try #require(await render(cancelled: true))

        #expect(active.pixelsWide == 760)
        #expect(active.pixelsHigh == 700)
        #expect(
            active.pixelsDiffering(from: cancelled) > 0,
            "o cartão RSVP e o cancelado renderizaram iguais; o estado não chegou à superfície"
        )
    }

    @Test("clicar em Aceitar atravessa o botão e enfileira o iTIP")
    func aceitarPeloBotao() async throws {
        let item = message(cancelled: false)
        let port = SendPort()
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [item], agenda: []),
            sendPort: port
        )
        await store.load()
        store.select(message: item.id)

        // Centro do botão «Aceitar» no mesmo quadro de 760×700 usado pela
        // captura. O evento entra numa NSWindow a −50.000pt, sem tocar na sessão.
        CliqueDeEnsaio.em(
            ReaderPane(store: store), size: CGSize(width: 760, height: 700),
            aY: 326, x: 75
        )

        let calendar = try #require(item.calendarICS)
        let invite = try #require(ICalendar.parse(calendar))
        #expect(port.sent.count == 1)
        #expect(port.sent.first?.calendarICS?.contains("PARTSTAT=ACCEPTED") == true)
        #expect(store.inviteRSVPState(for: invite, from: item) == .accepted)
    }
}
