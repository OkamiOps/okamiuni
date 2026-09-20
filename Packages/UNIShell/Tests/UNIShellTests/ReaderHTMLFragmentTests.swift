import AppKit
import Foundation
import Testing
import UNISync
import WebKit
@testable import UNIShell

@Suite("Fragmentos HTML chegam ao motor de desenho")
@MainActor
struct ReaderHTMLFragmentTests {
    @Test("O CSS inicial não é leitura e o boleto cabe no painel", arguments: [320.0, 500.0])
    func estiloInicial(largura: Double) async throws {
        // Mesma estrutura da falha reportada, sem dados da mensagem privada.
        let fonte = """
            <style>
            .alert-about-link { font-size: 11px; padding-top: 10px; line-height: 16px; }
            @media (max-width: 620px) { .footer { width: 100% !important; } }
            </style>
            <table width="600" bgcolor="#ffffff" cellpadding="20"><tr><td>
            <h1>Seu boleto está disponível</h1><p>Confira os dados antes de pagar.</p>
            <p class="alert-about-link">Mensagem de exemplo para validação do leitor.</p>
            </td></tr></table>
            """
        let corpo = MimeBody.decode(raw: fonte)
        let html = try #require(corpo.html)
        #expect(!corpo.text.contains("font-size"))
        let sonda = SondaDeWebView(largura: largura)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: html, fundo: "#ffffff", tinta: "#1a1a1a",
            link: "#1155cc", fonte: "-apple-system, sans-serif"
        ))
        let textoVisivel = try await sonda.web.evaluateJavaScript("document.body.innerText") as? String
        #expect(textoVisivel?.contains("Seu boleto está disponível") == true)
        #expect(textoVisivel?.contains("font-size") == false)

        let conteudo = try #require(await sonda.numero("document.body.scrollWidth"))
        let escala = ReaderHTMLPolicy.escala(painel: largura, conteudo: conteudo)
        sonda.web.pageZoom = escala
        let altura = try #require(await sonda.numero(ReaderHTMLPolicy.medidaDaAltura))
        let visivel = try #require(await sonda.numero("document.documentElement.clientWidth"))
        let fim = try #require(await sonda.numero("document.querySelector('table').getBoundingClientRect().right"))
        #expect(fim <= visivel + 1)
        #expect(altura > 20)
        #expect(escala > 0 && escala <= 1)
        sonda.web.frame.size.height = ReaderHTMLPolicy.altura(documento: altura, escala: escala)

        if let caminho = ProcessInfo.processInfo.environment["UNI_RENDER_DIR"] {
            let configuracao = WKSnapshotConfiguration()
            configuracao.rect = sonda.web.bounds
            let imagem = try await sonda.web.takeSnapshot(configuration: configuracao)
            let tiff = try #require(imagem.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let pasta = URL(fileURLWithPath: caminho, isDirectory: true)
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            try png.write(to: pasta.appendingPathComponent("leitor-fragmento-\(Int(largura)).png"))
        }
    }
}
