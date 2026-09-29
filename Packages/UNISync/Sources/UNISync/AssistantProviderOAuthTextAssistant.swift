import Foundation
import UNICore

/// Transporte HTTP de texto para a assinatura escolhida nas preferências.
public enum AssistantProviderOAuthTextAssistantError: Error, Sendable, Equatable, LocalizedError {
    case missingAuthorization, authenticationFailed, subscriptionNotEligible
    case rateLimited, timedOut, connectionFailed, redirectRefused, upgradeRequired
    case server(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAuthorization: L10n.tr("Conecte a assinatura OAuth deste provedor antes de usar a IA.")
        case .authenticationFailed: L10n.tr("O provedor recusou a sessão OAuth. Reconecte a assinatura e tente novamente.")
        case .subscriptionNotEligible: L10n.tr("Esta assinatura não liberou acesso a este modelo. Verifique a conta e tente novamente.")
        case .rateLimited: L10n.tr("O provedor pediu para desacelerar. Tente novamente em instantes.")
        case .timedOut: L10n.tr("O provedor demorou demais para responder. Tente novamente.")
        case .connectionFailed: L10n.tr("Não foi possível falar com o provedor de IA. Verifique a conexão e tente novamente.")
        case .redirectRefused: L10n.tr("O provedor tentou redirecionar uma chamada autenticada; a requisição foi interrompida por segurança.")
        case .upgradeRequired: L10n.tr("O provedor exige uma atualização do protocolo/cliente. Atualize o OkamiUNI e tente novamente.")
        case let .server(statusCode): L10n.tr("O provedor de IA respondeu com erro \(statusCode).")
        case .invalidResponse: L10n.tr("O provedor devolveu uma resposta que o OkamiUNI não consegue usar.")
        }
    }
}

public struct AssistantProviderOAuthTextAssistant: TextAssisting, AgentPlanning, Sendable {
    public let modelVersion: String
    private let configuration: AssistantProviderOAuthConfiguration
    private let accessToken: String
    private let accountID: String?
    private let additionalInstructions: String
    private let transport: any AssistantProviderOAuthHTTPTransport
    private let requestTimeout: TimeInterval

    public init(configuration: AssistantProviderOAuthConfiguration, accessToken: String, accountID: String? = nil, additionalInstructions: String = "", session: URLSession = .shared, requestTimeout: TimeInterval = 120) throws {
        try self.init(
            configuration: configuration,
            accessToken: accessToken,
            accountID: accountID,
            additionalInstructions: additionalInstructions,
            transport: URLSessionAssistantProviderOAuthHTTPTransport(session: session),
            requestTimeout: requestTimeout
        )
    }

    public init(configuration: AssistantProviderOAuthConfiguration, accessToken: String, accountID: String? = nil, additionalInstructions: String = "", transport: any AssistantProviderOAuthHTTPTransport, requestTimeout: TimeInterval = 120) throws {
        self.configuration = try configuration.validated()
        if self.configuration.kind == .codex {
            guard let validated = AssistantProviderOAuthClient.validatedCodexAccountID(accountID) else {
                throw AssistantProviderOAuthTextAssistantError.missingAuthorization
            }
            self.accountID = validated
        } else {
            self.accountID = nil
        }
        self.accessToken = try AssistantCredentialValidation.apiKey(accessToken)
        self.additionalInstructions = additionalInstructions
        self.transport = transport
        // grok-4.6 numa resposta de email completa passa de 30s fácil; o
        // catálogo (GET /models) autentica rápido e a geração é que estoura.
        self.requestTimeout = min(max(requestTimeout, 90), 180)
        modelVersion = "provider-oauth/\(self.configuration.kind.rawValue)/\(self.configuration.model)"
    }

    public func availability() async -> AppleIntelligenceAvailability { .available }

    public func agentPlan(prompt: String) async throws -> String {
        try await complete(instructions: AgentToolLoop.instructions, input: prompt)
    }

