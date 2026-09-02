import Foundation
import UNICore

/// Transporte de texto para a assinatura xAI. A assinatura ChatGPT é atendida
/// pelo runtime Codex local, sem um bearer passar pelo OkamiUNI.
public enum AssistantProviderOAuthTextAssistantError: Error, Sendable, Equatable, LocalizedError {
    case missingAuthorization, authenticationFailed, subscriptionNotEligible
    case rateLimited, timedOut, connectionFailed, redirectRefused, upgradeRequired
    case server(statusCode: Int)
    case invalidResponse, managedByCodexRuntime

    public var errorDescription: String? {
        switch self {
        case .missingAuthorization: "Conecte a assinatura OAuth deste provedor antes de usar a IA."
        case .authenticationFailed: "O provedor recusou a sessão OAuth. Reconecte a assinatura e tente novamente."
        case .subscriptionNotEligible: "Esta assinatura não está elegível para o acesso OAuth da xAI. Use uma chave de API ou outra conta."
        case .rateLimited: "O provedor pediu para desacelerar. Tente novamente em instantes."
        case .timedOut: "O provedor demorou demais para responder. Tente novamente."
        case .connectionFailed: "Não foi possível falar com o provedor de IA. Verifique a conexão e tente novamente."
        case .redirectRefused: "O provedor tentou redirecionar uma chamada autenticada; a requisição foi interrompida por segurança."
        case .upgradeRequired: "O provedor exige uma atualização do protocolo/cliente. Atualize o OkamiUNI e tente novamente."
        case let .server(statusCode): "O provedor de IA respondeu com erro \(statusCode)."
        case .invalidResponse: "O provedor devolveu uma resposta que o OkamiUNI não consegue usar."
        case .managedByCodexRuntime: "A sessão ChatGPT é atendida pelo runtime oficial do Codex neste Mac."
        }
    }
}

public struct AssistantProviderOAuthTextAssistant: TextAssisting, Sendable {
    public let modelVersion: String
    private let configuration: AssistantProviderOAuthConfiguration
    private let accessToken: String
    private let additionalInstructions: String
    private let transport: any AssistantProviderOAuthHTTPTransport
    private let requestTimeout: TimeInterval

    public init(configuration: AssistantProviderOAuthConfiguration, accessToken: String, additionalInstructions: String = "", session: URLSession = .shared, requestTimeout: TimeInterval = 120) throws {
        try self.init(
            configuration: configuration,
            accessToken: accessToken,
            additionalInstructions: additionalInstructions,
            transport: URLSessionAssistantProviderOAuthHTTPTransport(session: session),
            requestTimeout: requestTimeout
        )
    }

    public init(configuration: AssistantProviderOAuthConfiguration, accessToken: String, additionalInstructions: String = "", transport: any AssistantProviderOAuthHTTPTransport, requestTimeout: TimeInterval = 120) throws {
        self.configuration = try configuration.validated()
        guard self.configuration.kind == .xAI else { throw AssistantProviderOAuthTextAssistantError.managedByCodexRuntime }
        self.accessToken = try AssistantCredentialValidation.apiKey(accessToken)
        self.additionalInstructions = additionalInstructions
        self.transport = transport
        // grok-4.6 numa resposta de email completa passa de 30s fácil; o
        // catálogo (GET /models) autentica rápido e a geração é que estoura.
        self.requestTimeout = min(max(requestTimeout, 90), 180)
        modelVersion = "provider-oauth/xai/\(self.configuration.model)"
    }

    public func availability() async -> OnDeviceMessageAnalysisAvailability { .available }

    public func answer(question: String, in conversation: AssistantConversationSnapshot) async throws -> String {
        let question = try FoundationModelsTextAssistantValidation.question(question)
        return try FoundationModelsTextAssistantValidation.response(try await complete(
            instructions: FoundationModelsTextAssistantPrompt.answerInstructions(additionalInstructions: additionalInstructions),
            input: FoundationModelsTextAssistantPrompt.answer(
                question: question,
                conversation: conversation,
                budget: .configured
            )
        ))
    }

    public func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String {
        let text = try FoundationModelsTextAssistantValidation.transformText(text, action: action, context: context)
        return try FoundationModelsTextAssistantValidation.response(try await complete(
            instructions: FoundationModelsTextAssistantPrompt.transformInstructions(additionalInstructions: additionalInstructions),
            input: FoundationModelsTextAssistantPrompt.transform(
                text: text,
                action: action,
                context: context,
                budget: .configured
            )
        ))
    }

    private func complete(instructions: String, input: String) async throws -> String {
        var request = URLRequest(url: AssistantProviderOAuthClient.xAIResponsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ResponsesRequest(model: configuration.model, instructions: instructions, input: input, store: false))
        do {
            let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
            if (300..<400).contains(response.statusCode) { throw AssistantProviderOAuthTextAssistantError.redirectRefused }
            guard (200..<300).contains(response.statusCode) else { throw error(for: response.statusCode) }
            guard let decoded = try? JSONDecoder().decode(ResponsesResponse.self, from: data), let text = decoded.text else { throw AssistantProviderOAuthTextAssistantError.invalidResponse }
            return text
        } catch let error as TextAssistantError {
            throw error
        } catch let error as AssistantProviderOAuthTextAssistantError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw AssistantProviderOAuthTextAssistantError.timedOut }
            throw AssistantProviderOAuthTextAssistantError.connectionFailed
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantProviderOAuthTextAssistantError.connectionFailed
        }
    }

    private func error(for statusCode: Int) -> AssistantProviderOAuthTextAssistantError {
        switch statusCode {
        case 401: .authenticationFailed
        case 403: .subscriptionNotEligible
        case 408: .timedOut
        case 429: .rateLimited
        case 426: .upgradeRequired
        default: .server(statusCode: statusCode)
        }
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store: Bool
}

private struct ResponsesResponse: Decodable {
    struct Output: Decodable {
        struct Content: Decodable { let type: String?; let text: String? }
        let type: String?
        let content: [Content]?
    }
    let outputText: String?
    let output: [Output]?
    enum CodingKeys: String, CodingKey { case outputText = "output_text"; case output }

    var text: String? {
        if let outputText = outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty { return outputText }
        let values = (output ?? []).flatMap { item in
            (item.content ?? []).compactMap { content -> String? in
                guard content.type == nil || content.type == "output_text" || content.type == "text",
                      let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { return nil }
                return text
            }
        }
        let text = values.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
