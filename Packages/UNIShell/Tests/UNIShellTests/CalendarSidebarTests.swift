import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Lateral da Agenda")
@MainActor
struct CalendarSidebarTests {

    @Test("A marca da trilha encurta o título, não só a cor")
    func railMarkFromTitle() {
        let todoist = ConnectedCalendar(
            id: "t", title: "Todoist", source: "Todoist",
            colorHex: "#E44332", allowsModifications: false
        )
        let work = ConnectedCalendar(
            id: "w", title: "Work", source: "Google",
            colorHex: "#4285F4", allowsModifications: true
        )
        let mailbox = ConnectedCalendar(
            id: "m", title: "contato@hostinger.com", source: "OkamiUNI",
            colorHex: "#397852", allowsModifications: true
        )
        let onMyMac = ConnectedCalendar(
            id: "o", title: "On My Mac", source: "Other",
            colorHex: "#888888", allowsModifications: true
        )
        #expect(CalendarMark.rail(todoist) == "TOD")
        #expect(CalendarMark.rail(work) == "WOR")
        #expect(CalendarMark.rail(mailbox) == "HOS")
        #expect(CalendarMark.rail(onMyMac) == "OMM")
    }

    @Test("Dois calendários com o mesmo título distinguem pela origem")
    func railMarkDisambiguatesBySource() {
        let googleWork = ConnectedCalendar(
            id: "g", title: "Work", source: "Google",
            colorHex: "#4285F4", allowsModifications: true
        )
        let iCloudWork = ConnectedCalendar(
            id: "i", title: "Work", source: "iCloud",
            colorHex: "#FB3C45", allowsModifications: true
        )
        let siblings = [googleWork, iCloudWork]
        #expect(CalendarMark.rail(googleWork, among: siblings) == "GWO")
        #expect(CalendarMark.rail(iCloudWork, among: siblings) == "IWO")
        #expect(CalendarMark.rail(googleWork, among: siblings)
            != CalendarMark.rail(iCloudWork, among: siblings))
    }

    @Test("A cor do calendário lê o hex do EventKit")
    func tintFromHex() {
        let color = CalendarSidebar.tint("#673DE6")
        #expect(color != CalendarSidebar.tint("nope"))
    }

    @Test("A lateral da Agenda lista calendários, não caixas de email")
    func listsCalendarsNotMailboxes() async throws {
        let remote = AgendaItem(
            id: "ek-1", title: "Reunião", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar",
            calendarID: "todoist-1", calendarTitle: "Todoist",
            calendarColorHex: "#E44332", calendarSource: "Todoist"
        )
        let sync = SidebarCalendarSync(items: [remote], calendars: [
            ConnectedCalendar(
                id: "todoist-1", title: "Todoist", source: "Todoist",
                colorHex: "#E44332", allowsModifications: false
            )
        ])
        let store = MailStore(
            source: InMemoryMailSource.fixtures, calendarSync: sync
        )
        await store.load()
        #expect(store.calendarsForSidebar.contains { $0.source == "Todoist" })
        #expect(store.calendarsForSidebar.contains { $0.title == "Todoist" })

        let rep = try #require(Render.snapshot(
            CalendarSidebar(
                store: store,
                width: PaneLayout.expandedSidebarWidth,
                intelligencePresentation: .available,
                onOpenAssistant: {},
                onCreate: {}
            )
            .environment(ThemeStore()),
            named: "agenda-lateral-calendarios",
            size: CGSize(width: PaneLayout.expandedSidebarWidth, height: 700),
            theme: .tinta
        ))
        #expect(rep.pixelsWide == Int(PaneLayout.expandedSidebarWidth))
    }

    @Test("O mini calendário tem as seis semanas da grade do mês")
    func miniMonthHasSixWeeks() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let weeks = MonthAgenda.weeks(
            from: store.calendarAgenda, anchor: Fixtures.today, focusOffset: 0
        )
        #expect(weeks.count == MonthAgenda.weekCount)
        #expect(weeks.flatMap(\.days).count == 42)
    }

    @Test("a trilha recolhida cabe em 72pt e não pinta fora")
    func collapsedRailFitsTheStrip() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let size = CGSize(width: PaneLayout.railWidth, height: 700)
        let rep = try #require(Render.snapshot(
            CalendarSidebar(
                store: store,
                width: PaneLayout.railWidth,
                intelligencePresentation: .available,
                onOpenAssistant: {},
                onCreate: {}
            )
            .environment(ThemeStore()),
            named: "agenda-lateral-trilha",
            size: size,
            theme: .tinta
        ))
        #expect(rep.pixelsWide == Int(PaneLayout.railWidth))

        // O cartão laranja da IA, aberto, vazava para x>72. Na trilha o
        // acento da IA tem de caber dentro dos 72.
        let orange = (r: 1.0, g: 90.0 / 255, b: 31.0 / 255)
        func levels(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
            max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b))) * 255
        }
        var farthestOrange = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.5 else { continue }
                let pixel = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                if levels(pixel, orange) < 40 {
                    farthestOrange = max(farthestOrange, x)
                }
            }
        }
        #expect(farthestOrange < Int(PaneLayout.railWidth) - 4,
                "a IA da trilha chegou em x=\(farthestOrange), fora dos 72pt")
    }

    @Test("Recolher a origem esconde as linhas, sem apagar o calendário")
    func collapseHidesRows() async {
        let remote = AgendaItem(
            id: "ek-1", title: "Reunião", startMinute: 600, endMinute: 660,
            accountID: "okamiuni.system-calendar",
            calendarID: "todoist-1", calendarTitle: "Todoist",
            calendarColorHex: "#E44332", calendarSource: "Todoist"
        )
        let sync = SidebarCalendarSync(items: [remote], calendars: [
            ConnectedCalendar(
                id: "todoist-1", title: "Todoist", source: "Todoist",
                colorHex: "#E44332", allowsModifications: false
            )
        ])
        let store = MailStore(source: InMemoryMailSource.fixtures, calendarSync: sync)
        await store.load()
        #expect(store.calendarSourceExpanded("Todoist"))
        store.toggleCalendarSource("Todoist")
        #expect(!store.calendarSourceExpanded("Todoist"))
        #expect(store.calendarsForSidebar.contains { $0.id == "todoist-1" })
    }
}

@MainActor
private final class SidebarCalendarSync: CalendarSyncing {
    let items: [AgendaItem]
    let list: [ConnectedCalendar]

    init(items: [AgendaItem], calendars: [ConnectedCalendar]) {
        self.items = items
        self.list = calendars
    }

    func availability() async -> CalendarAvailability { .available }
    func calendars() async -> [ConnectedCalendar] { list }
    func synchronize(referenceDay _: Date, requestAuthorization _: Bool) async throws -> [AgendaItem] {
        items
    }
    func save(_: AgendaItem, referenceDay _: Date) async throws {}
    func remove(id _: String, referenceDay _: Date) async throws {}
}
