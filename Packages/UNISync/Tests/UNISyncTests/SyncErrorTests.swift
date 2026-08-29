import Foundation
import Testing
@testable import UNISync

@Suite("SyncError fala português e chega inteiro ao MailStore")
struct SyncErrorTests {
    @Test("Cada caso tem mensagem própria, nenhuma vazia, nenhuma repetida")
    func mensagensDistintas() {
        let casos: [SyncError] = [
            .rede("tempo esgotado"),
            .tls("certificado expirado"),
            .autenticacao,
            .autorizacaoRevogada,
            .quota,
            .servidor(codigo: 503, mensagem: "Service Unavailable"),
            .keychain(status: -25300),
            .semClientID,
            .resposta("BAD comando desconhecido"),
            .banco("disco cheio"),
        ]
        let mensagens = casos.map(\.mensagem)
        #expect(mensagens.allSatisfy { !$0.isEmpty })
        #expect(Set(mensagens).count == casos.count)
    }

    @Test("`localizedDescription` é a mensagem em português, não o nome do caso")
    func localizedDescriptionEmPortugues() {
        // É este texto que `MailStore.load()` grava em `loadError`. Sem
        // LocalizedError, o Foundation devolveria "The operation couldn’t be
        // completed. (UNISync.SyncError error 2.)" — erro engolido com outra
        // roupa.
        let erro: any Error = SyncError.autenticacao
        #expect(erro.localizedDescription == SyncError.autenticacao.mensagem)
        #expect(erro.localizedDescription.contains("senha"))
    }

    @Test("A mensagem do servidor carrega o código, para o relato não ser genérico")
    func mensagemDoServidorCitaOCodigo() {
        #expect(SyncError.servidor(codigo: 503, mensagem: "Service Unavailable").mensagem.contains("503"))
    }

    @Test("A falta do client ID aponta o roteiro, em vez de dizer só que falhou")
    func semClientIDApontaORoteiro() {
        #expect(SyncError.semClientID.mensagem.contains("docs/oauth-google.md"))
    }
}
