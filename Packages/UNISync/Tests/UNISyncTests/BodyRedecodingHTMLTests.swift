import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// O corpo do dono que abria como **código-fonte**: `<!doctype html>`,
/// `<html lang=3D"en">`, `charset=3DUTF-8=` com a quebra no meio.
///
/// Ele foi gravado por um caminho que pôs a parte HTML na coluna de texto sem
/// decodificar o quoted-printable. A varredura da abertura não o reconhecia: a
/// sondagem procurava MIME com cabeçalho, e isto é uma página avulsa com
/// cicatrizes de transporte.
private let corpoDoDono = """
    <!doctype html>
    <html lang=3D"en">
     <head>
     <title></title>
     <!--[if !mso]><!-- -->
     <meta http-equiv=3D"X-UA-Compatible" content=3D"IE=3Dedge" />
     <meta charset=3D"UTF-8" />
     </head>
     <body>
     <p>Sua conta da SpaceXAI foi criada. O c=C3=B3digo =C3=A9 4821.</p>
     </body>
    </html>
    """

@Suite("O corpo gravado como fonte HTML")
struct BodyRedecodingHTMLTests {

    @Test("O email do dono vira página sanitizada, sem um `=3D` sequer")
    func aTelaDoDono() {
        let conserto = MimeBody.redecodedBody([corpoDoDono])
        let pagina = try! #require(conserto?.html)

        #expect(!pagina.contains("=3D"))
        #expect(!pagina.contains("=C3"))
        // A leitura em texto sai legível, com o acento no lugar — é ela que
        // vira prévia da lista e índice de busca.
        let texto = (conserto?.paragraphs ?? []).joined(separator: "\n")
        #expect(texto.contains("Sua conta da SpaceXAI foi criada."))
        #expect(texto.contains("O código é 4821."))
        // E nenhuma marcação sobrou no texto.
        #expect(!texto.contains("<"))
        #expect(!texto.contains("doctype"))
    }

    @Test("A família é a nova, e não a de quoted-printable")
    func familiaCerta() {
        #expect(MimeBody.familia(de: corpoDoDono) == .htmlCru)
        #expect(MimeBody.looksRaw([corpoDoDono]))
    }

    @Test("Um email que FALA sobre HTML continua sendo texto")
    func oEmailQueCitaHTML() {
        // O padrão exigido é no **início** do corpo. Presença bastaria para
        // transformar este email — meu, escrito à mão — numa página.
        let citaHTML = [
            "Oi, consegui reproduzir o bug do rodapé.",
            "O template gera <div class=\"footer\"> sem fechar, e aí o <html> do "
            + "cliente de email se perde. Dá uma olhada no <head> também.",
        ]
        #expect(!MimeBody.looksRaw(citaHTML))
        #expect(MimeBody.redecodedBody(citaHTML) == nil)
    }

    @Test("Um documento HTML limpo, sem cicatriz de transporte, também é página")
    func htmlSemQuotedPrintable() {
        let limpo = "<html><body><p>Recibo da sua assinatura anual.</p></body></html>"
        let conserto = try! #require(MimeBody.redecodedBody([limpo]))
        #expect(conserto.html != nil)
        #expect(conserto.paragraphs == ["Recibo da sua assinatura anual."])
    }

    @Test("A varredura da abertura grava as duas metades e converge")
    func varreduraGrava() async throws {
        let db = try SyncDatabase.temporary()
        try await db.pool.write { conexao in
            try AccountRecord(
                Account(
                    id: "conta-a", address: "eu@x.com", displayName: "Eu",
                    provider: .imap, host: "x",
                    tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
                ),
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa"
            ).insert(conexao)
            let mensagem = Message(
                id: "m-html", accountID: "conta-a",
                from: Contact(name: "SpaceXAI", address: "noreply@spacexai.com"),
                receivedAt: Date(timeIntervalSince1970: 100),
                subject: "Sua conta", snippet: "<!doctype html>", body: [corpoDoDono],
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil
            )
            try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(conexao)
            var registro = MessageBodyRecord(messageID: "m-html", paragraphs: [corpoDoDono])
            try registro.insert(conexao)
        }

        #expect(try await BodyRedecoding.run(db) == 1)
        let depois = try await db.pool.read { conexao in
            try MessageBodyRecord.filter(Column("messageID") == "m-html").fetchOne(conexao)
        }
        let registro = try #require(depois)
        // A página está na coluna que o leitor lê.
        #expect(registro.html?.contains("SpaceXAI") == true)
        #expect(registro.html?.contains("=3D") == false)
        // E o texto, o que a busca indexa, está legível.
        #expect(registro.plain.contains("O código é 4821."))
        #expect(!registro.plain.contains("doctype"))

        // Converge: a segunda abertura não tem o que consertar.
        #expect(try await BodyRedecoding.run(db) == 0)
    }
}
