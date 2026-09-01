import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Dashboard")
@MainActor
struct DashboardScreenTests {

    @Test("o recorte das fixtures cabe na tela sem disparar a IA")
    func rendersFocusFromFixtures() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let image = try #require(Render.snapshot(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today
            )
            .environment(ThemeStore()),
            named: "dashboard-fixtures",
            size: CGSize(width: 1_200, height: 820),
            theme: .okami
        ))
        #expect(image.pixelsWide == 1_200)
        #expect(image.pixelsHigh == 820)
        #expect(DashboardScreen.briefingQuestion.contains("prioridades"))
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
                today: Fixtures.today
            )
            .environment(ThemeStore()),
            named: "dashboard-vazio",
            size: CGSize(width: 1_200, height: 820),
            theme: .okami
        ))
        #expect(image.pixelsWide == 1_200)
        #expect(image.pixelsHigh == 820)
    }

    @Test("a pergunta da IA é a de prioridades, não um disparo ao abrir")
    func briefingQuestionIsPriorities() {
        #expect(
            DashboardScreen.briefingQuestion
                == "Quais são minhas prioridades agora considerando e-mails e agenda? Entregue só o que precisa de mim hoje, em poucas linhas."
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
}
