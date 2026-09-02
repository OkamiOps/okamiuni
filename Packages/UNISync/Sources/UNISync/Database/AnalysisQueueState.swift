import Foundation
import Observation
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

    /// A coluna é `DOUBLE`. Sem esta estratégia o GRDB gravaria a data como
    /// texto ISO nela, e o SQLite a leria de volta como `2026.0` — o mesmo
    /// contrato de `MessageIntelligenceRecord`.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
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

/// O estado que a barra lateral observa.
///
/// A fonte é o próprio banco, via `ValueObservation`: a pausa é gravada por
/// dentro do coordenador, e uma tela que só lesse na abertura mostraria a
/// fila correndo enquanto ela já tinha parado.
@MainActor
@Observable
public final class AnalysisQueueStateModel {
    public private(set) var state: AnalysisQueueState = .running

    private let database: SyncDatabase
    private let coordinator: MessageIntelligenceCoordinator
    private var observationTask: Task<Void, Never>?

    public init(database: SyncDatabase, coordinator: MessageIntelligenceCoordinator) {
        self.database = database
        self.coordinator = coordinator
        self.state = (try? AnalysisQueueStateStore(database: database).state()) ?? .running
    }

    /// Idempotente, como a observação do coordenador.
    public func start() {
        guard observationTask == nil else { return }
        let pool = database.pool
        observationTask = Task { [weak self] in
            do {
                let changes = ValueObservation.tracking { db in
                    try AnalysisQueueStateRecord.fetchOne(
                        db, key: AnalysisQueueStateRecord.singletonID
                    )
                }
                for try await record in changes.values(in: pool) {
                    guard let self, !Task.isCancelled else { return }
                    if let record, record.isPaused, let reason = record.reason {
                        self.state = .paused(reason: reason)
                    } else {
                        self.state = .running
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// O "Tentar de novo" da barra lateral, ligado ao coordenador de verdade.
    public func retry() async {
        await coordinator.resumeAfterPause()
    }
}
