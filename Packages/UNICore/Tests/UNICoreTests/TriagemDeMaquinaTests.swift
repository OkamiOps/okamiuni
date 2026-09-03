import Foundation
import Testing

@testable import UNICore

/// Máquina não entra em "Esperando você".
///
/// Os dois casos são da caixa do dono: o aviso de abertura de chamado da AWS
/// (um robô que diz na cara que não lê resposta) e a newsletter da Abacus.
@Suite("Triagem · o que é máquina")
struct TriagemDeMaquinaTests {

    private static let agora: Date = {
        var partes = DateComponents()
        partes.year = 2026; partes.month = 9; partes.day = 3; partes.hour = 10
        return Calendar.current.date(from: partes)!
    }()

    private func mensagem(
        id: String, de: Contact, assunto: String, corpo: [String],
        triagem: MessageTriage, marcas: BulkMailMarks = []
    ) -> Message {
        Message(
            id: id, accountID: "gmail", from: de, receivedAt: Self.agora,
            subject: assunto, snippet: corpo.first ?? "", body: corpo,
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil, triage: triagem, bulkMarks: marcas
        )
    }

    private func plano(_ mensagens: [Message]) -> DayPlan {
        DayPlan.make(
            focus: DashboardFocus(
                mail: mensagens.map { DashboardFocus.MailItem(message: $0, reason: .today) },
                meetings: [], pending: [], omittedMailCount: 0,
                omittedMeetingCount: 0, nextUpLabel: ""
            ),
            drafts: [:], rules: [], agenda: [], filter: .standard,
            now: Self.agora, nowMinute: 600
        )
    }

    private func esperando(_ plano: DayPlan) -> [String] {
        plano.sections.first { $0.kind == .waitingOnYou }?.rows.map(\.id) ?? []
    }

    @Test("o aviso de chamado da AWS não entra em Esperando você")
    func awsSupportCaseIsNotAPerson() {
        let aws = mensagem(
            id: "aws",
            de: Contact(
                name: "AWS Support", address: "notifications@support.amazonaws.com"
            ),
            assunto: "You have opened a new Support case: 175683920100238",
            corpo: [
                "Your case has been created.",
                "This mailbox cannot accept incoming e-mail.",
            ],
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
        let plano = plano([aws])
        #expect(esperando(plano).isEmpty, "a AWS entrou como gente esperando")
        #expect(plano.removed.contains { $0.messageID == "aws" })
        #expect(plano.removed.first { $0.messageID == "aws" }?.why
            == DayPlan.automatedRemovalReason)
    }

    @Test("a newsletter da Abacus não é gente, e o prazo dela sobrevive")
    func abacusNewsletterKeepsOnlyItsDeadline() {
        let sábado = Calendar.current.date(byAdding: .day, value: 3, to: Self.agora)!
        let abacus = mensagem(
            id: "abacus",
            de: Contact(name: "Abacus AI", address: "no-reply@abacus.ai"),
            assunto: "Erinnerung: Ihre 6.000 Bonus-Credits laufen ab",
            corpo: ["Ihre Bonus-Credits laufen ab."],
            triagem: MessageTriage(
                needsReply: true, intent: .transactional, urgency: .normal,
                deadline: DetectedDeadline(
                    date: sábado, evidence: "6.000 créditos expiram sábado"
                )
            ),
            marcas: [.listUnsubscribe]
        )
        let plano = plano([abacus])
        #expect(esperando(plano).isEmpty, "a Abacus entrou como gente esperando")
        let vence = plano.sections.first { $0.kind == .due }?.rows.map(\.id) ?? []
        #expect(vence == ["abacus"], "o prazo da Abacus sumiu junto com o robô")
    }

    @Test("só pedido, agendamento e lead ganham o botão primário")
    func onlyHumanIntentsEarnThePrimaryButton() {
        #expect(DayPlan.pedeGente(
            MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        ))
        #expect(DayPlan.pedeGente(
            MessageTriage(needsReply: true, intent: .scheduling, urgency: .normal)
        ))
        #expect(!DayPlan.pedeGente(
            MessageTriage(needsReply: true, intent: .transactional, urgency: .normal)
        ))
        #expect(!DayPlan.pedeGente(nil))
    }
}
