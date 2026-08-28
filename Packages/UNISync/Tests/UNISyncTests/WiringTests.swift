import Foundation
import Testing
import GRDB
import NIOCore
@testable import UNISync

/// As dependências novas, provadas **pelo trabalho que fazem**.
///
/// Havia um quarto teste aqui, `wiring`, e ele era inútil por construção:
/// `#expect(UNISync.wiringCheck() == "GRDB+NIO")` comparava um literal com o
/// literal que a função devolvia. Nenhum defeito de produção podia derrubá-lo —
/// tirar GRDB ou SwiftNIO do `Package.swift` quebra a **compilação**, que
/// nenhum teste observa, e é uma prova mais forte do que qualquer asserção
/// daqui. O doc-comment do `Wiring.swift` já previa a própria saída ("se um dia
/// alguém o apagar e nada quebrar, ele terá cumprido o papel"); ele saiu junto,
/// porque o teste era o único chamador que lhe restava.
///
/// Os três que ficam fazem o trabalho de verdade: abrem banco, exigem o FTS5
/// com o tokenizer que dobra acento — que é o que a busca do Marco 2 depende e
/// que uma compilação bem-sucedida NÃO garante —, e movem bytes pelo NIO.
@Suite("Wiring das dependências novas")
struct WiringTests {
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