    public func answer(question: String, in conversation: AssistantConversationSnapshot) async throws -> String {
        let question = try FoundationModelsTextAssistantValidation.question(question)
        return try FoundationModelsTextAssistantValidation.response(try await complete(
            instructions: AssistantPrompt.answerInstructions(additionalInstructions: additionalInstructions),
            input: AssistantPrompt.answer(
                question: question,
                conversation: conversation,
                budget: .configured
            )
        ))
    }

    public func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String {
        let text = try FoundationModelsTextAssistantValidation.transformText(text, action: action, context: context)
        return try FoundationModelsTextAssistantValidation.response(try await complete(
            instructions: AssistantPrompt.transformInstructions(additionalInstructions: additionalInstructions),
            input: AssistantPrompt.transform(
                text: text,
                action: action,
                context: context,
                budget: .configured
            )
        ))
    }

    private func complete(instructions: String, input: String) async throws -> String {
        let isCodex = configuration.kind == .codex
        var request = URLRequest(url: isCodex ? AssistantProviderOAuthClient.codexResponsesURL : AssistantProviderOAuthClient.xAIResponsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(isCodex ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": configuration.model, "instructions": instructions, "store": false, "stream": true,
                "input": [["role": "user", "content": [["type": "input_text", "text": input]]]]
            ])
        } else {
            request.httpBody = try JSONEncoder().encode(ResponsesRequest(model: configuration.model, instructions: instructions, input: input, store: false))
        }
        do {
            let (data, response) = try await transport.data(for: request, rejectingRedirects: true)
            if (300..<400).contains(response.statusCode) { throw AssistantProviderOAuthTextAssistantError.redirectRefused }
            guard (200..<300).contains(response.statusCode) else { throw error(for: response.statusCode) }
            guard !data.isEmpty, data.count <= 16_777_216 else { throw AssistantProviderOAuthTextAssistantError.invalidResponse }
            if isCodex { return try CodexResponsesEventStream.text(from: data) }
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

/// Codex entrega Responses via SSE. Só a conclusão explícita autoriza usar
/// o resultado; desconexões e eventos de erro não viram respostas parciais.
enum CodexResponsesEventStream {
    static func text(from data: Data) throws -> String {
        guard let stream = String(data: data, encoding: .utf8) else {
            throw AssistantProviderOAuthTextAssistantError.invalidResponse
        }
        var fields: [String] = []
        var deltas = ""
        var completedText: String?
        var completed = false
        func receiveEvent() throws {
            guard !fields.isEmpty else { return }
            let payload = fields.joined(separator: "\n")
            fields.removeAll(keepingCapacity: true)
            if payload == "[DONE]" { return }
            guard let bytes = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let type = object["type"] as? String
            else { throw AssistantProviderOAuthTextAssistantError.invalidResponse }
            switch type {
            case "response.output_text.delta":
                guard let delta = object["delta"] as? String else { throw AssistantProviderOAuthTextAssistantError.invalidResponse }
                deltas += delta
            case "response.completed":
                completed = true
                if let response = object["response"], JSONSerialization.isValidJSONObject(response),
                   let encoded = try? JSONSerialization.data(withJSONObject: response),
                   let decoded = try? JSONDecoder().decode(ResponsesResponse.self, from: encoded) {
                    completedText = decoded.text
                }
            case "error", "response.failed", "response.incomplete":
                throw AssistantProviderOAuthTextAssistantError.invalidResponse
            default:
                break
            }
        }
        for raw in stream.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw[...]
            if line.isEmpty {
                try receiveEvent()
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.hasPrefix(" ") { value = value.dropFirst() }
                fields.append(String(value))
            }
        }
        try receiveEvent()
        let text = (completedText ?? deltas).trimmingCharacters(in: .whitespacesAndNewlines)
        guard completed, !text.isEmpty else { throw AssistantProviderOAuthTextAssistantError.invalidResponse }
        return text
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
