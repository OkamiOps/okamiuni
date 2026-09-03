import Foundation
import Testing
import UNICore
@testable import UNIShell

/// As duas costuras entre o `MailStore` e o `DayPlan.make` — cada uma nasceu
/// de um defeito visto no render: rascunho válido parecendo vencido (o focus
/// não carrega corpo) e a Abacus sumindo do "Vence" (o ranking descarta todo
/// disparo).
@Suite("Dashboard 08 · a entrada do plano")
struct DashboardPlanInputTests {

    private func mensagem(
        id: String = "m1", corpo: [String] = ["um corpo de verdade"],
        marcas: BulkMailMarks = []
    ) -> Message {
        Message(
            id: id, accountID: "gmail",
            from: Contact(name: "Alguém", address: "alguem@exemplo.com"),
            receivedAt: Date(timeIntervalSince1970: 1_780_000_000),
            subject: "Assunto", snippet: "trecho", body: corpo,
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil, bulkMarks: marcas
        )
    }

    @Test("rascunho válido para a mensagem cheia passa a valer para o recorte sem corpo")
    func validDraftSurvivesTheTrimmedFocus() {
        let cheia = mensagem()
        let draft = ReadyDraft(
            messageID: "m1", text: "Oi.",
            contentHash: ReadyDraft.contentHash(for: cheia),
            modelVersion: "v1"
        )
        let validados = DashboardPlanInput.validatedDrafts(["m1": draft]) { _ in cheia }
        let recorte = cheia.withoutHeavyPayload()
        #expect(validados["m1"]?.matches(recorte) == true,
                "o hash reescrito não casa com o recorte que o DayPlan vê")
        // E o rascunho cru NÃO casa com o recorte — é o defeito que a costura
        // conserta; se isto um dia passar, a costura pode morrer.
        #expect(!draft.matches(recorte))
    }

    @Test("rascunho vencido continua caindo fora")
    func staleDraftIsStillDropped() {
        let cheia = mensagem()
        let vencido = ReadyDraft(
            messageID: "m1", text: "Oi.",
            contentHash: "outro-hash", modelVersion: "v1"
        )
        let validados = DashboardPlanInput.validatedDrafts(["m1": vencido]) { _ in cheia }
        #expect(validados.isEmpty)
    }

    @Test("os disparos descartados voltam ao recorte, sem contar dos dois lados")
    func broadcastsRejoinTheFocus() {
        let visivel = mensagem(id: "a")
        let disparo = mensagem(id: "b", marcas: [.listUnsubscribe])
        let focus = DashboardFocus(
            mail: [.init(message: visivel, reason: .needsReply)],
            meetings: [], pending: [],
            omittedMailCount: 0, omittedMeetingCount: 0, nextUpLabel: "",
            discardedMailCount: 5, discardedBroadcastCount: 3
        )
        let plano = DashboardPlanInput.planFocus(focus, broadcasts: [visivel, disparo])
        #expect(plano.mail.map(\.id) == ["a", "b"], "o disparo não entrou (ou o visível dobrou)")
        #expect(plano.mail.last?.reason == .broadcast)
        #expect(plano.discardedMailCount == 4, "o acrescentado continuou contado como descartado")
        #expect(plano.discardedBroadcastCount == 2)
    }

    @Test("sem disparo novo, o focus sai intacto")
    func noBroadcastsNoChange() {
        let visivel = mensagem(id: "a")
        let focus = DashboardFocus(
            mail: [.init(message: visivel, reason: .needsReply)],
            meetings: [], pending: [],
            omittedMailCount: 0, omittedMeetingCount: 0, nextUpLabel: "amanhã",
            discardedMailCount: 5, discardedBroadcastCount: 3
        )
        #expect(DashboardPlanInput.planFocus(focus, broadcasts: [visivel]) == focus)
    }
}
