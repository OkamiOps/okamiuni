import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Prévia de assinatura e tema")
struct SignaturePreviewThemeTests {
    @Test("assinatura com paleta própria recebe papel branco no tema escuro")
    func authorPaletteUsesPaperInDarkTheme() throws {
        let dark = try #require(Theme.all.filter(\.isDark).first)
        let html = """
        <table role="presentation" style="background-color:#121415">
          <tr><td><span style="color:#CE2968">Marcos Santos</span></td></tr>
        </table>
        """

        let preview = try #require(SignatureRichDocument.previewDocument(
            html: html,
            resources: [],
            theme: dark
        ))

        #expect(ReaderHTMLPolicy.paleta(para: html) == .papel)
        #expect(preview.contains(":root{color-scheme:light}"))
        #expect(preview.contains("background:#ffffff;color:#1a1a1a"))
        #expect(preview.contains("color:#CE2968"))
    }
}
