import Foundation
import UNICore

/// Um provedor cujo IMAP a gente já sabe de cor.
public struct ImapPreset: Sendable, Hashable {
    /// O nome que a janela mostra: "iCloud", "Zoho", "Fastmail".
    public let name: String
    /// O que vai para `Account.host` e aparece no chip em versalete da lateral.
    public let hostMark: String
    public let endpoint: ImapEndpoint
    /// Sempre em caixa baixa.
    public let domains: [String]

    public init(name: String, hostMark: String, endpoint: ImapEndpoint, domains: [String]) {
        self.name = name
        self.hostMark = hostMark
        self.endpoint = endpoint
        self.domains = domains
    }
}

/// A tabela de provedores conhecidos.
///
/// **É conveniência de preenchimento, nunca porteiro.** Um domínio fora desta
/// lista não é recusado: ele cai em `ProviderRoute.manual`, com
/// `imap.<domínio>:993` sugerido no formulário, que a pessoa corrige se
/// precisar. Nada aqui limita provedor ou domínio — a lista existe só para
/// poupar digitação de quem usa um dos casos comuns.
///
/// Consulta de MX **não** entra: rede no caminho da digitação é latência a cada
/// tecla, e a tabela mais o formulário manual já cobrem o mesmo espaço.
public enum ImapPresets {
    public static let all: [ImapPreset] = [
        ImapPreset(
            name: "iCloud", hostMark: "icloud",
            endpoint: ImapEndpoint(host: "imap.mail.me.com", port: 993, security: .tls),
            domains: ["icloud.com", "me.com", "mac.com"]
        ),
        ImapPreset(
            name: "Zoho", hostMark: "zoho",
            endpoint: ImapEndpoint(host: "imap.zoho.com", port: 993, security: .tls),
            domains: ["zoho.com", "zohomail.com"]
        ),
        ImapPreset(
            name: "Hostinger", hostMark: "hostinger",
            endpoint: ImapEndpoint(host: "imap.hostinger.com", port: 993, security: .tls),
            domains: ["hostinger.com"]
        ),
        ImapPreset(
            name: "Fastmail", hostMark: "fastmail",
            endpoint: ImapEndpoint(host: "imap.fastmail.com", port: 993, security: .tls),
            domains: ["fastmail.com", "fastmail.fm"]
        ),
        ImapPreset(
            name: "Outlook", hostMark: "outlook",
            endpoint: ImapEndpoint(host: "outlook.office365.com", port: 993, security: .tls),
            domains: ["outlook.com", "hotmail.com", "live.com"]
        ),
        ImapPreset(
            name: "Yahoo", hostMark: "yahoo",
            endpoint: ImapEndpoint(host: "imap.mail.yahoo.com", port: 993, security: .tls),
            domains: ["yahoo.com", "yahoo.com.br", "ymail.com"]
        ),
        ImapPreset(
            name: "UOL", hostMark: "uol",
            endpoint: ImapEndpoint(host: "imap.uol.com.br", port: 993, security: .tls),
            domains: ["uol.com.br", "bol.com.br"]
        ),
        ImapPreset(
            name: "Locaweb", hostMark: "locaweb",
            endpoint: ImapEndpoint(host: "imap.locaweb.com.br", port: 993, security: .tls),
            domains: ["locaweb.com.br"]
        ),
    ]

    private static let porDominio: [String: ImapPreset] = {
        var tabela: [String: ImapPreset] = [:]
        for preset in all {
            for dominio in preset.domains { tabela[dominio] = preset }
        }
        return tabela
    }()

    public static func preset(forDomain domain: String) -> ImapPreset? {
        porDominio[domain.lowercased()]
    }
}
