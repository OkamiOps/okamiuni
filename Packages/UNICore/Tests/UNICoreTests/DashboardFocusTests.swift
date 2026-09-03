import Foundation
import Testing
@testable import UNICore

@Suite("DashboardFocus")
struct DashboardFocusTests {

    @Test("as fixtures deixam só o que pede ação, na ordem da urgência")
    func fixturesKeepActionableMail() {
        let snap = DashboardFocus.snapshot(
            messages: Fixtures.messages,
            agenda: Fixtures.agenda,
            pending: Fixtures.pendingItems,
            nowMinute: Fixtures.nowMinute
        )
        #expect(snap.mail.map(\.id) == ["m6", "m1", "m4", "m2", "m3"])
        // `m6` é lead **e** prazo, e a etiqueta passou a dizer o mais
        // específico dos dois: uma data manda mais do que uma categoria. Ver
        // `DashboardFocus.strongestReason`.
        #expect(snap.mail.map(\.reason) == [.deadline, .needsReply, .needsReply, .deadline, .unread])
        #expect(snap.mail.contains { $0.id == "m5" } == false)
        #expect(snap.mail.contains { $0.id == "m7" } == false)
        #expect(snap.meetings.map(\.id) == ["e3", "e4", "e5"])
        #expect(snap.pending.map(\.id) == ["p1", "p2"])
        #expect(snap.nextUpLabel == "em 30 min: Almoço — bloqueado")
        #expect(snap.omittedMailCount == 0)
        #expect(snap.omittedMeetingCount == 0)
    }

    @Test("lixo, rascunho e enviado não entram mesmo com etiqueta forte")
    func excludedBucketsStayOut() {
        let tagged = [
            mail(id: "junk", bucket: .junk, tags: [UNICore.Tag(name: "Precisa resposta")], isRead: false),
            mail(id: "trash", bucket: .trash, tags: [UNICore.Tag(name: "Lead")], isRead: false),
            mail(id: "draft", bucket: .drafts, tags: [UNICore.Tag(name: "Prazo")], isRead: false),
            mail(id: "sent", bucket: .sent, tags: [UNICore.Tag(name: "Precisa resposta")], isRead: false),
            mail(id: "ok", bucket: .today, tags: [UNICore.Tag(name: "Precisa resposta")], isRead: false),
        ]
        let snap = DashboardFocus.snapshot(
            messages: tagged, agenda: [], pending: [], nowMinute: 720
        )
        #expect(snap.mail.map(\.id) == ["ok"])
    }

    @Test("newsletter cai fora; estrela ou resposta a tira de volta")
    func promotionsNeedAMark() {
        let promo = mail(
            id: "promo",
            bucket: .later,
            tags: [UNICore.Tag(name: "Leitura")],
            isRead: false,
            category: .promotions
        )
        let flagged = mail(
            id: "star",
            bucket: .later,
            tags: [],
            isRead: true,
            isFlagged: true,
            category: .promotions
        )
        let snap = DashboardFocus.snapshot(
            messages: [promo, flagged], agenda: [], pending: [], nowMinute: 720
        )
        #expect(snap.mail.map(\.id) == ["star"])
        #expect(snap.mail.first?.reason == .flagged)
    }

    @Test("recibo arquivado some; prazo ou estrela no arquivo ficam")
    func archivedNeedsAction() {
        let recibo = mail(id: "recibo", bucket: .archived, tags: [UNICore.Tag(name: "Recibo")], isRead: false)
        let prazo = mail(id: "prazo", bucket: .archived, tags: [UNICore.Tag(name: "Prazo")], isRead: true)
        let snap = DashboardFocus.snapshot(
            messages: [recibo, prazo], agenda: [], pending: [], nowMinute: 720
        )
        #expect(snap.mail.map(\.id) == ["prazo"])
        #expect(snap.mail.first?.reason == .deadline)
    }

