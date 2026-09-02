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
    private let analyzer: any MessageAnalyzing
    private let queueStateStore: AnalysisQueueStateStore
    private let timeZone: @Sendable () -> TimeZone
    /// Falhas de ambiente seguidas. Zera em qualquer sucesso.
    private var consecutivePolicyFailures = 0
    private var observationTask: Task<Void, Never>?
    /// A mensagem que a pessoa está lendo fura a fila histórica. Guardamos
    /// somente a seleção mais recente: clicar rapidamente em cinco mensagens
    /// não deve obrigar o modelo a resumir quatro telas que já ficaram para trás.
    private var priorityMessageID: String?
    /// `actor` é reentrante durante a geração. Esta guarda preserva um único
    /// worker mesmo quando a observação do banco e a seleção acordam juntas.
    private var isProcessing = false

    /// Três seguidas. Uma falha é ruído de rede; três é configuração errada,
    /// e insistir manda a caixa inteira para um endpoint que recusa.
    public static let failuresBeforePause = 3

    private static let log = Logger(
        subsystem: "com.okamiops.okamiuni",
        category: "MessageIntelligence"
    )

    public init(
        database: SyncDatabase,
        analyzer: any MessageAnalyzing,
        timeZone: @Sendable @escaping () -> TimeZone = { .current }
    ) {
        self.database = database
        self.store = MessageIntelligenceStore(database: database)
        self.queueStateStore = AnalysisQueueStateStore(database: database)
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

    /// Coloca a mensagem aberta na frente do backlog sem cancelar a inferência
    /// já em andamento. Se o worker estiver ocioso, este próprio pedido o
    /// acorda; se estiver ocupado, a prioridade é relida antes do próximo item.
    public func prioritize(messageID: String) async {
        guard !messageID.isEmpty else { return }
        priorityMessageID = messageID
        guard !isProcessing else { return }
        _ = await processPending()
    }

    /// Processa um lote pequeno. É público para permitir uma prova
    /// determinística da integração sem depender do agendamento de uma View.
    /// A observação coalesce as escritas do lote e chama outro quando ainda há
    /// trabalho, portanto o limite contém o uso de memória sem deixar fila.
    @discardableResult
    public func processPending(limit: Int = 20) async -> Int {
        guard limit > 0, !isProcessing else { return 0 }
        // Fila pausada não anda sozinha, e não cai para o motor local: só o
        // "Tentar de novo" da lateral a destrava.
        guard case .running = queueState() else { return 0 }
        isProcessing = true
        defer { isProcessing = false }
        guard await analyzer.availability() == .available else { return 0 }

        var completed = 0
        for _ in 0..<limit {
            if Task.isCancelled { break }

            let work: MessageIntelligenceWork
            do {
                guard let next = try store.pendingWork(
                    limit: 1,
                    modelVersion: analyzer.modelVersion,
                    acceptedModelVersions: analyzer.acceptedModelVersions,
                    priorityMessageID: priorityMessageID
                ).first else { break }
                work = next
            } catch {
                Self.log.error("Não foi possível ler a fila de inteligência: \(error)")
                break
            }

            do {
                guard try store.markProcessing(
                    work,
                    modelVersion: analyzer.modelVersion,
                    acceptedModelVersions: analyzer.acceptedModelVersions
                ) else { continue }
                if priorityMessageID == work.messageID {
                    priorityMessageID = nil
                }

                let sender = work.fromName.isEmpty
                    ? work.fromAddress
                    : "\(work.fromName) <\(work.fromAddress)>"
                let result = try await analyzer.analyze(
                    MessageAnalysisInput(
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
                    detectedEventJSON: MessageRecord.encodeDetectedEvent(result.detectedEvent),
                    category: result.category
                )
                if saved { completed += 1 }
                consecutivePolicyFailures = 0
            } catch is CancellationError {
                break
            } catch MessageAnalysisError.unavailable {
                // O estado `processing` é retomável na próxima abertura ou
                // mudança do banco. Marcar como falha tornaria uma condição
                // global temporária permanente para esta mensagem.
                break
            } catch {
                if Self.isEnvironmentFailure(error) {
                    consecutivePolicyFailures += 1
                    // O estado `processing` desta mensagem é retomável; ela não
                    // é marcada como falha porque o defeito não é dela.
                    if consecutivePolicyFailures >= Self.failuresBeforePause {
                        let reason = (error as? any LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        try? queueStateStore.pause(reason: reason, at: Date())
                        Self.log.error("Fila de análise pausada: \(reason, privacy: .public)")
                        break
                    }
                    continue
                }
                consecutivePolicyFailures = 0
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

    /// O que a lateral mostra. `try?` porque um banco que não responde não
    /// pode transformar a barra numa tela de erro: a fila segue como corrente.
    public func queueState() -> AnalysisQueueState {
        (try? queueStateStore.state()) ?? .running
    }

    /// "Tentar de novo" da barra lateral. Zera o contador e destrava a fila.
    public func resumeAfterPause() async {
        try? queueStateStore.resume()
        consecutivePolicyFailures = 0
        _ = await processPending()
    }

    /// Auth e rede são condições **do ambiente**, não da mensagem: marcar a
    /// mensagem como falha tornaria permanente uma chave que ainda vai ser
    /// corrigida em Ajustes.
    static func isEnvironmentFailure(_ error: any Error) -> Bool {
        switch error {
        case let error as OpenAICompatibleTextAssistantError:
            switch error {
            case .missingAPIKey, .missingOAuthAuthorization, .oauthProviderUnavailable,
                 .authenticationFailed, .rateLimited, .timedOut, .connectionFailed, .server:
                return true
            case .invalidResponse:
                return false
            }
        case let error as AssistantProviderOAuthTextAssistantError:
            switch error {
            case .missingAuthorization, .authenticationFailed, .subscriptionNotEligible,
                 .rateLimited, .timedOut, .connectionFailed, .redirectRefused,
                 .upgradeRequired, .server, .managedByCodexRuntime:
                return true
            case .invalidResponse:
                return false
            }
        case let error as AssistantCLITextAssistantError:
            switch error {
            case .executableNotFound, .executableNotAllowed, .processFailed, .timedOut:
                return true
            case .outputTooLarge, .invalidResponse:
                return false
            }
        case is AssistantProviderOAuthError:
            return true
        case let error as URLError:
            return error.code != .cancelled
        default:
            return false
        }
    }
}
