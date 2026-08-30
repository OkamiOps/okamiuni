import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@MainActor
private final class CalendarStatusSyncDouble: CalendarSyncing {
    func availability() async -> CalendarAvailability { .authorizationRequired }
    func synchronize(referenceDay _: Date, requestAuthorization _: Bool) async throws -> [AgendaItem] { [] }
    func save(_: AgendaItem, referenceDay _: Date) async throws {}
    func remove(id _: String, referenceDay _: Date) async throws {}
}

@Suite("Estado visível da agenda conectada")
@MainActor
struct CalendarStatusBandTests {
    @Test("Autorização pendente explica a causa e oferece a ação correta")
    func actionableCopy() {
        #expect(CalendarStatusCopy.text(for: .authorizationRequired)?.contains("Permita o acesso") == true)
        #expect(CalendarStatusCopy.action(for: .authorizationRequired) == "Permitir acesso")
        #expect(CalendarStatusCopy.action(for: .unavailable("Negado")) == nil)
    }

    @Test("A faixa de autorização renderiza fora da tela na aba Agenda")
    func rendersOffscreen() async throws {
        let store = MailStore(
            source: InMemoryMailSource.fixtures, calendarSync: CalendarStatusSyncDouble()
        )
        await store.load()
        let image = try #require(Render.snapshot(
            CalendarScreen(store: store, now: Fixtures.nowMinute, anchor: Fixtures.today)
                .environment(ThemeStore()),
            named: "agenda-autorizacao-pendente",
            size: CGSize(width: 1_200, height: 820), theme: .tinta
        ))
        #expect(image.pixelsWide == 1_200)
        #expect(image.pixelsHigh == 820)
    }
}
