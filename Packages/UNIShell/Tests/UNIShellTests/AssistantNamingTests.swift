import Foundation
import Testing
import UNICore
@testable import UNIShell

@Suite("Nomes do assistente no shell")
@MainActor
struct AssistantShellNamingTests {
    @Test("painel, escopo e sugestões perderam o prefixo Local")
    func shellTypesAreRenamed() {
        let scope = AssistantScope.workspace
        #expect(scope.suggestions.count == AssistantSuggestion.workspaceDefaults.count)
        let context = AssistantContext(subject: "Assunto", sender: "a@b.c")
        #expect(context.title == "Assunto")
        let message = AssistantMessage(speaker: .assistant, text: "ok")
        #expect(message.speaker == AssistantSpeaker.assistant)
        let request = AssistantRequest(context: context, question: "q", conversation: [message])
        #expect(request.conversation.count == 1)
        #expect(AssistantPanel.defaultWidth == 360)
        #expect(AppleIntelligenceAvailability.available.isAvailable)
    }
}
