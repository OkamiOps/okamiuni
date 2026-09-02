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
        #expect(AssistantFailure(AssistantProviderOAuthTextAssistantError.authenticationFailed).recovery == nil)
        #expect(AssistantFailure(AssistantProviderOAuthError.missingSession).recovery == nil)
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

    /// Enquanto `processFailed` não carrega o stderr (Task 11), a regra de
    /// recorte é verificada direto no ajudante que a implementa.
    @Test("do stderr do CLI só a primeira linha vira mensagem")
    func cliMessageKeepsFirstStderrLine() {
        let message = AssistantFailure.cliMessage(
            base: "O CLI de IA não concluiu a resposta.",
            stderrTail: "error: not logged in\nrun `codex login`"
        )
        #expect(message.contains("error: not logged in"))
        #expect(!message.contains("codex login"))
        // Cauda vazia não deixa a frase com sobra de espaço.
        #expect(AssistantFailure.cliMessage(base: "Falhou.", stderrTail: "  \n ") == "Falhou.")
    }

    @Test("o CLI que morreu mostra a primeira linha do stderr",
          .disabled("stderr chega na Task 11"))
    func cliFailureShowsStderr() {
        let failure = AssistantFailure(AssistantCLITextAssistantError.processFailed)
        // Passa quando `processFailed` passar a carregar `stderrTail`.
        #expect(failure.message.contains("error: not logged in"))
        #expect(failure.recovery == .openSettings)
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
