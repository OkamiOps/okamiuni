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

    /// A conversa do dashboard como o `InboxScreen` a monta: o escopo é
    /// resolvido na hora, a partir do email **selecionado**.
    private func dashboardConversation(
        _ spy: DashboardSpyAssistant,
        store: MailStore,
        selected: Message?
    ) -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true),
            engine: AssistantBridge.engine(
                using: spy,
                supportsDraftReply: true,
                mailContext: {
                    guard let selected else { return AssistantMailContext(workspace: store) }
                    return AssistantMailContext(message: selected)
                }
            )
        )
    }

    /// O centro da cápsula do CTA no recorte de 1200×820.
    private static let ctaPoint = (x: CGFloat(1_110), y: CGFloat(112))
    private static let dashboardSize = CGSize(width: 1_200, height: 820)

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
        #expect(
            AssistantConversation.briefingQuestion == """
                Faça um briefing do meu dia em até 120 palavras: o que exige \
                resposta hoje, os compromissos de hoje em ordem, e o que pode \
                esperar. Cite remetentes e horários.
                """
        )
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

    @Test("com email selecionado o CTA rascunha, não pergunta")
    func draftButtonClickReachesDraftReply() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let spy = DashboardSpyAssistant()
        let mail = try #require(store.dashboardFocus(nowMinute: Fixtures.nowMinute).mail.first)
        let conversation = dashboardConversation(spy, store: store, selected: mail.message)

        CliqueDeEnsaio.em(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: conversation,
                selectedMailID: .constant(mail.id)
            )
            .environment(ThemeStore()),
            size: Self.dashboardSize,
            aY: Self.ctaPoint.y,
            x: Self.ctaPoint.x
        )
        await conversation.waitForIdle()

        #expect(spy.transforms.map(\.action) == [.draftReply])
        #expect(spy.answers.isEmpty)
    }

    @Test("sem email selecionado o CTA pede briefing, e nunca rascunho")
    func ctaWithoutSelectionAsksForBriefing() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let spy = DashboardSpyAssistant()
        let conversation = dashboardConversation(spy, store: store, selected: nil)

        CliqueDeEnsaio.em(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: conversation
            )
            .environment(ThemeStore()),
            size: Self.dashboardSize,
            aY: Self.ctaPoint.y,
            x: Self.ctaPoint.x
        )
        await conversation.waitForIdle()

        // Briefing sai por `answer`, com a pergunta fixa da §2.5, e o
        // contexto é o ambiente — não um email que ninguém escolheu.
        #expect(spy.transforms.isEmpty)
        #expect(spy.answers.count == 1)
        #expect(conversation.briefingText == "resposta")
        #expect(conversation.messages.isEmpty)
        #expect(conversation.failure == nil)
        if case .workspace = try #require(spy.answers.first?.mailContext) {} else {
            Issue.record("O briefing pediu contexto de email sem email selecionado")
        }
    }

    @Test("o rótulo do CTA segue a seleção, e não o topo da lista")
    func ctaLabelFollowsSelection() {
        #expect(DashboardScreen.ctaDraftsReply(canDraftReply: true, hasSelectedMail: true))
        #expect(!DashboardScreen.ctaDraftsReply(canDraftReply: true, hasSelectedMail: false))
        #expect(!DashboardScreen.ctaDraftsReply(canDraftReply: false, hasSelectedMail: true))
        #expect(DashboardScreen.ctaTitle(draftsReply: true) == "Gerar rascunho")
        #expect(DashboardScreen.ctaTitle(draftsReply: false) == "Gerar briefing")
    }

    @Test("rascunho no transcript sai literal, sem Markdown")
    func draftTurnIsNotRenderedAsMarkdown() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let text = "Oi Marina,\n\n**Fechado** para terça.\n\n- item um\n- item dois"

        func bitmap(kind: AssistantTurnKind) throws -> NSBitmapImageRep {
            let conversation = AssistantConversation(
                scope: .email,
                context: .init(subject: "Revisão"),
                destination: .unconfigured,
                engine: .unavailable,
                debugState: AssistantPanelDebugState(
                    messages: [.init(speaker: .assistant, text: text, kind: kind)]
                )
            )
            return try #require(Render.bitmap(
                DashboardScreen(
                    store: store,
                    now: Fixtures.nowMinute,
                    today: Fixtures.today,
                    conversation: conversation
                )
                .environment(ThemeStore()),
                size: Self.dashboardSize,
                theme: .okami
            ))
        }

        // O mesmo texto como `.message` passa pelo Markdown: os asteriscos
        // somem e a lista ganha marcador. Como `.draft` fica literal.
        #expect(
            try bitmap(kind: .draft).pixelsDiffering(from: try bitmap(kind: .message)) > 200
        )
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
