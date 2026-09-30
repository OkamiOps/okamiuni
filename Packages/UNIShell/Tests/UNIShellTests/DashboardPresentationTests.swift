import Foundation
import Testing
import UNICore
@testable import UNIShell

@Suite("Dashboard · apresentação das prioridades")
struct DashboardPresentationTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 11))!

    private func mail(_ id: String, daysAgo: Int, flagged: Bool = false, deadline: Int? = nil) -> Message {
        Message(id: id, accountID: "a", from: Contact(name: id, address: "\(id)@example.com"),
            receivedAt: now.addingTimeInterval(-Double(daysAgo) * 86400), subject: id,
            snippet: "Pode revisar?", body: [], tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil,
            triage: .init(needsReply: true, intent: .request, urgency: .normal,
                deadline: deadline.map { .init(date: now.addingTimeInterval(Double($0) * 86400), evidence: "Data expressa") }),
            isFlagged: flagged)
    }

    private func model(_ messages: [Message]) -> PainelDoDiaModelo {
        let focus = DashboardFocus.snapshot(messages: messages, agenda: [], pending: [], nowMinute: 660, now: now)
        let plan = DayPlan.make(focus: focus, drafts: [:], rules: [], agenda: [], filter: .standard, now: now, nowMinute: 660)
        return PainelDoDiaModelo(plan: plan, drafts: [:], pending: [], agenda: [], messages: messages, today: now, nowMinute: 660)
    }

    @Test("as respostas recentes vêm primeiro com data explícita")
    func recentFirstWithDates() {
        let result = model([mail("ontem", daysAgo: 1), mail("hoje", daysAgo: 0), mail("antigo", daysAgo: 31)])
        #expect(result.espera.map(\.id) == ["hoje", "ontem"])
        #expect(result.espera.map(\.recebida) == ["Hoje", "Ontem"])
        #expect(result.espera.allSatisfy { !$0.alerta })
    }

    @Test("estrela antiga fica sinalizada e o prazo expirado não entra no radar")
    func flaggedIsNotAnOverdueRequest() {
        let result = model([mail("guardado", daysAgo: 31, flagged: true, deadline: -30)])
        #expect(result.espera.first?.palavra == "Sinalizado")
        #expect(result.espera.first?.alerta == false)
        #expect(result.dinheiro.isEmpty)
    }
}
