import Foundation

/// A parte estável do prompt que pode ser inspecionada em Configurações.
/// Contexto de e-mail, histórico, ação e pergunta são anexados somente no
/// momento da chamada e continuam sujeitos aos limites determinísticos do
/// adaptador.
public enum AssistantPromptKind: String, CaseIterable, Identifiable, Sendable {
    case questions
    case writing

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .questions: "Perguntas e análises"
        case .writing: "Escrita e respostas"
        }
    }
}

public enum AssistantPromptCatalog {
    public static func effectiveSystemPrompt(
        for kind: AssistantPromptKind,
        settings: AssistantSettings
    ) -> String {
        effectiveSystemPrompt(
            for: kind,
            additionalInstructions: settings.configuredInstructions(for: kind)
        )
    }

    public static func effectiveSystemPrompt(
        for kind: AssistantPromptKind,
        additionalInstructions: String
    ) -> String {
        switch kind {
        case .questions:
            FoundationModelsTextAssistantPrompt.answerInstructions(
                additionalInstructions: additionalInstructions
            )
        case .writing:
            FoundationModelsTextAssistantPrompt.transformInstructions(
                additionalInstructions: additionalInstructions
            )
        }
    }
}
