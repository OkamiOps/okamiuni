import Foundation
import Testing
@testable import UNICore

@Suite("Importação de HTML de assinatura")
struct SignatureHTMLImporterTests {
    @Test("documento Vantion mantém a tabela, o estilo e troca data URI por CID")
    func importsVantionStyleTable() throws {
        let logo = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let source = """
        <!doctype html>
        <html><head><title>Assinatura</title></head><body>
        <table role="presentation" cellpadding="0" cellspacing="0" style="width:600px;border-collapse:separate">
          <tr><td style="background:#121415;padding:20px">
            <img src="data:image/png;base64,\(logo.base64EncodedString())" alt="Vantion" style="display:block;width:190px;height:auto" width="190">
          </td><td style="padding-left:22px"><strong>Marcos Santos</strong></td></tr>
        </table>
        </body></html>
        """

        let result = SignatureHTMLImporter.normalize(source: source)

        #expect(!result.html.contains("<!doctype"))
        #expect(!result.html.contains("<head"))
        #expect(result.html.contains("<table role=\"presentation\""))
        #expect(result.html.contains("style=\"background:#121415;padding:20px\""))
        #expect(result.html.contains("src=\"cid:"))
        #expect(result.html.contains("alt=\"Vantion\""))
        #expect(result.html.contains("style=\"display:block;width:190px;height:auto\""))
        #expect(result.inlineResources.count == 1)
        #expect(result.inlineResources[0].mimeType == "image/png")
        #expect(result.inlineResources[0].data == logo)
        #expect(result.externalImageURLs.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("reutiliza recurso CID e conteúdo já incorporado")
    func reusesExistingResource() throws {
        let data = Data([1, 2, 3, 4])
        let resource = try InlineSignatureResource(
            contentID: "vantion-logo@inline.local", mimeType: "image/png", data: data
        )

        let result = SignatureHTMLImporter.normalize(
            source: "<td><img src='data:image/png;base64,\(data.base64EncodedString())' style='width:190px'></td>",
            existingResources: [resource]
        )

        #expect(result.inlineResources == [resource])
        #expect(result.html.contains("src=\"cid:vantion-logo@inline.local\""))
        #expect(result.html.contains("style='width:190px'"))
    }

    @Test("mantém e reporta imagens HTTPS externas sem baixar nada")
    func preservesHTTPSImages() {
        let source = "<table><tr><td><img src=\"https://cdn.vantion.com/brand/logo.png?version=2\" style=\"width:190px\"></td></tr></table>"
        let result = SignatureHTMLImporter.normalize(source: source)

        #expect(result.html == source)
        #expect(result.externalImageURLs == ["https://cdn.vantion.com/brand/logo.png?version=2"])
        #expect(result.inlineResources.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("remove fontes locais, ativas e data URI não suportada")
    func removesUnsupportedImageSources() {
        let source = """
        <p>Marcos</p>
        <img src="file:///Users/marcos/logo.png">
        <img src="javascript:alert(1)">
        <img src="data:image/svg+xml;base64,PHN2Zz4=">
        """

        let result = SignatureHTMLImporter.normalize(source: source)

        #expect(result.html.contains("<p>Marcos</p>"))
        #expect(!result.html.contains("<img"))
        #expect(result.warnings.count == 3)
    }

    @Test("aplica os limites de quantidade, imagem individual e total")
    func appliesInlineImageLimits() throws {
        let existing = try (0..<8).map { index in
            try InlineSignatureResource(
                contentID: "logo-\(index)@inline.local", mimeType: "image/png", data: Data([UInt8(index)])
            )
        }
        let smallURI = dataURI(bytes: Data([0x09]))
        let atCountLimit = SignatureHTMLImporter.normalize(
            source: "<img src=\"\(smallURI)\">", existingResources: existing
        )
        #expect(atCountLimit.inlineResources.count == 8)
        #expect(!atCountLimit.html.contains("<img"))
        #expect(atCountLimit.warnings.contains { $0.contains("8 imagens") })

        let overTwoMegabytes = Data(repeating: 0x01, count: InlineSignatureResource.maximumByteCount + 1)
        let overSingleLimit = SignatureHTMLImporter.normalize(
            source: "<img src=\"\(dataURI(bytes: overTwoMegabytes))\">"
        )
        #expect(overSingleLimit.inlineResources.isEmpty)
        #expect(overSingleLimit.warnings.contains { $0.contains("2 MB") })

        let twoMegabytes = Data(repeating: 0x02, count: InlineSignatureResource.maximumByteCount)
        let resourceA = try InlineSignatureResource(contentID: "a@inline.local", mimeType: "image/png", data: twoMegabytes)
        let resourceB = try InlineSignatureResource(contentID: "b@inline.local", mimeType: "image/png", data: twoMegabytes)
        let pushesTotalOverLimit = SignatureHTMLImporter.normalize(
            source: "<img src=\"\(dataURI(bytes: Data(repeating: 0x03, count: 1_200_000)))\">",
            existingResources: [resourceA, resourceB]
        )
        #expect(pushesTotalOverLimit.inlineResources == [resourceA, resourceB])
        #expect(pushesTotalOverLimit.warnings.contains { $0.contains("5 MB") })
    }

    private func dataURI(bytes: Data) -> String {
        "data:image/png;base64,\(bytes.base64EncodedString())"
    }
}
