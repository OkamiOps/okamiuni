import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Editor rico de assinaturas")
@MainActor
struct SignatureRichEditorTests {
    @Test("codec visual conserva negrito, cor e link em CSS inline")
    func codecPreservaFormatacao() throws {
        var body = AttributedString("Okami")
        var selection = AttributedTextSelection(range: body.startIndex..<body.endIndex)
        ComposerEditor.perform(.bold, on: &body, selection: &selection, theme: .tinta)
        ComposerEditor.perform(.color("#CE2968"), on: &body, selection: &selection, theme: .tinta)
        ComposerEditor.perform(
            .link(url: URL(string: "https://okamiops.com")!, label: ""),
            on: &body,
            selection: &selection,
            theme: .tinta
        )

        let html = try #require(SignatureRichDocument.html(
            from: body, resources: [], theme: .tinta
        ))
        let signature = try EmailSignature(plainText: "Okami", html: html)
        let storedHTML = try #require(signature.html)

        #expect(storedHTML.contains("font-weight:700"))
        #expect(storedHTML.contains("color:#CE2968"))
        #expect(storedHTML.contains("https://okamiops.com"))
        #expect(storedHTML.contains("<style") == false)
    }

    @Test("imagem local vira CID na assinatura e data URL somente na prévia")
    func imagemLocalNuncaViraURLRemota() throws {
        let image = try InlineSignatureResource(
            contentID: "logo@inline.local",
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let html = SignatureRichDocument.ensuringImages("<div>Marcos</div>", resources: [image])
        let signature = try EmailSignature(
            plainText: "Marcos", html: html, inlineResources: [image]
        )
        let preview = try #require(SignatureRichDocument.previewDocument(
            html: signature.html, resources: signature.inlineResources, theme: .tinta
        ))

        #expect(signature.html?.contains("cid:logo@inline.local") == true)
        #expect(preview.contains("data:image/png;base64"))
        #expect(preview.contains("cid:logo@inline.local") == false)
        #expect(preview.contains("default-src 'none'"))
        #expect(preview.contains("https://") == false)
    }

    @Test("prévia HTML reserva HTTPS apenas para imagens externas")
    func previaReservaHTTPSParaImagensExternas() throws {
        let html = """
        <table role="presentation" style="width:600px;border-collapse:collapse">
          <tr><td style="background-color:#121415"><img src="https://cdn.example/logo.png" alt="Vantion"></td>
          <td style="padding:20px"><strong>Marcos Santos</strong></td></tr>
        </table>
        <script>window.location = 'https://tracker.example'</script>
        """

        let preview = try #require(SignatureRichDocument.previewDocument(
            html: html, resources: [], theme: .tinta
        ))

        #expect(preview.contains("img-src data: https:"))
        #expect(preview.contains("default-src 'none'"))
        #expect(preview.contains("connect-src 'none'"))
        #expect(preview.contains("https://cdn.example/logo.png"))
        #expect(preview.contains("window.location") == false)
    }

    @Test("prévia permite ao host escolher a margem sem alterar o HTML salvo")
    func previaAceitaPaddingDoHost() throws {
        let preview = try #require(SignatureRichDocument.previewDocument(
            html: "<div>Marcos Santos</div>",
            resources: [],
            theme: .tinta,
            bodyPadding: 0
        ))

        #expect(preview.contains("body{padding:0.0px}"))
        #expect(preview.contains("Marcos Santos"))
    }

    @Test("HTML colado com documento completo e data image renderiza o mesmo fragmento salvo")
    func previaNormalizaColagemCompletaComDataImage() throws {
        let logo = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let pasted = """
        <!doctype html><html><head><title>Gerador</title></head><body>
        <table role="presentation" style="width:600px"><tr>
          <td style="background:#121415">
            <img src="data:image/png;base64,\(logo.base64EncodedString())"
                 alt="Vantion" width="190" style="display:block;width:190px;height:auto">
          </td><td>Marcos Santos</td>
        </tr></table>
        </body></html>
        """
        let imported = SignatureHTMLImporter.normalize(source: pasted)
        let preview = try #require(SignatureRichDocument.previewDocument(
            html: imported.html,
            resources: imported.inlineResources,
            theme: .tinta
        ))

        #expect(imported.html.contains("<!doctype") == false)
        #expect(imported.html.contains("<title>") == false)
        #expect(imported.html.contains("src=\"cid:"))
        #expect(preview.contains("data:image/png;base64"))
        #expect(preview.contains("Vantion"))
        #expect(preview.contains("width: 190px"))
    }

    @Test("WebKit desenha assinatura importada com tabela, cor, link e logo")
    func webKitDesenhaAssinaturaImportada() async throws {
        // GIF 1x1 válido. O objetivo aqui não é testar um decoder de imagem,
        // mas provar que a logo que veio em data: sobrevive à importação, vira
        // CID e volta a pixels dentro da mesma prévia usada pela tela.
        let logo = "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        let imported = SignatureHTMLImporter.normalize(source: """
        <!doctype html><html><body>
        <table role="presentation" style="width:600px;border-collapse:separate">
          <tr>
            <td style="width:190px;padding:20px;background:#121415">
              <img src="data:image/gif;base64,\(logo)" alt="Vantion"
                   width="190" style="display:block;width:190px;height:auto">
            </td>
            <td style="padding:20px">
              <strong style="font-size:22px">Marcos Santos</strong>
              <a href="https://vantion.com.br">vantion.com.br</a>
            </td>
          </tr>
        </table>
        </body></html>
        """)
        let document = try #require(SignatureRichDocument.previewDocument(
            html: imported.html,
            resources: imported.inlineResources,
            theme: .tinta
        ))
        let probe = SondaDeWebView(largura: 760)
        await probe.carrega(document)

        #expect(await probe.numero("document.querySelector('table').getBoundingClientRect().width") == 600)
        #expect(await probe.numero("getComputedStyle(document.querySelector('td')).backgroundColor === 'rgb(18, 20, 21)' ? 1 : 0") == 1)
        #expect(await probe.numero("document.querySelector('img').complete ? 1 : 0") == 1)
        #expect(await probe.numero("document.querySelector('img').naturalWidth") == 1)
        #expect(await probe.numero("document.querySelector('a').href === 'https://vantion.com.br/' ? 1 : 0") == 1)
    }

    @Test("tabela do editor sai como tabela HTML, sem folha de estilo externa")
    func tabelaSobreviveAoCodec() throws {
        var body = AttributedString("")
        var selection = AttributedTextSelection(insertionPoint: body.startIndex)
        ComposerEditor.perform(.table(rows: 1, columns: 2), on: &body, selection: &selection, theme: .tinta)

        let html = try #require(SignatureRichDocument.html(
            from: body, resources: [], theme: .tinta
        ))
        let signature = try EmailSignature(plainText: String(body.characters), html: html)

        #expect(signature.html?.contains("<table") == true)
        #expect(signature.html?.contains("<td") == true)
        #expect(signature.html?.contains("<style") == false)
    }

    @Test("arquivo aceito é determinado pela extensão permitida")
    func tiposDeImagemAceitos() {
        #expect(SignatureRichDocument.mimeType(for: URL(fileURLWithPath: "/tmp/logo.PNG")) == "image/png")
        #expect(SignatureRichDocument.mimeType(for: URL(fileURLWithPath: "/tmp/logo.jpeg")) == "image/jpeg")
        #expect(SignatureRichDocument.mimeType(for: URL(fileURLWithPath: "/tmp/logo.gif")) == "image/gif")
        #expect(SignatureRichDocument.mimeType(for: URL(fileURLWithPath: "/tmp/logo.webp")) == "image/webp")
        #expect(SignatureRichDocument.mimeType(for: URL(fileURLWithPath: "/tmp/logo.svg")) == nil)
    }
}
