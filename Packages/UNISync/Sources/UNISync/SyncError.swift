import Foundation

/// O único tipo de erro que sai do `UNISync`.
///
/// Único de propósito: toda superfície que mostra uma conta mostra o erro dela
/// com uma ação, e uma superfície só consegue fazer isso se souber a lista
/// inteira de coisas que podem dar errado. Um `Error` opaco vindo do
/// `URLSession` ou do `NIOSSL` obrigaria a UI a escrever "algo deu errado" —
/// que é erro engolido com boa apresentação.
///
/// `LocalizedError` não é enfeite: `MailStore.load()` grava
/// `error.localizedDescription` em `loadError`, e sem esta conformidade o
/// Foundation devolveria "The operation couldn’t be completed."
public enum SyncError: Error, Sendable, Hashable, LocalizedError {
    /// Não chegou ao servidor: sem rota, tempo esgotado, DNS.
    case rede(String)
    /// Chegou, mas o TLS não fechou: certificado, versão, `STARTTLS` recusado.
    case tls(String)
    /// O servidor entendeu e recusou as credenciais.
    case autenticacao
    /// O usuário negou o consentimento, ou revogou o acesso depois.
    case autorizacaoRevogada
    /// O provedor pediu para desacelerar (HTTP 429, `[THROTTLED]` no IMAP).
    case quota
    /// O servidor respondeu com falha própria.
    case servidor(codigo: Int, mensagem: String)
    /// O Keychain recusou. `status` é o `OSStatus` cru, para o relato ter o que
    /// procurar; a mensagem já vem traduzida.
    case keychain(status: Int32)
    /// Falta o OAuth Client ID do Google no bundle. Ver `docs/oauth-google.md`.
    case semClientID
    /// A resposta chegou e não dá para entender — JSON fora do contrato,
    /// `BAD` do IMAP, redirect sem `code` nem `error`.
    case resposta(String)

    /// A frase que o usuário lê. Uma por caso, nenhuma genérica: "erro de
    /// rede" e "senha recusada" pedem ações diferentes, e uma frase só para as
    /// duas manda a pessoa tentar a coisa errada.
    public var mensagem: String {
        switch self {
        case .rede(let detalhe):
            "Não foi possível falar com o servidor: \(detalhe). Verifique a conexão e tente de novo."
        case .tls(let detalhe):
            "A conexão segura falhou: \(detalhe). Confira a porta e a forma de TLS da conta."
        case .autenticacao:
            "O servidor recusou o endereço ou a senha. Em provedores com verificação em duas etapas, use uma senha de app."
        case .autorizacaoRevogada:
            "Autorização negada ou revogada. Reconecte a conta para autorizar de novo."
        case .quota:
            "O provedor pediu para desacelerar. A carga continua sozinha em instantes."
        case .servidor(let codigo, let mensagem):
            "O servidor respondeu \(codigo): \(mensagem)."
        case .keychain(let status):
            "Não foi possível guardar o segredo no Keychain (código \(status))."
        case .semClientID:
            "Falta o OAuth Client ID do Google. Siga docs/oauth-google.md e rode xcodegen generate."
        case .resposta(let detalhe):
            "Resposta inesperada do servidor: \(detalhe)."
        }
    }

    public var errorDescription: String? { mensagem }
}
