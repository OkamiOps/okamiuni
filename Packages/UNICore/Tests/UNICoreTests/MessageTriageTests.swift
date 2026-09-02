import Foundation
import Testing
@testable import UNICore

@Suite("MessageTriage")
struct MessageTriageTests {

    private func input(
        subject: String = "Proposta comercial",
        body: String = "Precisamos da assinatura até sexta, 15h."
    ) -> MessageAnalysisInput {
        MessageAnalysisInput(
            subject: subject,
            sender: "Marina <marina@cliente.com>",
            receivedAt: Date(timeIntervalSince1970: 1_756_000_000),
            body: body,
            timeZone: TimeZone(identifier: "America/Sao_Paulo")!
        )
    }

    @Test("prazo com evidência literal sobrevive à validação")
    func literalEvidenceSurvives() {
        let triagem = MessageTriage(
            needsReply: true,
            intent: .lead,
            urgency: .high,
            deadline: DetectedDeadline(
                date: Date(timeIntervalSince1970: 1_756_400_000),
                evidence: "até sexta, 15h"
            )
        )
        let validada = triagem.validated(against: input())
        #expect(validada.deadline?.evidence == "até sexta, 15h")
        #expect(validada.needsReply)
        #expect(validada.intent == .lead)
    }

    @Test("evidência inventada descarta o prazo e mantém o resto")
    func inventedEvidenceDropsDeadline() {
        let triagem = MessageTriage(
            needsReply: true,
            intent: .request,
            urgency: .normal,
            deadline: DetectedDeadline(
                date: Date(timeIntervalSince1970: 1_756_400_000),
                evidence: "até quarta, 9h"
            )
        )
        let validada = triagem.validated(against: input())
        #expect(validada.deadline == nil)
        #expect(validada.needsReply)
        #expect(validada.intent == .request)
    }

    @Test("evidência no assunto também vale")
    func evidenceInSubjectCounts() {
        let triagem = MessageTriage(
            needsReply: false,
            intent: .scheduling,
            urgency: .low,
            deadline: DetectedDeadline(
                date: Date(timeIntervalSince1970: 1_756_400_000),
                evidence: "Proposta comercial"
            )
        )
        #expect(triagem.validated(against: input()).deadline != nil)
    }

    @Test("evidência vazia não é trecho literal de nada")
    func emptyEvidenceIsNotLiteral() {
        let triagem = MessageTriage(
            needsReply: false,
            intent: .informational,
            urgency: .low,
            deadline: DetectedDeadline(
                date: Date(timeIntervalSince1970: 1_756_400_000),
                evidence: "   "
            )
        )
        #expect(triagem.validated(against: input()).deadline == nil)
    }

    @Test("evidência curta demais não conta: 'de' casa por acaso em qualquer email")
    func evidenceHasAFloor() {
        #expect(MessageAnalysisEventEvidence.minimumEvidenceCharacters == 4)
        // "até" está literalmente no corpo, e não prova nada.
        let curta = MessageTriage(
            needsReply: true,
            intent: .request,
            urgency: .normal,
            deadline: DetectedDeadline(
                date: Date(timeIntervalSince1970: 1_756_400_000),
                evidence: "até"
            )
        )
        #expect(curta.validated(against: input()).deadline == nil)

        // Quatro caracteres, literais, sobrevivem.
        let minima = MessageTriage(
            needsReply: true,
            intent: .request,
            urgency: .normal,
            deadline: DetectedDeadline(
                date: Date(timeIntervalSince1970: 1_756_400_000),
                evidence: "sexta"
            )
        )
        #expect(minima.validated(against: input()).deadline != nil)
    }

    @Test("ida e volta pelo JSON guardado")
    func jsonRoundTrip() throws {
        let triagem = MessageTriage(
            needsReply: true,
            intent: .transactional,
            urgency: .high,
            deadline: DetectedDeadline(
                date: Date(timeIntervalSince1970: 1_756_400_000),
                evidence: "até sexta, 15h"
            )
        )
        let json = try #require(MessageTriage.encodedJSON(triagem))
        #expect(MessageTriage.decoded(json) == triagem)
        #expect(MessageTriage.encodedJSON(nil) == nil)
        #expect(MessageTriage.decoded("não é json") == nil)
    }
}
