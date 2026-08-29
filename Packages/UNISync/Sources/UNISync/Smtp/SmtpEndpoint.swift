import Foundation
import UNICore

/// Onde fica o servidor de envio de uma conta.
///
/// Mesma forma do `ImapEndpoint`, e de propósito: as duas pontas do mesmo
/// provedor têm as mesmas três perguntas (host, porta, como o TLS entra), e um
/// tipo próprio para cada uma faria a segunda copiar as decisões da primeira.
/// `Security` é reaproveitada de `ImapEndpoint` pela mesma razão.
public struct SmtpEndpoint: Sendable, Hashable {
    public let host: String
    public let port: Int
    public let security: ImapEndpoint.Security

    public init(host: String, port: Int, security: ImapEndpoint.Security) {
        self.host = host
        self.port = port
        self.security = security
    }

    /// A porta 465 é TLS implícito por definição (o "SMTPS" histórico, de volta
    /// como padrão em RFC 8314), e a 587 é submissão com `STARTTLS`
    /// obrigatório. Quem monta um endpoint à mão não precisa decorar isso.
    public static func submission(host: String) -> SmtpEndpoint {
        SmtpEndpoint(host: host, port: 587, security: .startTLS)
    }
}

/// De onde sai o servidor de envio quando ninguém o digitou.
///
/// **É derivação, nunca porteiro** — a mesma regra do `ImapPresets`. O app não
/// tem (ainda) campo de SMTP no formulário de conta, e inventar um agora seria
/// pedir à pessoa uma informação que dá para acertar sozinho em praticamente
/// todo provedor: o host de envio é o de leitura com `imap` trocado por `smtp`.
/// A tabela cobre os poucos casos em que essa troca não vale.
///
/// O valor derivado é **guardável por conta** no futuro sem nada mudar aqui:
/// quem chamar `endpoint(for:)` com um endpoint já gravado passa a receber o
/// gravado, e esta função vira o padrão de quem não tem um.
public enum SmtpDiscovery {
    /// Os hosts em que trocar o prefixo não dá o servidor certo.
    private static let excecoes: [String: String] = [
        "outlook.office365.com": "smtp.office365.com",
        "imap.gmail.com": "smtp.gmail.com",
    ]

    /// O servidor de envio de uma conta IMAP, ou `nil` quando ela não tem
    /// servidor de leitura para derivar de.
    public static func endpoint(forImap imap: ImapEndpoint?) -> SmtpEndpoint? {
        guard let imap else { return nil }
        let host = imap.host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return nil }
        return .submission(host: excecoes[host] ?? derivaHost(host))
    }

    /// `imap.exemplo.com` → `smtp.exemplo.com`; `mail.exemplo.com` fica como
    /// está (é o host genérico que serve os dois, e um `smtp.mail.…` não
    /// existiria); um host qualquer ganha o prefixo `smtp.`.
    ///
    /// O terceiro caso é o que atende quem digitou o servidor à mão: o palpite
    /// é o mesmo que o formulário de conta já dá para o IMAP, do outro lado.
    static func derivaHost(_ host: String) -> String {
        if host.hasPrefix("imap.") { return "smtp." + host.dropFirst("imap.".count) }
        if host.hasPrefix("mail.") || host.hasPrefix("smtp.") { return host }
        return "smtp." + host
    }
}
