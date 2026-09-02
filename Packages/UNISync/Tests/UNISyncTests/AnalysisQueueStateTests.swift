import Foundation
import GRDB
import Testing
@testable import UNISync

@Suite("O estado da fila de análise automática")
struct AnalysisQueueStateTests {
    @Test("uma fila nova roda, e a pausa persiste com o motivo")
    func pauseAndResume() throws {
        let database = try SyncDatabase.temporary()
        let store = AnalysisQueueStateStore(database: database)

        #expect(try store.state() == .running)

        try store.pause(reason: "A chave de API foi recusada.", at: Date(timeIntervalSince1970: 10))
        #expect(try store.state() == .paused(reason: "A chave de API foi recusada."))

        // Outra instância lê o mesmo banco: o estado não mora em memória.
        #expect(try AnalysisQueueStateStore(database: database).state()
            == .paused(reason: "A chave de API foi recusada."))

        try store.resume()
        #expect(try store.state() == .running)
    }

    @Test("a linha é única: pausar duas vezes não cria uma segunda")
    func singleRow() throws {
        let database = try SyncDatabase.temporary()
        let store = AnalysisQueueStateStore(database: database)
        try store.pause(reason: "Primeira", at: Date(timeIntervalSince1970: 1))
        try store.pause(reason: "Segunda", at: Date(timeIntervalSince1970: 2))
        let count = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis_queue_state") ?? 0
        }
        #expect(count == 1)
        #expect(try store.state() == .paused(reason: "Segunda"))
    }
}
