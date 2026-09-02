import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("O ciclo de inteligência local")
struct MessageIntelligenceCoordinatorTests {
    private let timeZone = TimeZone(identifier: "America/Sao_Paulo")!

    private func database() throws -> SyncDatabase {
        let database = try SyncDatabase.temporary()
        try database.pool.write { db in
            try AccountRecord(
                Account(
                    id: "a", address: "eu@example.com", displayName: "Eu",
                    provider: .imap, host: "example.com",
                    tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
                ),
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(db)
            try FolderRecord(
                id: "a/INBOX", accountID: "a", serverName: "INBOX",
                role: .inbox, displayName: "Entrada"
            ).insert(db)
            let message = Message(
                id: "m", accountID: "a",
                from: Contact(name: "Marina", address: "marina@example.com"),
                receivedAt: Date(timeIntervalSince1970: 1_788_000_000),
                subject: "Revisão", snippet: "Falamos amanhã",
                body: ["Falamos amanhã às 15h."], tags: [], bucket: .today,
                isRead: false, summary: nil, detectedEvent: nil
            )
            try MessageRecord(message, folderID: "a/INBOX").insert(db)
            var body = MessageBodyRecord(
                messageID: "m", paragraphs: ["Falamos amanhã às 15h."]
            )
            try body.insert(db)
        }
        return database
    }

    private func insertMessage(
        id: String,
        subject: String,
        receivedAt: Date,
        database: SyncDatabase
    ) throws {
        try database.pool.write { db in
            let message = Message(
                id: id, accountID: "a",
                from: Contact(name: "Marina", address: "marina@example.com"),
                receivedAt: receivedAt,
                subject: subject, snippet: subject,
                body: ["Conteúdo de \(subject)."], tags: [], bucket: .today,
                isRead: false, summary: nil, detectedEvent: nil
            )
            try MessageRecord(message, folderID: "a/INBOX").insert(db)
            var body = MessageBodyRecord(
                messageID: id,
                paragraphs: ["Conteúdo de \(subject)."]
            )
            try body.insert(db)
        }
    }

    @Test("corpo real atravessa motor, banco e fonte da tela uma vez")
    func endToEnd() async throws {
        let database = try database()
        let event = DetectedEvent(
            label: "Revisão",
            start: Date(timeIntervalSince1970: 1_788_084_000),
            duration: 45 * 60
        )
        let analyzer = AnalysisSpy(
            result: MessageAnalysisResult(
                summary: "Marina confirmou a revisão.",
                detectedEvent: event,
                modelVersion: "double-v1",
                category: .primary
            )
        )
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: analyzer,
            timeZone: { self.timeZone }
        )

        #expect(await coordinator.processPending(limit: 1) == 1)
        #expect(await coordinator.processPending(limit: 1) == 0)
        #expect(await analyzer.callCount() == 1)

        let input = try #require(await analyzer.lastInput())
        #expect(input.subject == "Revisão")
        #expect(input.sender == "Marina <marina@example.com>")
        #expect(input.body == "Falamos amanhã às 15h.")
        #expect(input.timeZone == timeZone)

        let messages = try await DatabaseMailSource(database: database).messages()
        let saved = try #require(messages.first)
        #expect(saved.summary == "Marina confirmou a revisão.")
        #expect(saved.detectedEvent == event)
        #expect(saved.category == .primary)
    }

    @Test("modelo indisponível não assume nem marca a mensagem como falha")
    func unavailableLeavesWorkPending() async throws {
        let database = try database()
        let analyzer = AnalysisSpy(
            availability: .appleIntelligenceNotEnabled,
            result: MessageAnalysisResult(
                summary: "não deve rodar", detectedEvent: nil, modelVersion: "double-v1"
            )
        )
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: analyzer,
            timeZone: { self.timeZone }
        )

