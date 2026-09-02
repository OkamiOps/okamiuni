import Foundation
import Testing
@testable import UNISync

@Suite("Destino do assistente")
struct AssistantDestinationTests {
    @Test("o Foundation Models é o único que pode prometer que nada sai")
    func localDestination() {
        let destination = AssistantDestination(settings: .init(provider: .foundationModels))
        #expect(destination.label == "Neste Mac")
        #expect(destination.detail == "Nada sai deste Mac.")
        #expect(destination.isLocal)
    }

    @Test("assinatura direta nomeia o provedor e para onde o texto vai")
    func providerOAuthDestinations() {
        let grok = AssistantDestination(settings: .init(
            provider: .providerOAuth,
            providerOAuth: .init(kind: .xAI, model: "grok-4.6")
        ))
        #expect(grok.label == "Grok · xAI")
        #expect(grok.detail == "Sai deste Mac para a xAI.")
        #expect(!grok.isLocal)

        let codex = AssistantDestination(settings: .init(
            provider: .providerOAuth,
            providerOAuth: .init(kind: .codex, model: "gpt-5-codex")
        ))
        #expect(codex.label == "Codex · ChatGPT")
        #expect(codex.detail == "Sai deste Mac pelo Codex instalado.")
    }

    @Test("o endpoint compatível mostra o host, e PKCE se identifica como LiteLLM")
    func openAICompatibleDestinations() {
        let api = AssistantDestination(settings: .init(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://api.example.com/v1",
                model: "gpt-4o-mini",
                credentialID: "primary",
                authenticationMode: .apiKey
            )
        ))
        #expect(api.label == "API · api.example.com")
        #expect(api.detail == "Sai deste Mac para api.example.com.")

        let proxy = AssistantDestination(settings: .init(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "http://127.0.0.1:4000/v1",
                model: "gateway",
                credentialID: "team",
                authenticationMode: .litellmOAuthPKCE
            )
        ))
        #expect(proxy.label == "LiteLLM · 127.0.0.1")
        #expect(proxy.detail == "Sai deste Mac para 127.0.0.1.")
    }

    @Test("endpoint em branco não inventa host")
    func openAICompatibleWithoutEndpoint() {
        let destination = AssistantDestination(settings: .init(
            provider: .openAICompatible,
            openAICompatible: .init(endpoint: "", model: "m", credentialID: "c")
        ))
        #expect(destination.label == "API · sem endpoint")
        #expect(destination.detail == "Informe o endpoint nos Ajustes.")
        #expect(!destination.isLocal)
    }

    @Test("cada CLI aparece pelo nome do binário que a pessoa instalou")
    func cliDestinations() {
        let expected: [(AssistantCLIKind, String)] = [
            (.claude, "Claude Code · CLI"),
            (.codex, "Codex CLI · CLI"),
            (.openCode, "OpenCode · CLI"),
        ]
        for (kind, label) in expected {
            let destination = AssistantDestination(settings: .init(provider: .cli, cli: .init(kind: kind)))
            #expect(destination.label == label)
            #expect(destination.detail == "Sai deste Mac pelo CLI instalado.")
            #expect(!destination.isLocal)
        }
    }
}
