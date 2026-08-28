import AuthenticationServices
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Quem abre o navegador e devolve o redirect.
///
/// É porta, e não chamada direta, por dois motivos: nenhum teste pode abrir um
/// navegador, e o ensaio `--ensaiar-contas` precisa percorrer o fluxo Google
/// inteiro sem sair da máquina. `WebAuthorizationPresenter` é o de verdade;
/// `StubAuthorizationPresenter` é o dos testes e do ensaio.
public protocol AuthorizationPresenter: Sendable {
    func authorize(url: URL, callbackScheme: String) async throws -> URL
}

/// `ASWebAuthenticationSession`: a sessão do sistema, com a barra que mostra o
/// domínio real ao usuário. **Não é uma WebView nossa** — o Google recusa
/// consentimento em WebView embarcada, e com razão: numa WebView nossa o app
/// enxergaria a senha digitada.
public final class WebAuthorizationPresenter:
    NSObject, AuthorizationPresenter,
    ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {

    /// A sessão viva. Guardada porque `ASWebAuthenticationSession` é
    /// desalocada — e cancelada — se ninguém a segurar.
    private var session: ASWebAuthenticationSession?

    public override init() { super.init() }

    public func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let sessao = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme
                ) { callback, erro in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if let erro = erro as? ASWebAuthenticationSessionError,
                              erro.code == .canceledLogin {
                        continuation.resume(throwing: SyncError.autorizacaoRevogada)
                    } else {
                        continuation.resume(throwing: SyncError.rede(
                            erro?.localizedDescription ?? "a janela de autorização fechou sem resposta"
                        ))
                    }
                }
                sessao.presentationContextProvider = self
                // Sessão **não** efêmera: reconectar uma conta que o navegador
                // já conhece não deve exigir digitar a senha do Google de novo.
                sessao.prefersEphemeralWebBrowserSession = false
                self.session = sessao
                guard sessao.start() else {
                    continuation.resume(throwing: SyncError.rede(
                        "não foi possível abrir a janela de autorização"
                    ))
                    return
                }
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

/// O apresentador dos testes e do ensaio: devolve o redirect que o roteiro
/// mandar, sem abrir nada.
public struct StubAuthorizationPresenter: AuthorizationPresenter {
    private let redirect: @Sendable (URL) throws -> URL

    public init(redirect: @Sendable @escaping (URL) throws -> URL) {
        self.redirect = redirect
    }

    public func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try redirect(url)
    }
}
