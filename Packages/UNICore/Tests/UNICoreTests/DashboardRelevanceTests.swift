import Foundation
import Testing
@testable import UNICore

@Suite("Dashboard · ações atuais")
struct DashboardRelevanceTests {
    private let now = Calendar.current.date(from: DateComponents(
        year: 2026, month: 9, day: 30, hour: 11
    ))!

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now)!
    }

    private func mail(
        _ id: String, age: Int = 0, bucket: TriageBucket = .today,
        flagged: Bool = false, read: Bool = true,
        intent: MessageTriage.Intent = .request, needsReply: Bool = true,
        deadline: Int? = nil, event: DetectedEvent? = nil,
        ics: String? = nil, thread: String? = nil, references: [String] = [],
        marks: BulkMailMarks = []
    ) -> Message {
        Message(id: id, accountID: "a", from: Contact(name: id, address: "\(id)@example.com"),
                receivedAt: day(-age), subject: id, snippet: "Pedido identificado", body: [],
                tags: [], bucket: bucket, isRead: read, summary: nil, detectedEvent: event,
                triage: MessageTriage(needsReply: needsReply, intent: intent, urgency: .normal,
                    deadline: deadline.map { DetectedDeadline(date: day($0), evidence: "Data no email") }),
                isFlagged: flagged, calendarICS: ics, rfcMessageID: "\(id)@example.com",
                references: references, threadKey: thread, bulkMarks: marks)
    }

    private func focus(_ messages: [Message], pending: [PendingItem] = []) -> DashboardFocus {
        DashboardFocus.snapshot(messages: messages, agenda: [], pending: pending,
                                nowMinute: 660, now: now)
    }

    private func plan(_ focus: DashboardFocus) -> DayPlan {
        DayPlan.make(focus: focus, drafts: [:], rules: [], agenda: [],
                     filter: .standard, now: now, nowMinute: 660)
    }

    @Test("pedidos antigos não preenchem o dia nem contam como newsletters")
    func oldRequestsStayInTheInbox() {
        let result = focus([
            mail("old-request", age: 31, read: false),
            mail("old-invite", age: 20, intent: .scheduling),
            mail("expired-notice", age: 31, needsReply: false, deadline: -31),
        ])
        #expect(result.mail.isEmpty)
        #expect(result.discardedMailCount == 0)
        #expect(plan(result).hero == nil)
        #expect(plan(result).replyBlock == nil)
    }

    @Test("a semana recente inclui o limite e não promove o dia anterior")
    func freshnessBoundary() {
        let result = focus([mail("seven", age: 7), mail("eight", age: 8)])
        #expect(result.mail.map(\.id) == ["seven"])
    }

    @Test("fonte antiga com vencimento próximo continua, sem afirmar espera antiga")
    func oldSourceWithUpcomingDeadline() {
        let result = focus([mail("renewal", age: 30, deadline: 1)])
        #expect(result.mail.map(\.id) == ["renewal"])
        #expect(result.mail.first?.reason == .deadline)
        let dayPlan = plan(result)
        #expect(dayPlan.sections.first?.kind == .due)
        #expect(dayPlan.hero == nil)
    }

    @Test("aviso recente vencido ontem sobrevive, prazo histórico não")
    func recentOverdueRequestsRemain() {
        let invoice = mail("invoice", age: 2, needsReply: false, deadline: -1)
        let historic = mail("historic", age: 2, needsReply: false, deadline: -31)
        let result = focus([historic, invoice])
        #expect(result.mail.map(\.id) == ["invoice"])
        #expect(result.mail.first?.reason == .deadline)
        #expect(DashboardFocus.relevantDeadline(for: invoice, now: now)?.date == day(-1))
        #expect(DashboardFocus.relevantDeadline(for: historic, now: now) == nil)
    }

    @Test("encerramento e feedback recentes não viram tarefas vencidas pela data citada")
    func recentCompletedNoticesDoNotBecomeOverdue() {
        let notices = [
            mail("contract-ended", age: 1, intent: .informational, needsReply: false, deadline: -1),
            mail("gave-feedback", age: 1, intent: .informational, needsReply: false, deadline: -1),
            mail("receipt", age: 1, intent: .transactional, needsReply: false, deadline: -1),
            mail("automatic-feedback", age: 1, intent: .informational, deadline: -1,
                 marks: .autoSubmitted),
        ]
        let request = mail("unresolved-request", age: 1, needsReply: false, deadline: -1)
        let replyNeeded = mail("explicit-reply", age: 1, intent: .informational, deadline: -1)
        let result = focus(notices + [request, replyNeeded])
        for notice in notices {
            #expect(DashboardFocus.relevantDeadline(for: notice, now: now) == nil)
        }
        #expect(Set(result.mail.filter { $0.reason == .deadline }.map(\.id))
            == ["unresolved-request", "explicit-reply"])
        #expect(!result.mail.contains { item in
            notices.contains { $0.id == item.id } && item.reason == .deadline
        })
        let overdueRows = plan(result).sections.first { $0.kind == .due }?.rows ?? []
        #expect(overdueRows.map(\.id) == ["unresolved-request"])
    }

    @Test("estrela antiga preserva decisão da pessoa sem inventar prazo ou cobrança")
    func oldFlaggedIsAnExplicitFlag() {
        let result = focus([mail("important", age: 30, flagged: true, intent: .lead, deadline: -20)])
        #expect(result.mail.first?.reason == .flagged)
        let dayPlan = plan(result)
        #expect(dayPlan.hero == nil)
        #expect(!dayPlan.sections.contains { $0.kind == .due || $0.kind == .lead })
        #expect(dayPlan.sections.flatMap(\.rows).map(\.id) == ["important"])
    }

    @Test("estrela explícita sobrevive no plano em avisos, disparos e remetente automático")
    func flaggedNoticesSurviveTheDayPlan() {
        let messages = [
            mail("informational", age: 30, flagged: true, intent: .informational),
            mail("newsletter", flagged: true, intent: .newsletter, needsReply: false),
            mail("bulk-old", age: 30, flagged: true, marks: .listUnsubscribe),
            mail("bulk-recent", flagged: true, intent: .lead, marks: .listUnsubscribe),
            mail("no-reply", age: 30, flagged: true, intent: .informational),
        ]
        let result = focus(messages)
        let dayPlan = plan(result)
        let rows = dayPlan.sections.flatMap(\.rows)
        #expect(Set(rows.map(\.id)) == Set(messages.map(\.id)))
        #expect(rows.allSatisfy { $0.item.reason == .flagged })
        #expect(dayPlan.hero == nil)
        #expect(dayPlan.removed.isEmpty)
        #expect(dayPlan.sections.map(\.kind) == [.waitingOnYou])
    }

    @Test("sinalização preserva a seção de lead real e vencimento atual")
    func flaggedCurrentPrioritiesKeepTheirSections() {
        let result = focus([
            mail("lead", flagged: true, intent: .lead),
            mail("deadline", flagged: true, needsReply: false, deadline: 1,
                 marks: .listUnsubscribe),
        ])
        let dayPlan = plan(result)
        #expect(dayPlan.sections.first { $0.kind == .lead }?.rows.map(\.id) == ["lead"])
        #expect(dayPlan.sections.first { $0.kind == .due }?.rows.map(\.id) == ["deadline"])
    }

    @Test("arquivar, adiar e excluir vencem estrela e prazo mesmo no ranking puro")
    func dismissedStateWins() {
        let messages = [TriageBucket.archived, .later, .trash, .junk, .drafts].map {
            mail($0.rawValue, bucket: $0, flagged: true, deadline: 1)
        }
        #expect(focus(messages).mail.isEmpty)
    }

    @Test("convite cancelado ou encerrado não vira pedido de resposta")
    func closedInvitationsStayOut() {
        let cancelled = """
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        SUMMARY:Reunião
        DTSTART:20261001T100000Z
        STATUS:CANCELLED
        END:VEVENT
        END:VCALENDAR
        """
        let ended = DetectedEvent(label: "Reunião encerrada", start: day(-1), duration: 1800)
        let result = focus([
            mail("cancelled", intent: .scheduling, deadline: 1, ics: cancelled),
            mail("ended", intent: .scheduling, event: ended),
            mail("expired-invitation", intent: .scheduling, deadline: -1),
        ])
        #expect(result.mail.isEmpty)
    }

    @Test("atualização recente de série não é concluída pela primeira ocorrência")
    func recurringInvitationIsNotAssumedEnded() {
        let recurring = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Reunião semanal
        DTSTART:20260901T100000Z
        DTEND:20260901T110000Z
        RRULE:FREQ=WEEKLY
        END:VEVENT
        END:VCALENDAR
        """
        let result = focus([mail("updated-series", intent: .scheduling, ics: recurring)])
        #expect(result.mail.first?.reason == .needsReply)
    }

    @Test("falta de ação atual não usa Hoje para uma mensagem lida ontem")
    func fallbackDateIsTruthful() {
        #expect(focus([mail("yesterday", age: 1, needsReply: false)]).mail.isEmpty)
        #expect(focus([mail("today", needsReply: false)]).mail.first?.reason == .today)
    }

    @Test("resposta resolve a pergunta, mas não a nova mensagem da conversa")
    func answeredEvidenceAndNewQuestion() {
        let old = mail("question", age: 2, thread: "conversation")
        let reply = mail("reply", age: 1, bucket: .sent, thread: "conversation",
                         references: ["question@example.com"])
        let latest = mail("latest", thread: "conversation")
        #expect(focus([old, reply, latest]).mail.map(\.id) == ["latest"])
    }

    @Test("vencimentos não transformam avisos distantes em ações desta semana")
    func deadlineAndPendingHorizon() {
        let result = focus([mail("next-week", age: 30, deadline: 7),
                            mail("later", age: 30, deadline: 8)], pending: [
            PendingItem(id: "expired", text: "Antigo", accountID: "a", dueDate: day(-20)),
            PendingItem(id: "soon", text: "Amanhã", accountID: "a", dueDate: day(1)),
            PendingItem(id: "later", text: "Depois", accountID: "a", dueDate: day(8)),
            PendingItem(id: "undated", text: "Promessa sem data", accountID: "a"),
        ])
        #expect(result.mail.map(\.id) == ["next-week"])
        #expect(result.pending.map(\.id) == ["soon", "undated"])
    }
}
