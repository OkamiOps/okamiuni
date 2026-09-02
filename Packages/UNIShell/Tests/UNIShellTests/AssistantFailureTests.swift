import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

@Suite("Tradução de falhas do assistente")
struct AssistantFailureTests {
    @Test("credencial ausente manda para os Ajustes, não para 'tentar de novo'")
    func missingCredentialsOpenSettings() {
        #expect(AssistantFailure(OpenAICompatibleTextAssistantError.missingAPIKey).recovery == .openSettings)
        #expect(AssistantFailure(OpenAICompatibleTextAssistantError.missingOAuthAuthorization).recovery == .openSettings)
        #expect(AssistantFailure(AssistantCLITextAssistantError.executableNotFound(.codex)).recovery == .openSettings)
        #expect(AssistantFailure(AssistantSettingsError.missingModel).recovery == .openSettings)
    }

    @Test("sessão recusada pede reconexão do provedor certo")
    func authenticationAsksForReconnect() {
        // Sem saber a assinatura, o caminho ainda existe: Ajustes. `nil`
        // deixava a faixa de erro sem botão nenhum.
        #expect(AssistantFailure(AssistantProviderOAuthTextAssistantError.authenticationFailed)
            .recovery == .openSettings)
        #expect(AssistantFailure(AssistantProviderOAuthError.missingSession)
            .recovery == .openSettings)
        // A reconexão só sabe o provedor quando quem traduz o informa.
        let grok = AssistantFailure(
            AssistantProviderOAuthTextAssistantError.authenticationFailed,
            provider: .xAI
        )
        #expect(grok.recovery == .reconnect(.xAI))
        #expect(grok.message == AssistantProviderOAuthTextAssistantError.authenticationFailed.errorDescription)
    }

    @Test("erro temporário oferece tentar de novo")
    func transientErrorsRetry() {
        #expect(AssistantFailure(OpenAICompatibleTextAssistantError.timedOut).recovery == .retry)
        #expect(AssistantFailure(OpenAICompatibleTextAssistantError.rateLimited).recovery == .retry)
        #expect(AssistantFailure(OpenAICompatibleTextAssistantError.connectionFailed).recovery == .retry)
        #expect(AssistantFailure(AssistantCLITextAssistantError.timedOut).recovery == .retry)
        #expect(AssistantFailure(TextAssistantError.emptyResponse).recovery == .retry)
        #expect(AssistantFailure(TextAssistantError.emptyResponse).message
            == "O assistente devolveu uma resposta vazia.")
    }

    /// A regra de recorte também é verificada direto no ajudante que a
    /// implementa, sem passar pelo erro do transporte.
    @Test("do stderr do CLI só a última linha vira mensagem")
    func cliMessageKeepsLastStderrLine() {
        // O que chega aqui é uma cauda cortada por byte: a primeira linha é o
        // meio de uma frase, e a causa está no fim. Pegar a primeira mostrava
        // um fragmento sem sentido e escondia "not logged in".
        let message = AssistantFailure.cliMessage(
            base: "O CLI de IA não concluiu a resposta.",
            stderrTail: "ing model catalog…\n[####      ] 40%\nerror: not logged in"
        )
        #expect(message.contains("error: not logged in"))
        #expect(!message.contains("ing model catalog"))

        // O corte também parte sequências UTF-8 ao meio; o resto não é linha.
        let partida = AssistantFailure.cliMessage(
            base: "Falhou.",
            stderrTail: "\u{FFFD}\u{FFFD}\nerror: model not found\n\u{FFFD}"
        )
        #expect(partida == "Falhou. error: model not found")

        // Cauda vazia não deixa a frase com sobra de espaço.
        #expect(AssistantFailure.cliMessage(base: "Falhou.", stderrTail: "  \n ") == "Falhou.")
    }

    @Test("o CLI que morreu mostra a última linha do stderr")
    func cliFailureShowsStderr() {
        let failure = AssistantFailure(AssistantCLITextAssistantError.processFailed(
            exitCode: 1,
            stderrTail: "run `codex login`\nerror: not logged in"
        ))
        #expect(failure.message.contains("error: not logged in"))
        #expect(!failure.message.contains("codex login"))
        #expect(failure.recovery == .openSettings)
    }

    /// Um provedor desconhecido não pode deixar a faixa de erro sem botão:
    /// "Abrir Ajustes" é a saída que sempre existe.
    @Test("sem assinatura conhecida, o 401 ainda oferece Ajustes")
    func unknownProviderStillOffersSettings() {
        #expect(
            AssistantFailure(AssistantProviderOAuthTextAssistantError.missingAuthorization)
                .recovery == .openSettings
        )
        #expect(
            AssistantFailure(AssistantProviderOAuthError.missingSession).recovery == .openSettings
        )
        #expect(
            AssistantFailure(
                AssistantProviderOAuthTextAssistantError.missingAuthorization, provider: .xAI
            ).recovery == .reconnect(.xAI)
        )
    }

    // MARK: - Uma linha por caso de cada enum de adaptador

    @Test("todo caso de TextAssistantError tem recuperação e frase própria",
          arguments: [
              (TextAssistantError.unavailable(.available), AssistantFailure.Recovery.openSettings),
              (.unavailable(.deviceNotEligible), .openSettings),
              (.unavailable(.appleIntelligenceNotEnabled), .openSettings),
              (.unavailable(.modelNotReady), .openSettings),
              (.invalidRequest("A pergunta está vazia."), .openSettings),
              (.emptyResponse, .retry),
              (.generationFailed("O modelo desistiu no meio."), .retry),
          ])
    func textAssistantErrorTable(
        error: TextAssistantError, expected: AssistantFailure.Recovery
    ) {
        let failure = AssistantFailure(error)
        #expect(failure.recovery == expected)
        #expect(!failure.message.isEmpty)
        #expect(failure.message == error.errorDescription)
    }

    @Test("todo caso de OpenAICompatibleTextAssistantError tem recuperação e frase própria",
          arguments: [
              (OpenAICompatibleTextAssistantError.missingAPIKey, AssistantFailure.Recovery.openSettings),
              (.missingOAuthAuthorization, .openSettings),
              (.oauthProviderUnavailable, .openSettings),
              (.authenticationFailed, .openSettings),
              (.rateLimited, .retry),
              (.timedOut, .retry),
              (.connectionFailed, .retry),
              (.server(statusCode: 500), .retry),
              (.invalidResponse, .retry),
          ])
    func openAICompatibleErrorTable(
        error: OpenAICompatibleTextAssistantError, expected: AssistantFailure.Recovery
    ) {
        let failure = AssistantFailure(error)
        #expect(failure.recovery == expected)
        #expect(!failure.message.isEmpty)
        #expect(failure.message == error.errorDescription)
    }

    /// A mesma linha vale duas vezes: sem provedor informado, o 401 não pode
    /// mandar reconectar uma conta que talvez nem seja a configurada — mas
    /// também não pode ficar sem botão. A saída anônima é Ajustes.
    @Test("todo caso de AssistantProviderOAuthTextAssistantError responde igual com e sem provedor",
          arguments: [
              (AssistantProviderOAuthTextAssistantError.missingAuthorization,
               AssistantFailure.Recovery.openSettings, AssistantFailure.Recovery.reconnect(.codex)),
              (.authenticationFailed, .openSettings, .reconnect(.codex)),
              (.subscriptionNotEligible, .openSettings, .reconnect(.codex)),
              (.managedByCodexRuntime, .openSettings, .reconnect(.codex)),
              (.rateLimited, .retry, .retry),
              (.timedOut, .retry, .retry),
              (.connectionFailed, .retry, .retry),
              (.redirectRefused, .retry, .retry),
              (.upgradeRequired, .retry, .retry),
              (.server(statusCode: 503), .retry, .retry),
              (.invalidResponse, .retry, .retry),
          ])
    func providerOAuthTextAssistantErrorTable(
        error: AssistantProviderOAuthTextAssistantError,
        semProvedor: AssistantFailure.Recovery,
        comProvedor: AssistantFailure.Recovery
    ) {
        let anonima = AssistantFailure(error)
        #expect(anonima.recovery == semProvedor)
        #expect(anonima.message == error.errorDescription)
        #expect(!anonima.message.isEmpty)
        #expect(AssistantFailure(error, provider: .codex).recovery == comProvedor)
    }

    @Test("todo caso de AssistantProviderOAuthError responde igual com e sem provedor",
          arguments: [
              (AssistantProviderOAuthError.missingSession,
               AssistantFailure.Recovery.openSettings, AssistantFailure.Recovery.reconnect(.xAI)),
              (.sessionProviderMismatch, .openSettings, .reconnect(.xAI)),
              (.authorizationDenied, .openSettings, .reconnect(.xAI)),
              (.authorizationExpired, .openSettings, .reconnect(.xAI)),
              (.invalidTokenResponse, .openSettings, .reconnect(.xAI)),
              (.invalidDiscovery, .retry, .retry),
              (.redirectRefused, .retry, .retry),
              (.deviceAuthorizationUnavailable, .retry, .retry),
              (.invalidDeviceAuthorization, .retry, .retry),
              (.rateLimited, .retry, .retry),
              (.timedOut, .retry, .retry),
              (.server(statusCode: 502), .retry, .retry),
          ])
    func providerOAuthErrorTable(
        error: AssistantProviderOAuthError,
        semProvedor: AssistantFailure.Recovery,
        comProvedor: AssistantFailure.Recovery
    ) {
        let anonima = AssistantFailure(error)
        #expect(anonima.recovery == semProvedor)
        #expect(anonima.message == error.errorDescription)
        #expect(!anonima.message.isEmpty)
        #expect(AssistantFailure(error, provider: .xAI).recovery == comProvedor)
    }

    @Test("todo caso de AssistantCLITextAssistantError tem recuperação e frase própria",
          arguments: [
              (AssistantCLITextAssistantError.executableNotFound(.codex),
               AssistantFailure.Recovery.openSettings),
              (.executableNotFound(.claude), .openSettings),
              (.executableNotAllowed, .openSettings),
              (.processFailed(exitCode: 1, stderrTail: ""), .openSettings),
              (.timedOut, .retry),
              (.outputTooLarge, .retry),
              (.invalidResponse, .retry),
          ])
    func cliErrorTable(
        error: AssistantCLITextAssistantError, expected: AssistantFailure.Recovery
    ) {
        let failure = AssistantFailure(error)
        #expect(failure.recovery == expected)
        #expect(!failure.message.isEmpty)
        #expect(failure.message == error.errorDescription)
    }

    @Test("cancelamento é da pessoa: frase própria e nenhum botão")
    func cancellationHasNoRecovery() {
        let failure = AssistantFailure(CancellationError())
        #expect(failure.message == "Pedido cancelado.")
        #expect(failure.recovery == nil)
    }

    @Test("erro sem descrição aproveitável não vira frase vazia")
    func unknownErrorHasCopy() {
        struct Silencioso: Error {}
        let failure = AssistantFailure(Silencioso())
        #expect(!failure.message.isEmpty)
        #expect(failure.recovery == .retry)
    }
}

