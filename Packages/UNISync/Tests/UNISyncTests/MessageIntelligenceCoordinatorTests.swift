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

    @Test("corpo real atravessa motor, banco e fonte da tela uma vez")
    func endToEnd() async throws {
        let database = try database()
        let event = DetectedEvent(
            label: "Revisão",
            start: Date(timeIntervalSince1970: 1_788_084_000),
            duration: 45 * 60
        )
        let analyzer = AnalysisSpy(
            result: OnDeviceMessageAnalysisResult(
                summary: "Marina confirmou a revisão.",
                detectedEvent: event,
                modelVersion: "double-v1"
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
    }

    @Test("modelo indisponível não assume nem marca a mensagem como falha")
    func unavailableLeavesWorkPending() async throws {
        let database = try database()
        let analyzer = AnalysisSpy(
            availability: .appleIntelligenceNotEnabled,
            result: OnDeviceMessageAnalysisResult(
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
}

private actor AnalysisSpy: OnDeviceMessageAnalyzing {
    nonisolated let modelVersion = "double-v1"
    private let currentAvailability: OnDeviceMessageAnalysisAvailability
    private let result: OnDeviceMessageAnalysisResult
    private var inputs: [OnDeviceMessageAnalysisInput] = []

    init(
        availability: OnDeviceMessageAnalysisAvailability = .available,
        result: OnDeviceMessageAnalysisResult
    ) {
        self.currentAvailability = availability
        self.result = result
    }

    func availability() async -> OnDeviceMessageAnalysisAvailability {
        currentAvailability
    }

    func analyze(
        _ input: OnDeviceMessageAnalysisInput
    ) async throws -> OnDeviceMessageAnalysisResult {
        inputs.append(input)
        return result
    }

    func callCount() -> Int { inputs.count }
    func lastInput() -> OnDeviceMessageAnalysisInput? { inputs.last }
}
