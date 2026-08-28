import Foundation
import Testing
import GRDB
import NIOCore
@testable import UNISync

@Suite("Wiring das dependências novas")
struct WiringTests {
    @Test("O pacote existe e nomeia as dependências novas")
    func wiring() {
        #expect(UNISync.wiringCheck() == "GRDB+NIO")
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

    @Test("SwiftNIO está linkado e move bytes")
    func nioExiste() {
        // Era o `swift-nio-imap` que este teste afirmava. Ele saiu do pacote na
        // rodada de conserto 2 da Task 10, e quem ficou sustentando a sessão
        // IMAP inteira é o SwiftNIO — que é o que precisa linkar.
        var buffer = ByteBuffer()
        buffer.writeString("INBOX")
        #expect(buffer.readableBytes == 5)
        #expect(String(buffer: buffer) == "INBOX")
    }
}
