import AppKit
import UNIDesign
import Foundation
import Testing
import UNICore
@testable import UNIShell

@Suite("Mover para Aplicativos")
struct AppLocationTests {

    @Test("aberto de dentro do .dmg, o app pede para ser movido")
    func volumeDoInstalador() {
        #expect(AppLocation.needsMove(bundlePath: "/Volumes/OkamiUNI/OkamiUNI.app"))
    }

    @Test("aberto translocado, de Downloads, também")
    func translocado() {
        #expect(AppLocation.needsMove(
            bundlePath: "/private/var/folders/x1/abc/T/AppTranslocation/1F2E/d/OkamiUNI.app"
        ))
    }

    @Test("em Aplicativos, ou em qualquer pasta gravável, não pede nada")
    func lugaresBons() {
        #expect(!AppLocation.needsMove(bundlePath: "/Applications/OkamiUNI.app"))
        #expect(!AppLocation.needsMove(bundlePath: "/Users/ana/Applications/OkamiUNI.app"))
        #expect(!AppLocation.needsMove(bundlePath: "/Users/ana/Downloads/OkamiUNI.app"))
    }
}

/// A folha do convite, fotografada fora da tela nos dois temas.
@Suite("Retrato do convite de mover", .serialized)
@MainActor
struct MoveToApplicationsRenderTests {

    @Test("a folha diz o porquê e oferece mover como ação principal", arguments: [
        ("tinta", Theme.tinta), ("noite", Theme.noite),
    ])
    func retrato(nome: String, tema: Theme) throws {
        // O ícone do app de verdade: no processo de teste, o ícone da
        // aplicação é o do executor da suíte.
        let raiz = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let icone = try #require(NSImage(contentsOf: raiz.appendingPathComponent(
            "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png"
        )))
        let folha = MoveToApplicationsSheet(icon: icone, onMove: {}, onDismiss: {})
        let rep = try #require(Render.snapshot(
            folha, named: "mover-para-aplicativos-\(nome)",
            size: CGSize(width: 420, height: 128), theme: tema, scale: 2
        ))
        #expect(rep.pixelsWide == 840)
    }
}
