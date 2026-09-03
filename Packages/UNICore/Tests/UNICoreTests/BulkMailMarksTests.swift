import Foundation
import Testing
@testable import UNICore

/// Os cabeçalhos que denunciam disparo em massa, lidos sem palpite nenhum.
@Suite("Marcas de disparo em massa")
struct BulkMailMarksTests {

    @Test("List-Unsubscribe é disparo")
    func listUnsubscribe() {
        let marcas = BulkMailMarks.detect(
            headers: ["List-Unsubscribe": "<mailto:x@y.com>"],
            from: "gente@empresa.com"
        )
        #expect(marcas.contains(.listUnsubscribe))
        #expect(marcas.isBulk)
    }

    @Test("List-Id é disparo")
    func listID() {
        let marcas = BulkMailMarks.detect(
            headers: ["list-id": "<news.resend.dev>"], from: "a@b.com"
        )
        #expect(marcas.contains(.listID))
    }

    @Test("Precedence bulk, list e junk são disparo; qualquer outro valor não")
    func precedence() {
        for valor in ["bulk", "list", "junk", "BULK"] {
            #expect(
                BulkMailMarks.detect(headers: ["Precedence": valor], from: "a@b.com")
                    .contains(.precedence),
                "\(valor) devia contar"
            )
        }
        #expect(
            !BulkMailMarks.detect(headers: ["Precedence": "first-class"], from: "a@b.com")
                .contains(.precedence)
        )
    }

    @Test("Auto-Submitted diferente de no é disparo; `no` não é")
    func autoSubmitted() {
        #expect(
            BulkMailMarks.detect(headers: ["Auto-Submitted": "auto-generated"], from: "a@b.com")
                .contains(.autoSubmitted)
        )
        #expect(
            !BulkMailMarks.detect(headers: ["Auto-Submitted": "no"], from: "a@b.com")
                .contains(.autoSubmitted)
        )
    }

    @Test("X-Auto-Response-Suppress é disparo")
    func autoResponseSuppress() {
        #expect(
            BulkMailMarks.detect(
                headers: ["X-Auto-Response-Suppress": "OOF, AutoReply"], from: "a@b.com"
            ).contains(.autoResponseSuppress)
        )
    }

    @Test("no-reply, noreply e donotreply no remetente são disparo")
    func noReplySenders() {
        for endereco in [
            "no-reply@resend.dev", "noreply@zoho.com", "donotreply@upwork.com",
            "NoReply@Upwork.com", "no_reply@x.com",
        ] {
            #expect(
                BulkMailMarks.detect(headers: [:], from: endereco).contains(.noReplySender),
                "\(endereco) devia contar"
            )
        }
        #expect(!BulkMailMarks.detect(headers: [:], from: "jack@whitmore.com").isBulk)
        // "reply@" sozinho não é "no-reply@" — a caça a substring não pode
        // pegar quem só tem a palavra dentro do nome.
        #expect(!BulkMailMarks.detect(headers: [:], from: "reply@x.com").isBulk)
    }

    @Test("cabeçalho vazio não conta — ausência é ausência")
    func vazioNaoConta() {
        let marcas = BulkMailMarks.detect(
            headers: ["List-Unsubscribe": "  ", "Precedence": ""], from: "a@b.com"
        )
        #expect(marcas.isEmpty)
        #expect(!marcas.isBulk)
    }

    @Test("o bloco cru de cabeçalhos do IMAP é lido com dobra de linha")
    func blocoCru() {
        let bloco = """
            List-Unsubscribe: <https://x.com/u/1>,
             <mailto:u@x.com>\r
            Precedence: bulk\r
            """
        let marcas = BulkMailMarks.detect(rawHeaderBlock: bloco, from: "a@b.com")
        #expect(marcas.contains(.listUnsubscribe))
        #expect(marcas.contains(.precedence))
    }

    @Test("a marca sobrevive ao inteiro que o banco guarda")
    func rawValueEstavel() {
        let marcas: BulkMailMarks = [.listUnsubscribe, .noReplySender]
        #expect(BulkMailMarks(rawValue: marcas.rawValue) == marcas)
    }
}
