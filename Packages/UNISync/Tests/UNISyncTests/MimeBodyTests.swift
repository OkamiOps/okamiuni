import Foundation
import Testing
import UNICore
@testable import UNISync

/// Fontes MIME como elas chegam de verdade.
///
/// Escritas à mão, byte a byte, e não geradas: o que se testa aqui é
/// justamente a leitura do que **outros** produzem, e um gerador nosso só
/// provaria que sabemos ler o que sabemos escrever. As únicas partes calculadas
/// são as cargas base64, para não haver um bloco de letras no teste que ninguém
/// consegue conferir de olho.
private enum Fonte {
    /// O caso mais comum de todos: `multipart/alternative` com texto em
    /// quoted-printable e HTML ao lado.
    static let alternativeComQP = """
        --_b1_
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        Ol=C3=A1, a revis=C3=A3o do contrato ficou pronta.

        Podemos fechar quinta=3F Abra=C3=A7o, Marina.
        --_b1_
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        <p>Ol=C3=A1</p>
        --_b1_--
        """

    static let tipoAlternative = "multipart/alternative; boundary=\"_b1_\""

    /// Uma parte de texto em base64, quebrada em 76 colunas como o RFC 2045
    /// manda — a quebra é o que faz `Data(base64Encoded:)` cru recusar tudo.
    static func base64Simples(_ texto: String) -> String {
        let carga = Data(texto.utf8).base64EncodedString()
        let linhas = stride(from: 0, to: carga.count, by: 76).map { inicio -> String in
            let a = carga.index(carga.startIndex, offsetBy: inicio)
            let b = carga.index(a, offsetBy: min(76, carga.count - inicio))
            return String(carga[a..<b])
        }
        return """
            Content-Type: text/plain; charset="utf-8"
            Content-Transfer-Encoding: base64

            \(linhas.joined(separator: "\n"))
            """
    }

    /// `multipart/mixed` com um `multipart/alternative` dentro, e um anexo ao
    /// lado — a forma de qualquer mensagem com arquivo junto.
    static let aninhada = """
        Preâmbulo que nenhum leitor deve mostrar.
        --externa
        Content-Type: multipart/alternative; boundary="interna"

        --interna
        Content-Type: text/plain; charset="utf-8"

        O relatório está anexado.
        --interna
        Content-Type: text/html; charset="utf-8"

        <p>O relat&oacute;rio est&aacute; anexado.</p>
        --interna--
        --externa
        Content-Type: text/csv; charset="utf-8"
        Content-Disposition: attachment; filename="dados.csv"

        a,b,c
        --externa--
        Epílogo, idem.
        """

    static let tipoAninhada = "multipart/mixed; boundary=externa"

    static let soHTML = """
        <html><head><style>p { color: red }</style><title>Não mostrar</title></head>
        <body>
          <h1>Fatura de agosto</h1>
          <p>Ol&aacute;, Marina &amp; equipe.</p>
          <div>Vencimento: <b>10/09</b>.<br>Valor: R&#36; 1.200,00</div>
          <script>alert('não')</script>
          <ul><li>Item um</li><li>Item dois</li></ul>
        </body></html>
        """
}

@Suite("MIME: o corpo de verdade virando texto")
struct MimeBodyTests {

    @Test("multipart misto expõe anexo com nome seguro e mantém texto fora dele")
    func extractsReceivedAttachment() {
        let raw = """
        --outer
        Content-Type: text/plain; charset=utf-8

        Segue o arquivo.
        --outer
        Content-Type: application/pdf; name=../../contrato.pdf
        Content-Disposition: attachment; filename=../../contrato.pdf
        Content-Transfer-Encoding: base64

        UERG
        --outer--
        """
        let decoded = MimeBody.decode(raw: raw, contentType: "multipart/mixed; boundary=outer")
        #expect(decoded.text == "Segue o arquivo.")
        #expect(decoded.attachments.count == 1)
        let attachment = decoded.attachments.first
        #expect(attachment?.filename == "contrato.pdf")
        #expect(attachment?.mimeType == "application/pdf")
        #expect(attachment?.data == Data("PDF".utf8))
    }

