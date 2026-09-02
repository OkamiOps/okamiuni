import Foundation
import Testing
@testable import UNISync

@Suite("Preferências de comportamento do assistente")
struct AssistantBehaviorPreferencesTests {
    @Test("inglês não produz a palavra português em lugar nenhum do prompt")
    func englishNeverMentionsPortuguese() {
        let settings = AssistantSettings(
            provider: .openAICompatible,
            behavior: .init(language: .english)
        )
        let instructions = settings.configuredInstructions(for: .questions)
        #expect(instructions.contains("Respond in English."))
        #expect(!instructions.lowercased().contains("português"))

        let prompt = AssistantPrompt.answer(
            question: "What is urgent?",
            conversation: .init(mailContext: .workspace(.init(
                accounts: [], emailCount: 0, unreadCount: 0,
                mailboxes: [], emails: [], agenda: []
            ))),
            budget: .configured
        )
        #expect(!prompt.lowercased().contains("português"))

        let writing = AssistantPrompt.transform(
            text: "Please review.",
            action: .summarize,
            context: nil,
            budget: .configured
        )
        #expect(!writing.lowercased().contains("português"))
    }

    @Test("português do Brasil também é emitido: o padrão deixou de ser implícito")
    func portugueseIsEmittedToo() {
        let settings = AssistantSettings(behavior: .init(language: .portugueseBrazil))
        #expect(settings.configuredInstructions(for: .writing)
            .contains("Responda em português do Brasil."))
    }
}
