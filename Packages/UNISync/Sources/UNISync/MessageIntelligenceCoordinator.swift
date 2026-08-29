import Foundation
import GRDB
import UNICore
import os

/// Liga a fila SQLite ao modelo local, uma mensagem por vez.
///
/// O disparo vem de `ValueObservation`: corpo novo ou alterado acorda o ciclo
/// imediatamente, sem polling e sem fiação espalhada pelos sincronizadores.
/// O ator serializa as gerações porque duas sessões concorrentes só disputariam
/// memória e poderiam concluir fora de ordem sobre a mesma mensagem.
public actor MessageIntelligenceCoordinator {
    private let database: SyncDatabase
    private let store: MessageIntelligenceStore
    private let analyzer: any OnDeviceMessageAnalyzing
    private let timeZone: @Sendable () -> TimeZone
    private var observationTask: Task<Void, Never>?

    private static let log = Logger(
        subsystem: "com.okamiops.okamiuni",
        category: "MessageIntelligence"
    )

    public init(
        database: SyncDatabase,
        analyzer: any OnDeviceMessageAnalyzing,
        timeZone: @Sendable @escaping () -> TimeZone = { .current }
    ) {
        self.database = database
        self.store = MessageIntelligenceStore(database: database)
        self.analyzer = analyzer
        self.timeZone = timeZone
    }

    /// Começa a observar corpos disponíveis. Idempotente: a composição pode
    /// chamar uma vez sem precisar coordenar o ciclo de vida da primeira tela.
    public func start() {
        guard observationTask == nil else { return }
        let pool = database.pool
        observationTask = Task { [weak self] in
            do {
                let changes = ValueObservation.tracking { db in
                    try MessageBodyRecord.fetchCount(db)
                        &+ MessageIntelligenceRecord.fetchCount(db)
                }
                for try await _ in changes.values(
                    in: pool,
                    bufferingPolicy: .bufferingNewest(1)
                ) {
                    guard let self, !Task.isCancelled else { return }
                    _ = await self.processPending()
                }
            } catch is CancellationError {
                return
            } catch {
                Self.log.error("Observação da inteligência local terminou: \(error)")
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Processa um lote pequeno. É público para permitir uma prova
    /// determinística da integração sem depender do agendamento de uma View.
    /// A observação coalesce as escritas do lote e chama outro quando ainda há
    /// trabalho, portanto o limite contém o uso de memória sem deixar fila.
    @discardableResult
    public func processPending(limit: Int = 20) async -> Int {
        guard limit > 0, await analyzer.availability() == .available else { return 0 }

        let works: [MessageIntelligenceWork]
        do {
            works = try store.pendingWork(limit: limit)
        } catch {
            Self.log.error("Não foi possível ler a fila de inteligência: \(error)")
            return 0
        }

        var completed = 0
        for work in works {
            if Task.isCancelled { break }
            do {
                guard try store.markProcessing(
                    work,
                    modelVersion: analyzer.modelVersion
                ) else { continue }

                let sender = work.fromName.isEmpty
                    ? work.fromAddress
                    : "\(work.fromName) <\(work.fromAddress)>"
                let result = try await analyzer.analyze(
                    OnDeviceMessageAnalysisInput(
                        subject: work.subject,
                        sender: sender,
                        receivedAt: work.receivedAt,
                        body: work.plainBody,
                        timeZone: timeZone()
                    )
                )
                let saved = try store.markCompleted(
                    work,
                    modelVersion: result.modelVersion,
                    summary: result.summary,
                    detectedEventJSON: MessageRecord.encodeDetectedEvent(result.detectedEvent)
                )
                if saved { completed += 1 }
            } catch is CancellationError {
                break
            } catch OnDeviceMessageAnalysisError.unavailable {
                // O estado `processing` é retomável na próxima abertura ou
                // mudança do banco. Marcar como falha tornaria uma condição
                // global temporária permanente para esta mensagem.
                break
            } catch {
                do {
                    _ = try store.markFailed(
                        work,
                        modelVersion: analyzer.modelVersion,
                        error: error.localizedDescription
                    )
                } catch {
                    Self.log.error("Não foi possível registrar falha da inteligência: \(error)")
                }
            }
        }
        return completed
    }
}