        #expect(await coordinator.processPending(limit: 1) == 0)
        #expect(await analyzer.callCount() == 0)
        let stateCount = try await database.pool.read { db in
            try MessageIntelligenceRecord.fetchCount(db)
        }
        #expect(stateCount == 0)
        #expect(try MessageIntelligenceStore(database: database).pendingWork().count == 1)
    }

    @Test("o coordenador troca um resumo antigo quando a política do motor muda")
    func newModelVersionReprocessesStoredSummary() async throws {
        let database = try database()
        let store = MessageIntelligenceStore(database: database)
        let old = try #require(try store.pendingWork(modelVersion: "double-v1").first)
        #expect(try store.markProcessing(old, modelVersion: "double-v1"))
        #expect(try store.markCompleted(
            old,
            modelVersion: "double-v1",
            summary: "Mensagem recebida hoje.",
            detectedEventJSON: nil
        ))

        let analyzer = AnalysisSpy(
            modelVersion: "double-v2-tldr",
            result: MessageAnalysisResult(
                summary: "Marina propõe revisar o assunto amanhã às 15h.",
                detectedEvent: nil,
                modelVersion: "double-v2-tldr"
            )
        )
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: analyzer,
            timeZone: { self.timeZone }
        )

        #expect(await coordinator.processPending(limit: 1) == 1)
        #expect(await coordinator.processPending(limit: 1) == 0)
        #expect(await analyzer.callCount() == 1)

        let saved = try #require(try await DatabaseMailSource(database: database).messages().first)
        #expect(saved.summary == "Marina propõe revisar o assunto amanhã às 15h.")
    }

    @Test("três falhas de autenticação seguidas pausam a fila; nada cai para o Mac")
    func threeAuthFailuresPauseTheQueue() async throws {
        let database = try database()
        for index in 2...5 {
            try insertMessage(
                id: "m\(index)", subject: "Assunto \(index)",
                receivedAt: Date(timeIntervalSince1970: 1_788_000_000 + Double(index)),
                database: database
            )
        }
        let analyzer = FailingAnalyzer(error: OpenAICompatibleTextAssistantError.authenticationFailed)
        let coordinator = MessageIntelligenceCoordinator(
            database: database, analyzer: analyzer, timeZone: { self.timeZone }
        )
        _ = await coordinator.processPending()

        #expect(analyzer.calls == MessageIntelligenceCoordinator.failuresBeforePause)
        #expect(await coordinator.queueState() == .paused(
            reason: OpenAICompatibleTextAssistantError.authenticationFailed.errorDescription!
        ))

        // A pausa sobrevive a uma nova instância: ela está no banco.
        let reopened = MessageIntelligenceCoordinator(
            database: database, analyzer: analyzer, timeZone: { self.timeZone }
        )
        #expect(await reopened.processPending() == 0)
        #expect(analyzer.calls == MessageIntelligenceCoordinator.failuresBeforePause)

        await reopened.resumeAfterPause()
        #expect(analyzer.calls > MessageIntelligenceCoordinator.failuresBeforePause)
    }

    @Test("duas falhas de ambiente ainda não pausam nada")
    func twoFailuresDoNotPause() async throws {
        let database = try database()
        let analyzer = FailingAnalyzer(
            error: OpenAICompatibleTextAssistantError.authenticationFailed,
            failuresBeforeSuccess: MessageIntelligenceCoordinator.failuresBeforePause - 1
        )
        let coordinator = MessageIntelligenceCoordinator(
            database: database, analyzer: analyzer, timeZone: { self.timeZone }
        )
        #expect(await coordinator.processPending() == 1)
        #expect(await coordinator.queueState() == .running)
    }

    @Test("JSON inválido é falha da mensagem, não do ambiente: a fila continua")
    func invalidResponseDoesNotPause() async throws {
        let database = try database()
        for index in 2...5 {
            try insertMessage(
                id: "m\(index)", subject: "Assunto \(index)",
                receivedAt: Date(timeIntervalSince1970: 1_788_000_000 + Double(index)),
                database: database
            )
        }
        let analyzer = FailingAnalyzer(
            error: MessageAnalysisError.invalidResponse("O JSON não bate com o contrato pedido.")
        )
        let coordinator = MessageIntelligenceCoordinator(
            database: database, analyzer: analyzer, timeZone: { self.timeZone }
        )
        _ = await coordinator.processPending()

        #expect(await coordinator.queueState() == .running)
        // Cada mensagem foi marcada como falha, uma vez, e a fila esvaziou.
        #expect(analyzer.calls == 5)
        let failed = try await database.pool.read { db in
            try MessageIntelligenceRecord
                .filter(Column("state") == MessageIntelligenceState.failed.rawValue)
                .fetchCount(db)
        }
        #expect(failed == 5)
    }

    @Test("a mensagem selecionada é a próxima depois da geração já iniciada")
    func selectedMessageJumpsTheBacklog() async throws {
        let database = try database()
        try insertMessage(
            id: "m-restante",
            subject: "Restante",
            receivedAt: Date(timeIntervalSince1970: 1_787_999_900),
            database: database
        )
        try insertMessage(
            id: "m-prioridade",
            subject: "Prioridade",
            receivedAt: Date(timeIntervalSince1970: 1_787_999_800),
            database: database
        )
        let analyzer = OrderedBlockingAnalysisSpy()
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: analyzer,
            timeZone: { self.timeZone }
        )

        let background = Task { await coordinator.processPending(limit: 3) }
        await analyzer.waitForFirstCall()
        await coordinator.prioritize(messageID: "m-prioridade")
        await analyzer.releaseFirstCall()

        #expect(await background.value == 3)
        #expect(await analyzer.subjects() == ["Revisão", "Prioridade", "Restante"])
    }
}

