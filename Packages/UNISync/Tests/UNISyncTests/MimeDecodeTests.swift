import Foundation
import Testing
@testable import UNISync

/// A descida na árvore MIME agora traz três coisas, não uma. Estes testes são
/// sobre as duas novas — o HTML e o convite — e sobre a primeira continuar
/// exatamente como estava.
@Suite("MimeBody.decode: o texto, o HTML e o convite saem da mesma descida")
struct MimeDecodeTests {

    private static let alternative = """
        --limite
        Content-Type: text/plain; charset="utf-8"

        A versao em texto.
        --limite
        Content-Type: text/html; charset="utf-8"

        <html><body><p>A vers&atilde;o em <b>HTML</b>.</p></body></html>
        --limite--
        """

    @Test("O plain continua sendo o texto, e o HTML sai ao lado dele")
    func plainEHtmlSaemJuntos() throws {
        let saida = MimeBody.decode(
            raw: Self.alternative, contentType: "multipart/alternative; boundary=\"limite\""
        )
        #expect(saida.text == "A versao em texto.")
        let html = try #require(saida.html)
        #expect(html.contains("<b>HTML</b>"))
        #expect(saida.calendar == nil)
    }

    @Test("A mensagem só de HTML continua virando texto — e agora também guarda o HTML")
    func soHtml() throws {
        let saida = MimeBody.decode(
            raw: "<p>Recibo</p><p>Total: R$ 10</p>", contentType: "text/html; charset=utf-8"
        )
        #expect(saida.text.contains("Recibo"))
        let html = try #require(saida.html)
        #expect(html.contains("<p>Recibo</p>"))
    }

    @Test("A mensagem só de texto não ganha HTML nenhum — só-texto fica só-texto")
    func soTextoFicaSoTexto() {
        let saida = MimeBody.decode(raw: "Bom dia.", contentType: "text/plain")
        #expect(saida.text == "Bom dia.")
        #expect(saida.html == nil)
    }

    @Test("O HTML que sai já está limpo: o script da mensagem não chega ao leitor")
    func htmlSaiSanitizado() throws {
        let saida = MimeBody.decode(
            raw: "<p>Oi</p><script>alert(1)</script>", contentType: "text/html"
        )
        let html = try #require(saida.html)
        #expect(!html.contains("alert"))
    }

    @Test("A imagem embutida vira data: dentro do HTML, sem nenhuma ida à rede")
    func imagemInlineViraData() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let cru = """
            --rel
            Content-Type: text/html; charset="utf-8"

            <p>Veja</p><img src="cid:logo@okami">
            --rel
            Content-Type: image/png
            Content-ID: <logo@okami>
            Content-Transfer-Encoding: base64
            Content-Disposition: inline

            \(bytes.base64EncodedString())
            --rel--
            """
        let saida = MimeBody.decode(
            raw: cru, contentType: "multipart/related; boundary=\"rel\""
        )
        let html = try #require(saida.html)
        #expect(html.contains("data:image/png;base64,\(bytes.base64EncodedString())"))
    }

    @Test("A imagem marcada como anexo, mas apontada por cid:, entra assim mesmo")
    func imagemAnexaComCidEntra() throws {
        let bytes = Data([0xAA, 0xBB])
        let cru = """
            --rel
            Content-Type: text/html

            <img src="cid:x@y">
            --rel
            Content-Type: image/gif
            Content-ID: <x@y>
            Content-Transfer-Encoding: base64
            Content-Disposition: attachment; filename="logo.gif"

            \(bytes.base64EncodedString())
            --rel--
            """
        let saida = MimeBody.decode(raw: cru, contentType: "multipart/related; boundary=rel")
        let html = try #require(saida.html)
        #expect(html.contains(bytes.base64EncodedString()))
    }

    @Test("O CSV anexado continua fora do texto — anexo é arquivo, não mensagem")
    func anexoDeTextoContinuaFora() {
        let cru = """
            --mix
            Content-Type: text/plain

            O corpo.
            --mix
            Content-Type: text/plain; name="dados.csv"
            Content-Disposition: attachment; filename="dados.csv"

            a,b,c
            --mix--
            """
        let saida = MimeBody.decode(raw: cru, contentType: "multipart/mixed; boundary=mix")
        #expect(saida.text == "O corpo.")
    }

    @Test("O convite sai inteiro, ao lado do HTML — era ele que virava 'esta mensagem não tem texto'")
    func conviteSaiAoLado() throws {
        let cru = """
            --conv
            Content-Type: text/html

            <p>Convite</p>
            --conv
            Content-Type: text/calendar; method=REQUEST; charset="utf-8"

            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Revisão de contrato
            END:VEVENT
            END:VCALENDAR
            --conv--
            """
        let saida = MimeBody.decode(raw: cru, contentType: "multipart/alternative; boundary=conv")
        let agenda = try #require(saida.calendar)
        #expect(agenda.contains("SUMMARY:Revisão de contrato"))
        #expect(saida.html != nil)
    }

    @Test("application/ics conta como convite: o nome muda, o conteúdo não")
    func applicationIcsTambemEhConvite() throws {
        let cru = """
            --c
            Content-Type: application/ics

            BEGIN:VCALENDAR
            END:VCALENDAR
            --c--
            """
        let saida = MimeBody.decode(raw: cru, contentType: "multipart/mixed; boundary=c")
        let agenda = try #require(saida.calendar)
        #expect(agenda.contains("VCALENDAR"))
    }

    @Test("invite.ics marcado como anexo ainda vira convite")
    func icsAnexadoAindaEhConvite() throws {
        let cru = """
            --mix
            Content-Type: text/plain

            Esta mensagem não tem texto.
            --mix
            Content-Type: application/octet-stream; name="invite.ics"
            Content-Disposition: attachment; filename="invite.ics"

            BEGIN:VCALENDAR
            METHOD:CANCEL
            BEGIN:VEVENT
            SUMMARY:teste okamiUNI
            STATUS:CANCELLED
            END:VEVENT
            END:VCALENDAR
            --mix--
            """
        let saida = MimeBody.decode(raw: cru, contentType: "multipart/mixed; boundary=mix")
        let agenda = try #require(saida.calendar)
        #expect(agenda.contains("METHOD:CANCEL"))
        #expect(agenda.contains("teste okamiUNI"))
    }

    @Test("O PDF de quatro megabytes nem é decodificado — ele não é folha nenhuma")
    func anexoBinarioNaoVira() {
        let cru = """
            --mix
            Content-Type: text/plain

            Segue em anexo.
            --mix
            Content-Type: application/pdf
            Content-Transfer-Encoding: base64

            \(Data(repeating: 7, count: 4096).base64EncodedString())
            --mix--
            """
        let saida = MimeBody.decode(raw: cru, contentType: "multipart/mixed; boundary=mix")
        #expect(saida.text == "Segue em anexo.")
        #expect(saida.html == nil)
        #expect(saida.calendar == nil)
    }

    @Test("`text(raw:)` continua devolvendo o mesmo de sempre — ninguém quebrou por causa do HTML novo")
    func textoContinuaOMesmo() {
        #expect(
            MimeBody.text(
                raw: Self.alternative, contentType: "multipart/alternative; boundary=limite"
            ) == "A versao em texto."
        )
    }
}
