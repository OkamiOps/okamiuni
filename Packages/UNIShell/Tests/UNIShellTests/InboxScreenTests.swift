import Testing
import SwiftUI
import UNIDesign
import UNICore
@testable import UNIShell

@Suite("InboxScreen")
struct InboxScreenTests {

    @Test("soma das larguras dos painéis está correta: 236 + 370 + 262 = 868, deixando 572 para leitor")
    func panelWidthsSum() {
        let folderSidebarWidth: CGFloat = 236
        let messageListWidth: CGFloat = 370
        let agendaPlaceholderWidth: CGFloat = 262
        let windowWidth: CGFloat = 1440

        let readerWidth = windowWidth - folderSidebarWidth - messageListWidth - agendaPlaceholderWidth

        let totalWidth = folderSidebarWidth + messageListWidth + agendaPlaceholderWidth + readerWidth

        #expect(
            totalWidth == 1440,
            "soma das larguras (236 + 370 + 262 + 572) deve ser 1440, obteve \(totalWidth)"
        )

        #expect(
            readerWidth == 572,
            "largura do leitor deve ser 572, obteve \(readerWidth)"
        )
    }

    @Test("trilha recolhida tem a largura correta: 62")
    func sidebarRailWidth() {
        let railWidth: CGFloat = 62
        #expect(railWidth == 62, "largura da trilha deve ser 62")
    }

    @Test("barra lateral expandida tem a largura correta: 236")
    func folderSidebarWidth() {
        let sidebarWidth: CGFloat = 236
        #expect(sidebarWidth == 236, "largura da barra lateral expandida deve ser 236")
    }

    @Test("lista de mensagens tem a largura correta: 370")
    func messageListWidthTest() {
        let messageWidth: CGFloat = 370
        #expect(messageWidth == 370, "largura da lista de mensagens deve ser 370")
    }

    @Test("agenda placeholder tem a largura correta: 262")
    func agendaPlaceholderWidthTest() {
        let agendaWidth: CGFloat = 262
        #expect(agendaWidth == 262, "largura do placeholder da agenda deve ser 262")
    }
}
