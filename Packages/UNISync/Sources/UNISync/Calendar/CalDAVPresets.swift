import Foundation
import UNICore

/// Onde falar CalDAV com um provedor cujo IMAP a gente já conhece.
///
/// **É a mesma ideia do `ImapPresets`:** conveniência, nunca porteiro.
/// Hostinger e o IMAP genérico não têm CalDAV público — essas caixas ganham
/// um calendário OkamiUNI local. Zoho, Yahoo e Fastmail têm servidor de
/// agenda, e a senha de app do IMAP serve aqui.
public struct CalDAVPreset: Sendable, Hashable {
    public let name: String
    public let baseURL: URL
    public let allowedHosts: Set<String>

    public init(name: String, baseURL: URL, allowedHosts: Set<String>) {
        self.name = name
        self.baseURL = baseURL
        self.allowedHosts = allowedHosts
    }
}

public enum CalDAVPresets {
    public static let zoho = CalDAVPreset(
        name: "Zoho",
        baseURL: URL(string: "https://calendar.zoho.com")!,
        allowedHosts: [
            "calendar.zoho.com", "caldav.calendar.zoho.com",
            "calendar.zoho.eu", "caldav.calendar.zoho.eu",
            "calendar.zoho.in", "caldav.calendar.zoho.in",
        ]
    )

    public static let yahoo = CalDAVPreset(
        name: "Yahoo",
        baseURL: URL(string: "https://caldav.calendar.yahoo.com")!,
        allowedHosts: ["caldav.calendar.yahoo.com", "calendar.yahoo.com"]
    )

    public static let fastmail = CalDAVPreset(
        name: "Fastmail",
        baseURL: URL(string: "https://caldav.fastmail.com")!,
        allowedHosts: ["caldav.fastmail.com", "www.fastmail.com"]
    )

    /// Pelo host IMAP da conta, não pelo domínio do endereço: Zoho no domínio
    /// próprio continua em `imap.zoho.com`.
    public static func preset(for account: Account) -> CalDAVPreset? {
        let host = (account.imap?.host ?? account.host).lowercased()
        if host.contains("zoho") { return zoho }
        if host.contains("yahoo") || host.contains("ymail") { return yahoo }
        if host.contains("fastmail") { return fastmail }
        return nil
    }
}
