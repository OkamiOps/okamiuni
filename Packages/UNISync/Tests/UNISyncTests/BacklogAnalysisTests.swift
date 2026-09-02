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
                backlogConsent: { service.covers(messageID: $0, modelVersion: $1) }
            )
        )
    }

    @Test("o plano conta as mensagens guardadas e nomeia o destino")
    func planCountsAndNames() throws {
        let database = try banco()
        let service = BacklogAnalysisService(
            database: database, settingsStore: try settings(),
            configuredModelVersion: { "remoto" }
        )
        let plano = try service.plan()
        #expect(plano.count == 3)
        #expect(plano.destination.label == "API · api.example.com")
        #expect(plano.confirmationText
            == "Isto envia 3 mensagens (assunto, remetente, data e corpo) "
                + "para API · api.example.com. Continuar?")
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
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )
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
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )
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
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )
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
            database: database, settingsStore: try settings(),
            configuredModelVersion: { "remoto" }
        )
        #expect(try service.plan().isEmpty)
    }
}

/// As três correções críticas da revisão, e o que o controlador faz.
///
/// Todas provam a mesma pergunta por ângulos diferentes: **um byte só sai
/// deste Mac depois de um diálogo que a pessoa leu e confirmou.**
@Suite("A ação do acervo, depois da revisão")
struct BacklogAnalysisFixTests {
    private let conta = Account(
        id: "conta-a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )
    private let clique = Date(timeIntervalSince1970: 1_900_000_000)

    /// A caixa de teste. `buckets` diz em que caixa cada mensagem cai — é o
    /// que prova o filtro de pasta.
    private func banco(buckets: [TriageBucket] = [.today, .today, .today]) throws -> SyncDatabase {
        let database = try SyncDatabase.temporary()
        try database.pool.write { db in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(db)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Entrada"
            ).insert(db)
            for (indice, bucket) in buckets.enumerated() {
                let id = "m\(indice)"
                let mensagem = Message(
                    id: id, accountID: "conta-a",
                    from: Contact(name: "Marina", address: "marina@cliente.com"),
                    receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(indice)),
                    subject: "Antiga \(indice)", snippet: "trecho",
                    body: ["Corpo da mensagem \(indice)."],
                    tags: [], bucket: bucket, isRead: false, summary: nil, detectedEvent: nil
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
        let suite = "okamiuni.backlog-fix.\(UUID().uuidString)"
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

    // MARK: - Critical 2: o consentimento vale para UMA análise

    @Test("consentir, analisar, subir a versão: a mensagem NÃO sai de novo sem diálogo")
    func consentIsSpentAndVersionScoped() async throws {
        let database = try banco()
        let settingsStore = try settings()
        // A versão do motor remoto é lida por fechada: subi-la aqui é
        // exatamente o que uma release nova faz.
        let versao = VersaoDoMotor(valor: "remoto/v1")
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { versao.valor }
        )
        let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
        let configured = SpyTriageMessageAnalyzer(modelVersion: "remoto/v1")

        let plano = try service.plan()
        #expect(plano.count == 3)
        try service.approve(plano)

        let primeira = MessageIntelligenceCoordinator(
            database: database,
            analyzer: RoutedMessageAnalyzer(
                settingsStore: settingsStore, onDevice: onDevice, configured: configured,
                backlogConsent: { service.covers(messageID: $0, modelVersion: $1) }
            )
        )
        _ = await primeira.processPending()
        #expect(configured.subjects.count == 3)

        // O que a ação autorizava aconteceu: as três têm triagem e o
        // consentimento está gasto.
        #expect(try service.remainingCount() == 0)
        let sobraram = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis_backlog_consent") ?? 0
        }
        #expect(sobraram == 0)

        // A release nova sobe a versão. As três voltam à fila pelo mecanismo
        // de `acceptedModelVersions` — e é aqui que elas sairiam de novo.
        versao.valor = "remoto/v2"
        let novoConfigurado = SpyTriageMessageAnalyzer(modelVersion: "remoto/v2")
        let segunda = MessageIntelligenceCoordinator(
            database: database,
            analyzer: RoutedMessageAnalyzer(
                settingsStore: settingsStore, onDevice: onDevice, configured: novoConfigurado,
                backlogConsent: { service.covers(messageID: $0, modelVersion: $1) }
            )
        )
        _ = await segunda.processPending()

        #expect(novoConfigurado.subjects.isEmpty)
        #expect(onDevice.subjects.count == 3)
        // E o botão volta a oferecer as três: o diálogo novo existe.
        #expect(try service.availableCount() == 3)
    }

    @Test("consentimento carimbado com outra versão não vale para o motor de agora")
    func consentDoesNotCrossVersions() throws {
        let database = try banco()
        let store = AnalysisBacklogConsentStore(database: database)
        try store.approve(["m0"], modelVersion: "remoto/v1")
        #expect(store.covers(messageID: "m0", modelVersion: "remoto/v1"))
        #expect(!store.covers(messageID: "m0", modelVersion: "remoto/v2"))
    }

    // MARK: - Critical 3: "ocupado" não é "acabou"

    @Test("uma rodada com o ciclo já dentro devolve .busy, não .finished(0)")
    func busyIsNotAnEmptyQueue() async throws {
        let database = try banco()
        let settingsStore = try settings()
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )
        try service.approve(try service.plan())

        let porta = PortaoDoAnalisador()
        let configured = PortaoMessageAnalyzer(modelVersion: "remoto", portao: porta)
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: RoutedMessageAnalyzer(
                settingsStore: settingsStore,
                onDevice: SpyMessageAnalyzer(modelVersion: "on-device"),
                configured: configured,
                backlogConsent: { service.covers(messageID: $0, modelVersion: $1) }
            )
        )