@Suite("Faixa única de falha do assistente")
@MainActor
struct AssistantFailureBandTests {
    private func band(_ recovery: AssistantFailure.Recovery?) -> some View {
        AssistantFailureBand(
            failure: AssistantFailure(message: "O provedor recusou a credencial.", recovery: recovery)
        )
        .padding(12)
    }

    private func pixels(_ recovery: AssistantFailure.Recovery?, named name: String) throws -> Data {
        let image = try #require(Render.snapshot(
            band(recovery),
            named: name,
            size: CGSize(width: 360, height: 120), theme: .tinta
        ))
        return try #require(image.representation(using: .png, properties: [:]))
    }

    @Test("cada provedor tem o seu próprio rótulo de reconexão")
    func reconnectTitlePerKind() {
        #expect(AssistantFailureBand.reconnectTitle(.codex) == "Reconectar ChatGPT")
        #expect(AssistantFailureBand.reconnectTitle(.xAI) == "Reconectar xAI")
    }

    @Test("cada recuperação desenha uma faixa diferente, e nenhuma quebra")
    func drawsOnePerRecovery() throws {
        let retry = try pixels(.retry, named: "falha-assistente-tentar")
        let settings = try pixels(.openSettings, named: "falha-assistente-ajustes")
        let reconnect = try pixels(.reconnect(.xAI), named: "falha-assistente-reconectar")
        let semAcao = try pixels(nil, named: "falha-assistente-sem-acao")
        // Rótulos diferentes: se a faixa ignorasse a recuperação, seriam iguais.
        #expect(retry != settings)
        #expect(settings != reconnect)
        #expect(semAcao != retry)
    }
}
