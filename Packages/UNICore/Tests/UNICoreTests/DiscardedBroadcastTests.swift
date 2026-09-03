import Foundation
import Testing

@testable import UNICore

@Suite("Disparos que ficaram fora da lista")
struct DiscardedBroadcastTests {

    private static let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func mensagem(
        _ id: String,
        segundos: TimeInterval = 0,
        endereco: String = "gente@exemplo.com",
        marks: BulkMailMarks = [],
        triage: MessageTriage?
    ) -> Message {
        Message(
            id: id, accountID: "gmail",
            from: Contact(name: "Quem escreve", address: endereco),
            receivedAt: Self.agora.addingTimeInterval(segundos),
            subject: "Assunto \(id)", snippet: "Trecho", body: ["Corpo"],
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil, triage: triage,
            bulkMarks: marks
        )
    }

    private let disparo = MessageTriage(
        needsReply: true, intent: .lead, urgency: .normal
    )
    private let pedeResposta = MessageTriage(
        needsReply: true, intent: .request, urgency: .normal
    )

    /// Uma pessoa e treze disparos: o caso do mockup, e o único em que a
    /// diferença entre "quantos couberam" e "quantos existem" aparece.
    private func trezeDisparos() -> [Message] {
        var mensagens = [mensagem("m0", segundos: 0, triage: pedeResposta)]
        for indice in 1...13 {
            mensagens.append(
                mensagem(
                    "d\(indice)", segundos: -TimeInterval(indice),
                    endereco: "lista\(indice)@exemplo.com",
                    marks: .listUnsubscribe, triage: disparo
                )
            )
        }
        return mensagens
    }

    @Test("os disparos que não couberam na lista são contados")
    func countsBroadcastsOutOfTheList() {
        let focus = DashboardFocus.snapshot(
            messages: trezeDisparos(), agenda: [], pending: [],
            nowMinute: 600, now: Self.agora
        )
        let naLista = focus.mail.filter { $0.message.effectiveBulkMarks.isBulk }.count
        #expect(focus.mail.count == DashboardFocus.mailLimit)
        #expect(naLista == 6)
        #expect(focus.discardedBroadcastCount == 7)
    }

    @Test("o disparo que sobreviveu na lista não é contado duas vezes")
    func doesNotCountVisibleBroadcasts() {
        let comPrazo = MessageTriage(
            needsReply: false, intent: .informational, urgency: .normal,
            deadline: DetectedDeadline(
                date: Self.agora.addingTimeInterval(100_000), evidence: "Corpo"
            )
        )
        let focus = DashboardFocus.snapshot(
            messages: [mensagem("m1", marks: .listUnsubscribe, triage: comPrazo)],
            agenda: [], pending: [], nowMinute: 600, now: Self.agora
        )
        #expect(focus.mail.map(\.id) == ["m1"])
        #expect(focus.discardedBroadcastCount == 0)
    }

    @Test("sem disparo nenhum, a conta é zero")
    func zeroWithoutBroadcasts() {
        let focus = DashboardFocus.snapshot(
            messages: [mensagem("m1", triage: pedeResposta)],
            agenda: [], pending: [], nowMinute: 600, now: Self.agora
        )
        #expect(focus.discardedBroadcastCount == 0)
    }

    @Test("o plano do dia conta os treze disparos, e não os seis que couberam")
    func dayPlanCountsThemAll() {
        let focus = DashboardFocus.snapshot(
            messages: trezeDisparos(), agenda: [], pending: [],
            nowMinute: 600, now: Self.agora
        )
        let plano = DayPlan.make(
            focus: focus, drafts: [:], rules: [], agenda: [],
            filter: .standard, now: Self.agora, nowMinute: 600
        )
        #expect(plano.counts[.broadcasts] == 13)
    }
}
