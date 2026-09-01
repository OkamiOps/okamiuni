import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Painel de mover para pasta")
@MainActor
struct MoveFolderPanelTests {

    @Test("o painel cabe 20 linhas e o resto rola")
    func capsAtTwentyRows() {
        #expect(MoveFolderPanel.visibleRows == 20)
        #expect(MoveFolderPanel.listMaxHeight == 20 * MoveFolderPanel.rowHeight)
    }

    @Test("os submenus viram seções de uma lista só")
    func flattensSubmenus() {
        let entries: [ContextMenuEntry] = [
            .submenu(title: "Mover para marcador", items: [
                ContextMenuItem("Trabalho", .copy("t")),
            ]),
            .submenu(title: "Aplicar marcador", items: [
                ContextMenuItem("Pessoal", .copy("p")),
            ]),
        ]
        let groups = MoveFolderPanel.groups(from: entries)
        #expect(groups.map(\.title) == ["Mover para marcador", "Aplicar marcador"])
        #expect(groups[0].items.map(\.title) == ["Trabalho"])
        #expect(groups[1].items.map(\.title) == ["Pessoal"])
    }

    @Test("quarenta pastas não esticam o painel além de 20 linhas")
    @MainActor
    func manyFoldersStayCapped() {
        let items = (1...40).map {
            ContextMenuItem(String(format: "Pasta %02d", $0), .copy("\($0)"))
        }
        let many = MoveFolderPanel(
            groups: [MoveFolderGroup(title: "Mover para pasta", items: items)],
            onPick: { _ in }
        )
        let few = MoveFolderPanel(
            groups: [MoveFolderGroup(
                title: "Mover para pasta",
                items: Array(items.prefix(5))
            )],
            onPick: { _ in }
        )
        let manyHeight = Self.fittingHeight(many)
        let fewHeight = Self.fittingHeight(few)
        #expect(
            manyHeight <= MoveFolderPanel.listMaxHeight + 80,
            "o painel cresceu com as 40 pastas: \(manyHeight)pt"
        )
        #expect(fewHeight < manyHeight)
        #expect(manyHeight < CGFloat(40) * MoveFolderPanel.rowHeight)
    }

    @Test("o painel usa os tokens do tema, não o menu do sistema")
    @MainActor
    func drawsWithThemeTokens() async throws {
        let items = (1...8).map {
            ContextMenuItem("Pasta \($0)", .copy("\($0)"))
        }
        let rep = try #require(
            Render.snapshot(
                MoveFolderPanel(
                    groups: [MoveFolderGroup(title: "Mover para pasta", items: items)],
                    onPick: { _ in }
                ).environment(ThemeStore()),
                named: "mover-pasta-painel",
                size: CGSize(width: 300, height: 320),
                theme: .tinta
            )
        )
        #expect(rep.pixels(matching: Theme.tinta.surface, tolerance: 0.02) > 1_000)
        #expect(rep.pixels(matching: Theme.tinta.ink, tolerance: 0.08) > 80)
    }

    private static func fittingHeight<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(
            rootView: view.theme(.tinta).environment(ThemeStore())
                .frame(width: MoveFolderPanel.width)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