    @Test("compromisso cancelado e o que já passou não entram")
    func remainingMeetingsOnly() {
        let items = [
            AgendaItem(id: "past", title: "Manhã", startMinute: 540, endMinute: 600, accountID: "a"),
            AgendaItem(id: "now", title: "Agora", startMinute: 700, endMinute: 760, accountID: "a"),
            AgendaItem(id: "next", title: "Tarde", startMinute: 900, endMinute: 960, accountID: "a"),
            AgendaItem(id: "cancel", title: "X", startMinute: 800, endMinute: 860, accountID: "a")
                .markingCancelled(),
            AgendaItem(id: "amanha", title: "Amanhã", startMinute: 600, endMinute: 660,
                       accountID: "a", dayOffset: 1),
        ]
        let snap = DashboardFocus.snapshot(
            messages: [], agenda: items, pending: [], nowMinute: 720
        )
        #expect(snap.meetings.map(\.id) == ["now", "next", "amanha"])
        #expect(snap.nextUpLabel.hasPrefix("agora: Agora"))
    }

    @Test("o teto corta a lista e conta o que ficou de fora")
    func capsAndOmits() {
        let many = (1...10).map { i in
            mail(
                id: "m\(i)",
                bucket: .today,
                tags: [UNICore.Tag(name: "Precisa resposta")],
                isRead: false,
                receivedAt: Fixtures.today.addingTimeInterval(TimeInterval(i))
            )
        }
        let meetings = (1...10).map { i in
            AgendaItem(
                id: "e\(i)", title: "E\(i)",
                startMinute: 800 + i * 10, endMinute: 850 + i * 10,
                accountID: "a"
            )
        }
        let snap = DashboardFocus.snapshot(
            messages: many, agenda: meetings, pending: [], nowMinute: 720
        )
        #expect(snap.mail.count == DashboardFocus.mailLimit)
        #expect(snap.omittedMailCount == 3)
        #expect(snap.mail.first?.id == "m10")
        #expect(snap.meetings.count == DashboardFocus.meetingLimit)
        #expect(snap.omittedMeetingCount == 2)
    }

    @Test("sem etiqueta, a caixa Hoje ainda alimenta o recorte")
    func todayBucketFillsEmptyRanking() {
        let hoje = mail(id: "hoje", bucket: .today, tags: [], isRead: true)
        let snap = DashboardFocus.snapshot(
            messages: [hoje], agenda: [], pending: [], nowMinute: 720
        )
        #expect(snap.mail.map(\.id) == ["hoje"])
        #expect(snap.mail.first?.reason == .today)
    }

    @Test("resposta e prazo são Alta; o resto é Média")
    func rankLabels() {
        #expect(DashboardFocus.Reason.needsReply.rankLabel == "Alta")
        #expect(DashboardFocus.Reason.deadline.rankLabel == "Alta")
        #expect(DashboardFocus.Reason.unread.rankLabel == "Média")
    }

