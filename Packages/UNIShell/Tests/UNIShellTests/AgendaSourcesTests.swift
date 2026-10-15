import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// O agrupamento da coluna "Suas agendas": quem entrega cada calendário.
///
/// A classificação é por **identidade do id**, e é isso que se prova aqui —
/// um calendário chamado "Trabalho" pode vir do Mac, de um CalDAV ou do
/// próprio app, e o nome não diz qual.
@Suite("As fontes da aba Agendas")
@MainActor
struct AgendaSourcesTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func calendario(
        _ id: String, _ title: String, readOnly: Bool = false
    ) -> ConnectedCalendar {
        ConnectedCalendar(
            id: id, title: title, source: "x", colorHex: "#6d63ff",
            allowsModifications: !readOnly
        )
    }

    @Test("Cada calendário cai na fonte que o entrega")
    func agrupaPorIdentidade() {
        let fontes = AgendaSources.build(
            calendars: [
                calendario("EK-1", "Pessoal"),
                calendario("EK-2", "Feriados", readOnly: true),
                calendario(
                    ConnectedCalendar.calDAVID(accountID: "zoho", calendarURL: "https://z/1"),
                    "Trabalho"
                ),
                calendario(ConnectedCalendar.mailboxID(forAccountID: "okami"), "contato@okami.dev"),
                ConnectedCalendar.email,
            ],
            accounts: [],
            availability: .available,
            now: agora
        )

        #expect(fontes.map(\.kind) == [.eventKit, .calDAV(accountID: "zoho"), .local])
        #expect(fontes[0].calendars.map(\.title) == ["Pessoal", "Feriados"])
        #expect(fontes[0].state == L10n.tr("Autorizado"))
        #expect(fontes[1].calendars.map(\.title) == ["Trabalho"])
        #expect(fontes[2].calendars.count == 2)
        #expect(fontes[2].state == L10n.tr("Só neste Mac"))
    }

    /// Sem permissão, o Mac continua na lista — é o lugar do aviso. Sumir com
    /// ele deixaria a pessoa sem saber por que as agendas não estão ali.
    @Test("Sem permissão, o Mac continua na lista, sem agendas")
    func semPermissaoMantemOBloco() {
        let fontes = AgendaSources.build(
            calendars: [ConnectedCalendar.email],
            accounts: [], availability: .authorizationRequired, now: agora
        )
        #expect(fontes.first?.kind == .eventKit)
        #expect(fontes.first?.calendars.isEmpty == true)
        #expect(fontes.first?.tone == .orange)
        #expect(AgendaSources.needsCalendarPermission(.authorizationRequired))
        #expect(AgendaSources.needsCalendarPermission(.unavailable("negado")))
        #expect(!AgendaSources.needsCalendarPermission(.available))
        #expect(!AgendaSources.needsCalendarPermission(.loading))
        #expect(!AgendaSources.needsCalendarPermission(nil))
    }

    @Test("Autorizado e sem calendário nenhum, o bloco do Mac não aparece")
    func autorizadoSemCalendarioNaoDesenhaOBloco() {
        let fontes = AgendaSources.build(
            calendars: [ConnectedCalendar.email],
            accounts: [], availability: .available, now: agora
        )
        #expect(fontes.map(\.kind) == [.local])
    }

    @Test("A contagem conta agendas e fontes")
    func contagem() {
        let fontes = AgendaSources.build(
            calendars: [
                calendario("EK-1", "Pessoal"),
                calendario("EK-2", "Trabalho"),
                ConnectedCalendar.email,
            ],
            accounts: [], availability: .available, now: agora
        )
        #expect(AgendaSources.countNote(fontes) == "3 \(L10n.tr("agendas")), \(L10n.tr("em 2 fontes"))")
        #expect(AgendaSources.countNote([]) == L10n.tr("nenhuma agenda conectada ainda"))
    }
}
