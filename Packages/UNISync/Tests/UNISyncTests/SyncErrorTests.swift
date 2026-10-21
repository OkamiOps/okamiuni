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
            .loginRecusado(resposta: "[ALERT] Remote IMAP access is disabled"),
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
        // A frase fala da credencial — em **qualquer** dos quatro idiomas. O
        // `contains("senha")` que estava aqui só passava enquanto a chave não
        // existia no catálogo e a tradução caía de volta na chave em
        // português: o processo de teste resolve o idioma pelo
        // `Locale.preferredLanguages` da máquina, que não é escolha nossa.
        #expect(["senha", "password", "Passwort", "mot de passe"].contains {
            erro.localizedDescription.localizedCaseInsensitiveContains($0)
        })
    }

    @Test("A mensagem do servidor carrega o código, para o relato não ser genérico")
    func mensagemDoServidorCitaOCodigo() {
        #expect(SyncError.servidor(codigo: 503, mensagem: "Service Unavailable").mensagem.contains("503"))
    }

    @Test("A falta do client ID aponta o roteiro, em vez de dizer só que falhou")
    func semClientIDApontaORoteiro() {
        #expect(SyncError.semClientID.mensagem.contains("docs/oauth-google.md"))
    }

    @Test("A recusa de login repete o que o servidor disse, palavra por palavra")
    func loginRecusadoCitaOServidor() {
        // "Remote IMAP access is disabled for this account" pede ligar o IMAP
        // no painel do provedor; "Invalid credentials" pede reler a senha.
        // Traduzir as duas pela mesma frase genérica — o que esta folha fez
        // durante toda a vida dela — manda a pessoa fazer a coisa errada.
        let dito = "[ALERT] Remote IMAP access is disabled for this account"
        #expect(SyncError.loginRecusado(resposta: dito).mensagem.contains(dito))
        #expect(SyncError.loginRecusado(resposta: dito).mensagem != SyncError.autenticacao.mensagem)
    }

    @Test("Recusa de login pede reconexão, como a autenticação pede")
    func loginRecusadoPedeReconexao() {
        // Ela é uma `.autenticacao` com legenda: a ação que resolve é a mesma,
        // e um caso novo que não dissesse isso daria à conta o botão errado.
        #expect(SyncError.loginRecusado(resposta: "NO").pedeReconexao)
    }
}
