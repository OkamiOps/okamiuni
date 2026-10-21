import Foundation

/// A credencial do mecanismo SASL `XOAUTH2`, montada como texto puro.
///
/// Mora aqui, do lado do IMAP, pelo mesmo acordo que pôs `SmtpEndpoint.Security`
/// emprestado de `ImapEndpoint`: o IMAP é quem estreia o mecanismo, o SMTP usa
/// **a mesma string** byte por byte, e duas funções — uma em cada `Wire` —
/// seriam duas chances de errar o separador e um defeito que só aparece no
/// envio, nunca na leitura.
///
/// O formato é o do XOAUTH2 original do Google, adotado tal e qual pelo Zoho
/// (`https://www.zoho.com/mail/help/sasl-xoauth2-smtp-imap-pop-protocol-exchange.html`):
///
///     base64("user=" + endereço + \u{01} + "auth=Bearer " + token + \u{01} + \u{01})
///
/// **O separador é `0x01`, e não um espaço nem uma vírgula.** Ele é invisível
/// em qualquer log e em qualquer editor, então um erro aqui não se vê: o
/// servidor recusa com `Invalid credentials` e a pessoa passa a tarde achando
/// que o login dela é que está errado. Daí esta função ser pura, pequena e ter
/// teste próprio que confere os bytes depois do base64.
public enum SASLXOAuth2 {
    /// O byte `^A` que o RFC do mecanismo chama de `CTRL+A`.
    static let separator = "\u{01}"

    /// A resposta inicial, já em base64 — o que vai depois de
    /// `AUTHENTICATE XOAUTH2` (IMAP) ou de `AUTH XOAUTH2` (SMTP).
    public static func initialResponse(user: String, accessToken: String) -> String {
        let bruto = "user=\(user)\(separator)auth=Bearer \(accessToken)\(separator)\(separator)"
        return Data(bruto.utf8).base64EncodedString()
    }
}
