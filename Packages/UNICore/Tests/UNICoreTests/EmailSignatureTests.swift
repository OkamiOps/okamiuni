import Foundation
import Testing
@testable import UNICore

@Suite("Assinatura rica de e-mail")
struct EmailSignatureTests {
    @Test("HTML preserva imagens HTTPS e CID, mas remove fontes inseguras")
    func sanitizaRecursosRemotos() throws {
        let logo = try InlineSignatureResource(
            contentID: "logo@inline.local", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let signature = try EmailSignature(
            plainText: "Marcos\nOkami", html: """
            <p><strong>Marcos</strong></p>
            <img src="https://assets.vantion.com/logo.png?brand=vantion&amp;size=190" alt="Logo Vantion" title="Vantion" width="190" height="80" style="display:block; width:190px; max-width:100%; margin:0 auto; padding:2px; border:0; border-radius:12px; vertical-align:middle; object-fit:contain; background:url(https://tracker.example/pixel.png); color:red; min-width:expression(alert(1));">
            <img src="https://assets.vantion.com/oversized.png" width="9000" height="101%">
            <img src="http://tracker.example/pixel.png">
            <img src="file:///Users/marcos/logo.png">
            <img src="data:image/png;base64,AAAA">
            <img src="javascript:alert('x')">
            <img src="cid:logo@inline.local" alt="Logo Okami" width="160" height="48">
            <svg><script>alert('x')</script></svg>
            <a href="javascript:alert('x')">não</a>
            """, inlineResources: [logo]
        )

        let html = try #require(signature.html)
        #expect(html.contains("https://assets.vantion.com/logo.png?brand=vantion&amp;size=190"))
        #expect(html.contains("title=\"Vantion\""))
        #expect(html.contains("style=\"display: block; width: 190px; max-width: 100%; margin: 0 auto; padding: 2px; border: 0; border-radius: 12px; vertical-align: middle; object-fit: contain\""))
        #expect(html.contains("cid:logo@inline.local"))
        #expect(html.contains("alt=\"Logo Okami\""))
        #expect(html.contains("width=\"160\""))
        #expect(html.contains("height=\"48\""))
        #expect(!html.contains("width=\"9000\""))
        #expect(!html.contains("height=\"101%\""))
        #expect(!html.contains("http://tracker.example"))
        #expect(!html.contains("file:"))
        #expect(!html.contains("data:image"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<svg"))
        #expect(!html.contains("javascript:"))
        #expect(!html.contains("background:"))
        #expect(!html.contains("color:red"))
        #expect(!html.contains("expression"))
        #expect(signature.plainText == "Marcos\nOkami")
        #expect(signature.inlineResources == [logo])
    }

    @Test("assinatura sem fallback explícito extrai texto seguro do HTML")
    func criaFallbackPlainText() throws {
        let signature = try EmailSignature(
            plainText: "", html: "<p>Marcos<br><strong>Okami</strong></p>"
        )
        #expect(signature.plainText == "Marcos\nOkami")
    }

    @Test("fallback tabular compacta indentação sem colar células")
    func compactaFallbackTabular() throws {
        let signature = try EmailSignature(
            plainText: "", html: """
            <!doctype html>
            <html>
              <body>
                <table role="presentation" style="width:600px">
                  <tbody>
                    <tr>
                      <td style="padding:0 24px">
                        <strong>Vantion</strong><br>
                        <span>Marcos Silva</span><br>
                        <a href="mailto:marcos@example.com">marcos@example.com</a>
                      </td>
                      <td>
                        <strong>Telefone:</strong>
                        <span>+55 (11) 99999-0000</span><br>
                        <strong>Site:</strong>
                        <span>www.vantion.com</span>
                      </td>
                    </tr>
                    <tr>
                      <td colspan="2">
                        <p>Atenciosamente,</p>
                        <p>Equipe Vantion</p>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </body>
            </html>
            """
        )

        // A alternativa texto não deve carregar a indentação do documento nem
        // perder a fronteira entre as duas células da primeira linha.
        // Também limitamos a uma linha vazia entre blocos estruturais.
        let expected = [
            "Vantion",
            "Marcos Silva",
            "marcos@example.com",
            "Telefone: +55 (11) 99999-0000",
            "Site: www.vantion.com",
            "",
            "Atenciosamente,",
            "Equipe Vantion",
        ].joined(separator: "\n")
        #expect(signature.plainText == expected)
        #expect(!signature.plainText.contains("VantionTelefone"))
        #expect(!signature.plainText.contains("\n\n\n"))
        #expect(!signature.plainText.contains("  "))
    }

    @Test("recusa tipo ativo, Content-ID inseguro e IDs repetidos")
    func validaRecursos() throws {
        #expect(throws: EmailSignatureError.self) {
            try InlineSignatureResource(mimeType: "image/svg+xml", data: Data([1]))
        }
        #expect(throws: EmailSignatureError.self) {
            try InlineSignatureResource(contentID: "logo\r\nBcc: x", mimeType: "image/png", data: Data([1]))
        }

        let first = try InlineSignatureResource(
            contentID: "same@inline.local", mimeType: "image/png", data: Data([1])
        )
        let second = try InlineSignatureResource(
            contentID: "same@inline.local", mimeType: "image/png", data: Data([2])
        )
        #expect(throws: EmailSignatureError.duplicateContentID) {
            try EmailSignature(plainText: "Marcos", inlineResources: [first, second])
        }
    }

    @Test("conta antiga continua expondo assinatura simples como estruturada")
    func ponteDaContaLegada() {
        let account = Account(
            id: "conta", address: "marcos@example.com", displayName: "Marcos",
            provider: .imap, host: "example", tintLightHex: "#111111", tintDarkHex: "#eeeeee",
            signature: "Marcos\nOkami"
        )
        #expect(account.signature == "Marcos\nOkami")
        #expect(account.emailSignature == EmailSignature(legacyText: "Marcos\nOkami"))
    }

    @Test("fila anterior à assinatura rica continua decodificando")
    func outgoingMessageLegadoDecode() throws {
        let legacy = """
        {
          "messageID":"m@x.com","accountID":"conta",
          "from":{"name":"Eu","address":"eu@x.com"},
          "to":[{"name":"Você","address":"voce@x.com"}],
          "subject":"Oi","plainText":"Olá"
        }
        """
        let message = try JSONDecoder().decode(OutgoingMessage.self, from: Data(legacy.utf8))
        #expect(message.inlineResources.isEmpty)
        #expect(message.attachments.isEmpty)
        #expect(message.html == nil)
    }
}
