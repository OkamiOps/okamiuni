import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Novo compromisso na Agenda")
@MainActor
struct NewAppointmentSheetTests {
    private let conta = Account(
        id: "conta", address: "marcos@okamiops.com", displayName: "Marcos",
        provider: .imap, host: "okamiops",
        tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )

    private func store() async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [conta], messages: [], agenda: [])
        )
        await store.load()
        return store
    }

    @Test("o botão da lateral abre o fluxo de criação")
    func buttonCallsCreate() async {
        let store = await store()
        var creates = 0

        // Janela de ensaio fora da tela: o clique não toca no mouse nem no
        // foco de quem está usando o desktop. O "Novo compromisso" mora na
        // lateral da Agenda — o cabeçalho não tem mais essa ação.
        CliqueDeEnsaio.em(
            CalendarSidebar(
                store: store,
                width: PaneLayout.expandedSidebarWidth,
                intelligencePresentation: .onThisMac,
                onOpenAssistant: {},
                onCreate: { creates += 1 }
            ),
            size: CGSize(width: PaneLayout.expandedSidebarWidth, height: 80),
            aY: 36,
            x: PaneLayout.expandedSidebarWidth / 2
        )

        #expect(creates == 1, "Novo compromisso desenhou, mas não abriu o editor")
    }

    @Test("o editor desenha os campos em uma janela offscreen")
    func sheetRendersItsFields() async throws {
        let store = await store()
        let size = NewAppointmentSheet.size
        let editor = try #require(Render.snapshot(
            NewAppointmentSheet(
                store: store, anchor: Fixtures.today, initialDayOffset: 1,
                initialTitle: "Revisão semanal",
                initialMeetingLink: "https://empresa.webex.com/meet/revisao",
                onClose: {}
            ),
            named: "new-appointment-sheet",
            size: size, theme: .tinta
        ))
        let blank = try #require(Render.bitmap(
            Rectangle().fill(Theme.tinta.paper.color), size: size, theme: .tinta
        ))

        #expect(
            editor.pixelsDiffering(from: blank) > 2_000,
            "o editor não desenhou os campos do compromisso"
        )
    }

    @Test("Adicionar leva o link da reunião até o compromisso")
    func addCarriesMeetingLink() async throws {
        let store = await store()
        var closes = 0
        let size = NewAppointmentSheet.size

        CliqueDeEnsaio.em(
            NewAppointmentSheet(
                store: store, anchor: Fixtures.today, initialDayOffset: 0,
                initialTitle: "Revisão semanal",
                initialMeetingLink: "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
                onClose: { closes += 1 }
            ),
            size: size, aY: size.height - 28, x: size.width - 50
        )

        #expect(closes == 1)
        let created = try #require(store.agenda.first { $0.title == "Revisão semanal" })
        #expect(created.detail?.link == "https://teams.microsoft.com/l/meetup-join/19%3ameeting")
    }
}
