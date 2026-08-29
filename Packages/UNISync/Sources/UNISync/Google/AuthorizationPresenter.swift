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
            // O completion do `ASWebAuthenticationSession` chega numa fila de
            // fundo do XPC, não na principal. A closure precisa nascer AQUI,
            // `@Sendable` e fora do `Task { @MainActor }` — lá dentro ela
            // herdaria o isolamento do MainActor e o runtime derrubaria o app
            // na checagem (`dispatch_assert_queue_fail`, SIGTRAP) no momento
            // em que o login termina.
            let completa: @Sendable (URL?, Error?) -> Void = { callback, erro in
                continuation.resume(with: Self.traduz(callback, erro))
            }
            Task { @MainActor in
                let sessao = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme,
                    completionHandler: completa
                )
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

    /// O que o retorno do navegador significa. Pura e `nonisolated` de
    /// propósito: é chamada da fila do XPC, e a classe inteira é inferida
    /// `@MainActor` pela conformance ao provedor de âncora.
    nonisolated static func traduz(_ callback: URL?, _ erro: Error?) -> Result<URL, SyncError> {
        if let callback {
            return .success(callback)
        }
        if let erro = erro as? ASWebAuthenticationSessionError,
           erro.code == .canceledLogin {
            return .failure(.autorizacaoRevogada)
        }
        return .failure(.rede(
            erro?.localizedDescription ?? "a janela de autorização fechou sem resposta"
        ))
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
