import Foundation
import GRDB

/// A fila de análise automática nunca cai para o Mac em silêncio: ela
/// para, com o motivo na tela, e só volta por um clique.
public enum AnalysisQueueState: Sendable, Hashable {
    case running
    case paused(reason: String)

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public var reason: String? {
        if case let .paused(reason) = self { return reason }
        return nil
    }
}

/// Linha única. A fila é global — não existe uma por conta — e por isso ela
/// não podia morar em `sync_state`, cuja `accountID` referencia `account(id)`.
struct AnalysisQueueStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "analysis_queue_state"
    static let singletonID = "default"

    var id: String
    var isPaused: Bool
    var reason: String?
    var pausedAt: Date?
}

public struct AnalysisQueueStateStore: Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) { self.database = database }

    public func state() throws -> AnalysisQueueState {
        try database.pool.read { db in
            guard let record = try AnalysisQueueStateRecord.fetchOne(
                db, key: AnalysisQueueStateRecord.singletonID
            ), record.isPaused, let reason = record.reason else {
                return .running
            }
            return .paused(reason: reason)
        }
    }

    public func pause(reason: String, at date: Date) throws {
        try database.pool.write { db in
            try AnalysisQueueStateRecord(
                id: AnalysisQueueStateRecord.singletonID,
                isPaused: true, reason: reason, pausedAt: date
            ).save(db)
        }
    }

    public func resume() throws {
        try database.pool.write { db in
            try AnalysisQueueStateRecord(
                id: AnalysisQueueStateRecord.singletonID,
                isPaused: false, reason: nil, pausedAt: nil
            ).save(db)
        }
    }
}