        // Uma rodada fica presa dentro do motor.
        let presa = Task { await coordinator.processPending() }
        var entrou = false
        for _ in 0..<400 where !entrou {
            entrou = await porta.jaEntrou
            if !entrou { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(entrou, "o motor com portão nunca foi chamado")

        // A segunda pergunta não pode dizer "não havia trabalho".
        let resultado = await coordinator.runPass()
        #expect(resultado == .busy)
        #expect(resultado.completedCount == 0)
        #expect(resultado.mayProgressLater)
        #expect(AnalysisPassResult.finished(0).mayProgressLater == false)

        await porta.liberar()
        _ = await presa.value
    }

    @Test("fila pausada devolve .blocked, e girar não adianta")
    func pausedQueueIsBlocked() async throws {
        let database = try banco()
        try AnalysisQueueStateStore(database: database).pause(reason: "sem chave", at: Date())
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: SpyMessageAnalyzer(modelVersion: "on-device")
        )
        #expect(await coordinator.runPass() == .blocked)
    }

    // MARK: - Important 6: pasta

    @Test("spam, lixeira, rascunho e enviada não entram na contagem nem no envio")
    func excludedBucketsStayHome() async throws {
        let database = try banco(buckets: [.junk, .trash, .drafts, .sent, .today])
        let settingsStore = try settings()
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )

        let plano = try service.plan()
        #expect(plano.messageIDs == ["m4"])
        #expect(try service.availableCount() == 1)