    /// Checagem de mutação: se o limite sair antes da decodificação, esta
    /// carga passaria a materializar 25 MiB no processo ou a sumir da tela.
    @Test("anexo acima do teto continua visível, mas sem bytes em memória")
    func keepsOversizedAttachmentMetadata() {
        let encoded = String(repeating: "A", count: OutgoingAttachment.maximumByteCount * 4 / 3 + 4)
        let raw = """
        --outer
        Content-Type: application/octet-stream; name=arquivo-grande.bin
        Content-Disposition: attachment; filename=arquivo-grande.bin
        Content-Transfer-Encoding: base64

        \(encoded)
        --outer--
        """
        let decoded = MimeBody.decode(raw: raw, contentType: "multipart/mixed; boundary=outer")
        #expect(decoded.attachments.count == 1)
        let attachment = decoded.attachments.first
        #expect(attachment?.filename == "arquivo-grande.bin")
        #expect(attachment?.byteCount ?? 0 > OutgoingAttachment.maximumByteCount)
        #expect(attachment?.data == nil)
    }
    // MARK: A forma mais comum

    @Test("multipart/alternative com quoted-printable acentuado sai em texto legível")
    func alternativeComQuotedPrintable() {
        let paragrafos = MimeBody.paragraphs(
            raw: Fonte.alternativeComQP, contentType: Fonte.tipoAlternative
        )
        #expect(paragrafos == [
            "Olá, a revisão do contrato ficou pronta.",
            "Podemos fechar quinta? Abraço, Marina.",
        ])
    }

    @Test("HTML quoted-printable sem cabeçalho da parte ainda é decodificado")
    func htmlQuotedPrintableSemCabecalhoDaParte() {
        // O SendGrid/OpenAI observado em produção declarou o multipart no
        // cabeçalho externo, mas deixou a parte HTML sem o seu próprio
        // Content-Transfer-Encoding. O corpo continuou trazendo QP: `=20`,
        // `=3D` e quebras suaves. Sanitizar antes de desfazer isso transforma
        // atributos em `width=\"3D&amp;quot;100%...\"` e espreme a mensagem.
        let raw = """
            --openai
            Content-Type: text/html; charset=utf-8

            <html><body><table width=3D"100%"><tr><td>=20</td></tr></table>=
            <p>Enter this temporary verification code to continue:</p>
            <p>478457</p></body></html>
            --openai--
            """

        let decoded = MimeBody.decode(
            raw: raw,
            contentType: "multipart/alternative; boundary=openai",
            contentTransferEncoding: "7bit"
        )
        let html = try! #require(decoded.html)

        #expect(html.contains("Enter this temporary verification code"))
        #expect(html.contains("width=\"100%\""))
        #expect(!html.contains("=20"))
        #expect(!html.contains("=3D"))
        #expect(!html.contains("3D&amp;quot"))
    }

    /// **Prova por mutação do decodificador.** Um `text(raw:…)` que devolvesse
    /// a fonte crua — que é literalmente o que o app fazia antes desta tarefa —
    /// passa por qualquer afirmação sobre "o corpo não está vazio". O que o
    /// mata é afirmar o que **não** pode estar na tela: a fronteira, o
    /// sub-cabeçalho e o escape.
    @Test("Nada da fonte MIME sobra no texto — nem fronteira, nem cabeçalho, nem escape")
    func nadaDaFonteSobra() {
        let texto = MimeBody.text(
            raw: Fonte.alternativeComQP, contentType: Fonte.tipoAlternative
        )
        #expect(!texto.contains("--_b1_"))
        #expect(!texto.contains("Content-Type"))
        #expect(!texto.contains("Content-Transfer-Encoding"))
        #expect(!texto.contains("=C3"))
        #expect(!texto.contains("<p>"))
        #expect(texto.contains("revisão"))
    }

    // MARK: base64

    @Test("Uma parte em base64, quebrada em 76 colunas, decodifica inteira")
    func base64EmColunas() {
        let original = "Segue o contrato revisado, com as cláusulas 4 e 7 ajustadas "
            + "conforme conversamos na quinta-feira passada.\n\nAbraço, Marina."
        let paragrafos = MimeBody.paragraphs(raw: Fonte.base64Simples(original))
        #expect(paragrafos == [
            "Segue o contrato revisado, com as cláusulas 4 e 7 ajustadas "
                + "conforme conversamos na quinta-feira passada.",
            "Abraço, Marina.",
        ])
    }

    // MARK: Aninhamento

    @Test("multipart dentro de multipart: o texto sai de dentro, o anexo fica fora")
    func aninhamento() {
        let paragrafos = MimeBody.paragraphs(
            raw: Fonte.aninhada, contentType: Fonte.tipoAninhada
        )
        #expect(paragrafos == ["O relatório está anexado."])
    }

    @Test("Preâmbulo e epílogo não são mensagem")
    func preambuloEEpilogo() {
        let texto = MimeBody.text(raw: Fonte.aninhada, contentType: Fonte.tipoAninhada)
        #expect(!texto.contains("Preâmbulo"))
        #expect(!texto.contains("Epílogo"))
    }

    @Test("Um `.csv` anexado é arquivo, não a mensagem — mesmo sendo texto")
    func anexoDeTextoNaoEntra() {
        let texto = MimeBody.text(raw: Fonte.aninhada, contentType: Fonte.tipoAninhada)
        #expect(!texto.contains("a,b,c"))
    }

    // MARK: Só HTML

    @Test("Mensagem só de HTML vira texto: tags fora, entidades decodificadas")
    func somenteHTML() {
        let paragrafos = MimeBody.paragraphs(
            raw: Fonte.soHTML, contentType: "text/html; charset=utf-8"
        )
        // Blocos preservados: o título, o parágrafo, o bloco de valores e cada
        // item da lista são unidades separadas — e não um bolo só.
        #expect(paragrafos.contains("Fatura de agosto"))
        #expect(paragrafos.contains("Olá, Marina & equipe."))
        #expect(paragrafos.contains("Item um"))
        #expect(paragrafos.contains("Item dois"))
        // `<br>` quebra linha **dentro** do parágrafo, sem o partir.
        #expect(paragrafos.contains { $0.contains("Vencimento: 10/09.\nValor: R$ 1.200,00") })
    }

    @Test("`script`, `style` e `title` não são conteúdo — o miolo deles some junto")
    func mudosSomem() {
        let texto = MimeBody.textFromHTML(Fonte.soHTML)
        #expect(!texto.contains("color: red"))
        #expect(!texto.contains("alert"))
        #expect(!texto.contains("Não mostrar"))
    }

    @Test("`&` que não abre entidade continua sendo `&`")
    func eComercialSolto() {
        #expect(MimeBody.textFromHTML("<p>P&D e R&amp;D</p>") == "P&D e R&D")
    }

    // MARK: Charsets

    @Test("ISO-8859-1 declarado, com a carga em base64, sai acentuado")
    func latin1() {
        // Os bytes de verdade: `é` é 0xE9 em latin1, e não os dois bytes do
        // UTF-8. Ler isto como UTF-8 devolveria um losango de substituição.
        let bytes = Data([
            0x52, 0x65, 0x75, 0x6E, 0x69, 0xE3, 0x6F, 0x20, // "Reunião "
            0x64, 0x65, 0x20, 0x74, 0x65, 0x72, 0xE7, 0x61, // "de terça"
            0x2D, 0x66, 0x65, 0x69, 0x72, 0x61, 0x2E,       // "-feira."
        ])
        let cru = """
            Content-Type: text/plain; charset="iso-8859-1"
            Content-Transfer-Encoding: base64

            \(bytes.base64EncodedString())
            """
        #expect(MimeBody.paragraphs(raw: cru) == ["Reunião de terça-feira."])
    }

    @Test("windows-1252: a aspa curva da faixa que o latin1 puro chama de controle")
    func windows1252() {
        // 0x93 e 0x94 são “ e ” em cp1252, e caracteres de controle em
        // ISO-8859-1 ao pé da letra. Todo remetente do Word manda isto.
        let bytes = Data([0x93, 0x6F, 0x6C, 0xE1, 0x94])  // “olá”
        let cru = """
            Content-Type: text/plain; charset="windows-1252"
            Content-Transfer-Encoding: base64

            \(bytes.base64EncodedString())
            """
        #expect(MimeBody.paragraphs(raw: cru) == ["“olá”"])
    }

    @Test("Charset que mente: bytes UTF-8 sob `iso-8859-1` continuam legíveis")
    func charsetQueMente() {
        let cru = """
            Content-Type: text/plain; charset="iso-8859-1"
            Content-Transfer-Encoding: base64

            \(Data("Reunião".utf8).base64EncodedString())
            """
        // A ordem de tentativa é o que salva: UTF-8 é o único que falha quando
        // não é dele, então tentá-lo primeiro é grátis — e aqui ele acerta.
        #expect(MimeBody.paragraphs(raw: cru) == ["Reunião"])
    }

    // MARK: As peças

    @Test("A fronteira é lida com aspas, sem aspas e depois de uma continuação")
    func fronteiras() {
        #expect(MimeBody.parametro("boundary", em: "multipart/mixed; boundary=abc") == "abc")
        #expect(MimeBody.parametro("boundary", em: "multipart/mixed; boundary=\"a b\"") == "a b")
        // `xboundary=` não é `boundary=`.
        #expect(MimeBody.parametro("boundary", em: "multipart/mixed; xboundary=abc") == nil)
    }

    @Test("O cabeçalho quebrado em duas linhas é desdobrado antes de ser lido")
    func continuacaoDeCabecalho() {
        let parte = """
            Content-Type: multipart/alternative;
             boundary="quebrada"

            corpo
            """
        let (cabecalhos, corpo) = MimeBody.separaCabecalhos(parte)
        #expect(MimeBody.parametro("boundary", em: cabecalhos["content-type"] ?? "") == "quebrada")
        #expect(corpo == "corpo")
    }

    @Test("Quoted-printable: a quebra suave some, o escape vira byte")
    func quebraSuave() {
        let dados = MimeBody.quotedPrintable(
            "uma linha muito com=\nprida e um cifr=C3=A3o", sublinhadoEhEspaco: false
        )
        #expect(String(data: dados, encoding: .utf8) == "uma linha muito comprida e um cifrão")
    }

    @Test("A variante de cabeçalho é a mesma função: `_` vale espaço, `=\\n` não")
    func varianteDeCabecalho() {
        let dados = MimeBody.quotedPrintable("Revis=C3=A3o_do_contrato", sublinhadoEhEspaco: true)
        #expect(String(data: dados, encoding: .utf8) == "Revisão do contrato")
        // E o RFC 2047 continua passando pela mesma peça, agora com um só dono.
        #expect(MailAddress.decodeRFC2047("=?UTF-8?Q?Revis=C3=A3o_do_contrato?=")
                == "Revisão do contrato")
    }

    @Test("Um corpo que já é texto atravessa intacto")
    func textoSimplesNaoEMexido() {
        let simples = "Bom dia.\n\nSegue o combinado — até quinta.\n\n--\nMarina"
        #expect(MimeBody.paragraphs(raw: simples) == [
            "Bom dia.", "Segue o combinado — até quinta.", "--\nMarina",
        ])
    }

    @Test("Aninhamento sem fim não come a pilha: o teto corta")
    func tetoDeProfundidade() {
        // Uma boneca russa de `multipart` que se aponta para si mesma em cada
        // nível. Sem teto, isto desce até o processo morrer.
        var cru = "conteúdo profundo"
        for nivel in (0..<20).reversed() {
            cru = """
                --n\(nivel)
                Content-Type: multipart/mixed; boundary="n\(nivel + 1)"

                \(cru)
                --n\(nivel)--
                """
        }
        // O que importa é terminar, e terminar sem inventar texto: a resposta é
        // vazia porque o teto foi atingido antes de qualquer folha de texto.
        #expect(MimeBody.paragraphs(raw: cru, contentType: "multipart/mixed; boundary=\"n0\"")
                .isEmpty)
    }
}