private actor AnalysisSpy: MessageAnalyzing {
    nonisolated let modelVersion: String
    private let currentAvailability: AppleIntelligenceAvailability
    private let result: MessageAnalysisResult
    private var inputs: [MessageAnalysisInput] = []

    init(
        modelVersion: String = "double-v1",
        availability: AppleIntelligenceAvailability = .available,
        result: MessageAnalysisResult
    ) {
        self.modelVersion = modelVersion
        self.currentAvailability = availability
        self.result = result
    }

    func availability() async -> AppleIntelligenceAvailability {
        currentAvailability
    }

    func analyze(
        _ input: MessageAnalysisInput
    ) async throws -> MessageAnalysisResult {
        inputs.append(input)
        return result
    }

    func callCount() -> Int { inputs.count }
    func lastInput() -> MessageAnalysisInput? { inputs.last }
}

private actor OrderedBlockingAnalysisSpy: MessageAnalyzing {
    nonisolated let modelVersion = "ordered-v1"
    private var inputs: [MessageAnalysisInput] = []
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    func availability() async -> AppleIntelligenceAvailability { .available }

    func analyze(
        _ input: MessageAnalysisInput
    ) async throws -> MessageAnalysisResult {
        inputs.append(input)
        if inputs.count == 1 {
            await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
        }
        return MessageAnalysisResult(
            summary: "TL;DR de \(input.subject).",
            detectedEvent: nil,
            modelVersion: modelVersion
        )
    }

    func waitForFirstCall() async {
        while inputs.isEmpty { await Task.yield() }
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }

    func subjects() -> [String] { inputs.map(\.subject) }
}

final class FailingAnalyzer: MessageAnalyzing, @unchecked Sendable {
    let modelVersion = "failing/v1"
    private let lock = NSLock()
    private var count = 0
    private let error: any Error
    /// Quantas chamadas falham antes de a primeira dar certo. `nil` = todas.
    private let failuresBeforeSuccess: Int?
    var calls: Int { lock.withLock { count } }

    init(error: any Error, failuresBeforeSuccess: Int? = nil) {
        self.error = error
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func availability() async -> AppleIntelligenceAvailability { .available }

    func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
        let current = lock.withLock { count += 1; return count }
        if let failuresBeforeSuccess, current > failuresBeforeSuccess {
            return .init(
                summary: "Marina confirmou a revisão do orçamento desta semana.",
                detectedEvent: nil,
                modelVersion: modelVersion
            )
        }
        throw error
    }
}
