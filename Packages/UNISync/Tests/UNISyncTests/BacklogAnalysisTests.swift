import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// A ação explícita de analisar o que já estava na caixa.
///
/// A prova que importa é uma: sem o clique de confirmação, nada sai deste
/// Mac; com ele, saem exatamente as mensagens que o diálogo contou.
@Suite("Analisar as mensagens já recebidas")
struct BacklogAnalysisTests {
    private let conta = Account(
        id: "conta-a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )

    /// O clique no opt-in. Tudo que está no banco chegou antes dele.
    private let clique = Date(timeIntervalSince1970: 1_900_000_000)

    private func banco(mensagens: Int = 3) throws -> SyncDatabase {
        let database = try SyncDatabase.temporary()
        try database.pool.write { db in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(db)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Entrada"
            ).insert(db)
            for indice in 0..<mensagens {
                let id = "m\(indice)"
                let mensagem = Message(
                    id: id, accountID: "conta-a",
                    from: Contact(name: "Marina", address: "marina@cliente.com"),
                    receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(indice)),
                    subject: "Antiga \(indice)", snippet: "trecho",
                    body: ["Corpo da mensagem \(indice)."],
                    tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil
                )
                try MessageRecord(
                    mensagem, folderID: "conta-a/INBOX",
                    firstSeenAt: Date(timeIntervalSince1970: 1_800_000_000)
                ).insert(db)
                var corpo = MessageBodyRecord(
                    messageID: id, paragraphs: ["Corpo da mensagem \(indice)."]
                )
                try corpo.insert(db)
            }
        }
        return database
    }

    private func settings() throws -> AssistantSettingsStore {
        let suite = "okamiuni.backlog.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try store.save(.init(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://api.example.com/v1", model: "m",
                credentialID: "primary", authenticationMode: .apiKey
            ),
            automaticAnalysis: .configuredProvider,
            automaticAnalysisSince: clique
        ))
        return store
    }

    private func coordinator(
        _ database: SyncDatabase,
        _ settingsStore: AssistantSettingsStore,
        _ service: BacklogAnalysisService,
        onDevice: SpyMessageAnalyzer,
        configured: SpyMessageAnalyzer
    ) -> MessageIntelligenceCoordinator {
        MessageIntelligenceCoordinator(
            database: database,
            analyzer: RoutedMessageAnalyzer(
                settingsStore: settingsStore,
                onDevice: onDevice,
                configured: configured,
                backlogConsent: { service.covers(messageID: $0) }
            )
        )
    }

    @Test("o plano conta as mensagens guardadas e nomeia o destino")
    func planCountsAndNames() throws {
        let database = try banco()
        let service = BacklogAnalysisService(
            database: database, settingsStore: try settings()
        )
        let plano = try service.plan()
        #expect(plano.count == 3)
        #expect(plano.destination.label == "API · api.example.com")
        #expect(plano.confirmationText
            == "Isto envia 3 mensagens (assunto e corpo) para API · api.example.com. Continuar?")
        #expect(BacklogAnalysisPlan.actionTitle == "Analisar as mensagens já recebidas")
        #expect(BacklogAnalysisPlan.confirmTitle == "Analisar")
        #expect(BacklogAnalysisPlan.cancelTitle == "Cancelar")
    }

    @Test("com a rota neste Mac o plano é vazio: não há para onde mandar")
    func planIsEmptyWithoutRemoteRoute() throws {
        let database = try banco()
        let suite = "okamiuni.backlog.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try store.save(.init(automaticAnalysis: .onDeviceOnly))
        #expect(try BacklogAnalysisService(database: database, settingsStore: store)
            .plan().isEmpty)
    }

    @Test("cancelar não manda nada: o acervo continua sendo analisado neste Mac")
    func cancelSendsNothing() async throws {
        let database = try banco()
        let settingsStore = try settings()
        let service = BacklogAnalysisService(database: database, settingsStore: settingsStore)
        let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
        let configured = SpyMessageAnalyzer(modelVersion: "remoto")

        // O plano é montado — a pessoa viu o diálogo — e nada é aprovado.
        let plano = try service.plan()
        #expect(plano.count == 3)

        let coordinator = coordinator(
            database, settingsStore, service, onDevice: onDevice, configured: configured
        )
        _ = await coordinator.processPending()

        #expect(configured.subjects.isEmpty)
        #expect(onDevice.subjects.count == 3)
    }

    @Test("confirmar manda exatamente as mensagens que o diálogo contou")
    func confirmSendsExactlyTheCountedMessages() async throws {
        let database = try banco()
        let settingsStore = try settings()
        let service = BacklogAnalysisService(database: database, settingsStore: settingsStore)
        let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
        let configured = SpyMessageAnalyzer(modelVersion: "remoto")

        let plano = try service.plan()
        try service.approve(plano)

        let coordinator = coordinator(
            database, settingsStore, service, onDevice: onDevice, configured: configured
        )
        _ = await coordinator.processPending()

        #expect(Set(configured.subjects) == ["Antiga 0", "Antiga 1", "Antiga 2"])
        #expect(configured.subjects.count == plano.count)
        #expect(onDevice.subjects.isEmpty)
    }

    @Test("parar apaga o consentimento e o que sobrou volta para este Mac")
    func stopRevokesConsent() async throws {
        let database = try banco()
        let settingsStore = try settings()
        let service = BacklogAnalysisService(database: database, settingsStore: settingsStore)
        let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
        let configured = SpyMessageAnalyzer(modelVersion: "remoto")

        try service.approve(try service.plan())
        #expect(try service.remainingCount() == 3)
        try service.stop()

        let coordinator = coordinator(
            database, settingsStore, service, onDevice: onDevice, configured: configured
        )
        _ = await coordinator.processPending()
        #expect(configured.subjects.isEmpty)
    }

    @Test("o que o carimbo já cobre fica fora da contagem")
    func alreadyCoveredMessagesAreNotCounted() throws {
        let database = try SyncDatabase.temporary()
        try database.pool.write { db in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(db)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Entrada"
            ).insert(db)
            let nova = Message(
                id: "nova", accountID: "conta-a",
                from: Contact(name: "Marina", address: "marina@cliente.com"),
                receivedAt: self.clique.addingTimeInterval(60),
                subject: "Nova", snippet: "trecho", body: ["Chegou depois do clique."],
                tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil
            )
            try MessageRecord(
                nova, folderID: "conta-a/INBOX",
                firstSeenAt: self.clique.addingTimeInterval(60)
            ).insert(db)
            var corpo = MessageBodyRecord(
                messageID: "nova", paragraphs: ["Chegou depois do clique."]
            )
            try corpo.insert(db)
        }
        let service = BacklogAnalysisService(
            database: database, settingsStore: try settings()
        )
        #expect(try service.plan().isEmpty)
    }
}
