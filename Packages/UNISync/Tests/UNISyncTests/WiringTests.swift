import Foundation
import Testing
import GRDB
import NIOCore
import NIOIMAP
@testable import UNISync

@Suite("Wiring das dependências novas")
struct WiringTests {
    @Test("O pacote existe e nomeia as duas dependências")
    func wiring() {
        #expect(UNISync.wiringCheck() == "GRDB+NIOIMAP")
    }

    @Test("GRDB abre um banco em memória e responde SQL")
    func grdbAbre() throws {
        let queue = try DatabaseQueue()
        let um = try queue.read { db in try Int.fetchOne(db, sql: "SELECT 1") }
        #expect(um == 1)
    }

    @Test("SQLite foi compilado com FTS5 e com o tokenizer que dobra acento")
    func fts5Existe() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE t USING fts5(
                    corpo, tokenize='unicode61 remove_diacritics 2'
                )
                """)
            try db.execute(sql: "INSERT INTO t(corpo) VALUES ('Revisão do contrato')")
        }
        let achou = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM t WHERE t MATCH 'Revisao'")
        }
        #expect(achou == 1)
    }

    @Test("swift-nio-imap está linkado e monta um nome de caixa")
    func nioImapExiste() {
        let caixa = MailboxName(ByteBuffer(string: "INBOX"))
        #expect(caixa.bytes.count == 5)
    }
}