    @Test("a saudação muda com a hora e usa o primeiro nome")
    func greetingFollowsTheClock() {
        #expect(DashboardFocus.greeting(nowMinute: 540, name: "Marcos Santos") == "Bom dia, Marcos")
        #expect(DashboardFocus.greeting(nowMinute: 720, name: "Marcos Santos") == "Boa tarde, Marcos")
        #expect(DashboardFocus.greeting(nowMinute: 1260, name: nil) == "Boa noite")
        #expect(
            DashboardFocus.personName(displayName: "marcos@okamiops.com", address: "marcos@okamiops.com")
                == "Marcos"
        )
        #expect(
            DashboardFocus.greeting(
                nowMinute: 800, displayName: "marcos@okamiops.com", address: "marcos@okamiops.com"
            ) == "Boa tarde, Marcos"
        )
    }

    @Test("a varredura para no teto e ainda devolve o recorte")
    func scanStopsAtCap() {
        let many = (0..<500).map { i in
            mail(
                id: "n\(i)",
                bucket: .today,
                tags: [],
                isRead: false,
                receivedAt: Fixtures.today.addingTimeInterval(TimeInterval(i))
            )
        }
        let snap = DashboardFocus.snapshot(
            messages: many, agenda: [], pending: [], nowMinute: 720
        )
        #expect(snap.mail.count == DashboardFocus.mailLimit)
        #expect(DashboardFocus.candidateCap == 300)
    }

    @Test("a conta selecionada recorta as três listas")
    func accountFilter() {
        let snap = DashboardFocus.snapshot(
            messages: Fixtures.messages,
            agenda: Fixtures.agenda,
            pending: Fixtures.pendingItems,
            nowMinute: Fixtures.nowMinute,
            accountID: "zoho"
        )
        #expect(Set(snap.mail.map(\.message.accountID)) == ["zoho"])
        #expect(Set(snap.meetings.map(\.accountID)) == ["zoho"])
        #expect(snap.pending.map(\.id) == ["p1"])
    }

    private func mail(
        id: String,
        bucket: TriageBucket,
        tags: [UNICore.Tag],
        isRead: Bool,
        isFlagged: Bool = false,
        category: MailCategory? = nil,
        receivedAt: Date = Fixtures.today
    ) -> Message {
        Message(
            id: id, accountID: "a",
            from: Contact(name: "Quem", address: "quem@exemplo.com"),
            receivedAt: receivedAt,
            subject: id, snippet: id, body: [],
            tags: tags, bucket: bucket, isRead: isRead,
            summary: nil, detectedEvent: nil, category: category,
            isFlagged: isFlagged
        )
    }
}

/// O excedente que a faixa HOJE escreve à direita — "12 fora da lista ·
/// newsletters e avisos".
///
/// É outro número que o `omittedMailCount`: aquele conta o que **ranqueou** e
/// não coube no teto de sete; este conta o que a triagem **descartou** por não
/// pedir a pessoa. Sem os dois, a faixa mentiria dizendo que a caixa só tem o
/// que está na lista.
@Suite("Dashboard · excedente da triagem")
struct DashboardDiscardedTests {

    private func mensagem(
        _ id: String, triage: MessageTriage, isRead: Bool = true
    ) -> Message {
        Message(
            id: id,
            accountID: "a1",
            from: Contact(name: "Quem \(id)", address: "\(id)@exemplo.com"),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Assunto \(id)",
            snippet: "trecho",
            body: ["corpo"],
            tags: [],
            bucket: .today,
            isRead: isRead,
            summary: nil,
            detectedEvent: nil,
            triage: triage
        )
    }

    @Test("newsletter e transacional entram no excedente, não na lista")
    func discardedCountsTheNoise() {
        let pedeResposta = MessageTriage(
            needsReply: true, intent: .request, urgency: .normal
        )
        let ruido = MessageTriage(
            needsReply: false, intent: .newsletter, urgency: .low
        )
        let recibo = MessageTriage(
            needsReply: false, intent: .transactional, urgency: .low
        )

        let focus = DashboardFocus.snapshot(
            messages: [
                mensagem("m1", triage: pedeResposta),
                mensagem("m2", triage: ruido),
                mensagem("m3", triage: recibo),
                mensagem("m4", triage: ruido),
            ],
            agenda: [],
            pending: [],
            nowMinute: 600
        )

        #expect(focus.mail.map(\.id) == ["m1"])
        #expect(focus.discardedMailCount == 3)
        #expect(focus.omittedMailCount == 0)
    }

    @Test("sem ruído, o excedente é zero")
    func nothingDiscarded() {
        let pedeResposta = MessageTriage(
            needsReply: true, intent: .request, urgency: .normal
        )
        let focus = DashboardFocus.snapshot(
            messages: [mensagem("m1", triage: pedeResposta)],
            agenda: [], pending: [], nowMinute: 600
        )
        #expect(focus.discardedMailCount == 0)
    }
}
