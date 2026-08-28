import Foundation

public enum OAuthCallback {
    /// O `code` do redirect, conferindo o `state`.
    ///
    /// A conferência do `state` não é burocracia: sem ela, qualquer coisa
    /// capaz de abrir uma URL `com.okamiops.okamiuni:/oauth?code=…` na máquina
    /// injetaria um código de autorização de **outra** conta no nosso fluxo, e
    /// o app conectaria a caixa de outra pessoa achando que era a sua.
    public static func code(from url: URL, expectedState: String) throws -> String {
        guard let itens = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw SyncError.resposta("O redirect do Google veio sem parâmetros.")
        }
        func valor(_ nome: String) -> String? { itens.first { $0.name == nome }?.value }

        if let erro = valor("error") {
            // `access_denied` é o usuário clicando "Cancelar" ou não estando na
            // lista de testadores — os dois pedem a mesma ação: reconectar.
            if erro == "access_denied" { throw SyncError.autorizacaoRevogada }
            throw SyncError.resposta("O Google recusou a autorização: \(erro).")
        }
        guard valor("state") == expectedState else {
            throw SyncError.resposta("O redirect do Google veio com um `state` que não é o nosso.")
        }
        guard let code = valor("code"), !code.isEmpty else {
            throw SyncError.resposta("O redirect do Google veio sem código de autorização.")
        }
        return code
    }
}
