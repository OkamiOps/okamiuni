import Foundation
import Testing
@testable import UNICore

@Suite("Nomes do assistente")
struct AssistantNamingTests {
    /// A tabela 1.1 da spec proíbe typealias de transição: o nome novo tem
    /// de ser o único nome. Este teste não compila enquanto o rename não
    /// acontecer, e é essa a falha esperada.
    @Test("o contrato de texto não carrega mais o prefixo OnDevice")
    func contractIsRenamed() {
        let turn = AssistantTurn(role: .user, text: "oi")
        let snapshot = AssistantConversationSnapshot(
            mailContext: .email(
                AssistantEmailContext(subject: "Assunto", sender: "a@b.c", body: "corpo")
            ),
            turns: [turn]
        )
        #expect(snapshot.turns.count == 1)
        #expect(snapshot.turns[0].role == AssistantTurnRole.user)
        #expect(WritingAction.draftReply == WritingAction.draftReply)
        #expect(TextAssistantError.emptyResponse.errorDescription?.isEmpty == false)
        #expect(String(describing: (any TextAssisting).self).contains("TextAssisting"))
    }
}