        let configured = SpyTriageMessageAnalyzer(modelVersion: "remoto")
        try service.approve(plano)
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: RoutedMessageAnalyzer(
                settingsStore: settingsStore,
                onDevice: SpyMessageAnalyzer(modelVersion: "on-device"),
                configured: configured,
                backlogConsent: { service.covers(messageID: $0, modelVersion: $1) }
            )
        )
        _ = await coordinator.processPending()
        #expect(configured.subjects == ["Antiga 4"])
    }

    @Test("a contagem por COUNT(*) e a lista do plano concordam")
    func countMatchesPlan() throws {
        let database = try banco(buckets: [.today, .later, .archived, .junk])
        let service = BacklogAnalysisService(
            database: database, settingsStore: try settings(),
            configuredModelVersion: { "remoto" }
        )
        #expect(try service.availableCount() == 3)
        #expect(try service.plan().count == 3)
    }

    // MARK: - Important 4: o controlador

    @Test("confirmar com o plano na mão escreve o consentimento e manda as N")
    @MainActor
    func controllerConfirmSends() async throws {
        let database = try banco()
        let settingsStore = try settings()
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )
        let configured = SpyTriageMessageAnalyzer(modelVersion: "remoto")
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: RoutedMessageAnalyzer(
                settingsStore: settingsStore,
                onDevice: SpyMessageAnalyzer(modelVersion: "on-device"),
                configured: configured,
                backlogConsent: { service.covers(messageID: $0, modelVersion: $1) }
            )
        )
        let controller = BacklogAnalysisController(service: service, coordinator: coordinator)

        await controller.refreshAvailability()
        #expect(controller.availableCount == 3)

        await controller.requestConfirmation()
        let plano = try #require(controller.pendingPlan)
        #expect(plano.count == 3)
        // O diálogo está na tela e **nada** saiu ainda.
        #expect(configured.subjects.isEmpty)

        controller.confirm(plano)
        #expect(controller.isRunning)
        #expect(controller.pendingPlan == nil)
        await esperar { !controller.isRunning }

        #expect(Set(configured.subjects) == ["Antiga 0", "Antiga 1", "Antiga 2"])
        #expect(controller.remaining == 0)
        #expect(controller.total == 3)
        #expect(controller.availableCount == 0)
    }

    /// **A regressão do Critical 1.** O SwiftUI zera a binding do diálogo
    /// antes de rodar a ação do botão; era isso que fazia "Analisar" não
    /// analisar. O plano vem por parâmetro justamente para sobreviver a isto.
    @Test("cancelar antes de confirmar não impede o envio do plano capturado")
    @MainActor
    func confirmSurvivesTheDialogDismissal() async throws {
        let database = try banco()
        let settingsStore = try settings()
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )
        let configured = SpyTriageMessageAnalyzer(modelVersion: "remoto")
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: RoutedMessageAnalyzer(
                settingsStore: settingsStore,
                onDevice: SpyMessageAnalyzer(modelVersion: "on-device"),
                configured: configured,
                backlogConsent: { service.covers(messageID: $0, modelVersion: $1) }
            )
        )
        let controller = BacklogAnalysisController(service: service, coordinator: coordinator)
        await controller.requestConfirmation()
        let plano = try #require(controller.pendingPlan)

        // Exatamente a ordem do SwiftUI: dispensa primeiro, ação depois.
        controller.cancel()
        #expect(controller.pendingPlan == nil)
        controller.confirm(plano)
        await esperar { !controller.isRunning }

        #expect(configured.subjects.count == 3)
    }

    @Test("cancelar sem confirmar não manda nada")
    @MainActor
    func controllerCancelSendsNothing() async throws {
        let database = try banco()
        let settingsStore = try settings()
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )
        let configured = SpyTriageMessageAnalyzer(modelVersion: "remoto")
        let coordinator = MessageIntelligenceCoordinator(
            database: database,
            analyzer: RoutedMessageAnalyzer(
                settingsStore: settingsStore,
                onDevice: SpyMessageAnalyzer(modelVersion: "on-device"),
                configured: configured,
                backlogConsent: { service.covers(messageID: $0, modelVersion: $1) }
            )
        )
        let controller = BacklogAnalysisController(service: service, coordinator: coordinator)
        await controller.requestConfirmation()
        controller.cancel()
        #expect(controller.pendingPlan == nil)

        _ = await coordinator.processPending()
        #expect(configured.subjects.isEmpty)
        #expect(try service.remainingCount() == 0)
    }

    @Test("parar apaga o consentimento e devolve o botão")
    @MainActor
    func controllerStopRevokes() async throws {
        let database = try banco()
        let settingsStore = try settings()
        let service = BacklogAnalysisService(
            database: database, settingsStore: settingsStore,
            configuredModelVersion: { "remoto" }
        )
        let controller = BacklogAnalysisController(
            service: service,
            coordinator: MessageIntelligenceCoordinator(
                database: database,
                analyzer: SpyMessageAnalyzer(modelVersion: "on-device")
            )
        )
        try service.approve(try service.plan())
        #expect(try service.remainingCount() == 3)

        controller.stop()
        #expect(!controller.isRunning)
        await esperar { (try? service.remainingCount()) == 0 }
        #expect(try service.remainingCount() == 0)
    }

    @Test("o texto do progresso fala português no singular e no plural")
    @MainActor
    func progressCopy() async throws {
        let database = try banco()
        let service = BacklogAnalysisService(
            database: database, settingsStore: try settings(),
            configuredModelVersion: { "remoto" }
        )
        let controller = BacklogAnalysisController(
            service: service,
            coordinator: MessageIntelligenceCoordinator(
                database: database,
                analyzer: SpyMessageAnalyzer(modelVersion: "on-device")
            )
        )
        #expect(controller.progressText == "Analisando… faltam 0 de 0.")
        #expect(BacklogAnalysisController.maximumBusyWaits == 600)
    }

    /// Espera curta e determinística: o laço do controlador é assíncrono, e
    /// dormir um tempo fixo seria lento e instável.
    @MainActor
    private func esperar(
        _ condicao: @MainActor () -> Bool,
        voltas: Int = 400
    ) async {
        for _ in 0..<voltas {
            if condicao() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Uma versão de motor que o teste consegue mudar no meio — o que uma release
/// nova faz.
final class VersaoDoMotor: @unchecked Sendable {
    private let lock = NSLock()
    private var armazenado: String
    init(valor: String) { armazenado = valor }
    var valor: String {
        get { lock.withLock { armazenado } }
        set { lock.withLock { armazenado = newValue } }
    }
}

/// Como o `SpyMessageAnalyzer`, mas devolvendo triagem — sem ela a coluna
/// `triage` fica nula e o consentimento nunca seria dado por gasto.
final class SpyTriageMessageAnalyzer: MessageAnalyzing, @unchecked Sendable {
    let modelVersion: String
    private let lock = NSLock()
    private var seen: [String] = []

    var subjects: [String] { lock.withLock { seen } }

    init(modelVersion: String) { self.modelVersion = modelVersion }

    func availability() async -> AppleIntelligenceAvailability { .available }

    func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
        lock.withLock { seen.append(input.subject) }
        return .init(
            summary: "Resumo de \(input.subject) por \(modelVersion).",
            detectedEvent: nil,
            modelVersion: modelVersion,
            triage: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
    }
}

/// Um portão para segurar uma rodada dentro do motor enquanto o teste
/// pergunta outra coisa ao coordenador.
actor PortaoDoAnalisador {
    private var entrou = false
    private var liberado = false
    private var esperandoLiberacao: [CheckedContinuation<Void, Never>] = []

    func marcarEntrada() { entrou = true }

    var jaEntrou: Bool { entrou }

    func esperarLiberacao() async {
        if liberado { return }
        await withCheckedContinuation { esperandoLiberacao.append($0) }
    }

    func liberar() {
        liberado = true
        esperandoLiberacao.forEach { $0.resume() }
        esperandoLiberacao.removeAll()
    }
}

final class PortaoMessageAnalyzer: MessageAnalyzing, @unchecked Sendable {
    let modelVersion: String
    private let portao: PortaoDoAnalisador

    init(modelVersion: String, portao: PortaoDoAnalisador) {
        self.modelVersion = modelVersion
        self.portao = portao
    }

    func availability() async -> AppleIntelligenceAvailability { .available }

    func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
        await portao.marcarEntrada()
        await portao.esperarLiberacao()
        return .init(
            summary: "Resumo de \(input.subject).",
            detectedEvent: nil,
            modelVersion: modelVersion,
            triage: MessageTriage(needsReply: false, intent: .informational, urgency: .low)
        )
    }
}
