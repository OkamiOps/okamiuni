import Foundation
import UNICore

/// Falhas que pertencem ao transporte OpenAI-compatible, sem expor endpoint,
/// chave ou conteúdo de e-mail na mensagem apresentada à pessoa.
public enum OpenAICompatibleTextAssistantError: Error, Sendable, Equatable, LocalizedError {
    case missingAPIKey
    case missingOAuthAuthorization
    case oauthProviderUnavailable
    case authenticationFailed
    case rateLimited
    case timedOut
    case connectionFailed
    case server(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            L10n.tr("Adicione uma chave de API para o provedor de IA selecionado.")
        case .missingOAuthAuthorization:
            L10n.tr("Conecte o LiteLLM por OAuth antes de usar este provedor.")
        case .oauthProviderUnavailable:
            L10n.tr("Este build ainda não tem o conector OAuth do LiteLLM configurado.")
        case .authenticationFailed:
            L10n.tr("O provedor de IA recusou a credencial. Confira a chave ou reconecte o OAuth e tente de novo.")
        case .rateLimited:
            L10n.tr("O provedor de IA pediu para desacelerar. Tente de novo em instantes.")
        case .timedOut:
            L10n.tr("O provedor de IA demorou demais para responder. Tente de novo.")
        case .connectionFailed:
            L10n.tr("Não foi possível falar com o provedor de IA. Verifique a conexão e o endpoint.")
        case let .server(statusCode):
            L10n.tr("O provedor de IA respondeu com erro \(statusCode).")
        case .invalidResponse:
            L10n.tr("O provedor de IA devolveu uma resposta que o OkamiUNI não consegue usar.")
        }
    }
}

/// Adaptador para LiteLLM e qualquer endpoint que implemente
/// `POST /v1/chat/completions`. Ele não descobre modelos nem faz sondagens de
/// rede: cada ação de assistente resulta em uma única chamada explícita.
public struct OpenAICompatibleTextAssistant: TextAssisting, Sendable {
    public let modelVersion: String

    private let configuration: OpenAICompatibleAssistantConfiguration
    private let authorizationToken: String?
    private let additionalInstructions: String
    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(
        configuration: OpenAICompatibleAssistantConfiguration,
        apiKey: String,
        additionalInstructions: String = "",
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 120
    ) throws {
        try self.init(
            configuration: configuration,
            authorizationToken: apiKey,
            additionalInstructions: additionalInstructions,
            session: session,
            requestTimeout: requestTimeout
        )
    }

    /// `authorizationToken` é obtido pelo roteador somente para os modos que
    /// requerem autenticação. No modo `.none` ele é deliberadamente descartado
    /// para impedir que uma credencial antiga seja enviada por engano.
    public init(
        configuration: OpenAICompatibleAssistantConfiguration,
        authorizationToken: String? = nil,
        additionalInstructions: String = "",
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 120
    ) throws {
        self.configuration = try configuration.validated()
        switch self.configuration.authenticationMode {
        case .none:
            self.authorizationToken = nil
        case .apiKey:
            guard let authorizationToken else {
                throw OpenAICompatibleTextAssistantError.missingAPIKey
            }
            self.authorizationToken = try AssistantCredentialValidation.apiKey(authorizationToken)
        case .litellmOAuthPKCE:
            guard let authorizationToken else {
                throw OpenAICompatibleTextAssistantError.missingOAuthAuthorization
            }
            self.authorizationToken = try AssistantCredentialValidation.apiKey(authorizationToken)
        }
        self.additionalInstructions = additionalInstructions
        self.session = session
        self.requestTimeout = max(1, requestTimeout)
        modelVersion = "openai-compatible/\(self.configuration.model)"
    }

    public func availability() async -> AppleIntelligenceAvailability { .available }

    public func answer(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> String {
        let question = try FoundationModelsTextAssistantValidation.question(question)
        let response = try await complete(
            systemInstructions: AssistantPrompt.answerInstructions(
                additionalInstructions: additionalInstructions
            ),
            prompt: AssistantPrompt.answer(
                question: question,
                conversation: conversation,
                budget: .configured
            )
        )
        return try FoundationModelsTextAssistantValidation.response(response)
    }

    public func transform(
        _ text: String,
        using action: WritingAction,
        context: AssistantMailContext?
    ) async throws -> String {
        let text = try FoundationModelsTextAssistantValidation.transformText(
            text,
            action: action,
            context: context
        )
        let response = try await complete(
            systemInstructions: AssistantPrompt.transformInstructions(
                additionalInstructions: additionalInstructions
            ),
            prompt: AssistantPrompt.transform(
                text: text,
                action: action,
                context: context,
                budget: .configured
            )
        )
        return try FoundationModelsTextAssistantValidation.response(response)
    }

    private func complete(systemInstructions: String, prompt: String) async throws -> String {
        var request = URLRequest(url: try configuration.chatCompletionsURL())
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(ChatCompletionsRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: systemInstructions),
                .init(role: "user", content: prompt),
            ]
        ))

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw OpenAICompatibleTextAssistantError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw error(for: response.statusCode)
            }
            guard let decoded = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data),
                  let content = decoded.choices.first?.message.content
            else {
                throw OpenAICompatibleTextAssistantError.invalidResponse
            }
            return content
        } catch let error as TextAssistantError {
            throw error
        } catch let error as OpenAICompatibleTextAssistantError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled {
                throw CancellationError()
            }
            if error.code == .timedOut {
                throw OpenAICompatibleTextAssistantError.timedOut
            }
            throw OpenAICompatibleTextAssistantError.connectionFailed
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OpenAICompatibleTextAssistantError.connectionFailed
        }
    }

    private func error(for statusCode: Int) -> OpenAICompatibleTextAssistantError {
        switch statusCode {
        case 401, 403:
            .authenticationFailed
        case 408:
            .timedOut
        case 429:
            .rateLimited
        default:
            .server(statusCode: statusCode)
        }
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}
