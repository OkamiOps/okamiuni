import Foundation
import Testing
@testable import UNICore

/// O ranking do dashboard quando existe triagem. As heurísticas por etiqueta
/// continuam valendo para quem ainda não foi analisado; a triagem vence.
@Suite("DashboardFocus com triagem")
struct DashboardFocusTriageTests {

    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a triagem vence a etiqueta: a ordem muda quando a análise discorda")
    func triageBeatsTags() {
        // Pela etiqueta, "etiquetada" iria na frente (+100 de "Precisa
        // resposta"). Pela triagem, ela é só informativa e "triada" é um lead
        // que pede resposta.
        let etiquetada = mail(
            id: "etiquetada",
            tags: [UNICore.Tag(name: "Precisa resposta")],
            isRead: false
        )
        let triada = mail(
            id: "triada",
            isRead: true,
            triage: MessageTriage(needsReply: true, intent: .lead, urgency: .high)
        )
        let rebaixada = mail(
            id: "rebaixada",
            tags: [UNICore.Tag(name: "Precisa resposta")],
            isRead: false,
            triage: MessageTriage(needsReply: false, intent: .informational, urgency: .low)
        )
        let snap = DashboardFocus.snapshot(
            messages: [etiquetada, rebaixada, triada],
            agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.map(\.id) == ["triada", "etiquetada", "rebaixada"])
        #expect(snap.mail.first?.reason == .needsReply)
    }

    @Test("newsletter sem sinalização some; sinalizada entra")
    func newsletterNeedsAMark() {
        let ruido = mail(
            id: "ruido",
            isRead: false,
            triage: MessageTriage(needsReply: false, intent: .newsletter, urgency: .low)
        )
        let recibo = mail(
            id: "recibo",
            isRead: false,
            triage: MessageTriage(needsReply: false, intent: .transactional, urgency: .normal)
        )
        let estrelada = mail(
            id: "estrelada",
            isRead: true,
            isFlagged: true,
            triage: MessageTriage(needsReply: false, intent: .newsletter, urgency: .low)
        )
        let cobrada = mail(
            id: "cobrada",
            isRead: true,
            triage: MessageTriage(needsReply: true, intent: .transactional, urgency: .normal)
        )
        let snap = DashboardFocus.snapshot(
            messages: [ruido, recibo, estrelada, cobrada],
            agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.map(\.id) == ["cobrada", "estrelada"])
    }

    @Test("prazo em 12 h fica acima de prazo em 5 dias")
    func nearerDeadlineWins() {
        let logo = mail(
            id: "logo",
            isRead: true,
            triage: triagemComPrazo(horas: 12)
        )
        let longe = mail(
            id: "longe",
            isRead: true,
            triage: triagemComPrazo(horas: 24 * 5)
        )
        let meio = mail(
            id: "meio",
            isRead: true,
            triage: triagemComPrazo(horas: 48)
        )
        let snap = DashboardFocus.snapshot(
            messages: [longe, meio, logo],
            agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.map(\.id) == ["logo", "meio", "longe"])
        #expect(snap.mail.map(\.reason) == [.deadline, .deadline, .deadline])
    }

    @Test("urgência alta desempata sem virar motivo próprio")
    func urgencyIsWeightNotReason() {
        let urgente = mail(
            id: "urgente",
            isRead: true,
            triage: MessageTriage(needsReply: false, intent: .request, urgency: .high)
        )
        let calma = mail(
            id: "calma",
            isRead: true,
            triage: MessageTriage(needsReply: false, intent: .request, urgency: .normal)
        )
        let snap = DashboardFocus.snapshot(
            messages: [calma, urgente], agenda: [], pending: [], nowMinute: 720, now: agora
        )
        // Urgência sozinha não é motivo: quem não tem motivo cai no recorte de
        // hoje, e lá as duas empatam pela data.
        #expect(snap.mail.map(\.reason).allSatisfy { $0 == .today })
    }

    @Test("urgência alta desempata dois leads, contra a data")
    func urgencyBreaksTheTie() {
        // O mais recente ganharia o desempate por data; a urgência alta o
        // ultrapassa. Sem os 20 pontos, a ordem seria a inversa.
        let urgente = mail(
            id: "urgente",
            isRead: true,
            receivedAt: Fixtures.today.addingTimeInterval(-3_600),
            triage: MessageTriage(needsReply: false, intent: .lead, urgency: .high)
        )
        let recente = mail(
            id: "recente",
            isRead: true,
            receivedAt: Fixtures.today,
            triage: MessageTriage(needsReply: false, intent: .lead, urgency: .normal)
        )
        let snap = DashboardFocus.snapshot(
            messages: [recente, urgente], agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.map(\.id) == ["urgente", "recente"])
    }

    @Test("lead triado entra sem etiqueta nenhuma")
    func leadWithoutTags() {
        let lead = mail(
            id: "lead",
            isRead: true,
            triage: MessageTriage(needsReply: false, intent: .lead, urgency: .normal)
        )
        let snap = DashboardFocus.snapshot(
            messages: [lead], agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.map(\.id) == ["lead"])
        #expect(snap.mail.first?.reason == .lead)
    }

    @Test("sem triagem, a heurística por etiqueta continua inteira")
    func untriagedKeepsTagHeuristics() {
        let snap = DashboardFocus.snapshot(
            messages: Fixtures.messages,
            agenda: Fixtures.agenda,
            pending: Fixtures.pendingItems,
            nowMinute: Fixtures.nowMinute,
            now: agora
        )
        #expect(snap.mail.map(\.id) == ["m6", "m1", "m4", "m2", "m3"])
    }

    private func triagemComPrazo(horas: Double) -> MessageTriage {
        MessageTriage(
            needsReply: false,
            intent: .request,
            urgency: .normal,
            deadline: DetectedDeadline(
                date: agora.addingTimeInterval(horas * 3_600),
                evidence: "até lá"
            )
        )
    }

    private func mail(
        id: String,
        bucket: TriageBucket = .today,
        tags: [UNICore.Tag] = [],
        isRead: Bool,
        isFlagged: Bool = false,
        category: MailCategory? = nil,
        receivedAt: Date = Fixtures.today,
        triage: MessageTriage? = nil
    ) -> Message {
        Message(
            id: id, accountID: "a",
            from: Contact(name: "Quem", address: "quem@exemplo.com"),
            receivedAt: receivedAt,
            subject: id, snippet: id, body: [],
            tags: tags, bucket: bucket, isRead: isRead,
            summary: nil, detectedEvent: nil, category: category,
            triage: triage,
            isFlagged: isFlagged
        )
    }
}
