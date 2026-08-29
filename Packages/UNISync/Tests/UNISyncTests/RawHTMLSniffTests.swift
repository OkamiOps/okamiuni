import Foundation
import Testing
import UNICore
@testable import UNISync

/// A tela do dono da M3-21: "Zoho Workplace — Informações alteradas" abrindo
/// como **código-fonte**, com as cicatrizes do transporte ainda inteiras —
/// `=3D` no lugar de `=`, e a quebra suave partindo a URL do `DOCTYPE` no meio
/// (`http://www.=` numa linha, `w3.org/...` na outra).
///
/// É o mesmo defeito da M3-12 por **outra porta**. Lá o corpo já estava no
/// banco e a varredura da abertura o consertava; aqui a mensagem não tem corpo
/// gravado nenhum, e quem a mostra é a decodificação ao vivo
/// (`MimeBody.decode`) da busca por demanda — que, sem `Content-Type` no
/// cabeçalho, assumia `text/plain` e devolvia a página inteira como se fosse
/// leitura. A sondagem que sabia reconhecê-la nunca era perguntada.
private let zohoDoDono = """
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.=
    w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd"> <html xmlns=3D"http://www.w3.=
    org/1999/xhtml"><head><meta http-equiv=3D"Content-Type" content=3D"text/html=
    ; charset=3DUTF-8" /><title>Zoho</title></head><body><table><tr><td><p>As \
    informa=C3=A7=C3=B5es da sua conta Zoho Workplace foram alteradas.</p></td>\
    </tr></table></body></html>
    """

@Suite("O fonte de QP que escapava da sondagem")
struct RawHTMLSniffTests {

    // MARK: A porta da decodificação ao vivo

    @Test("Sem cabeçalho nenhum, o fonte do dono ainda vira mensagem")
    func oZohoDoDono() {
        let corpo = MimeBody.decode(raw: zohoDoDono)
        // O que o leitor desenha: página, não código.
        let pagina = try! #require(corpo.html)
        #expect(pagina.contains("foram alteradas"))
        #expect(!pagina.contains("=3D"))
        // E a leitura em texto — a que vira prévia da lista, índice de busca e
        // citação no composer — sai limpa.
        #expect(corpo.text.contains("As informações da sua conta Zoho Workplace foram alteradas."))
        #expect(!corpo.text.contains("DOCTYPE"))
        #expect(!corpo.text.contains("=3D"))
    }

    @Test("A prévia da lista e a citação do composer saem do mesmo texto")
    func previaECitacao() {
        // As duas telas que o dono mostrou com o cru vazando são vistas deste
        // mesmo valor: a prévia é `paragraphs.first`, a citação é o texto
        // inteiro. Consertada a decodificação, as duas se consertam junto.
        let paragrafos = MimeBody.paragraphs(raw: zohoDoDono)
        #expect(paragrafos.first?.hasPrefix("As informações") == true)
    }

    // MARK: A sondagem, caso a caso

    @Test("O DOCTYPE em maiúsculas, com declaração XHTML, é fonte HTML")
    func doctypeXHTML() {
        #expect(MimeBody.familia(de: zohoDoDono) == .htmlCru)
    }

    @Test("A quebra suave dentro do próprio DOCTYPE não esconde a página")
    func quebraDentroDoDoctype() {
        // A quebra de QP cai onde a linha completa 76 colunas — e isso pode ser
        // no meio da palavra `DOCTYPE`. Enquanto ela estiver lá, não há prefixo
        // nenhum a casar: por isso o QP é desfeito **antes** de perguntar.
        let partido = """
            <!DOCT=
            YPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN">
            <html xmlns=3D"http://www.w3.org/1999/xhtml"><body><p>Ol=C3=A1</p></body></html>
            """
        #expect(MimeBody.familia(de: partido) == .htmlCru)
        #expect(MimeBody.redecodedBody([partido])?.paragraphs == ["Olá"])
    }

    @Test("O `<html` partido no meio também")
    func quebraDentroDoHtml() {
        let partido = """
            <ht=
            ml xmlns=3D"http://www.w3.org/1999/xhtml"><body><p>Ol=C3=A1</p></body></html>
            """
        #expect(MimeBody.familia(de: partido) == .htmlCru)
    }

    @Test("O prólogo XML na frente da página não a disfarça")
    func prologoXML() {
        let comPrologo = """
            <?xml version=3D"1.0" encoding=3D"UTF-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN">
            <html xmlns=3D"http://www.w3.org/1999/xhtml"><body><p>Ol=C3=A1</p></body></html>
            """
        #expect(MimeBody.familia(de: comPrologo) == .htmlCru)
        #expect(MimeBody.redecodedBody([comPrologo])?.paragraphs == ["Olá"])
    }

    @Test("Uma página sem uma palavra dentro ainda vale o conserto")
    func paginaSemTexto() {
        // Newsletter que é só imagem: o texto derivado sai vazio. Antes, a
        // guarda do vazio abortava o conserto inteiro e o **fonte** continuava
        // sendo a leitura. A página vale por si.
        let soImagem = """
            <!DOCTYPE html>
            <html><body><table><tr><td><img src=3D"http://x/y.png" /></td></tr></table></body></html>
            """
        let conserto = try! #require(MimeBody.redecodedBody([soImagem]))
        #expect(conserto.html?.contains("<img") == true)
        #expect(conserto.paragraphs.isEmpty)
    }

    // MARK: A guarda da M3-12, intacta

    @Test("O email que FALA de HTML continua sendo texto — em todas as portas")
    func oEmailQueCitaHTMLContinuaTexto() {
        let citaHTML = [
            "Oi, consegui reproduzir o bug do rodapé.",
            "O template gera <div class=\"footer\"> sem fechar, e aí o <html> do "
            + "cliente de email se perde. Dá uma olhada no <head> também.",
        ]
        #expect(!MimeBody.looksRaw(citaHTML))
        #expect(MimeBody.redecodedBody(citaHTML) == nil)
        // E pela porta nova: decodificado ao vivo, continua sendo o texto que é.
        let cru = citaHTML.joined(separator: "\n\n")
        #expect(MimeBody.decode(raw: cru).html == nil)
        #expect(MimeBody.decode(raw: cru).text.contains("bug do rodapé"))
    }

    @Test("Um email de texto simples não vira página por ter um `=` no meio")
    func textoSimplesContinuaTexto() {
        let cru = "Bom dia.\n\nO total é 100 = 40 + 60, conforme a planilha."
        #expect(MimeBody.decode(raw: cru).html == nil)
        #expect(MimeBody.decode(raw: cru).text == cru)
    }

    @Test("Com `Content-Type` de verdade, a sondagem nem é perguntada")
    func cabecalhoDeclaradoVence() {
        // O caminho normal: o servidor disse o que era. A sondagem é a saída de
        // emergência de quando ninguém disse.
        let corpo = MimeBody.decode(
            raw: "<html><body><p>Recibo</p></body></html>",
            contentType: "text/plain; charset=utf-8"
        )
        #expect(corpo.html == nil)
    }
}
