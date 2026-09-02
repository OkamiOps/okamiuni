import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Espião próprio desta suíte. O de `AssistantConversationTests` é privado
/// daquele arquivo — duas suítes não partilham espião por acidente.
private final class DashboardSpyAssistant: TextAssisting, @unchecked Sendable {
    struct TransformCall: Equatable {
        let text: String
        let action: WritingAction
    }

    let modelVersion = "spy/dashboard"
    var answerResult: Result<String, any Error> = .success("resposta")
    var transformResult: Result<String, any Error> = .success("Oi Marina,\n\nFechado.")
    private(set) var answers: [AssistantConversationSnapshot] = []
    private(set) var transforms: [TransformCall] = []

    func availability() async -> AppleIntelligenceAvailability { .available }

    func answer(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> String {
        answers.append(conversation)
        return try answerResult.get()
    }

    func transform(
        _ text: String,
        using action: WritingAction,
        context: AssistantMailContext?
    ) async throws -> String {
        transforms.append(.init(text: text, action: action))
        return try transformResult.get()
    }
}

@Suite("Dashboard")
@MainActor
struct DashboardScreenTests {

    /// Conversa que não fala com ninguém: as capturas do recorte não podem
    /// depender de provedor, e o dashboard não dispara nada sozinho.
    private func inertConversation(scope: AssistantScope = .email) -> AssistantConversation {
        AssistantConversation(
            scope: scope,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .unconfigured,
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
        )
    }

    private func spiedConversation(
        _ spy: DashboardSpyAssistant,
        mail: Message
    ) -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: mail.subject, sender: mail.from.display),
            destination: .init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true),
            engine: AssistantBridge.engine(
                using: spy,
                supportsDraftReply: true,
                mailContext: { AssistantMailContext(message: mail) }
            )
        )
    }

    @Test("o recorte das fixtures cabe na tela sem disparar a IA")
    func rendersFocusFromFixtures() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let image = try #require(Render.snapshot(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: inertConversation()
            )
            .environment(ThemeStore()),
            named: "dashboard-fixtures",
            size: CGSize(width: 1_200, height: 820),
            theme: .okami
        ))
        #expect(image.pixelsWide == 1_200)
        #expect(image.pixelsHigh == 820)
    }

    @Test("vazio ensina a ir para as outras abas")
    func rendersEmptyState() async throws {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: [])
        )
        await store.load()
        let image = try #require(Render.snapshot(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: inertConversation(scope: .workspace)
            )
            .environment(ThemeStore()),
            named: "dashboard-vazio",
            size: CGSize(width: 1_200, height: 820),
            theme: .okami
        ))
        #expect(image.pixelsWide == 1_200)
        #expect(image.pixelsHigh == 820)
    }

    @Test("a pergunta do briefing é a fixa da conversa, não uma cópia do dashboard")
    func briefingQuestionBelongsToTheConversation() {
        #expect(AssistantConversation.briefingQuestion.contains("briefing do meu dia"))
    }

    @Test("clicar o email abre a leitura por cima, sem trocar de aba")
    func rendersMailSheetOverDashboard() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let id = try #require(store.messages.first?.id)
        let reading = Binding<String?>.constant(id)
        let image = try #require(Render.snapshot(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: inertConversation(),
                readingMailID: reading
            )
            .environment(ThemeStore()),
            named: "dashboard-leitura",
            size: CGSize(width: 1_200, height: 820),
            theme: .okami
        ))
        #expect(image.pixelsWide == 1_200)
        #expect(image.pixelsHigh == 820)
    }

    @Test("\"Gerar rascunho\" chama draftReply(), não ask()")
    func draftButtonUsesDraftReply() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let spy = DashboardSpyAssistant()
        let mail = try #require(store.dashboardFocus(nowMinute: Fixtures.nowMinute).mail.first)
        let conversation = spiedConversation(spy, mail: mail.message)
        conversation.draftReply()
        await conversation.waitForIdle()

        #expect(spy.transforms.map(\.action) == [.draftReply])
        #expect(spy.answers.isEmpty)
        #expect(conversation.messages.last?.kind == .draft)
    }

    @Test("o botão do dashboard leva ao rascunho, não à pergunta analítica")
    func draftButtonClickReachesDraftReply() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let spy = DashboardSpyAssistant()
        let mail = try #require(store.dashboardFocus(nowMinute: Fixtures.nowMinute).mail.first)
        let conversation = spiedConversation(spy, mail: mail.message)

        CliqueDeEnsaio.em(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: conversation
            )
            .environment(ThemeStore()),
            size: CGSize(width: 1_200, height: 820),
            aY: 112,
            x: 1_110
        )
        await conversation.waitForIdle()

        #expect(spy.transforms.map(\.action) == [.draftReply])
        #expect(spy.answers.isEmpty)
    }

    @Test("o dashboard não tem mais máquina de estado própria")
    func dashboardHasNoOwnStateMachine() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/UNIShell/Inbox/DashboardScreen.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("private func run("))
        #expect(!source.contains("private func runDraft("))
        #expect(!source.contains("private func runSuggestion("))
        #expect(!source.contains("@State private var loading"))
        #expect(!source.contains("@State private var errorMessage"))
    }
}
