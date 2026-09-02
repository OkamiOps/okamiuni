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

    @Test("a data da pausa vai e volta como número na coluna DOUBLE")
    func pausedAtRoundTrips() throws {
        let database = try SyncDatabase.temporary()
        let store = AnalysisQueueStateStore(database: database)
        let momento = Date(timeIntervalSince1970: 1_788_000_123)
        try store.pause(reason: "A chave de API foi recusada.", at: momento)

        let bruto = try database.pool.read { db in
            try Double.fetchOne(db, sql: "SELECT pausedAt FROM analysis_queue_state")
        }
        #expect(bruto == momento.timeIntervalSince1970)

        let record = try #require(try database.pool.read { db in
            try AnalysisQueueStateRecord.fetchOne(db, key: AnalysisQueueStateRecord.singletonID)
        })
        #expect(record.pausedAt == momento)
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
