import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// A faixa "A conta precisa de atenção" deixa de ter uma saída destrutiva só.
///
/// Antes desta task ela oferecia "Ver o roteiro" e "Remover conta…", e mais
/// nada — e remover apaga 1.446 mensagens locais e uma fila de saída com item
/// pendente. A queixa do dono foi essa: "eu tenho que remover a minha conta
/// toda e adicionar de novo?"
@Suite("A faixa de atenção oferece reconectar")
struct ReconnectBandTests {

    @Test("credencial recusada: Reconectar é a ação primária, e Remover continua lá")
    func reconectarEPrimaria() {
        let acoes = AccountsCopy.actions(for: status(erro: .autenticacao))
        #expect(acoes.first == .reconnect(.autenticacao))
        #expect(acoes.first?.label == "Reconectar")
        #expect(AccountsCopy.primary(for: status(erro: .autenticacao)) == .reconnect(.autenticacao))
        // A saída destrutiva não sumiu: ela deixou de ser a única.
        #expect(acoes.contains(.remove))
        #expect(acoes.count > 1)
    }

    @Test("autorização revogada também reconecta")
    func revogadaReconecta() {
        let acoes = AccountsCopy.actions(for: status(erro: .autorizacaoRevogada))
        #expect(acoes.first == .reconnect(.autorizacaoRevogada))
    }

    @Test("falta de Client ID não oferece Reconectar, e a faixa diz por quê")
    func semClientIDNaoReconecta() {
        let quebrada = status(erro: .semClientID)
        let acoes = AccountsCopy.actions(for: quebrada)
        #expect(!acoes.contains { $0.id == "reconnect" })
        #expect(acoes.first == .openRoteiro)
        // E a faixa **explica** em vez de calar: o botão que não pode
        // funcionar não aparece, mas a razão de ele não aparecer, sim.
        let nota = AccountsCopy.reconnectBlockedNote(for: quebrada)
        #expect(nota != nil)
        #expect(nota?.contains("aplicativo") == true)
    }

    @Test("conta sã não tem nota nenhuma nem ação primária de conserto")
    func contaSaNaoTemNota() {
        let boa = status(erro: nil)
        #expect(AccountsCopy.reconnectBlockedNote(for: boa) == nil)
        #expect(AccountsCopy.primary(for: boa) == nil)
    }

    @Test("a rota da reconexão segue o provedor da conta")
    func rotaSegueOProvedor() {
        #expect(AccountsCopy.reconnectRoute(for: status(erro: .autenticacao, provider: .gmail)) == .google)
        #expect(AccountsCopy.reconnectRoute(for: status(erro: .autenticacao, provider: .imap)) == .imapForm)
        // Sem causa que peça reconexão, não há rota nenhuma a seguir.
        #expect(AccountsCopy.reconnectRoute(for: status(erro: .semClientID, provider: .gmail)) == nil)
    }

    private func status(
        erro: SyncError?, provider: Account.Provider = .gmail
    ) -> AccountStatus {
        AccountStatus(
            accountID: "conta-a", address: "marcos@okamiops.com", hostMark: "okamiops",
            state: erro == nil ? .ativa : .erroDeAutenticacao,
            messageCount: 1_446, lastSyncedAt: nil,
            error: erro, progress: nil, pendingOperations: erro == nil ? 0 : 1,
            provider: provider,
            imap: provider == .imap
                ? ImapEndpoint(host: "imap.okamiops.com", port: 993, security: .tls)
                : nil
        )
    }
}
